/*============================================================================
 * Verify_BranchSeeding.sql  —  Step 2 (predicate-inversion seeding) check
 *----------------------------------------------------------------------------
 * Run AFTER Patch_v11_BranchSeeding.sql, on AdventureWorks2025 (or any DB with
 * the framework + tSQLt installed).  Demonstrates that value-gated branches a
 * happy+NULL driver would MISS are now reached on purpose.
 *
 * uat.fn_grade has four value-gated arms (>=90, >=80, >=70, else). A single
 * "happy" sample int lands on exactly one arm and NULL lands on the guard, so
 * WITHOUT seeding three arms are uncovered.  WITH seeding the extractor derives
 * @score = 90 / 80 / 70 from the predicate literals and drives each arm.
 * Expect: branch coverage at/near 100% and a "predicate-inversion seed(s) added"
 * message.  Then it sweeps the standard uat fixtures so you can confirm no
 * regression on the existing shapes.
 *============================================================================*/
SET NOCOUNT ON;
IF SCHEMA_ID('uat') IS NULL EXEC('CREATE SCHEMA uat');
GO
CREATE OR ALTER FUNCTION uat.fn_grade(@score INT) RETURNS VARCHAR(4)
AS BEGIN
    DECLARE @g VARCHAR(4);
    IF @score IS NULL RETURN 'n/a';
    IF @score >= 90      SET @g = 'A';
    ELSE IF @score >= 80 SET @g = 'B';
    ELSE IF @score >= 70 SET @g = 'C';
    ELSE                 SET @g = 'F';
    RETURN @g;
END
GO

PRINT '=== SECTION 1: extractor output (what seeds were derived) ===';
SELECT ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(
        OBJECT_DEFINITION(OBJECT_ID('uat.fn_grade')),
        N'@score');
-- expect rows: @score=NULL (the IS NULL guard), @score=90, @score=80, @score=70
GO

PRINT '';
PRINT '=== SECTION 2: coverage WITH seeding (expect branch ~100%) ===';
EXEC TestGen.GenerateTestsForObject @SchemaName='uat', @ObjectName='fn_grade', @ExecuteScript=1;
EXEC TestGen.RunCoverageForFunction @SchemaName='uat', @FunctionName='fn_grade', @OutputMode='TEXT';
GO

PRINT '';
PRINT '=== SECTION 3: a string-valued gate (IN / =) ===';
GO
CREATE OR ALTER FUNCTION uat.fn_region(@code NCHAR(2)) RETURNS VARCHAR(20)
AS BEGIN
    IF @code = 'US' RETURN 'United States';
    IF @code IN ('GB','UK') RETURN 'United Kingdom';
    IF @code = 'CA' RETURN 'Canada';
    RETURN 'Other';
END
GO
SELECT ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_region')), N'@code');
-- expect: @code='US', @code='GB' (first IN element), @code='CA'
EXEC TestGen.GenerateTestsForObject @SchemaName='uat', @ObjectName='fn_region', @ExecuteScript=1;
EXEC TestGen.RunCoverageForFunction @SchemaName='uat', @FunctionName='fn_region', @OutputMode='TEXT';
GO

PRINT '';
PRINT '=== SECTION 4: cleanup ===';
BEGIN TRY EXEC tSQLt.DropClass 'test_fn_grade';  END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC tSQLt.DropClass 'test_fn_region'; END TRY BEGIN CATCH END CATCH;
DROP FUNCTION IF EXISTS uat.fn_grade;
DROP FUNCTION IF EXISTS uat.fn_region;
GO
PRINT 'Verify_BranchSeeding.sql complete.  Also re-run Verify_Functions.sql for the';
PRINT 'no-regression sweep of the standard shapes (coverage should be >= before).';
GO
