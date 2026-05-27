# Easy usage — the four commands you'll use 80% of the time

UnitAutogen exposes around ten user-facing stored procedures, but you only
need four of them for a normal workflow. This page covers those four.
For switches, helper procs, and edge cases, see
[ADVANCED_USAGE.md](ADVANCED_USAGE.md); for the complete reference, see
[REFERENCE_GUIDE.md](REFERENCE_GUIDE.md).

## At a glance

| # | Method                                | What it does                                                                                  | When to reach for it                                                                  |
|---|---------------------------------------|-----------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| 1 | `TestGen.GenerateAndRunCoverage`      | One call: generate the tests, run them, print the coverage report — for **one** procedure.    | Single-procedure workflow. The fastest way to see UnitAutogen on a real proc.         |
| 2 | `TestGen.GenerateAndCoverDatabase`    | Same as above but for **every** procedure in the database (or a filtered schema).             | CI/CD; whole-database coverage; a single command to characterise an entire codebase.  |
| 3 | `TestGen.GenerateTestsForProcedure`   | Generates the test class for one procedure — does **not** run it.                             | When you want to inspect or hand-edit the generated tests before running them.        |
| 4 | `TestGen.GetCoverageReport`           | Re-prints the most recent coverage report for one procedure (switch TEXT ↔ HTML).             | Free re-print — no re-instrument, no re-run. Useful when you want HTML after a TEXT.  |

If you remember nothing else from this page, remember rows 1 and 2.
Those are the two "magic buttons" that give you the entire round trip
(generate → test → coverage) in one statement.

---

## 1. `TestGen.GenerateAndRunCoverage` — one procedure, one call

**What it does:** generates the test class for the procedure, installs it,
runs the tests, and prints the coverage report. Everything you need in
one statement.

**Minimum usage:**

```sql
EXEC TestGen.GenerateAndRunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials';
```

**With an HTML coverage report (paste into a browser):**

```sql
EXEC TestGen.GenerateAndRunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials',
     @OutputMode = N'HTML';
```

That's it. Output prints into the SSMS messages tab and looks like:

```
=== TestGen.GenerateAndRunCoverage: dbo.uspGetBillOfMaterials ===
--- Step 1 of 2: generate + install the test class ---
... 12 tests generated for test_uspGetBillOfMaterials.
--- Step 2 of 2: run + measure coverage ---
+----------------------+--------+--------+---------+
| Test                 | Result | Time   | ...     |
| test path branch 1   | PASS   | 12 ms  |         |
... (one row per generated test)
+----------------------+--------+--------+---------+
Line coverage   : 87.5 %  (35 / 40)
Branch coverage : 80.0 %  (12 / 15)
Autonomy        : 100 %   (12 of 12 tests pass without manual edits)
```

---

## 2. `TestGen.GenerateAndCoverDatabase` — whole database, one call

**What it does:** runs the full generate-and-cover cycle for every
testable user procedure in the database, then prints a combined report.
This is the command you wire into CI.

**Minimum usage (every user schema, HTML report):**

```sql
EXEC TestGen.GenerateAndCoverDatabase;
```

**Just one schema, TEXT report:**

```sql
EXEC TestGen.GenerateAndCoverDatabase
     @SchemaFilter = N'Sales',
     @OutputMode   = N'TEXT';
```

**Skip a set of procedures by name pattern (e.g., legacy procs):**

```sql
EXEC TestGen.GenerateAndCoverDatabase
     @SchemaFilter   = N'dbo',
     @ExcludePattern = N'usp[_]Legacy[_]%';
```

The report lists every procedure with its line and branch coverage,
marks NOT_TESTABLE procedures with a clear reason (so you don't
mistake "framework couldn't auto-test this" for "0% coverage"),
and ends with a database-wide summary row.

---

## 3. `TestGen.GenerateTestsForProcedure` — generate, but don't run

**What it does:** writes the test class for one procedure into the
database, *but does not run it*. Use this when you want to see the
generated SQL — perhaps to add a hand-written test before running, or
to copy the generated code into source control.

**Minimum usage:**

```sql
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName    = N'dbo',
     @ProcName      = N'uspGetBillOfMaterials',
     @ExecuteScript = 1;       -- 1 = install the class; 0 = just return the script
```

After this runs, you'll have a tSQLt test class called
`test_uspGetBillOfMaterials` in the database. To run it:

```sql
EXEC tSQLt.Run 'test_uspGetBillOfMaterials';
```

(`tSQLt.Run` is part of tSQLt, not UnitAutogen — it's the standard
way to run any tSQLt test class.)

If you'd rather inspect the generated script before installing it,
set `@ExecuteScript = 0` and pass an `OUTPUT` parameter:

```sql
DECLARE @script NVARCHAR(MAX);
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName      = N'dbo',
     @ProcName        = N'uspGetBillOfMaterials',
     @ExecuteScript   = 0,
     @GeneratedScript = @script OUTPUT;
SELECT @script;   -- the full CREATE PROCEDURE statements for each test
```

---

## 4. `TestGen.GetCoverageReport` — re-print the last report

**What it does:** re-prints the coverage report for a procedure from
the last instrumented run. It does **not** re-instrument, does **not**
re-run the tests, and is therefore essentially free.

**Use it when** you ran `GenerateAndRunCoverage` with the default
`@OutputMode = 'TEXT'`, and now you want the same data as HTML to
share with someone — or vice versa.

**Minimum usage:**

```sql
EXEC TestGen.GetCoverageReport
     @SchemaName = N'dbo',
     @ProcName   = N'uspGetBillOfMaterials',
     @OutputMode = N'HTML';   -- or 'TEXT'
```

If the procedure has never been run under coverage, the call prints a
clear message saying so — you'll need to run `GenerateAndRunCoverage`
or `RunCoverage` first.

---

## Next steps

You now know the four commands that cover most of the day-to-day
workflow. If you need more — schema-wide generation, custom
hand-written test classes, the per-feature switches like
`@EmitNullChecks = 0`, the testability assessment proc — see
[ADVANCED_USAGE.md](ADVANCED_USAGE.md).

If anything in this page didn't work as described, please open a
[bug report](../../../issues/new/choose) — that's the most valuable
feedback we can get during Beta.
