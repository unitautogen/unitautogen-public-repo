# Quick start

Get from "I just heard about UnitAutogen" to "I can see a coverage report for
one of my stored procedures" in under fifteen minutes.

## Prerequisites

- **SQL Server 2017 (MSSQL14) or later** running locally or somewhere you can
  reach with SSMS or Azure Data Studio.
- **tSQLt v1.0.7597.5637 (Oct 2020) or later** installed in the target
  database. Confirm with:

      SELECT tSQLt.Info();

  If you don't have tSQLt, install it from [https://tsqlt.org](https://tsqlt.org)
  first.

- **Permissions** on the target database: `CREATE PROCEDURE`, `CREATE FUNCTION`,
  `CREATE SCHEMA`.

- **Extended Events directory** the SQL Server service account can write to.
  By default UnitAutogen uses
  `D:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\` —
  change it in the installer if your instance is different.

## Step 1 — Install UnitAutogen

Open `Install_UnitAutogen.sql` in SSMS. The installer is **idempotent** — safe
to run on a fresh database or to re-run for an upgrade.

    USE YourDatabase;
    GO
    -- Then execute the whole `Install_UnitAutogen.sql` file.

You should see `Framework installed successfully.` near the end.

## Step 1b — Register the predicate parser

Open `clr/Install-UnitAutogenClr.SSMS.sql` (in the repo root `clr/` folder) in
SSMS against the **same** database and execute it. This registers the in-database
C# parser — the single parser UnitAutogen uses — which fills
`TestGen.PredicateInbox` so data-shape branches (EXISTS / COUNT / scalar-subquery
gates) get real seeded tests. It needs sysadmin once and `clr enabled = 1`
(see [`INSTALL.md`](../INSTALL.md)). Run it in SSMS, not `sqlcmd`.

> Prefer one command? `Install-Module UnitAutogen` then
> `Install-UnitAutogenDatabase` does both steps for you — see [`INSTALL.md`](../INSTALL.md).

For upgrade paths and the modular install option, see [`INSTALL.md`](../INSTALL.md).

## Step 2 — Generate a test class for one procedure

Pick any procedure in your database. We'll use `dbo.YourProcedure` as a stand-in.
First parse its predicates (once per procedure or per schema), then generate:

    EXEC TestGen.ParseProcedurePredicates
         @Schema   = N'dbo',
         @ProcName = N'YourProcedure';

    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName    = N'dbo',
         @ProcName      = N'YourProcedure',
         @ExecuteScript = 1;

This creates a `test_YourProcedure` class containing:

- A happy-path test
- Boundary tests (low/high values for numeric parameters)
- NULL-input rejection tests for each parameter
- A test per IF / CASE / EXISTS branch in the procedure

## Step 3 — (Optional) Bless a baseline result-set shape

If you want the "stable result-set shape" test to assert against the current
output:

    EXEC TestGen.BlessBaseline
         @SchemaName = N'dbo',
         @ProcName   = N'YourProcedure';

## Step 4 — Run the tests

    EXEC tSQLt.Run 'test_YourProcedure';

You'll get the standard tSQLt output: pass / fail counts per test.

## Step 5 — Measure coverage

    EXEC TestGen.RunCoverage
         @SchemaName = N'dbo',
         @ProcName   = N'YourProcedure',
         @OutputMode = N'TEXT';     -- or N'HTML' for a styled report

The coverage run will:

1. Re-instrument the procedure with line probes
2. Set up a synonym so calls route through the instrumented copy
3. Start an Extended Events capture
4. Run the test class
5. Parse the XEL file and fill `TestGen.CoverageHits`
6. Restore the original procedure
7. Print the coverage report

You should see line and branch coverage percentages and a list of any
uncovered lines/branches.

## Step 6 — Iterate

To re-fetch the latest coverage report without re-running:

    EXEC TestGen.GetCoverageReport
         @SchemaName = N'dbo',
         @ProcName   = N'YourProcedure',
         @OutputMode = N'HTML';

To regenerate the test class after changing the procedure's parameter list or
branch structure:

    EXEC tSQLt.DropClass 'test_YourProcedure';
    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName='dbo', @ProcName='YourProcedure', @ExecuteScript=1;

## When it doesn't work

See [`what-works.md`](what-works.md) for the honest scope. If you hit something
that should work but doesn't, please open an Issue with the bug-report template
filled in — that's the most valuable contribution you can make during Beta.

## Worked examples

See [`usage-examples.sql`](usage-examples.sql) for a longer worked example
against AdventureWorks-style procedures.

## Full reference guide

[`REFERENCE_GUIDE.md`](REFERENCE_GUIDE.md) contains the complete usage guide
for the v10 release line, including every stored procedure the framework
exposes, the coverage architecture, troubleshooting tips, and the full feature
history.
