# tSQLt Auto-Generation Framework v10.0.8 — Usage Guide

## What's new in v10.0.8

v10.0.8 is the **final stable release** of the v10 line.  It closes
four pre-emptive robustness gaps in the coverage instrumenter's line
walker — each a theoretical-but-realistic case where a real proc could
trip a false statement boundary.  v10.0.7 did not exhibit any of these
on the three reference databases, but they were waiting for a user
proc to hit them.

Validated on:

- AdventureWorks2025: 167 pass / 0 fail / 87.1% line / 79.7% branch / 100% autonomy
- Northwind:          42 pass / 0 fail / 100% line / 100% branch / 100% autonomy (identical to v10.0.7)
- WideWorldImporters: 24 pass / 0 fail / 0 err / 94.2% line / 100% autonomy (identical to v10.0.7)

The four:

1. **Multi-line `/* ... */` block comments** are now tracked across
   lines.  Keywords embedded in a block comment no longer fire false
   boundaries.
2. **`DECLARE … CURSOR FOR <SELECT>`** with the SELECT on a fresh
   line is now treated as a single statement (new `@ContDeclare`
   continuation table).
3. **DDL and cursor verbs** (`CREATE`/`ALTER`/`DROP`/`GRANT`/`REVOKE`/
   `DENY` and `OPEN`/`FETCH`/`CLOSE`/`DEALLOCATE`) now appear in the
   opener allowlist and fire their own boundaries instead of merging
   into the prior statement.
4. **Bracket `[…]` and double-quote `"…"` identifier tracking**
   (`@BracketDepth`, `@DQuoteOpen`) — keywords inside quoted
   identifiers no longer trigger boundary detection.

A new script, `scripts/Survey_v10_0_8_Patterns.sql`, detects which
procs in any user database exercise these new code paths.

## What's new in v10.0.7

v10.0.7 was the previous stable release of the v10 line.  It introduced
multi-statement-no-semicolons detection in the coverage instrumenter,
backed by a state machine with paren-depth, opener-allowlist and
string-literal awareness, plus a blank-line carry-over fix for
`UNION/EXCEPT/INTERSECT` continuations.

Validated on:

- AdventureWorks2025: 167 pass / 0 fail / 88.3% line coverage
- Northwind:          42 pass / 0 fail / 100% line coverage / 9 lines
- WideWorldImporters: 24 pass / 0 fail / 0 err / 94.2% line / 100% autonomy

Other v10 features (cumulative since v9.4.4):

- Testable Y/N column on the HTML coverage report
- Test preservation across regeneration (in-place developer edits survive)
- Autonomy headline metric
- View dependency resolution to underlying base tables
- Bodyless proc instrumentation (`CREATE PROC X AS SELECT ...`)
- NULL-evidence Pattern B (structural containment to suppress false positives)

The remainder of this guide still applies — v10 is a superset of v9.4.x.

## What's new in v9.4.4

v9.4.4 adds **in-place test preservation**. You can now edit a generated
test directly inside `test_<proc>` and the next regeneration will keep
your change. No rename to a `_custom` sibling class, no annotation marker,
no separate file. Modification is the ownership signal.

How it works at a glance:

- When the framework emits a test, it logs the body and a SHA2_256 hash
  into a new table, `TestGenLog.GeneratedTest`. This includes the
  `--[@tSQLt:SkipTest]` stubs emitted for NOT_TESTABLE procs.
- On the next regeneration, the framework re-hashes the current proc body
  from `sys.sql_modules.definition`. A hash mismatch means the developer
  modified the test.
- Before the destructive `DropClass + NewTestClass + CREATE` flow runs,
  the framework snapshots the modified body. After the flow, it drops the
  freshly-emitted same-named proc and replays the saved body. The
  developer's version survives.
- The original log row stays frozen at the FRAMEWORK's hash, so future
  regens keep detecting the divergence.

Each per-procedure row in `TestGen.CoverageResult` now carries a
`TestsPreserved INT NOT NULL DEFAULT 0` column counting how many of its
tests were carried across this regen. Both the in-place mechanism and
the existing `_custom` sibling-class mechanism remain supported - see
*Keeping your own tests across regeneration* below for the trade-offs and
the full workflow (including how to discard a preserved test if you want
to give it back to the framework).

## What's new in v9.4.3

v9.4.3 adds **"NOT TESTABLE" detection**. Some procedures cannot be meaningfully
auto-tested; the framework now *detects and labels* them instead of emitting
tests that error or report a misleading 0% coverage.

A new procedure, `TestGen.AssessTestability`, runs before generation and
classifies each procedure. A procedure is **NOT TESTABLE** when:

- it has no fakeable table/view dependencies and reads system catalog objects
  (the `sys` schema), which `tSQLt.FakeTable` cannot fake; or
- it uses a `FOR SYSTEM_TIME` time-travel query (see *Temporal tables* below); or
- it depends on a table that is currently system-versioned (see below).

A NOT TESTABLE procedure gets a single test carrying the `--[@tSQLt:SkipTest]`
annotation (it appears in the tSQLt **skipped** column with the reason), is
recorded as `NOT_TESTABLE` with NULL coverage in `TestGen.CoverageResult`, and
appears as its own row - excluded from the headline averages - in the
`GenerateAndCoverDatabase` report. `RunCoverage` and `GetCoverageReport` print a
NOT TESTABLE banner instead of a coverage number. Every other procedure is
generated and measured exactly as before.

### Prerequisite: temporal tables

`tSQLt.FakeTable` cannot fake a **system-versioned temporal table** - it cannot
rename a versioned table, and a temporal history table rejects a direct
`INSERT` (SQL Server error 13559). This is a known tSQLt limitation (tSQLt
issue #40).

**Before generating tests or running coverage on a database that has
system-versioned temporal tables, turn system versioning OFF on them, and turn
it back ON afterwards:**

    -- before testing
    ALTER TABLE [Schema].[TemporalTable] SET (SYSTEM_VERSIONING = OFF);
    -- ... run TestGen ...
    -- after testing
    ALTER TABLE [Schema].[TemporalTable]
        SET (SYSTEM_VERSIONING = ON
             (HISTORY_TABLE = [Schema].[TemporalTable_Archive]));

With versioning off, those tables behave as ordinary tables, and any procedure
that uses them as ordinary tables is generated and tested normally. A procedure
left depending on a still-versioned table is reported NOT TESTABLE with a
reason telling you to turn versioning off and regenerate.

One case turning versioning off cannot rescue: a procedure that uses
`FOR SYSTEM_TIME` (`AS OF`, `FROM ... TO`, `CONTAINED IN`, `ALL`). That clause
is valid only on a live system-versioned table, so such a procedure stays
NOT TESTABLE regardless.

## What's new in v9.4.2

v9.4.2 adds a **before/after delta assertion** to every branch test whose
body performs a known `INSERT` or `UPDATE`. It runs alongside the v9.4
`AssertEqualsTable` and closes two gaps the table compare alone left open:

- An **`INSERT`** branch must make its target table *gain a row from the
  procedure*. The baseline count is captured after all seeding, so the test's
  own seed rows never satisfy the assertion - only the procedure's `INSERT`
  does.
- An **`UPDATE`** branch must leave the row count unchanged *and* actually
  modify the table. This is the check `AssertEqualsTable` cannot make when the
  branch writes only a non-deterministic column (e.g. `ModifiedDate =
  GETDATE()`), which the table compare projects out.

The delta assertion replaces the old tautological `@RowsGrew = 1` / `1 = 1`
fallbacks, so every branch test with a table-writing body now carries a real
assertion of the procedure's effect.

v9.4.2 also makes the generator **honest about what it could not test**. When a
branch has no assertable effect - a compound or nested body, a branch that
writes no table and surfaces no result column, or a region with no analysable
paths - the generator no longer emits a quietly-passing smoke test. Instead it
marks that test with the tSQLt `--[@tSQLt:SkipTest]` annotation (a comment
placed immediately before the test's `CREATE PROCEDURE`), so it appears in the
**skipped** count of the tSQLt run summary. A generated test now either asserts
something real or declares, in plain sight, that you must write it by hand -
there are no phantom passes. See `CHANGES.md` (v9.4.2 entries).

> **tSQLt version note:** the `--[@tSQLt:SkipTest]` annotation is honored only
> by tSQLt **V1.0.7597.5637 (October 2020) or later**. On an older tSQLt the
> annotation is an inert comment, so such a test would simply run without an
> assertion. v9.4.2 therefore requires tSQLt >= V1.0.7597.5637 - check yours
> with `SELECT tSQLt.Info();`.

## What's new in v9.4

v9.4 is the **strong branch-test assertions** release. It turns the
framework's branch/path tests from coverage-only smoke tests into real
characterization tests.

Before v9.4, branch tests carried *tautological* assertions: `EXISTS_TRUE`
and `IF_ELSE` tests asserted "the row count grew", but the seed block itself
ran the `INSERT` that satisfied that — so the assertion was satisfied by the
seed, not by the procedure. `EXISTS_FALSE` tests asserted `1 = 1`. A branch
body gutted to do nothing would still pass.

v9.4 first fixed this with **snapshot-and-replay**; the current engine (v0.14)
supersedes it with a *measured-effect* assertion in proper Arrange-Act-Assert
order — see [strong-assertions.md](strong-assertions.md) for the canonical,
up-to-date description. For the record, the v9.4 approach worked as follows:

- For a branch whose body is a single leaf `UPDATE`/`INSERT`, the generated
  test snapshots the target table, replays the branch's *own* parsed DML onto
  the snapshot (with procedure parameters substituted by the test's literal
  arguments), executes the procedure, and asserts the real table equals the
  replayed expectation via `tSQLt.AssertEqualsTable`. Identity, computed and
  rowversion columns are projected out of the comparison.
- **v9.4.1** — a non-deterministic function (`GETDATE`, `SYSDATETIME`,
  `NEWID`, `RAND`, …) in an *assignment* position no longer vetoes the strong
  assertion. The replay still runs the function; the columns it feeds are
  projected out of the comparison by type family, the same way identity
  columns already were.
- **Phase B** — a branch whose body writes no table (e.g. a `CASE` that only
  assigns a local variable surfaced as a result-set column) gets a
  `tSQLt.AssertEqualsString` on that column instead. So **every branch test
  now carries a real assertion** — `AssertEqualsTable`, `AssertEqualsString`,
  or both. No branch test keeps a `1 = 1`.
- New helper `TestGen.ExtractLeafDml` captures a branch body's single leaf
  DML; `AnalyzeBranchPaths` records `BodyDmlKind` / `BodyDmlTable` /
  `BodyDmlText` for replay.

This is a **characterization / consistency oracle**: the "expected" state is
the procedure's own DML replayed. It catches the branch DML not running at
all, collateral changes (a wrong/missing `WHERE`, an unintended extra
statement), and regressions — once generated, the test pins current
behaviour. It does not independently judge whether the procedure's intent is
correct; that needs a human-written spec.

Coverage is unaffected by v9.4 — the procedure still runs and the same lines
are hit. Only pass/fail becomes stricter. A previously-green branch test may
now fail; that is the strengthened assertion working. See `CHANGES.md`.

## What's new in v9.3

v9.3 is a reliability release over v9.2: eight framework bugs fixed and one
capability added.

- `RunCoverage` now re-instruments on every run, so coverage is never
  measured against a stale `_cov` copy.
- `InstrumentProcedure` v5.1 wraps bare-body `IF`/`ELSE` branches, so the
  instrumented copy always compiles.
- `AnalyzeBranchPaths` parses complex predicates correctly: `WHERE` clauses
  containing `IN (...)`, multi-word string values, and function-wrapped
  columns such as `YEAR(OrderDate)`.
- `GenerateTestsForProcedure` gives EXISTS tests unique names, seeds the full
  ancestor chain for nested `EXISTS` predicates, and no longer truncates
  datetime seed values.
- NEW - the `IF_ELSE` test category exercises the `ELSE` side of a plain
  nested `IF @param = 'value'` branch.

See `CHANGES.md` for the full bug-by-bug history.

## What's new in v9.2

100% line and branch coverage achieved on the validation test procedure
`dbo.uspV9ValidationTest`. The framework now correctly handles:

- Multi-condition `IF EXISTS (...)` predicates with AND/OR
- `CASE WHEN` value assignments to local variables, then branched on
- `IN (...)` lists with multiple values
- `LIKE '%pattern%'` predicates
- JOIN-aliased columns in EXISTS subqueries
- EXISTS_FALSE paths that need the predicate's source table cleared
- Control-transfer statements (`RETURN`, `THROW`, `RAISERROR`)
- Identity/PK/computed columns (skipped from UPDATE seeds)
- String columns of varying max-length

## Prerequisites

- SQL Server 2017 (MSSQL15) or later
- tSQLt v1.0.5873.27393 or later installed in the target database
- User has `CREATE PROCEDURE`, `CREATE FUNCTION`, `CREATE SCHEMA` rights
- AdventureWorks2025 or your own application schema

## Install

```sql
USE YourDatabase;
GO
-- Run the combined installer (idempotent; safe to re-run):
:r Install_All_Combined_v9_4.sql
```

Or open in SSMS and execute. Expect to see `Framework installed successfully.`
near the end. The installer is idempotent — re-running it upgrades an
existing v9.2 / v9.3 install to v9.4 in place.

## Quick start: generate tests + measure coverage for one procedure

```sql
USE YourDatabase;
GO

-- 1. Generate the tSQLt test class for your procedure
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName    = N'dbo',
     @ProcName      = N'YourProcedure',
     @ExecuteScript = 1;

-- 2. (Optional) The "stable result-set shape" test auto-captures its
--    baseline on the FIRST run, so nothing is needed up front. Only AFTER
--    you intentionally change the procedure's output do you re-bless:
--        EXEC TestGen.BlessBaseline @TestClass = N'test_YourProcedure', @Kind = 'Shape';

-- 3. Run the tests
EXEC tSQLt.Run 'test_YourProcedure';

-- 4. Measure code coverage end-to-end
EXEC TestGen.RunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'YourProcedure',
     @OutputMode = N'TEXT';     -- or N'HTML' for a styled report

-- 5. (Optional) just see the report without re-running
EXEC TestGen.GetCoverageReport
     @SchemaName = N'dbo',
     @ProcName   = N'YourProcedure',
     @OutputMode = N'HTML';
```

## Verifying a v9.4 install

`scripts\Verify_v9_4.sql` is a single end-to-end check: it pre-flights that
the v9.4 / v9.4.1 / Phase B code is installed, regenerates the bundled sample
test classes, runs them so the strengthened assertions are exercised, prints
a strong-vs-weak assertion census, and runs coverage. Run it after install
and triage any newly-failing branch test (a generator bug, or a genuine
seed/replay mismatch the old weak assertion was masking).

## Procedure reference

### `TestGen.GenerateTestsForProcedure`

Generates a tSQLt test class for a stored procedure.

- `@SchemaName`     — schema of target proc (e.g. `'dbo'`)
- `@ProcName`       — name of target proc
- `@ExecuteScript`  — `1` to install the test class now; `0` to just return the script

Creates a test class named `test_<ProcName>` containing:
- Happy-path test (valid inputs)
- Boundary tests (low/high values)
- NULL-input rejection tests for each parameter
- Per-branch tests for every IF/CASE/EXISTS path, each carrying a strong
  v9.4 assertion (`AssertEqualsTable` and/or `AssertEqualsString`)

### `TestGen.RunCoverage`

Drop-in for "run my tests and tell me what got hit."

- `@SchemaName`, `@ProcName` — target proc
- `@OutputMode`              — `'TEXT'` or `'HTML'`

Internally:
1. (Re)instruments the proc on **every run**, creating a fresh `<name>_cov`
   with hit recorders. Re-instrumenting each time guarantees `<name>_cov`
   and the line registry reflect the current proc body and the current
   instrumenter version — a stale `<name>_cov` from an earlier run is
   never reused.
2. Renames target proc to `<name>_orig`
3. Creates a synonym so calls to `<name>` route to `<name>_cov`
4. Starts an Extended Events session capturing `sp_statement_completed`
5. Runs the test class
6. Stops capture, parses XEL file, fills `TestGen.CoverageHits`
7. Restores original proc
8. Prints the coverage report

### `TestGen.BlessBaseline`

Clears a procedure's stored baselines so the next test run auto-captures
fresh ones. Use it after an *intentional* change to the procedure that the
golden tests (the result-set shape test, etc.) would otherwise flag as drift.

- `@TestClass` — test class to bless, e.g. `'test_YourProcedure'`.
  `NULL` (the default) clears the baselines for **every** test class.
- `@Kind`      — `'Shape'`, `'Rows'`, or `'Both'` (default `'Both'`).

It only *deletes* the baseline rows (from `TestGenLog.ResultShapeBaseline` /
`TestGenLog.ResultRowsBaseline`); the next run of the test re-captures the
current values and passes. The cycle is: `BlessBaseline`, then re-run the test.

### `TestGen.GetCoverageReport`

Prints the latest coverage report for a procedure without re-running tests.

### `TestGen.InstrumentProcedure`

(Usually called by `RunCoverage`, not directly.) Reads the original proc
source, classifies each line as IsExec/IsBranch, injects
`EXEC TestGen.RecordCoverageHit ..., <lineno>` after each executable
statement, and creates `<ProcName>_cov`.

### `TestGen.AnalyzeBranchPaths`

(Usually called by `GenerateTestsForProcedure`, not directly.) Parses a
procedure's body to find all branch conditions and emit a path table that
drives test generation. It also records each leaf branch body's single
`UPDATE`/`INSERT`; the current engine *measures* that branch's effect at run time
to form the assertion (see [strong-assertions.md](strong-assertions.md)).

### `TestGen.ExtractLeafDml`

(v9.4, helper — called by `AnalyzeBranchPaths`.) Given a branch body block,
strips comments, runs a keyword census, and returns the single DML statement
only when the body is a genuine leaf (exactly one `UPDATE` or `INSERT`; no
`DELETE`/`MERGE`; no nested `IF`/`WHILE`). The returned text has the target
table rewritten to a `{{TARGET}}` token for replay re-pointing.

## Workflow tips

### Iterating on test design

After generating tests once, you can edit the proc body and re-run
without re-generating tests — the test class is decoupled from the
proc's instrumentation. But if the proc's parameter list or branch
structure changes, regenerate:

```sql
EXEC tSQLt.DropClass 'test_YourProcedure';
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName='dbo', @ProcName='YourProcedure', @ExecuteScript=1;
```

### Changing a procedure's output columns

Every generated test class includes a **`returns a stable result-set shape`**
test. The first time it runs it records the procedure's first result set —
each column's ordinal, name, type, length, precision, scale and nullability —
as a baseline in `TestGenLog.ResultShapeBaseline`. Every later run re-describes
the procedure's result set (via `sys.dm_exec_describe_first_result_set`, so the
procedure itself is never executed) and compares it to that baseline.

So if you later redesign the procedure and **add, remove, rename, retype,
resize or reorder an output column, that test will fail** — by design. It is a
result-set *contract* guard: a change to what the procedure returns should be
deliberate and reviewed, never silent. If the change was accidental — a
refactor that dropped a column — that failure is exactly what you want.

When the change is intentional, accept the new contract by re-blessing:

```sql
EXEC TestGen.BlessBaseline @TestClass = N'test_YourProcedure', @Kind = 'Shape';
EXEC tSQLt.Run 'test_YourProcedure';   -- the next run re-captures + passes
```

Two things to know:

- The baseline lives in `TestGenLog.ResultShapeBaseline`, a framework table
  keyed by test-class name. **Regenerating the test class does not clear it.**
  `DropClass` + `GenerateTestsForProcedure` recreates the test procedures but
  leaves the baseline table untouched — so after a redesign the shape test
  still fails on its first run until you explicitly run `BlessBaseline`.
- Only that one test reacts to an output-column change — the branch/path
  tests compare *table* effects, not the result set. And the shape test pins
  the **first** result set only; a change to a second result set, if the
  procedure returns more than one, is not caught.

### Looking at the generated test source

```sql
SELECT OBJECT_DEFINITION(OBJECT_ID(N'[test_YourProcedure].[<test name>]'));
```

### Skipped tests - what the generator could not test for you

A generated test class will usually contain some **skipped** tests - they show
in their own column of the tSQLt run summary (`... N skipped ...`). This is
deliberate, and it is the framework's central honesty guarantee: a generated
test either carries a real assertion or is skipped with a plain reason. It
never silently passes while asserting nothing.

A test is skipped when the generator genuinely cannot characterise the branch -
for example a compound or nested branch body (no single `INSERT`/`UPDATE` to
replay), a branch that writes no table and surfaces no result-set column, or a
region of the procedure with no analysable branch paths. The generator marks
such a test with the `--[@tSQLt:SkipTest]('MANUAL TEST REQUIRED: ...')`
annotation, placed as a comment immediately before the test's `CREATE
PROCEDURE`; the reason text says exactly why. Note `tSQLt.SkipTest` is a tSQLt
*annotation*, not a callable procedure - it requires tSQLt >= V1.0.7597.5637.

Treat the skipped list as your **to-do list**: those are the branches the
generator handed back to you, to write a tSQLt test for by hand. A skipped test
is not a framework bug and not a failure - it is the generator being honest
about the limit of what it could do automatically, so you always know what is
covered and what you own.

### Keeping your own tests across regeneration

There are two ways to keep developer-owned tests across regenerations - an
**in-place modification** route (added in v9.4.4) and the **sibling class**
route. They solve different problems; use whichever fits.

#### In-place modification (v9.4.4+)

You can edit a generated test directly inside `test_<proc>` and the next
regeneration will preserve your change. No rename, no annotation, no separate
class. Modification itself IS the ownership signal.

How it works: when the framework emits a test, it logs the body and a
`HASHBYTES('SHA2_256', ...)` of it into `TestGenLog.GeneratedTest`. On the
next regeneration, the framework hashes the current body in
`sys.sql_modules.definition` and compares against the logged hash. A mismatch
means the developer modified the test; the framework snapshots the current
body, lets its destructive `DropClass`/`NewTestClass` flow run, then drops
the freshly-emitted same-named proc and replays the developer's saved body.
The log row is left at the FRAMEWORK's original hash, so future regens still
see the divergence and keep preserving.

The most common case is taking over a NOT_TESTABLE skip stub: remove the
`--[@tSQLt:SkipTest]` annotation, write real test logic, save. Next regen
preserves it. Same mechanism also covers ordinary edits to a passing test -
e.g. seeding your own data inside a generated test to make the assertion
more meaningful.

To check how many tests were preserved on the last sweep:

```sql
SELECT SchemaName, ProcName, TestsPreserved
FROM   TestGen.CoverageResult
WHERE  BatchId = (SELECT MAX(BatchId) FROM TestGen.CoverageResult)
  AND  TestsPreserved > 0;
```

To diff your modified test against the framework's original (useful when you
later wonder "what did the framework produce here before I changed it?"):

```sql
;WITH latest AS (
    SELECT gt.*, ROW_NUMBER() OVER (
        PARTITION BY gt.TestClassName, gt.TestProcName ORDER BY gt.RunId DESC) AS rn
    FROM TestGenLog.GeneratedTest gt
)
SELECT l.OriginalBody                 AS GeneratedBody,
       OBJECT_DEFINITION(p.object_id) AS YourCurrentBody
FROM   latest l
JOIN   sys.procedures p ON p.schema_id = SCHEMA_ID(l.TestClassName)
                       AND p.name      = l.TestProcName
WHERE  l.rn = 1
  AND  l.TestClassName = 'test_<your_proc>'
  AND  l.TestProcName  = 'test ... ';
```

To **discard** a preserved test - i.e. give it back to the framework -
just drop the procedure:

```sql
DROP PROCEDURE [test_<proc>].[test ... ];
```

On the next regeneration, the snapshot scan finds nothing there, no
preservation happens, and the framework emits a fresh copy.

To **re-baseline** a preserved test - keep your body but make the framework
consider it "unchanged" again - replay your body via `ALTER PROCEDURE` (so
modify_date refreshes) and then re-run the generation; the capture step will
log the current body as the new baseline. Equivalent shortcut:

```sql
;WITH latest AS (
    SELECT TOP 1 GeneratedTestId
    FROM   TestGenLog.GeneratedTest
    WHERE  TestClassName = 'test_<proc>' AND TestProcName = 'test ... '
    ORDER  BY RunId DESC
)
UPDATE gt SET OriginalBody = OBJECT_DEFINITION(OBJECT_ID('[test_<proc>].[test ... ]'))
FROM   TestGenLog.GeneratedTest gt
JOIN   latest l ON l.GeneratedTestId = gt.GeneratedTestId;
```

Caveat: `TestGen.DropGeneratedTestClasses` (described below) DROPS preserved
tests along with everything else. It is the "wipe-all-framework-state"
button. If you want to keep your modifications, do not run it - or scope it
narrowly with `@SchemaFilter` and `@WhatIf = 1` first.

#### Sibling class (`test_<proc>_custom`)

The older, heavier-weight route: put your tests in a sibling class named
**`test_<proc>_custom`**. The framework never creates, drops, or edits that
class; it is yours entirely. `RunCoverage` runs `test_<proc>_custom`
alongside `test_<proc>`, so your tests count toward coverage.

When to choose this over in-place modification:

- You want BOTH a framework-generated test AND a hand-written test for the
  same procedure to coexist. In-place modification replaces the
  framework's test; a sibling class lets you have both.
- You are writing several developer-owned tests for one procedure and want
  to organise them as a logical group.
- You want the developer-owned tests to be visibly separate in tSQLt's
  output (a different class name shows up in `tSQLt.RunAll` results).

You can keep **more than one** developer class for a procedure: any class
named `test_<proc>_custom...` (a prefix match) is recognised by both
regeneration's dedup and `RunCoverage`. Pass `@Variant` to
`EnsureCustomTestClass` to create extras - e.g.
`@Variant = 'edge'` makes `test_<proc>_custom_edge`. One class can hold any
number of test procedures, so multiple classes are only for organising them.

### Tearing down generated tests

Generation is cheap and idempotent, so you need not keep hundreds of test
classes resident - generate, run, measure, then tear down.
`TestGen.DropGeneratedTestClasses` drops the classes the framework generated
(read from `TestGenLog.GenerationRun`, so only framework `test_<proc>`
classes); developer-owned `test_<proc>_custom...` classes are kept unless
`@IncludeCustom = 1`. Pass `@WhatIf = 1` to preview, `@SchemaFilter` to scope
it. Best practice: generate tests into a dev / CI database, not production -
the `test_*` schemas then never crowd the database that matters.

To **adopt** a generated test, create the custom class once with the wrapper -
`EXEC TestGen.EnsureCustomTestClass @SchemaName='dbo', @ProcName='<proc>';` (it
hides the naming convention and is safe to re-run) - then copy the generated test
procedure into it, keeping the same name. On the next regeneration the
framework sees the same-named test in `test_<proc>_custom` and drops its own
copy from `test_<proc>`, so the two never duplicate.

### Turning generated test families on or off

`GenerateTestsForProcedure` and `GenerateTestsForSchema` take two switches:

- `@EmitNullChecks` (default `0`) - when `1`, forces one NULL test per nullable
  parameter. Off by default: a procedure's genuine NULL handling is a real
  branch/line and is covered as such, so the framework no longer injects a
  speculative NULL test into every parameter.
- `@EmitScaffold` (default `1`) - when `0`, the set-based characterization
  scaffold is not generated.

`@EmitScaffold` defaults on; `@EmitNullChecks` defaults off. Pass
`@EmitScaffold = 0` to drop the scaffold, or `@EmitNullChecks = 1` to add the
per-parameter NULL tests for a given procedure or schema.

### Database-wide coverage report (CI/CD)

`TestGen.GenerateAndCoverDatabase` runs the whole pipeline across every user
procedure - generate, run, measure coverage - and emits one report:

    EXEC TestGen.GenerateAndCoverDatabase;                      -- HTML, all schemas
    EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'TEXT';
    EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = 'dbo';

The HTML report has one row per procedure - tests run / passed / failed /
errored / skipped, total lines, covered lines, line % and branch % - a TOTAL
row, and aggregate test-outcome percentages. Each procedure's result is also
persisted to `TestGen.CoverageResult` (keyed by `BatchId`) for trending.
Intended as a CI/CD coverage gate. It needs server-level XEvent permission
(via `RunCoverage`); the tests run once per procedure - `RunCoverage`
instruments the proc, runs the tests, measures coverage and returns the
pass/fail/skip/error counts in a single run.

### Coverage gaps

If lines are uncovered after the test run:
1. They might be in a branch the tests don't take. Look at the
   `UNCOVERED BRANCHES` section of the report.
2. They might be control-transfer lines (RETURN/THROW) — the framework
   places the hit BEFORE these, so they should always fire if the branch
   is taken.
3. They might be inside a nested EXISTS subquery whose JOIN condition
   the FK seed doesn't satisfy. The UPDATE-after-INSERT seed strategy
   should cover this in most cases.

### Re-installing after changes

The installer is idempotent. Just re-run `Install_All_Combined_v9_4.sql`
to pick up framework updates.

## Architecture

```
                 ┌──────────────────────────────────────┐
                 │   Your Stored Procedure              │
                 └────────────────┬─────────────────────┘
                                  │ introspected by
                                  ▼
   ┌─────────────────────┐  ┌─────────────────────┐  ┌────────────────┐
   │ AnalyzeBranchPaths  │  │ InstrumentProcedure │  │ GetSampleValue │
   │ - finds IF/EXISTS   │  │ - creates _cov copy │  │ Literal        │
   │ - resolves params   │  │ - injects hit calls │  │                │
   │ - extracts values   │  │                     │  │                │
   │ - captures leaf DML │  │                     │  │                │
   └──────────┬──────────┘  └──────────┬──────────┘  └────────┬───────┘
              │                        │                      │
              └──── #BranchPaths ──────┘                      │
                          │                                   │
                          ▼                                   ▼
                ┌────────────────────────┐         ┌──────────────────┐
                │ GenerateTestsForProc   │         │ EXEC arglist     │
                │ - builds EXEC arglist  │◄────────┤ uses sample      │
                │ - INSERT+UPDATE seeds  │         │ values for non-  │
                │ - measured effects     │         │ branch params    │
                │ - one test per branch  │         └──────────────────┘
                └──────────┬─────────────┘
                           │
                           ▼
                ┌────────────────────────┐
                │  [test_YourProc] class │
                │  in tSQLt              │
                └──────────┬─────────────┘
                           │ run by
                           ▼
                ┌────────────────────────┐         ┌──────────────────┐
                │  TestGen.RunCoverage   ├────────►│ XEvent capture   │
                │  - sets up synonym     │         │ of sp_stmt_done  │
                │  - runs tSQLt          │         └────────┬─────────┘
                │  - restores proc       │                  │
                └──────────┬─────────────┘                  │
                           │           ┌──────────────────┐ │
                           └──────────►│ CoverageHits     │◄┘
                                       │ + CoverageLines  │
                                       └────────┬─────────┘
                                                │
                                                ▼
                                       ┌──────────────────┐
                                       │ GetCoverageReport│
                                       │ - TEXT or HTML   │
                                       └──────────────────┘
```

## Troubleshooting

### A branch test fails with "Unexpected/missing resultset rows!"
This is the v9.4 `tSQLt.AssertEqualsTable` check reporting that the real
table after `EXEC` did not match the replayed expectation. Triage it: either
a generator bug (the replayed DML or parameter substitution is wrong, or the
test never actually reaches the branch because its seed is incomplete), or a
genuine seed/replay mismatch the old weak assertion was masking. Compare the
`<` (expected-only) and `>` (actual-only) rows in the test's message.

### A "returns a stable result-set shape" test fails after a procedure change
Expected behaviour — that test pins the procedure's output-column contract
(see "Changing a procedure's output columns" under Workflow tips). If you
added, removed, renamed or retyped a result-set column on purpose, accept the
new shape by re-blessing the baseline and re-running the test:
`EXEC TestGen.BlessBaseline @TestClass = N'test_YourProcedure', @Kind = 'Shape'`.
Regenerating the test class does **not** clear the baseline — you must bless.

### "Cannot update identity column 'X'"
The framework skips identity, computed, rowversion, and PK columns from
UPDATE SET clauses. If you see this error, your version of tSQLt's
`FakeTable` isn't removing identity as expected. The UPDATE is wrapped in
TRY/CATCH so it's non-fatal at runtime.

### Coverage shows 0% for a proc
Check that the XEvent session can write to its target directory. The
file path is logged at the start of `RunCoverage`. If the directory is
not writable by the SQL Server service account, no events get captured.

### Tests pass but coverage is low
The test's seed data might not satisfy the predicate. The framework emits an
UPDATE alongside each INSERT to maximize coverage, but if your predicate
has complex JOINs or sub-EXISTS, you may need a manual seed override.
Look at th