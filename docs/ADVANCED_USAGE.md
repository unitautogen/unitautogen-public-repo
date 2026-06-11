# Advanced usage — every user-facing method, every switch

This page documents the rest of the user-facing API and the full set
of parameters available on each procedure. If you haven't read
[EASY_USAGE.md](EASY_USAGE.md) yet, start there — it covers the four
commands you'll use 80% of the time. This page is what you reach for
when you need more control.

The complete reference (architecture, internals, every parameter on
every helper proc) lives in [REFERENCE_GUIDE.md](REFERENCE_GUIDE.md).
The paste-ready SQL snippets are in
[advanced-snippets.sql](advanced-snippets.sql).

## At a glance — every user-facing method

The four Easy Mode methods are included here for completeness; the
rest are the Advanced Mode additions.

| Method                                | Mode    | What it does                                                                                                       |
|---------------------------------------|---------|--------------------------------------------------------------------------------------------------------------------|
| `TestGen.GenerateAndRunCoverage`      | Easy    | One call: generate + run + coverage report, for one procedure.                                                     |
| `TestGen.GenerateAndCoverDatabase`    | Easy    | Same as above for every procedure in the database (or a filtered schema). CI/CD entry point.                       |
| `TestGen.GenerateTestsForProcedure`   | Easy    | Generate the test class for one procedure; do not run it.                                                          |
| `TestGen.GetCoverageReport`           | Easy    | Re-print the most recent coverage report for one procedure (switch TEXT ↔ HTML).                                   |
| `TestGen.GenerateTestsForSchema`      | Advanced| Generate test classes for every procedure in a schema (does not run them).                                         |
| `TestGen.RunCoverage`                 | Advanced| Run an existing test class under coverage instrumentation and print the report. (Used when you already have tests.)|
| `TestGen.EnsureCustomTestClass`       | Advanced| Create a separate `customtest_<proc>` class for your hand-written tests; never overwritten by regeneration.        |
| `TestGen.BlessBaseline`               | Advanced| Capture the current result-set shape as the baseline for the "stable shape" test.                                  |
| `TestGen.DropGeneratedTestClasses`    | Advanced| Tear-down helper: drop `test_*` classes the framework generated (with `@WhatIf` preview and `@SchemaFilter`).      |
| `TestGen.AssessTestability`           | Advanced| Inspect whether a procedure is auto-testable, and return the reason it isn't (if so).                              |
| `TestGen.AnalyzeBranchPaths`          | Advanced| Show the branch paths the generator will produce for a procedure (without generating anything).                    |

There are about twenty further internal procedures
(`SeedFakedTables`, `BootstrapCoverage`, `InstrumentProcedure`, etc.).
These are the framework's plumbing — you generally don't call them
directly. They're all documented in
[REFERENCE_GUIDE.md](REFERENCE_GUIDE.md).

---

## Generation switches — controlling what the test class contains

`TestGen.GenerateTestsForProcedure` (and the one-call wrappers that
delegate to it, `GenerateAndRunCoverage` and `GenerateAndCoverDatabase`)
accept several switches that toggle whole *families* of tests. The
defaults are sensible for most procedures; use these when you need to
opt out.

| Parameter                          | Default | Meaning                                                                                                          |
|------------------------------------|---------|------------------------------------------------------------------------------------------------------------------|
| `@EmitNullChecks`                  | `0`     | When `1`, force one NULL test per nullable parameter. Off by default — a procedure's genuine NULL handling is a real branch/line and is covered as such; this switch only adds speculative per-parameter NULL injection. |
| `@EmitScaffold`                    | `1`     | Generate the set-based / CTE characterisation scaffold test. Turn off for simple branching procedures.           |
| `@CaptureRows`                     | `0`     | Also generate a "golden row" baseline test that captures the current output of the procedure as the expected.    |
| `@EmitNegativeTests`               | `1`     | Scan the procedure source for `RAISERROR` / `THROW` paths and emit `ExpectException` tests for each.             |
| `@AssertExceptionOnInvalidInputs`  | `1`     | Boundary and NULL-for-matched-param tests expect an exception (only if the procedure has detectable error paths).|

**Example — minimal generation, no NULL checks and no scaffold:**

```sql
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName     = N'dbo',
     @ProcName       = N'uspV9ValidationTest',
     @EmitNullChecks = 0,
     @EmitScaffold   = 0;
```

**Example — generation with golden-row baseline:**

```sql
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName  = N'dbo',
     @ProcName    = N'uspGetOpenOrders',
     @CaptureRows = 1;
```

---

## `TestGen.GenerateTestsForSchema` — every procedure in a schema

Generates a test class for every procedure in the named schema, in
one call. Switches pass through to `GenerateTestsForProcedure`.

```sql
EXEC TestGen.GenerateTestsForSchema
     @SchemaName     = N'Production',
     @EmitNullChecks = 1,
     @EmitScaffold   = 1;
```

Use this when you want to *generate* schema-wide but don't yet want to
*run* coverage (which is what `GenerateAndCoverDatabase` does).

---

## `TestGen.RunCoverage` — measure coverage on existing tests

`RunCoverage` runs an existing test class under coverage
instrumentation and prints a report. Use it when the test class
already exists — either because you generated it earlier, or because
it's a class you wrote yourself.

```sql
EXEC TestGen.RunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials',
     @OutputMode = N'HTML';
```

`RunCoverage` is what `GenerateAndRunCoverage` calls internally after
generation. If you've just regenerated the test class via
`GenerateTestsForProcedure`, this is the second half of the cycle.

---

## Custom hand-written test classes — `EnsureCustomTestClass`

If you want to write tests by hand alongside the generated ones, do
**not** edit the generated `test_<proc>` class directly — your edits
will survive a regen (the framework hashes test bodies and preserves
yours), but the cleanest pattern is to put hand-written tests in a
separate class that the framework will never touch.

`EnsureCustomTestClass` creates `customtest_<proc>` for you, exactly
once per procedure:

```sql
EXEC TestGen.EnsureCustomTestClass
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials';
```

Then write your tests inside `customtest_uspGetBillOfMaterials`. They
will run under `tSQLt.Run` like any other class, and `RunCoverage`
will pick them up alongside the generated tests when calculating
coverage.

---

## `TestGen.BlessBaseline` — capture the current result-set shape

The generated scaffold test asserts that the procedure returns a
result set whose *shape* (column names and types) matches a stored
baseline. The first time you generate tests for a new procedure, no
baseline exists; `BlessBaseline` captures the current shape and
stores it as the expected baseline.

```sql
EXEC TestGen.BlessBaseline
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials';
```

Re-bless any time the procedure's result-set shape changes
intentionally — the test will start failing until you do.

---

## Tear-down — `DropGeneratedTestClasses`

When you want to drop the test classes the framework generated (e.g.
before re-creating them with different switches, or when retiring the
framework from a database), use `DropGeneratedTestClasses`. The
`@WhatIf = 1` flag previews without dropping.

```sql
EXEC TestGen.DropGeneratedTestClasses @WhatIf = 1;            -- preview
EXEC TestGen.DropGeneratedTestClasses;                         -- drop all generated classes
EXEC TestGen.DropGeneratedTestClasses @SchemaFilter = N'dbo';  -- drop only dbo's
EXEC TestGen.DropGeneratedTestClasses @IncludeCustom = 1;      -- also drop customtest_* classes
```

By default `customtest_*` classes are **not** dropped — your
hand-written tests are safe. Pass `@IncludeCustom = 1` only when you
really mean it.

---

## `TestGen.AssessTestability` — is this procedure auto-testable?

UnitAutogen detects procedures it can't meaningfully auto-test
(dynamic SQL, system-catalog dependencies, full-text search, etc.)
and labels them `NOT_TESTABLE` rather than producing misleading 0 %
coverage. `AssessTestability` lets you check ahead of time without
generating anything.

```sql
EXEC TestGen.AssessTestability
     @SchemaName = N'dbo',
     @ProcName   = N'uspSearchCandidateResumes';
-- returns: Verdict = 'NOT_TESTABLE', Reason = 'uses full-text search'
```

See [what-works.md](what-works.md) for the complete list of patterns
that flag NOT_TESTABLE and why.

---

## `TestGen.AnalyzeBranchPaths` — what tests will the generator produce?

`AnalyzeBranchPaths` shows you the branch paths the generator extracts
from a procedure — useful when you're debugging "why did the framework
only generate three tests?" or "which branch isn't being detected?"

```sql
EXEC TestGen.AnalyzeBranchPaths
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials';
-- returns one row per detected branch path, with the predicate text
-- and the leaf DML statement(s) under each branch
```

---

## Where to go next

The complete reference — every internal proc, the coverage
architecture, the strong-assertion mechanism, troubleshooting — is in
[REFERENCE_GUIDE.md](REFERENCE_GUIDE.md).

The paste-ready SQL snippets that illustrate everything on this page
are in [advanced-snippets.sql](advanced-snippets.sql).
