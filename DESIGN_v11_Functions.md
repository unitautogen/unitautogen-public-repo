# Design — v11: Scalar and Table-Valued Functions

Status: **proposed** (for review before any implementation). Builds on v10.0.8.

## 1. Goal and non-goals

Goal: extend TestGen to generate tests **and** measure line + branch coverage for
the three user-defined function shapes — **scalar (`FN`)**, **inline
table-valued (`IF`)**, and **multi-statement table-valued (`TF`)** — to the same
standard the v10 line achieves for stored procedures. The explicit bar set for
this release is **no coverage gaps**: every executable line of a function body
must be *measurable*, not reported as `n/a`. Where a line cannot be *reached*
(unsatisfiable predicate, nondeterministic input), the existing v10 honesty rule
applies — the test is emitted and marked "branch not reached — manual seed
required" — but the *instrumentation* must never be the thing that fails to see
a line.

Two decisions are fixed by the v10 line and carried forward:

- **Install-into-the-database model** is preserved — no external runner.
- **Characterization + regression target** is preserved — generated assertions
  confirm a function still behaves as it does today; they do not judge whether
  that behaviour is *correct* (§5).

Non-goals, stated plainly:

- **Intra-`SELECT` logical paths.** A set-based `SELECT` — including the single
  `RETURN (SELECT …)` body of an inline TVF — is one statement at the framework's
  coverage granularity (the v10 rule, DESIGN_v10 §1). Which `CASE` arm, which
  `JOIN` path, which `UNION` leg fired *inside* that `SELECT` is not decomposed.
  This is **not** a function-specific gap: it is the same atomic-statement rule
  applied to procedures, and "no gaps" is defined relative to this stated
  granularity (§4.4). The design is explicit about this so the promise stays
  honest.
- **Correctness oracle.** Same as v10 — characterization only.
- **CLR / external functions.** `EXTERNAL NAME` (SQLCLR) functions have no T-SQL
  body to parse or transform; they are classified `NOT_TESTABLE — CLR body` and
  reported as such, never as a false 0%.
- **Froid-dependent timing.** v11 does not rely on, and is not defeated by,
  scalar-UDF inlining (§4.2).

## 2. Why functions don't fit the procedure pipeline

The v10 pipeline rests on three assumptions that **all three** break:

1. **Tests invoke with `EXEC`.** A procedure test calls `EXEC dbo.usp …`. A
   function is invoked inside an expression — `SELECT dbo.fn(@a)` for a scalar,
   `SELECT * FROM dbo.fn(@a)` for a TVF. The whole EXEC-arglist emission and the
   before/after **delta assertions** (INSERT bodies must grow a table, UPDATE
   bodies must change rows — v9.4 strong assertions) are inapplicable: a function
   *cannot* have side effects, so there is no delta to assert.

2. **Coverage is captured by injecting side-effects.** `InstrumentProcedure`
   builds a `<name>_cov` copy with `EXEC TestGen.RecordCoverageHit …, <lineno>`
   after each statement, then `RunCoverage` swaps a synonym so test calls route
   to `_cov` and an Extended Events session captures `sp_statement_completed`.
   **A function body cannot contain `EXEC`, cannot call a procedure, and cannot
   write to a base table** — so a hit recorder cannot be injected into a function
   at all. This is the load-bearing problem and §4 is its answer.

3. **Coverage routes through a synonym.** `RunCoverage` renames the target to
   `_orig` and points a synonym `<name> → <name>_cov`. A synonym cannot turn a
   function reference inside a `SELECT` into a procedure call, and an instrumented
   *function* copy is impossible by (2). The synonym swap is unusable for
   functions.

The string/AST analyzer (`AnalyzeBranchPaths`, the v10 instrumenter's state
machine) and the downstream report and logging are reusable; the invocation,
assertion, and coverage-capture layers are not.

## 3. The three function shapes

**Scalar (`type = 'FN'`).** `CREATE FUNCTION dbo.f(@a …) RETURNS <type> AS BEGIN
… RETURN <expr> END`. Has a procedural body — `DECLARE`, `SET`, `IF`, `WHILE`,
`SELECT @x = …`, reads, and one or more `RETURN <expr>`. This is the richest case
for branch coverage and the primary driver of §4.

**Inline TVF (`type = 'IF'`).** `CREATE FUNCTION dbo.f(@a …) RETURNS TABLE AS
RETURN ( SELECT … )`. **One** statement, no procedural control flow. Statement
coverage is the single `RETURN (SELECT …)`; one invocation covers it fully and
there are zero procedural branches to miss.

**Multi-statement TVF (`type = 'TF'`).** `CREATE FUNCTION dbo.f(@a …) RETURNS @t
TABLE(…) AS BEGIN … INSERT @t … ; RETURN END`. A procedural body that populates a
table variable. Same branch richness as a scalar, plus `INSERT @t` statements
(legal in a procedure — `@t` is just a table variable there).

## 4. Coverage — the shadow-procedure transform

The centerpiece. Because a hit recorder cannot live inside a function and direct
statement-event capture is unreliable (§4.2), v11 measures coverage on a
**mechanically-derived shadow procedure** that has a one-to-one statement and
branch structure with the function body, and reuses the *entire* proven v10
coverage pipeline on it.

### 4.1 The transform

For a function `dbo.f`, v11 emits a procedure `dbo.f_covfn` whose body is the
function body with only the wrapper rewritten — the statements themselves are
unchanged, so their branch structure is preserved exactly.

*Scalar.*
```
CREATE FUNCTION dbo.f(@a INT) RETURNS INT AS         CREATE PROCEDURE dbo.f_covfn(@a INT, @__ret INT OUTPUT) AS
BEGIN                                                BEGIN
    DECLARE @r INT;                                      DECLARE @r INT;
    IF @a > 10 SET @r = @a * 2;            ───►          IF @a > 10 SET @r = @a * 2;
    ELSE       SET @r = 0;                               ELSE       SET @r = 0;
    RETURN @r;                                           SET @__ret = @r; RETURN;
END                                                  END
```
Only two edits: the `CREATE FUNCTION … RETURNS <type> AS` header becomes `CREATE
PROCEDURE …(@params, @__ret <type> OUTPUT) AS`, and each `RETURN <expr>;` becomes
`SET @__ret = <expr>; RETURN;`. Every other line is byte-identical, so its line
number maps directly.

*Multi-statement TVF.* The `RETURNS @t TABLE(<cols>) AS` header becomes `CREATE
PROCEDURE …(@params) AS` with `DECLARE @t TABLE(<cols>);` as the first body
statement; `INSERT @t …` lines are already procedure-legal and copy verbatim;
the trailing bare `RETURN` copies verbatim. (Optionally append `SELECT * FROM @t;`
so the same shadow can also serve the result assertion of §5 — gated by a
decision in §10.)

*Inline TVF.* `CREATE PROCEDURE …(@params) AS BEGIN <hit>; <the RETURN SELECT
without RETURN>; END` — a one-statement body. Coverage is trivially complete on
one invocation.

The transform is purely structural and small. It does **not** re-implement the
function's logic — it relocates it into a procedure shell. Because functions are
side-effect-free, every statement that can legally appear in a function can
legally appear in this procedure, so the transform never has to drop or rewrite a
statement to make it compile.

### 4.2 Why a shadow procedure, not direct event capture

Two facts make direct Extended-Events capture of a function body unreliable, which
is exactly why the indirection is worth it:

- Statements inside a scalar UDF execute as part of the *calling* statement, so
  they are not surfaced as independent `sp_statement_completed` events the way a
  procedure's statements are.
- SQL Server 2019+ **inlines** eligible scalar UDFs (the *Froid* framework folds
  the function body into the calling query's plan as relational algebra). An
  inlined body produces no per-statement events at all, and whether the optimizer
  inlines a given function is not under the test's control.

Running an ordinary **procedure** under the existing pipeline sidesteps both: a
procedure's statements are never inlined into a caller and always fire
`sp_statement_completed`. The shadow-procedure approach therefore yields exact
statement + branch coverage with the v10 capture path **completely unchanged**.

### 4.3 Driving the shadow and attributing hits

`RunCoverage` gains a function branch: instead of the synonym swap, it
(1) builds `f_covfn` via the transform, (2) instruments it with the **unchanged**
`InstrumentProcedure`, (3) executes it under the **unchanged** XEvent capture
using the *same seed data and the same per-branch argument matrix* the function's
test generator produced (§5) — `EXEC dbo.f_covfn @a = …, @__ret = @o OUTPUT` for
scalars, `EXEC dbo.f_covfn @a = …` for TVFs — then (4) drops the shadow.

A new column on `TestGen.CoverageLines` (or a small `TestGen.ShadowLineMap`)
records `FunctionLine → ShadowLine`. Since the transform changes only the header
and the `RETURN` lines, the map is near-identity (a fixed offset plus the handful
of rewritten `RETURN` lines), and `GetCoverageReport` attributes every hit back to
the original function's source line. The report and HTML output are otherwise
unchanged.

### 4.4 What "no gaps" means here, precisely

The shadow transform removes the *instrumentation* gap entirely: there is now a
mechanism that can place a hit recorder against **every executable line** of a
scalar or multi-statement function body, which was previously impossible. "No
gaps" is the guarantee that no function line is invisible to measurement. It is
**not** a claim that intra-`SELECT` logical paths are decomposed (they are atomic
for procedures too, §1) nor that every branch is *reachable* (unsatisfiable
predicates still get the honest "manual seed required" marker, never a phantom
green). With those two stated boundaries — identical to the proc line — every
function line is measurable and reported with a real number.

## 5. Assertion model for functions

The v9.4 strong-assertion design is **input → output characterization** for
functions; the before/after delta half is dropped (no side effects to delta).

**Scalar.** Seed read dependencies with `tSQLt.FakeTable`, fake called functions
with `tSQLt.FakeFunction`, then:
```
SELECT @actual = dbo.f(@a, @b);
EXEC tSQLt.AssertEquals @expected, @actual;   -- @expected blessed from current behaviour
```
One happy-path test, one per branch (arguments/seed chosen to drive each branch),
and NULL-argument characterizations (bless the output, which is often `NULL`).

**Inline and multi-statement TVF.** Snapshot-and-replay against the returned
table:
```
SELECT * INTO #actual FROM dbo.f(@a);
-- #expected populated from the blessed baseline
EXEC tSQLt.AssertEqualsTable '#expected', '#actual';
```
plus the **result-set shape** test reused from `CaptureResultShape` /
`AssertResultShape` (column names, types, ordering of the `RETURNS TABLE`
contract).

**Determinism guard.** A function reading `GETDATE()`, `NEWID()`, `@@SPID`,
`RAND()` or a sequence is flagged nondeterministic: its blessed output may not be
reproducible, so the value/table assertion is emitted but marked
"nondeterministic — characterization may be unstable" rather than asserted as a
hard equality. Same honesty rule, applied to the assertion instead of the seed.

## 6. Object-type routing and API

A thin dispatcher keeps back-compat:

- **`TestGen.GenerateTestsForObject @SchemaName, @ObjectName, @ExecuteScript`** —
  reads `sys.objects.type`, routes `P` to the existing procedure generator and
  `FN` / `IF` / `TF` to the new function generators. `GenerateTestsForProcedure`
  is retained unchanged for existing callers and scripts.
- **`TestGen.GenerateAndCoverDatabase`** — widen the work-set query from
  `FROM sys.procedures` to `FROM sys.objects WHERE type IN ('P','FN','IF','TF')`
  (the existing `tSQLt`/`TestGen`/`test_%`/`_cov`/`_orig`/`_covfn` exclusions
  carry over), classify each, and dispatch. Add an `ObjectType` column to
  `TestGen.CoverageResult` and group the report by it.
- **`TestGen.RunCoverage`** — add the function branch of §4.3 (build → instrument
  → drive shadow → drop), selected by object type; the procedure path is
  untouched.
- **`TestGen.AssessTestability`** — extend to classify `EXTERNAL NAME` (CLR) and
  encrypted function bodies as `NOT_TESTABLE` with a specific reason, consistent
  with the existing proc gate.

## 7. Seeding and dependency faking

Reaching a branch in a scalar or mTVF body uses the **same** predicate-seeding
machinery as procedures (DESIGN_v10 §6 — inversion of leaf comparisons, ancestor-
chain satisfaction, the honesty marker for the residue).

**Mocking, stated precisely — two cases that must not be confused.**

1. *The function under test is itself a TVF (or scalar).* It is **never mocked.**
   The whole point is to exercise its body; the test invokes the real object
   (`SELECT * INTO #actual FROM dbo.f(@a)` / `SELECT @actual = dbo.f(@a)`) and the
   shadow procedure of §4 is what carries the coverage instrumentation. Faking the
   object under test would defeat both the assertion and the coverage.

2. *The object under test depends on another function — including a TVF.* This
   dependency **is** mocked, and tSQLt supports it for table-valued functions, not
   only scalars. `tSQLt.FakeFunction` replaces any function with a compatible fake;
   its only hard constraints are that the original and the fake must be the **same
   function type** (both scalar, or both table-valued) and have **matching
   parameters** (and matching return type for scalars). So v11 mocks TVF
   dependencies the same way it mocks scalar ones.

The one real difference is the *shape of the fake the generator must synthesize*,
not whether mocking is possible:

- **Scalar dependency** → a one-line stub: `CREATE FUNCTION …(<same params>)
  RETURNS <same type> AS BEGIN RETURN <controlled constant> END`.
- **TVF dependency** → the fake must itself be a table-valued function with a
  matching signature and a controlled result set — an inline
  `RETURNS TABLE AS RETURN (SELECT <controlled rows>)` (or a multi-statement
  equivalent). Recent tSQLt also exposes a `@FakeDataSource` argument to
  `FakeFunction` for feeding fake rows into inline / multi-statement / CLR TVF
  fakes; v11 uses it where the installed tSQLt version supports it and falls back
  to the synthesized fake-function object otherwise (a capability check at
  generation time).

The framework already emits `tSQLt.FakeFunction` stubs for referenced functions
(installer ~line 3716); v11 extends that emitter to produce the TVF-shaped fake
above when the dependency is an `IF`/`TF`. Where a compatible fake genuinely
cannot be built (e.g. an unsupported tSQLt version against a CLR TVF), the test is
marked rather than silently coupled to the real dependency — honesty rule again.

## 8. Phased roadmap

Each phase leaves a **working framework**; the procedure pipeline is untouched
until the function path beside it is proven.

- **Phase 0 — plumbing.** Object-type classification, the `GenerateTestsForObject`
  dispatcher, the widened `GenerateAndCoverDatabase` work-set, the `ObjectType`
  column, and the `AssessTestability` CLR/encrypted gate. No behavioural change
  for procedures. Gate: the three reference databases regenerate and re-cover
  identically to v10.0.8.
- **Phase 1 — scalar (`FN`).** Generator (SELECT-invocation assertions, per-branch
  + NULL tests) and the shadow-procedure coverage path. Gate: a sample scalar UDF
  with `IF`/`WHILE`/multiple `RETURN` reaches 100% line + branch via the shadow,
  and its characterization tests pass.
- **Phase 2 — inline TVF (`IF`).** Generator (`AssertEqualsTable` + result-shape),
  single-statement shadow coverage. Gate: sample inline TVF, tests pass,
  one-statement coverage recorded.
- **Phase 3 — multi-statement TVF (`TF`).** Table-variable shadow transform,
  per-branch tests, `AssertEqualsTable`. Gate: sample mTVF with branches reaches
  full line + branch coverage.
- **Phase 4 — breadth and hardening.** Nondeterminism flagging, `FakeFunction`
  recursion, NULL-argument matrices, the `FunctionLine → ShadowLine` attribution
  in the HTML report, and the honest markers for unfakeable inline-TVF
  dependencies.
- **Phase 5 — release as v11.** Run the full suite on AdventureWorks2025,
  Northwind, and WideWorldImporters (which now contain functions previously
  skipped) and record the pass/coverage/autonomy headline per database.

## 9. Risks

- **Shadow / function divergence.** Coverage is only honest if the shadow's
  control flow matches the function's exactly. Mitigation: the transform edits
  *only* the header and `RETURN` lines and copies every statement verbatim, so
  divergence is structurally impossible for the body; a Phase-1 check compares the
  shadow's branch model against the function's `AnalyzeBranchPaths` model and
  fails the build on any mismatch.
- **Table-variable semantics in the mTVF shadow.** A `@t TABLE(…)` declared in a
  procedure behaves like the function's return table for population purposes;
  edge cases (identity on the table var, computed columns in the `RETURNS` clause)
  reuse the proc generator's existing identity/computed-column skip logic.
- **Blessing nondeterministic output.** Handled by the determinism guard (§5) —
  flagged, not asserted hard.
- **`FakeFunction` coverage limits** for inline TVFs (§7) — surfaced honestly.
- **Froid** is explicitly *not* a risk: v11 measures a procedure, which is never
  inlined into a caller (§4.2).

## 10. Decisions needed before Phase 1

- **Dispatcher vs. separate entry procs** — `GenerateTestsForObject` router
  (recommended) vs. distinct `GenerateTestsForScalarFunction` /
  `…ForTableFunction` public procs.
- **Shadow lifetime** — build-and-drop per run (clean, recommended) vs. persist
  `f_covfn` like `_cov` (debuggable, but another stranded-object class to exclude).
- **mTVF result assertion strictness** — `AssertEqualsTable` exact-match vs.
  unordered-set comparison for functions whose `RETURN` order is unspecified.
- **Whether the shadow also serves result assertions** (append `SELECT * FROM @t`)
  or assertions always invoke the real function (recommended — keeps the
  coverage shadow single-purpose and the assertion bound to the genuine object).
- **`ShadowLineMap` table vs. a column on `CoverageLines`** for hit attribution.

## 11. What stays true from v10

The AST/string analyzer, the `RunCoverage` capture path (rename/instrument/XEvent/
XEL-parse — now also driving shadow procedures), `CoverageLines` / `CoverageHits`,
`GetCoverageReport` (TEXT + HTML), `BlessBaseline`, `CaptureResultShape` /
`AssertResultShape`, the `TestGen` / `TestGenLog` schemas and logging, test
preservation across regeneration, and the **never-lie rule** all carry forward
intact. v11 adds a third and fourth and fifth *object shape* the framework
understands; it does not change what a good generated test or an honest coverage
number looks like.
