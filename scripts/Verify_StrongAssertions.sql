/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License v3.0 as published
 * by the Free Software Foundation. See the LICENSE file at the repository
 * root for the full text, and COPYRIGHT for the author's notice.
 *
 * Distributed WITHOUT ANY WARRANTY, even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * A separate commercial licence (AGPL-free) is available from the copyright
 * holder. Contact: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

/*============================================================================
  Verify_v9_4.sql   --   tSQLt Auto-Gen Framework   v9.4 end-to-end verification
  ----------------------------------------------------------------------------
  PURPOSE
    One script to verify the v9.4 "strong branch-test assertions" release
    (incl. v9.4.1 + Phase B) on a live database.  It:
      STEP 0   pre-flight: confirm the v9.4 / v9.4.1 / Phase B code is installed
      STEP 1-3 drop + regenerate the test class for each exercised procedure
      STEP 4   run the tSQLt tests against the REAL procedures, so the
               STRENGTHENED assertions are actually exercised -- this is where
               v9.4 may surface new FAILURES that the old weak assertions hid
      STEP 5   STRONG-vs-WEAK assertion census for every generated test  (grid)
      STEP 6   tSQLt.TestResult dump -- failures first, with Msg, for triage (grid)
      STEP 7   TestGen.RunCoverage for each proc -- coverage must still hold 100%

  PREREQUISITE
    The v9.4 framework code must already be installed.  If STEP 0 reports any
    FAIL, STOP -- STEPs 1-7 will be skipped -- and apply ONE of:
      - scripts\Patch_TestGen_StrongAssertions.sql   (re-creates the 3 procs)
      - Install_All_Combined_v9_2_FINAL.sql          (full idempotent install)
    then re-run this script.

  HOW TO READ THE RESULT
    - Coverage (STEP 7) should still be 100% / 100% / 100%.  v9.4 does NOT change
      which lines are hit -- only how strictly each branch test asserts.
    - Some branch tests that were green on weak assertions MAY now FAIL.  That is
      the strengthened assertion working.  Triage each failure from STEP 6:
        * a generator bug      -> the replayed DML / param substitution is wrong
        * a genuine mismatch   -> the seed and the proc's real effect disagree
      The 4 (uspV9) + 3 (uspLevel3) NULL-rejection failures are a known
      proc-design gap, NOT a v9.4 regression.

  HOW TO USE
    Run the whole script in SSMS against AdventureWorks2025.
    Send back the Messages pane in full, plus the STEP 5 and STEP 6 grids.

  This script DROPS and REGENERATES test classes (test_<proc>).
  It creates / alters / drops NO framework objects.
============================================================================*/
SET NOCOUNT ON;
USE [AdventureWorks2025];
GO

PRINT '============================================================';
PRINT ' STEP 0 : pre-flight -- is the v9.4 framework code installed?';
PRINT '============================================================';
DECLARE @ok BIT = 1;

IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
BEGIN PRINT '  FAIL : TestGen.ExtractLeafDml is missing (v9.4 leaf-DML helper).'; SET @ok = 0; END
ELSE PRINT '  OK   : TestGen.ExtractLeafDml present.';

DECLARE @ana NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('TestGen.AnalyzeBranchPaths'));
IF @ana IS NULL OR @ana NOT LIKE '%ExtractLeafDml%' OR @ana NOT LIKE '%BodyDmlText%'
BEGIN PRINT '  FAIL : TestGen.AnalyzeBranchPaths is not the v9.4 version (no body-DML capture).'; SET @ok = 0; END
ELSE PRINT '  OK   : TestGen.AnalyzeBranchPaths is v9.4 (body-DML capture present).';

DECLARE @gen NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('TestGen.GenerateTestsForProcedure'));
IF @gen IS NULL OR @gen NOT LIKE '%AssertEqualsTable%'
BEGIN PRINT '  FAIL : TestGen.GenerateTestsForProcedure does not emit AssertEqualsTable (pre-v9.4).'; SET @ok = 0; END
ELSE PRINT '  OK   : TestGen.GenerateTestsForProcedure emits AssertEqualsTable (v9.4).';

IF @gen IS NOT NULL AND @gen LIKE '%AssertEqualsString%'
    PRINT '  OK   : TestGen.GenerateTestsForProcedure emits AssertEqualsString (v9.4 Phase B).';
ELSE
    PRINT '  WARN : no AssertEqualsString in the generator -- v9.4 Phase B not applied.';

IF @ok = 1
    PRINT '  --> pre-flight PASSED.  Proceeding with regeneration.';
ELSE
    PRINT '  --> pre-flight FAILED.  STOP: apply the v9.4 patch, then re-run.  STEPs 1-7 are skipped.';
GO

----------------------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT ' STEP 1 : regenerate test class for dbo.uspV9ValidationTest';
PRINT '============================================================';
IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
    PRINT '  SKIPPED -- v9.4 not installed (see STEP 0).';
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'test_uspV9ValidationTest')
    BEGIN
        EXEC tSQLt.DropClass 'test_uspV9ValidationTest';
        PRINT '  Dropped existing class test_uspV9ValidationTest.';
    END
    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName    = N'dbo',
         @ProcName      = N'uspV9ValidationTest',
         @ExecuteScript = 1;
END
GO

PRINT '';
PRINT '============================================================';
PRINT ' STEP 2 : regenerate test class for dbo.uspLevel3ValidationTest';
PRINT '============================================================';
IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
    PRINT '  SKIPPED -- v9.4 not installed (see STEP 0).';
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'test_uspLevel3ValidationTest')
    BEGIN
        EXEC tSQLt.DropClass 'test_uspLevel3ValidationTest';
        PRINT '  Dropped existing class test_uspLevel3ValidationTest.';
    END
    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName    = N'dbo',
         @ProcName      = N'uspLevel3ValidationTest',
         @ExecuteScript = 1;
END
GO

PRINT '';
PRINT '============================================================';
PRINT ' STEP 3 : regenerate test class for dbo.uspGetBillOfMaterials';
PRINT '============================================================';
IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
    PRINT '  SKIPPED -- v9.4 not installed (see STEP 0).';
ELSE
BEGIN
    IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'test_uspGetBillOfMaterials')
    BEGIN
        EXEC tSQLt.DropClass 'test_uspGetBillOfMaterials';
        PRINT '  Dropped existing class test_uspGetBillOfMaterials.';
    END
    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName    = N'dbo',
         @ProcName      = N'uspGetBillOfMaterials',
         @ExecuteScript = 1;
END
GO

----------------------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT ' STEP 4 : run the tSQLt tests against the REAL procedures';
PRINT '          (this exercises the strengthened v9.4 assertions)';
PRINT '============================================================';
-- tSQLt.RunAll resets tSQLt.TestResult and runs every test class in the DB,
-- so STEP 6 can read a complete result set in one place.
IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
    PRINT '  SKIPPED -- v9.4 not installed (see STEP 0).';
ELSE
    EXEC tSQLt.RunAll;
GO

----------------------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT ' STEP 5 : STRONG-vs-WEAK assertion census (result grid)';
PRINT '          every branch test should carry a STRONG assertion';
PRINT '============================================================';
SELECT
    SCHEMA_NAME(p.schema_id)                       AS TestClass,
    p.name                                         AS TestName,
    CASE WHEN p.name LIKE '%path%' THEN 'branch' ELSE 'generic' END AS TestKind,
    CASE
        WHEN OBJECT_DEFINITION(p.object_id) LIKE '%AssertEqualsTable%'
            THEN 'STRONG -- AssertEqualsTable (snapshot/replay)'
        WHEN OBJECT_DEFINITION(p.object_id) LIKE '%AssertEqualsString%'
            THEN 'STRONG -- AssertEqualsString (result-set)'
        WHEN OBJECT_DEFINITION(p.object_id) LIKE '%coverage/smoke only%'
            THEN 'SMOKE  -- labelled (no-table / compound branch)'
        WHEN OBJECT_DEFINITION(p.object_id) LIKE '%ExpectException%'
            THEN 'n/a    -- ExpectException (NULL-rejection test)'
        WHEN OBJECT_DEFINITION(p.object_id) LIKE '%AssertEquals %'
            THEN 'WEAK   -- AssertEquals row-count / 1=1  <== investigate'
        ELSE 'other'
    END AS AssertionKind
FROM sys.procedures p
WHERE SCHEMA_NAME(p.schema_id) IN
      ('test_uspV9ValidationTest','test_uspLevel3ValidationTest','test_uspGetBillOfMaterials')
ORDER BY TestClass,
         CASE WHEN p.name LIKE '%path%' THEN 0 ELSE 1 END,   -- branch tests first
         p.name;
GO

----------------------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT ' STEP 6 : tSQLt.TestResult -- failures first, with Msg (grid)';
PRINT '          triage each failing branch test:';
PRINT '            generator bug  vs  genuine seed/replay mismatch';
PRINT '============================================================';
SELECT
    r.Class,
    r.TestCase,
    r.Result,
    r.Msg
FROM tSQLt.TestResult AS r
WHERE r.Class IN
      ('test_uspV9ValidationTest','test_uspLevel3ValidationTest','test_uspGetBillOfMaterials')
ORDER BY
    CASE r.Result WHEN 'Success' THEN 1 ELSE 0 END,   -- Failure / Error first
    r.Class,
    r.TestCase;
GO

----------------------------------------------------------------------------
PRINT '';
PRINT '============================================================';
PRINT ' STEP 7 : coverage -- must still hold 100% / 100% / 100%';
PRINT '============================================================';
IF OBJECT_ID('TestGen.ExtractLeafDml','P') IS NULL
    PRINT '  SKIPPED -- v9.4 not installed (see STEP 0).';
ELSE
BEGIN
    PRINT '----- uspV9ValidationTest -----';
    EXEC TestGen.RunCoverage @SchemaName = N'dbo', @ProcName = N'uspV9ValidationTest',    @OutputMode = 'TEXT';
    PRINT '';
    PRINT '----- uspLevel3ValidationTest -----';
    EXEC TestGen.RunCoverage @SchemaName = N'dbo', @ProcName = N'uspLevel3ValidationTest', @OutputMode = 'TEXT';
    PRINT '';
    PRINT '----- uspGetBillOfMaterials -----';
    EXEC TestGen.RunCoverage @SchemaName = N'dbo', @ProcName = N'uspGetBillOfMaterials',   @OutputMode = 'TEXT';
END
GO

PRINT '';
PRINT '============================================================';
PRINT ' Verify_v9_4 complete.';
PRINT '   Send back: the full Messages pane + STEP 5 and STEP 6 grids.';
PRINT '============================================================';
GO
