# Testing functions (scalar & table-valued) — experimental

> **Status: working, validated on AdventureWorks2025.** Installed by
> `modules/30_Function_Support_v1.sql` (spliced into `Install_UnitAutogen.sql`),
> it runs side-by-side with the procedure pipeline and changes nothing about how
> procedures are tested. Verified end-to-end via `scripts/Verify_Functions.sql`:
> scalar, inline-TVF and multi-statement-TVF functions all get real line **and**
> branch coverage. Coverage gaps reflect branches the sample inputs don't reach
> (reported honestly), never an instrumentation blind spot. Please still file
> issues for anything it gets wrong on your own functions.

UnitAutogen can now generate tests and measure real line/branch coverage for the
three user-defined function shapes:

| Type | SQL                                        | Tested via            |
| ---- | ------------------------------------------ | --------------------- |
| `FN` | scalar function                            | `SELECT dbo.fn(...)`  |
| `IF` | inline table-valued function               | `SELECT * FROM dbo.fn(...)` |
| `TF` | multi-statement table-valued function      | `SELECT * FROM dbo.fn(...)` |

## Quick start

```sql
-- Generate a tSQLt test class for any procedure OR function (auto-detected):
EXEC TestGen.GenerateTestsForObject
     @SchemaName = N'dbo',
     @ObjectName = N'YourFunction',
     @ExecuteScript = 1;

-- Run the tests:
EXEC tSQLt.Run 'test_YourFunction';

-- Measure line/branch coverage of the function:
EXEC TestGen.RunCoverageForFunction
     @SchemaName   = N'dbo',
     @FunctionName = N'YourFunction',
     @OutputMode   = N'TEXT';     -- or N'HTML'
```

`GenerateTestsForObject` is a dispatcher: it routes procedures to the existing
`GenerateTestsForProcedure` and functions to the new function generators, so you
can point it at anything.

## How coverage works — the shadow procedure

A T-SQL function body cannot contain `EXEC`, cannot call a procedure, and cannot
write to a table, so the coverage probe the procedure pipeline injects
(`EXEC TestGen.RecordCoverageHit`) cannot live inside a function. Capturing a
scalar function's statements directly with Extended Events is also unreliable —
its statements execute as part of the calling statement, and SQL Server 2019+
*inlines* eligible scalar functions (the Froid optimizer folds the body into the
caller's plan, emitting no per-statement events).

So `RunCoverageForFunction` builds a **shadow procedure** `<fn>_covfn` whose body
is the function body with only the wrapper rewritten (scalar `RETURN <expr>`
becomes `SET @__ret = <expr>; RETURN`; a multi-statement TVF's return table
becomes a table variable). Because the shadow has a one-to-one statement and
branch structure with the function, the **existing** coverage pipeline measures
it exactly — a procedure's statements always fire `sp_statement_completed` and
are never inlined. The shadow is built, measured, and dropped per run; coverage
is reported against the original function name.

If a function body is too unusual to transform safely, the shadow is **not**
built and coverage is reported as an honest deferral rather than a misleading
0%.

## What the generated tests assert

Functions have no side effects, so there is no before/after table delta to
assert. The generated tests are characterization/regression checks:

- **Scalar** — a *determinism* test (the function returns the same value for the
  same inputs, which catches `NEWID()`/`GETDATE()` leakage); for **pure**
  functions (those that read no tables) a *blessed-value* `AssertEquals` whose
  expected value is captured at generation time; and a NULL-argument test. A
  table-reading scalar whose value depends on seeded data gets a
  `[@tSQLt:SkipTest]` placeholder with guidance — never a faked green test.
- **Table-valued** — a *result-shape* assertion (the returned columns match the
  function's declared `RETURNS` contract via `AssertEqualsTableSchema`) and a
  *determinism* assertion (`AssertEqualsTable` of two materializations). Exact
  row-value blessing under seeded data is a planned follow-up and is emitted as a
  `[@tSQLt:SkipTest]` placeholder for now.

Referenced tables are isolated with `tSQLt.FakeTable`. Faking called *functions*
(including TVFs, via `tSQLt.FakeFunction`) is a planned follow-up.

## Whole-database runs

`TestGen.GenerateAndCoverDatabase` is function-aware: it enumerates stored
procedures **and** user functions (`FN`/`IF`/`TF`) and reports them together in
one coverage report. Functions are routed through `RunCoverageForFunction`
automatically. (A function row's *Tests* count currently reflects its coverage
driver, not its `test_<fn>` assertion suite — coverage is accurate; aggregating
the assertion-test counts is a follow-up.)

## Known limitations

- The coverage driver currently exercises happy-path and NULL argument sets;
  full per-branch seeding for functions is a follow-up.
- TVF row-value blessing and `FakeFunction` emission for dependencies are
  follow-ups.
- Encrypted and CLR (`EXTERNAL NAME`) functions are reported as not testable.

The full internal design rationale is in `DESIGN_v11_Functions.md`.
