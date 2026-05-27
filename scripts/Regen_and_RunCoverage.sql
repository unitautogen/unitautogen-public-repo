/*******************************************************************************
 * Regen_and_RunCoverage.sql
 *
 * The analyzer v3.1 fix only affects NEWLY GENERATED tests.  Existing
 * test_uspV9ValidationTest procs were created against the old (v3.0)
 * analyzer and still have single-column seed INSERTs.
 *
 * This script:
 *   1) Drops and regenerates the test class for dbo.uspV9ValidationTest
 *   2) Runs coverage end-to-end
 *
 * Run this AFTER installing 17_Branch_Path_Analyzer_v3_1.sql.
 ******************************************************************************/
USE AdventureWorks2025;
GO

SET NOCOUNT ON;

PRINT '========== Step 1: drop the existing test class ==========';
-- tSQLt class is a schema; dropping it removes all generated test procs.
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'test_uspV9ValidationTest')
BEGIN
    EXEC tSQLt.DropClass 'test_uspV9ValidationTest';
    PRINT 'Dropped class test_uspV9ValidationTest';
END
ELSE
    PRINT 'Class test_uspV9ValidationTest did not exist - nothing to drop.';
GO

PRINT '';
PRINT '========== Step 2: regenerate tests against analyzer v3.1 ==========';
EXEC TestGen.GenerateTestsForProcedure
    @SchemaName    = N'dbo',
    @ProcName      = N'uspV9ValidationTest',
    @ExecuteScript = 1;
GO

PRINT '';
PRINT '========== Step 3: spot-check the regenerated Premium test ==========';
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(
    OBJECT_ID(N'[test_uspV9ValidationTest].[test uspV9ValidationTest executes @OrderType = Premium EXISTS path]'));
IF @def IS NULL
    PRINT '!! Premium EXISTS test was not generated.'
ELSE IF CHARINDEX('([CustomerID],[SubTotal])', @def) > 0
       OR CHARINDEX('([SubTotal],[CustomerID])', @def) > 0
    PRINT 'PASS - Premium test has multi-column seed.'
ELSE
BEGIN
    PRINT '!! Premium test still has single-column seed.  Showing the seed line:';
    DECLARE @sp INT = CHARINDEX('-- Seed exact data so EXISTS = TRUE', @def);
    IF @sp > 0
        PRINT SUBSTRING(@def, @sp, 250);
    ELSE
        PRINT '(no "Seed exact data" marker found)';
END;
GO

PRINT '';
PRINT '========== Step 4: run end-to-end coverage ==========';
EXEC TestGen.RunCoverage
    @SchemaName = N'dbo',
    @ProcName   = N'uspV9ValidationTest',
    @OutputMode = 'TEXT';
GO
