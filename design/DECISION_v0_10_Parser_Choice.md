# DECISION: Parser implementation for v0.10 predicate-aware seeding

Status: CONFIRMED 2026-06-02 (spike passed clean — 11/11 shapes, 0 UNRECOGNISED)
Decided by: Munaf Khatri (with Claude's analysis)
Related: [DESIGN_v0_10_PredicateSeeding.md](DESIGN_v0_10_PredicateSeeding.md), [spike/](spike/)

## Spike result (2026-06-02)

Run-Spike.ps1 against TestProcedure.sql:
- 18 predicate rows extracted from 15 IFs + 2 CASE arms + 1 WHILE
- 11 of 11 target shapes correctly classified
- 0 UNRECOGNISED rows
- 0 parser errors

All target AST classes (`ExistsPredicate`, `BooleanComparisonExpression`,
`InPredicate`, `BooleanTernaryExpression`, `BooleanIsNullExpression`,
`ScalarSubquery`, `QuerySpecification`, `FunctionCall`,
`ColumnReferenceExpression`, `IfStatement`, `WhileStatement`,
`SearchedCaseExpression`, `TSql160Parser`) exposed and walkable as designed.

Decision is final: build v0.10 on ScriptDom (Option B).

---

## Context

v0.10 requires a T-SQL predicate parser that recognises the full
grammar in `DESIGN_v0_10_PredicateSeeding.md` §3.1: aggregate
subqueries, EXISTS/NOT EXISTS, scalar subqueries, multi-table joins
inside the subquery, full WHERE-clause AST, CASE arms, parameter and
variable resolution.

Until v0.10, every UnitAutogen analysis path is a hand-rolled scalar
T-SQL function (CHARINDEX walks, regex via PATINDEX, custom tokenisers).
That worked for the v9.x grammar but the gaps are documented in the
v10.0.8 robustness backlog (block comments, DECLARE-cursor, DDL
openers, bracket/dquote tracking) and the predicate grammar in v0.10
is wider than anything we've parsed before.

## Options considered

### Option A — hand-roll the parser in T-SQL (v9.x convention)

Continue the existing pattern. Add `modules/31_Predicate_Parser_v1.sql`
with new scalar functions that walk the procedure body, extract IF /
WHILE / CASE-WHEN predicates, and produce `ParsedPredicate` records.

**Pros**
- 100% T-SQL framework, single-file install, zero external dependencies
- No architectural shift from v9.x
- Full control over parser behaviour for our specific needs

**Cons**
- ~10-13 days of build at 4h/day for the parser alone
- Edge-case bug iteration likely 4-5 days plus, as real-world procedures
  surface grammar constructs we missed
- Inherits all the gaps in the v10.0.8 backlog (block comments,
  brackets, quoted identifiers) — those become v0.10 bugs unless
  fixed in scope
- Grammar correctness ceiling is whatever we hand-roll
- Future grammar expansion (window functions, recursive CTEs, scalar
  UDF calls inside predicates) is more hand-rolling

### Option B — adopt `Microsoft.SqlServer.TransactSql.ScriptDom`

ScriptDom is Microsoft's official T-SQL parser. MIT-licensed,
distributed as a NuGet package and standalone DLL. Produces a full
T-SQL AST. Used inside SqlPackage and DacFx; battle-hardened over
a decade.

Architecture: the PowerShell module (`UnitAutogen.psm1` /
`Invoke-UnitAutogen`) loads the ScriptDom DLL, walks the AST,
extracts `ParsedPredicate` records, and writes them into a
`TestGen.PredicateInbox` staging table that the T-SQL seeder reads
from. The seeder stays in T-SQL; only the parser moves out.

**Pros**
- ~3-5 days of build at 4h/day to wrap ScriptDom AST into our
  `ParsedPredicate` format (vs ~10-13 days hand-rolled)
- Block comments, bracketed identifiers, quoted identifiers, CTEs,
  window functions, multi-line strings, operator precedence,
  compatibility-level-aware dialect quirks — all handled for free
- Closes most of the v10.0.8 robustness backlog as a side effect
- Bug iteration drops sharply — ScriptDom edge cases are already shaken
  out by Microsoft's own tooling and a decade of OSS use
- Future grammar expansion is free — ScriptDom already parses window
  functions, recursive CTEs, scalar UDF calls etc., we just teach the
  seeder to consume them
- Acquirer optics: "uses Microsoft's official T-SQL parser" reads as
  neutral-to-positive (Redgate uses ScriptDom themselves in tooling)
- Reversible — if ScriptDom turns out unsuitable, we fall back to
  hand-rolled parser; nothing locks us in long-term

**Cons**
- v0.10 predicate-aware seeding requires the PowerShell flow.
  SQL-only users keep v9.x semantics — graceful degradation, but
  worth calling out explicitly
- Framework no longer 100% T-SQL for the predicate-seeding feature
- Adds one external dependency (the ScriptDom NuGet package, MIT)
- Architectural shift: parsing moves from inside-the-database to
  inside-the-PowerShell-wrapper
- 2-hour upfront spike needed to verify ScriptDom exposes what we need
  for predicate cases (aggregate identification, WHERE-AST walk,
  subquery extraction, comparator/comparand extraction)

### Option C — hybrid: ScriptDom for procedure-level parsing, hand-roll for predicate decomposition

Use ScriptDom to get a clean AST of the procedure, but write our own
predicate-decomposition logic on top of it.

**Why not chosen**
- ScriptDom already exposes `BooleanExpression`, `ScalarSubquery`,
  `FunctionCall`, `QualifiedJoin`, `WhereClause` as discrete AST nodes
- Hand-rolling decomposition on top of an existing AST adds work
  without adding value
- Two parsing layers mean two failure modes
- The clean answer is "all in" or "all out" on ScriptDom

## Decision

**Adopt ScriptDom (Option B), gated on a 2-hour feasibility spike.**

The spike confirms ScriptDom exposes:
- Aggregate function calls (`COUNT`, `SUM`, `MIN`, `MAX`, `AVG`) as
  identifiable AST nodes
- The aggregated column and its source table
- The `WhereClause` AST walkable to extract column refs, literals,
  parameters, comparators, AND/OR composition
- `ExistsPredicate` / `BooleanComparisonExpression` /
  `BooleanInExpression` etc. for predicate shape recognition
- `QualifiedJoin` for multi-table FROM clauses
- Parameter and variable references resolvable to declared types

If the spike passes (expected outcome — ScriptDom is comprehensive),
we proceed with Option B. If it fails on a critical capability gap,
we fall back to Option A with the v10.0.8 backlog folded into v0.10
scope (adds ~1 week to the build).

## Consequences

### Architecture

- New PowerShell module file: `powershell/UnitAutogen/Get-ParsedPredicates.ps1`
- Loads `Microsoft.SqlServer.TransactSql.ScriptDom.dll` (NuGet)
- Walks the AST, extracts `ParsedPredicate` rows
- Writes to `TestGen.PredicateInbox` staging table (new) via SqlServer cmdlet
- T-SQL seeder reads from staging table, executes case analysis (no
  change vs the previous plan for the seeder layer)

### Module layout (revised)

- **REMOVED** `modules/31_Predicate_Parser_v1.sql` (was T-SQL parser —
  superseded)
- `modules/31_PredicateInbox_v1.sql` — new staging table + helpers
- `modules/32_Seeder_v1.sql` — single case-analysis seeder (unchanged
  from the previous revision)
- `modules/33_Predicate_TestGen_v1.sql` — integration into the test
  generator (unchanged)
- `powershell/UnitAutogen/Get-ParsedPredicates.ps1` — new ScriptDom
  wrapper

### Build time (revised)

| Phase | Days (Option A) | Days (Option B) |
| --- | --- | --- |
| ScriptDom feasibility spike | — | 0.25 (2 hrs) |
| Parser grammar spec + unit tests | 3-4 | 1 (covered by ScriptDom) |
| Parser implementation | 7-9 | 2-3 (AST→ParsedPredicate wrapper) |
| PredicateInbox staging table + sync | — | 1 |
| Single case-analysis seeder | 4-5 | 4-5 (unchanged) |
| Test generator integration | 4-5 | 4-5 (unchanged) |
| NOT_TESTABLE diagnostic flow | 2-3 | 2-3 (unchanged) |
| AdventureWorks + PredicateZoo validation | 3 | 3 (unchanged) |
| Bug iteration | 4-5 | 2-3 (less surface) |
| Docs + release notes | 2 | 2 |
| **Total** | **~30 days → 5 weeks calendar** | **~21 days → 3.5 weeks calendar** |

v0.10.0 candidate ready: late June 2026 (Option B) vs early July 2026
(Option A).

### User-facing change

- v0.10 features documented as requiring the PowerShell flow
  (`Install-UnitAutogenDatabase` + `Invoke-UnitAutogen`)
- SQL-only install continues to work and continues to deliver v9.x
  semantics — no regression
- Quickstart and Easy Mode docs updated to call out: predicate-aware
  seeding lights up when you use the PowerShell wrapper

### Licensing

ScriptDom is MIT-licensed. Compatible with our AGPL-3.0 licence
(AGPL is the licence on our code; MIT-licensed dependencies are
fine to consume).

### Acquirer narrative

ScriptDom is the parser Microsoft, Redgate (in some of their own
tools), and most modern SQL Server tooling already use. Adopting it
is consistent with the broader ecosystem and signals technical
maturity rather than NIH bias. For a Redgate acquisition pitch, this
is neutral-to-positive — they don't have to wonder whether our
bespoke parser will hold up.

### Reversibility

If a future maintainer wants to remove the ScriptDom dependency, the
seeder layer and staging table do not change — only
`Get-ParsedPredicates.ps1` is replaced with an equivalent T-SQL
parser. The interface boundary is the `TestGen.PredicateInbox` table.

## Validation gate

Before any of the v0.10 phase tasks (#54-#58) begin, run the 2-hour
ScriptDom feasibility spike. Spike deliverable: a PowerShell snippet
that takes a 50-line procedure body containing one of each predicate
shape from §3.2 and emits the corresponding `ParsedPredicate` rows.
If the snippet produces correct output for at least 12 of the 16
shapes, decision is confirmed. If fewer than 12 work, re-open this
decision.

## Out-of-scope considerations

- Replacing the existing v9.x scalar parsers with ScriptDom — not in
  v0.10 scope. Only the new v0.10 predicate parser uses ScriptDom.
  The v10.0.8 robustness backlog for the existing parsers is a
  separate decision.
- Embedding ScriptDom as a SQLCLR assembly inside the database —
  would let SQL-only users get v0.10 features, but SQLCLR is widely
  disabled in production environments and the deployment complexity
  is not worth it. PowerShell remains the path.
