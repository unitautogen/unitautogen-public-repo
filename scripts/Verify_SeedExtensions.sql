/*============================================================================
 * Verify_SeedExtensions.sql  —  reversed / NOT / non-numeric seed check
 *----------------------------------------------------------------------------
 * Run AFTER Patch_v11_SeedExtensions.sql, on AdventureWorks2025 (or any DB with
 * the framework + tSQLt installed).  Demonstrates that three predicate shapes
 * previously left as residue are now seeded on purpose, and that the existing
 * shapes + the lhsOk guard are unaffected.
 *============================================================================*/
SET NOCOUNT ON;
IF SCHEMA_ID('uat') IS NULL EXEC('CREATE SCHEMA uat');
GO

PRINT '=== SECTION 1: #2 reversed predicates (literal <op> @param) ===';
GO
CREATE OR ALTER FUNCTION uat.fn_rev(@status INT, @n INT) RETURNS INT
AS BEGIN
    IF 5 = @status RETURN 1;          -- reversed = : seed @status=5
    IF 0 < @n      RETURN 2;          -- reversed < : @n>0, seed @n=1
    IF 90 <= @n    RETURN 3;          -- reversed <=: @n<=90, seed @n=90
    IF @n > 10     RETURN 4;          -- param-first control: seed @n=11
    RETURN 0;
END
GO
SELECT BranchId, ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_rev')), N'@status,@n')
ORDER BY BranchId, ParamName;
-- expect: @status=5 ; @n=1 ; @n=90 ; @n=11
GO

PRINT '';
PRINT '=== SECTION 2: #3 NOT IN / NOT LIKE / NOT BETWEEN ===';
GO
CREATE OR ALTER FUNCTION uat.fn_not(@code NCHAR(2), @name VARCHAR(50), @amt INT) RETURNS INT
AS BEGIN
    IF @code NOT IN ('US','GB')          RETURN 1;   -- seed @code='US~'
    IF @name NOT LIKE 'abc%'             RETURN 2;   -- seed @name='' (empty)
    IF @amt  NOT BETWEEN 100 AND 200     RETURN 3;   -- seed @amt=99
    RETURN 0;
END
GO
SELECT BranchId, ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_not')), N'@code,@name,@amt')
ORDER BY BranchId, ParamName;
-- expect: @code='US~' ; @name='' ; @amt=99
GO

PRINT '';
PRINT '=== SECTION 3: #4 non-numeric < > <> (string / date literals) ===';
GO
CREATE OR ALTER FUNCTION uat.fn_str(@grade CHAR(1), @dt DATE) RETURNS INT
AS BEGIN
    IF @grade < 'M'           RETURN 1;   -- seed @grade='' (sorts before M)
    IF @grade > 'M'           RETURN 2;   -- seed @grade='M~'
    IF @grade <> 'X'          RETURN 3;   -- seed @grade='X~'
    IF @dt    < '2020-01-01'  RETURN 4;   -- seed @dt='' (lexical, ISO date)
    RETURN 0;
END
GO
SELECT BranchId, ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_str')), N'@grade,@dt')
ORDER BY BranchId, ParamName;
-- expect: @grade='' ; @grade='M~' ; @grade='X~' ; @dt=''
GO

PRINT '';
PRINT '=== SECTION 4: lhsOk guard — NO speculative seed on non-literal LHS ===';
GO
CREATE OR ALTER FUNCTION uat.fn_guard(@a INT, @b INT, @w INT) RETURNS INT
AS BEGIN
    IF @a + 5 > @b RETURN 1;   -- arithmetic LHS: NO seed (residue, correct)
    IF @a = 3      RETURN 2;   -- param-first control: seed @a=3
    RETURN 0;
END
GO
SELECT BranchId, ParamName, SeedLiteral
FROM TestGen.ExtractBranchSeeds(OBJECT_DEFINITION(OBJECT_ID('uat.fn_guard')), N'@a,@b,@w')
ORDER BY BranchId, ParamName;
-- expect: exactly ONE row, @a=3 (the @a+5>@b branch yields no seed)
GO

PRINT '';
PRINT '=== SECTION 5: end-to-end coverage on one proof fn (run in SSMS/sqlcmd; ';
PRINT '    XEvent capture does NOT work through a pooled MCP transaction) ===';
EXEC TestGen.GenerateTestsForObject  @SchemaName='uat', @ObjectName='fn_not', @ExecuteScript=1;
EXEC TestGen.RunCoverageForFunction  @SchemaName='uat', @FunctionName='fn_not', @OutputMode='TEXT';
GO

PRINT '';
PRINT '=== SECTION 6: cleanup ===';
BEGIN TRY EXEC tSQLt.DropClass 'test_fn_not'; END TRY BEGIN CATCH END CATCH;
DROP FUNCTION IF EXISTS uat.fn_rev;
DROP FUNCTION IF EXISTS uat.fn_not;
DROP FUNCTION IF EXISTS uat.fn_str;
DROP FUNCTION IF EXISTS uat.fn_guard;
GO
PRINT 'Verify_SeedExtensions.sql complete.  Re-run Verify_BranchSeeding.sql +';
PRINT 'Verify_Functions.sql for the no-regression sweep of the standard shapes.';
GO
