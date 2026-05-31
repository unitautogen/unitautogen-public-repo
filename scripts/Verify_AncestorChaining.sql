/*============================================================================
 * Verify_AncestorChaining.sql  —  Step 2.1 (ancestor-chained seeding) check
 *----------------------------------------------------------------------------
 * Run AFTER Patch_v11_AncestorChaining.sql, on AdventureWorks2025.
 *
 * fn_nested has branches nested inside a DIFFERENT parameter's gate:
 *     IF @kind = 'A'  BEGIN  IF @amount > 1000 ...  ELSE ...  END
 *     ELSE IF @kind = 'B'  BEGIN  IF @amount < 0 ...  END
 * Step 2 alone seeds @amount and leaves @kind happy, so the inner arms are never
 * reached.  Step 2.1 carries the enclosing @kind gate down, so each inner branch
 * is driven with BOTH params set.
 *============================================================================*/
SET NOCOUNT ON;
IF SCHEMA_ID('uat') IS NULL EXEC('CREATE SCHEMA uat');
GO
CREATE OR ALTER FUNCTION uat.fn_nested(@kind CHAR(1), @amount INT) RETURNS VARCHAR(10)
AS BEGIN
    DECLARE @r VARCHAR(10) = 'none';
    IF @kind = 'A'
    BEGIN
        IF @amount > 1000 SET @r = 'big';
        ELSE              SET @r = 'small';
    END
    ELSE IF @kind = 'B'
    BEGIN
        IF @amount < 0 SET @r = 'neg';
    END
    RETURN @r;
END
GO

PRINT '=== SECTION 1: extractor output, grouped by branch (note the ancestors) ===';
SELECT BranchId, ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_nested')), N'@kind,@amount')
ORDER BY BranchId, ParamName;
-- expect, e.g.:
--   1  @kind   'A'
--   2  @amount 1001        2  @kind 'A'      <- inner branch carries the @kind='A' gate
--   3  @kind   'B'
--   4  @amount -1          4  @kind 'B'      <- inner branch carries the @kind='B' gate
GO

PRINT '';
PRINT '=== SECTION 2: coverage WITH ancestor-chained seeding (expect branch ~100%) ===';
EXEC TestGen.GenerateTestsForObject @SchemaName='uat', @ObjectName='fn_nested', @ExecuteScript=1;
EXEC TestGen.RunCoverageForFunction @SchemaName='uat', @FunctionName='fn_nested', @OutputMode='TEXT';
GO

PRINT '';
PRINT '=== SECTION 3: cleanup ===';
BEGIN TRY EXEC tSQLt.DropClass 'test_fn_nested'; END TRY BEGIN CATCH END CATCH;
DROP FUNCTION IF EXISTS uat.fn_nested;
GO
PRINT 'Verify_AncestorChaining.sql complete.';
PRINT 'Also re-run Verify_BranchSeeding.sql (fn_grade still 5/5) and Verify_Functions.sql';
PRINT '(standard shapes unchanged) to confirm no regression.';
GO
