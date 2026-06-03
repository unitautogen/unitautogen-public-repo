# DESIGN: v0.10 — Predicate-Aware Data-Shape Seeding

Status: DRAFT (2026-06-02, rev 4 — open questions resolved; implementation started)
Targets: PowerShell module v0.10.0 + framework v11.1
Author: Munaf Khatri (draft prepared with Claude)
Related decision: [DECISION_v0_10_Parser_Choice.md](DECISION_v0_10_Parser_Choice.md)

---

## 1. Problem

The v11 seeder reaches value-gated branches by predicate inversion on
parameter comparisons (e.g. `IF @x = 5`). It does NOT engineer the
**contents of tables** to satisfy data-shape predicates such as:

```sql
IF (SELECT COUNT(*) FROM Students WHERE Active = 1) = 2 ...
IF EXISTS (SELECT 1 FROM Orders WHERE CustomerId = @CustId) ...
IF (SELECT SUM(Amount) FROM Sales WHERE Year = @Y) > 1000000 ...
```

These branches show as uncovered. Real production code uses them
heavily — they are gate checks, validation guards, and threshold tests.
The first real-world (non-reference-database) adoption surfaced them
immediately.

## 2. Goal

A single coverage run reaches every branch whose data-shape predicate
the parser recognises, AND marks as `NOT_TESTABLE` (with the verbatim
predicate text in the explanation) any branch whose predicate falls
outside the recognised grammar (UDF call inside the predicate,
recursive CTE, window function, etc.).

## 3. Architecture: ScriptDom parser in PowerShell, case-analysis seeder in SQL

Two layers, both built in full in v0.10.0. No staged scope.

The parser runs in PowerShell (via `Microsoft.SqlServer.TransactSql.ScriptDom`)
and produces structured `ParsedPredicate` rows that it writes into a
SQL staging table. The seeder runs in T-SQL (as it always would) and
reads from that staging table. See
[DECISION_v0_10_Parser_Choice.md](DECISION_v0_10_Parser_Choice.md) for
the rationale (build-time savings, grammar correctness ceiling,
acquirer optics, reversibility).

### 3.1 Parser layer — ScriptDom in PowerShell

New PowerShell file: `powershell/UnitAutogen/Get-ParsedPredicates.ps1`.

Flow:
1. Read procedure body from `sys.sql_modules`.
2. Parse via `TSql160Parser` (or version matching compat level).
3. Walk the AST. For each `IfStatement`, `WhileStatement`, and
   `CaseExpression`, extract the predicate and decompose:
   - Identify shape: `EXISTS`, `NOT EXISTS`, scalar subquery,
     aggregate subquery (with aggregate function name)
   - Extract target tables from the subquery's FROM (single table
     or `QualifiedJoin` chain)
   - Walk the WHERE clause AST: column refs, literals, parameter
     refs, variable refs, AND/OR composition, parenthesised sub-predicates
   - Extract comparator (`=`, `<>`, `!=`, `<`, `<=`, `>`, `>=`,
     `IS NULL`, `IS NOT NULL`, `IN (...)`, `NOT IN (...)`,
     `BETWEEN ... AND ...`)
   - Extract comparand (literal, parameter, variable, expression)
4. Emit `ParsedPredicate` rows into `TestGen.PredicateInbox`.

Grammar recognised (full ScriptDom coverage, no exclusions in
v0.10.0): subquery extraction, aggregate functions (`COUNT`, `SUM`,
`MIN`, `MAX`, `AVG`), full comparator set, EXISTS / NOT EXISTS,
scalar subqueries, multi-table joins (`INNER`, `LEFT`, `RIGHT`,
`CROSS`), nested AND/OR WHERE composition, CASE arms (each WHEN as
a separate `ParsedPredicate`), parameter/variable resolution to
declared types.

ScriptDom additionally handles for free, with no extra work on our
side: block comments and nested comments, bracketed and quoted
identifiers, multi-line string literals, CTEs and recursive CTEs,
window functions, operator precedence, compatibility-level-aware
dialect quirks. These close most of the v10.0.8 robustness backlog
as a side effect of adopting ScriptDom.

Predicates whose semantic content falls outside what the seeder can
satisfy (scalar UDF call inside the predicate body, table-valued
function in the FROM clause that the seeder can't faketable) get
`Shape = UNRECOGNISED` with the verbatim predicate text. ScriptDom
itself parses them — we simply choose not to seed them. The test
generator turns those into the `NOT_TESTABLE` fallthrough.

### 3.1.1 PredicateInbox staging table

```sql
CREATE TABLE TestGen.PredicateInbox (
    InboxId         INT IDENTITY(1,1) PRIMARY KEY,
    SchemaName      SYSNAME      NOT NULL,
    ProcName        SYSNAME      NOT NULL,
    BranchId        INT          NOT NULL,
    Shape           VARCHAR(32)  NOT NULL,  -- EXISTS, NOT_EXISTS,
                                            -- SCALAR_CMP, SCALAR_NULL,
                                            -- AGG_COUNT, AGG_SUM, AGG_MIN,
                                            -- AGG_MAX, AGG_AVG, UNRECOGNISED
    AggregateColumn SYSNAME      NULL,
    Comparator      VARCHAR(16)  NULL,
    Comparand       NVARCHAR(MAX) NULL,
    TargetTablesJson NVARCHAR(MAX) NOT NULL,
    JoinsJson       NVARCHAR(MAX) NULL,
    WhereAstJson    NVARCHAR(MAX) NULL,
    PredicateText   NVARCHAR(MAX) NOT NULL,
    RunId           UNIQUEIDENTIFIER NOT NULL
);
```

The PowerShell parser populates one row per branch. The seeder reads
by `(SchemaName, ProcName, RunId)`. JSON is used for nested AST data
to keep the table flat and avoid a parallel structure of child tables.

### 3.2 Seeder layer — one case-analysis procedure

The seeder is a single procedure: `TestGen.SatisfyPredicate(parsed,
direction)`. It does case analysis on the `ParsedPredicate` and emits
the T-SQL that, when run before the procedure under test, makes the
predicate evaluate to `direction`.

The cases:

| Predicate shape | Direction TRUE | Direction FALSE |
| --- | --- | --- |
| `EXISTS (...)` | INSERT 1 row satisfying WHERE | leave faked table empty |
| `NOT EXISTS (...)` | leave empty | INSERT 1 row satisfying WHERE |
| `COUNT(*) = N` | INSERT N matching rows | INSERT N+1 matching rows |
| `COUNT(*) > N` / `>= N` | INSERT N+1 (or N) matching rows | INSERT 0 matching rows |
| `COUNT(*) < N` / `<= N` | INSERT N-1 (or N) matching rows | INSERT N+1 matching rows |
| `COUNT(*) <> N` | INSERT N+1 matching rows | INSERT N matching rows |
| `COUNT(*) IN (...)` | INSERT first list value matching rows | INSERT value not in list |
| `COUNT(*) BETWEEN A AND B` | INSERT A matching rows | INSERT A-1 (or B+1) matching rows |
| `SUM(col) op N` | INSERT 1 row with col chosen to satisfy op | INSERT 1 row with col chosen to violate |
| `MIN(col) op N` | INSERT rows with col on satisfying side; if `op` is `<`/`<=` only 1 row needed | INSERT 1 row on violating side |
| `MAX(col) op N` | INSERT 1 row with col on satisfying side | INSERT rows with col on violating side |
| `AVG(col) op N` | INSERT 1 row with col on satisfying side (mean of 1 = value) | symmetric |
| `(SELECT col FROM ... WHERE) = v` | INSERT 1 row with col=v | INSERT 1 row with col<>v |
| `(SELECT col FROM ... WHERE) IS NULL` | leave faked table empty (scalar returns NULL) | INSERT 1 matching non-null row |
| `(SELECT col FROM ... WHERE) IS NOT NULL` | INSERT 1 matching non-null row | leave empty |
| Multi-join inside subquery | INSERT one satisfying row per joined table such that JOIN predicates + outer WHERE hold | violate by omitting one or by inserting non-matching row in one |
| CASE arm | parser emits one `ParsedPredicate` per WHEN; recurse | recurse |
| `Shape = UNRECOGNISED` | (not emitted as a test — see 4.2) | (not emitted as a test — see 4.2) |

The seeder reuses the existing identity / PK / computed / rowversion
exclusion helper for INSERT scripts (the v9.2 lesson applies).

### 3.3 Why no registry

A strategy-registry pattern adds value only when (a) strategies will
be added incrementally over time or (b) users will be customising
which strategies run. Neither applies here — v0.10.0 builds the full
case-analysis table above in one shot, and the framework doesn't
expose a customisation surface. The registry would have been
indirection without benefit.

## 4. Test class structure

### 4.1 Per-direction variants

Each branch with a recognised predicate produces two test bodies in
the generated tSQLt test class:

- `test_<ProcName>_Branch<N>_True` — seed engineered so the
  predicate is TRUE on entry, procedure executes the true arm
- `test_<ProcName>_Branch<N>_False` — seed engineered so the
  predicate is FALSE on entry, procedure executes the false arm

For multi-arm CASE (each WHEN), one test per arm.

### 4.2 NOT_TESTABLE branches

Branches whose parser shape is `UNRECOGNISED` emit a single placeholder
test that fails fast with `tSQLt.Fail` carrying the verbatim predicate
text:

```sql
EXEC tSQLt.Fail 'NOT_TESTABLE branch 7: predicate text
"(SELECT dbo.MyUdf(@x) FROM Sales WHERE ...) > 1000" —
contains a construct outside the v0.10 predicate grammar
(scalar UDF call). Hand-author via EnsureCustomTestClass to
close this branch.';
```

This:
- Keeps the test class structurally consistent (every branch has a row)
- Surfaces the exact predicate text in the test report
- Gives the developer the verbatim predicate to hand-author against
- Shows up in JUnit XML output for CI visibility

### 4.3 Coverage report semantics

NOT_TESTABLE branches mark as `hits="0"` in the Cobertura XML
(genuinely uncovered) and are annotated in the HTML report with a
tooltip `NOT_TESTABLE: <verbatim predicate>` so the user sees the
distinction between "ran but didn't reach this branch" (genuine code
path gap) vs "framework couldn't parse the predicate" (capability
gap).

## 5. Engineering plan

### 5.1 Module layout

New files in the framework SQL:

- `modules/31_PredicateInbox_v1.sql` — staging table + helpers
  (per §3.1.1)
- `modules/32_Seeder_v1.sql` — single case-analysis seeder
  (`TestGen.SatisfyPredicate`), reads from `PredicateInbox`
- `modules/33_Predicate_TestGen_v1.sql` — integration into the test
  generator (per-direction variants, NOT_TESTABLE emission)

New file in the PowerShell module:

- `powershell/UnitAutogen/Get-ParsedPredicates.ps1` — ScriptDom-based
  parser. Loads `Microsoft.SqlServer.TransactSql.ScriptDom.dll` (NuGet),
  walks the AST, writes `ParsedPredicate` rows into the staging table.

The existing `04_Test_Generator_v3.sql` calls into the new SQL modules
at the branch-handling site. The existing `Invoke-UnitAutogen` cmdlet
calls `Get-ParsedPredicates` before kicking off generation. Touch
points minimised.

### 5.1.1 ScriptDom dependency packaging

The ScriptDom NuGet package (`Microsoft.SqlServer.TransactSql.ScriptDom`)
ships the DLL. Two packaging options:

- **Bundle** the DLL inside the PowerShell module folder (added to
  `FileList` in `UnitAutogen.psd1`). Module is self-contained; users
  don't manage the dependency. Increases module size by ~2 MB.
- **Declare** it as an external module dependency via
  `RequiredAssemblies` or `ExternalModuleDependencies`. Users install
  via `Install-Module` or NuGet. Smaller PSGallery footprint.

Recommend bundle for v0.10.0 — zero-friction install matters more
than 2 MB of disk for a tool whose audience values "just works."

**Version policy (decided during implementation, 2026-06-02): latest, not
just available.** ScriptDom DLLs are cumulative and backward-compatible — the
latest assembly contains every `TSqlNNNParser` (80→170), so it parses every
older dialect *plus* the newest syntax. An older DLL simply lacks the newer
parser classes and would under-parse current SQL. Therefore:

- `Get-ParsedPredicates.ps1` enumerates **all** candidate DLLs and loads the one
  with the **highest file version**, not the first found.
- It auto-selects the **highest `TSqlNNNParser`** the loaded assembly exposes
  (an explicit `-ParserVersion` still wins).
- In DB mode it reads the database `compatibility_level` and **warns** if the
  loaded ScriptDom's top parser is older than that level — the staleness signal
  that says "install a newer ScriptDom."

Nuance: the public NuGet `Microsoft.SqlServer.TransactSql.ScriptDom` is on the
`161.x` train (tops out at `TSql160Parser` / SQL 2022), whereas the **SqlServer
PowerShell module 22.x** ships ScriptDom `17.0.x` which includes
`TSql170Parser` (SQL 2025). So "latest" means *highest available across all
sources*, which today is the module's 17.x — not the NuGet package. The bundle,
when cut for release, should therefore source the newest ScriptDom that carries
the highest `TSqlNNNParser`, refreshed each release.

### 5.2 Validation databases

Three regression targets:

1. **AdventureWorks2025** — existing reference DB. Goal: no regression
   on the 94.9% line / 94.4% branch baseline. Stretch: pick up any
   branches that were uncovered due to data-shape predicates.
2. **Synthetic `PredicateZoo`** — new examples database in the repo
   with one procedure per recognised predicate shape (full
   case-analysis matrix from 3.2) plus a handful of
   `UNRECOGNISED`-grammar procedures. Hand-built, deterministic, fast.
   Lives at `examples/PredicateZoo/`.
3. **EIN colleague's database (sanitised)** — if the colleague consents
   to a sanitised version (or to running locally and reporting numbers),
   real-world validation. Otherwise treat as out-of-tree integration
   test that we ask the colleague to run before release.

### 5.3 Time estimate (4h/day cap, ScriptDom adopted)

| Phase | Days | Calendar |
| --- | --- | --- |
| ScriptDom feasibility spike (gating) | 0.25 | wk 1 day 1 |
| Parser implementation (AST → ParsedPredicate) | 2-3 | wk 1 |
| PredicateInbox staging table + sync | 1 | wk 2 |
| Single case-analysis seeder | 4-5 | wk 2 |
| Test generator integration + per-direction variants | 4-5 | wk 3 |
| NOT_TESTABLE diagnostic flow + report integration | 2-3 | wk 3 |
| AdventureWorks regression + PredicateZoo validation | 3 | wk 4 |
| Bug iteration | 2-3 | wk 4 |
| Docs + release notes | 2 | wk 4 |

**Total: ~3.5 calendar weeks at 4h/day → v0.10.0 candidate late June
2026.** (Down from 5 weeks in rev 2 — ScriptDom collapses parser
build and sharply reduces edge-case bug iteration.)

Phase 2 outreach work runs in parallel — the build doesn't block
LinkedIn outreach, Simple Talk article, or marketplace extension work.

### 5.4 Versioning

- v0.9.5 — current production, operational fixes only
- v0.10.0 — this design (ScriptDom parser + full case-analysis seeder)
  - ScriptDom already parses recursive CTEs, window functions, scalar
    UDF calls etc., so future expansion is seeder-side only
- v0.11.0 — extending the seeder to satisfy additional shapes (e.g.
  scalar UDF predicates if we figure out a way to engineer the UDF
  return; multi-join WHERE with cross-table predicate composition if
  open question 5 fences it out for v0.10.0)
- v0.10 SQL-only install — continues to deliver v9.x semantics; the
  predicate-aware seeding is a PowerShell-flow feature

## 6. Open questions — RESOLVED (2026-06-02, rev 4)

All five settled before parser/seeder implementation. Decisions locked
below; the rationale is kept so the choices are auditable.

1. **Naming for the generated test bodies — RESOLVED: `True` / `False`.**
   The generated test suffix is
   `[test <Proc> executes branch <N> predicate TRUE]` /
   `[... predicate FALSE]`. Chosen over `Hit`/`Miss` because the
   existing branch tests already read in the natural-language
   `executes <param> = <val> path` style (see
   `04_Test_Generator_v3.sql` §test-name emission), and TRUE/FALSE maps
   one-to-one onto the `@Direction` argument of
   `TestGen.SatisfyPredicate` with no translation layer. `Hit`/`Miss`
   reads as coverage jargon and would diverge from the param-branch
   names already in the same class.
2. **NOT_TESTABLE rendering — RESOLVED: bottom panel, primary; inline
   tooltip, secondary.** The HTML report grows a single
   "Not-testable predicates" panel at the bottom listing
   `Schema.Proc — branch N — <verbatim predicate> — <reason>`, sourced
   from `PredicateInbox` rows where `Shape = 'UNRECOGNISED'`. This is
   the triage-at-a-glance view. A per-line `title=` tooltip on the
   branch row is added opportunistically where the reporter already
   emits a per-line cell, but the panel is the contract — the tooltip
   degrades gracefully if a future reporter rewrite drops per-line
   cells. Cobertura/JUnit XML already carry `hits="0"` + the Fail
   message, so CI visibility does not depend on the HTML choice.
3. **Reseeding semantics — RESOLVED: seeder appends INSERTs only,
   after SafeFakeTable, before Act.** The seeder NEVER calls
   `FakeTable`/`SafeFakeTable` itself. Its output is appended to the
   existing setup block at the same seam the current EXISTS seed block
   uses (`@ThisSeedBlock`, injected right after the proc body opens and
   after all `SafeFakeTable` calls — `04_Test_Generator_v3.sql`
   ~line 2855). The faked table is already empty at that point, so the
   seeder's engineered rows are the only rows; there is no double-seed
   and no clear-after-seed. For the FALSE direction of EXISTS/COUNT=0
   shapes the seeder emits nothing (empty faked table already satisfies
   it) — mirroring the existing `EXISTS_FALSE` "no seed" path.
4. **Identity / computed / PK / rowversion in INSERTs — RESOLVED:
   reuse the existing exclusion.** The seeder builds its INSERT column
   list from `sys.columns`/`sys.types` with exactly the v9.2/v9.4
   exclusion predicate (`is_identity = 0 AND is_computed = 0 AND
   t.name NOT IN ('timestamp','rowversion')`, see
   `04_Test_Generator_v3.sql` ~line 3047). No new helper; the seeder
   calls the same column-shaping logic, so FakeTable's
   version-dependent identity behaviour is handled identically to the
   replay path.
5. **Multi-join WHERE composition — RESOLVED: per-table-partitionable
   only in v0.10.0.** If every AND-clause of the subquery WHERE
   references columns from a single table (the predicate is
   partitionable per table), the seeder engineers one satisfying row
   per table independently. If any AND-clause references columns from
   more than one table (cross-table predicate composition that a join
   must jointly satisfy), the parser marks the row `Shape =
   UNRECOGNISED` with reason `multi-table WHERE composition` and the
   branch becomes NOT_TESTABLE. Full joint satisfaction is deferred to
   v0.11 (already listed in §5.4). This keeps v0.10.0 correct-by-
   construction and bounds the seeder's case analysis.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| ScriptDom feasibility spike reveals a critical capability gap | Fall back to hand-rolled T-SQL parser per Option A in DECISION doc — adds ~1.5 weeks. Spike runs day 1, so the cost of finding out is bounded. |
| ScriptDom DLL bundle size pushes PSGallery module above limits | PSGallery limit is 50 MB; ScriptDom is ~2 MB. Non-issue. |
| Multi-join WHERE clauses with cross-table predicate composition get hairy | Open question 5 — fence to per-table-partitionable WHERE in v0.10.0 if needed; revisit in v0.11 |
| Generated test classes balloon (one test per branch × 2 directions × many procedures) | Already happens for branch tests; report consumption is per-failure not per-test, so the larger class is fine |
| FakeTable semantics differ across tSQLt versions (v9.2 lesson) | Seeder reuses the same wrapper functions the existing seeder uses; no new direct FakeTable calls |
| Aggregate-with-comparator edge cases (e.g. `SUM` over a nullable column where seeded row's column is NULL) | Seeder picks NOT NULL values by default; document in code comments |
| SQL-only users feel left behind by PowerShell-only v0.10 feature | Quickstart already steers everyone to the PowerShell flow; SQL-only install continues working with v9.x semantics — explicit graceful degradation, called out in release notes |

## 8. Out of scope (explicit)

- Predicate-aware seeding for triggers (no test gen for triggers yet)
- Predicate-aware seeding for indexed views
- Scalar UDF calls inside predicates — falls into `UNRECOGNISED`,
  emits NOT_TESTABLE in v0.10.0; candidate for v0.11
- Recursive CTEs and window functions inside predicates — same
- Performance — `PredicateZoo` validation prioritises correctness;
  performance pass deferred to v0.11
- Localised string literals in predicates (`N'...'` handled; full
  collation awareness deferred)
