# tSQLt Auto-Generation Framework v9.4.2 - Installation

## Prerequisites
- SQL Server 2017 or later
- tSQLt installed in the target database - **V1.0.7597.5637 (Oct 2020) or
  later**, required for the `--[@tSQLt:SkipTest]` annotation v9.4.2 emits for
  branches it cannot auto-assert (check with `SELECT tSQLt.Info();`)
- Permissions: CREATE PROCEDURE, CREATE FUNCTION, CREATE SCHEMA

## Option 1 - Brand-new install (recommended for a fresh database)
Run the single-file combined installer:

  1. Open `Install_All_Combined_v9_2_FINAL.sql` in SSMS.
  2. `USE YourDatabase;`
  3. Execute the whole file (SQLCMD mode NOT required).

It is idempotent (safe to re-run) and DROP/CREATEs every framework object.
The last line of output is `TestGen.GetCoverageReport v2 created.`  This file
carries the full v9.4.2 code (strong branch-test + delta assertions) in its
test-generator and branch-analyzer sections; all coverage objects
(InstrumentProcedure, BootstrapCoverage, RecordCoverageHit, RunCoverage,
GetCoverageReport) are included and complete.

## Option 2 - Upgrade an existing v9.2 / v9.3 / v9.4 install in place
v9.4.2 only changes the branch analyzer and the test generator, so an existing
install can be upgraded with the SQLCMD-mode patch instead of a full re-run:

  1. Open `scripts\Patch_TestGen_StrongAssertions.sql` in SSMS.
  2. Query menu -> SQLCMD Mode  (must be ON - the script uses :r includes).
  3. Open the file FROM THE PACKAGE ROOT (the folder that contains the
     `modules` sub-folder) so the `:r modules\...` paths resolve.
  4. `USE YourDatabase;`  then execute the script.

It (re)creates TestGen.ExtractLeafDml, TestGen.AnalyzeBranchPaths and
TestGen.GenerateTestsForProcedure from modules\17_Branch_Path_Analyzer_v3_2.sql
and modules\04_Test_Generator_v3.sql - which carry all of v9.4, v9.4.1,
Phase B and v9.4.2.

Re-running the combined installer from Option 1 also upgrades in place, so
either path is fine.

## Quick start
    EXEC TestGen.GenerateTestsForProcedure @SchemaName='dbo', @ProcName='YourProc', @ExecuteScript=1;
    EXEC TestGen.RunCoverage              @SchemaName='dbo', @ProcName='YourProc', @OutputMode='TEXT';

## Verify
Run `scripts\Verify_v9_4.sql` in SSMS.  It regenerates the sample test
classes, exercises the strong branch-test assertions, and runs coverage.
On AdventureWorks2025 / uspV9ValidationTest, v9.4.2 holds 100% line and 100%
branch coverage; the only failing tests are the NULL-rejection tests, which
correctly report that the sample procedure does not validate NULL inputs
(a procedure-design gap, not a framework issue).

## What's in v9.4.2
Branch/path tests now carry real assertions and no tautologies: a
snapshot-and-replay AssertEqualsTable, a before/after delta assertion (an
INSERT branch must make the table gain a row from the procedure; an UPDATE
branch must hold the row count and actually change rows), and a result-set
AssertEqualsString for CASE-derived output columns.  Branch bodies that
cannot be replayed are marked with the `--[@tSQLt:SkipTest]` annotation
("MANUAL TEST REQUIRED") so they report as skipped instead of a silent
smoke pass - no phantom tests pass.  See README_v9_4.md ("What's new in
v9.4.2") and CHANGES.md.

## Package contents
- Install_All_Combined_v9_2_FINAL.sql - complete v9.4.2 single-file installer
- scripts\Patch_TestGen_St