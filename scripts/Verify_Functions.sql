/*============================================================================
 * Verify_Functions.sql  —  validate v11 scalar/TVF support on AdventureWorks2025
 *----------------------------------------------------------------------------
 * PREREQS
 *   1. tSQLt installed in this database.
 *   2. Install_UnitAutogen.sql already run (it now carries module 30,
 *      the function support).  Quick check: OBJECT_ID('TestGen.GenerateTestsForObject','P').
 *
 * WHAT IT DOES  (run the whole file; read the PRINT output top-to-bottom)
 *   Section 1  creates a self-contained [uat] schema with one function of each
 *              shape, so validation does not depend on which functions ship in
 *              your copy of AdventureWorks.
 *   Section 2  unit-checks the shadow-procedure transform directly
 *              (BuildShadowProcForFunction -> prints Status + the generated
 *              shadow body).  This is the riskiest piece, so it is checked in
 *              isolation first.
 *   Section 3  generates test classes (GenerateTestsForObject) and runs them.
 *   Section 4  measures coverage (RunCoverageForFunction, TEXT).
 *   Section 5  repeats 3-4 against REAL AdventureWorks functions if present.
 *   Section 6  teardown (drops the [uat] schema and the generated test classes).
 *
 * WHAT "PASS" LOOKS LIKE
 *   - Section 2 prints  Status = OK  for all four [uat] functions, and each
 *     shadow body is a compilable CREATE PROCEDURE mirroring the function.
 *   - Section 3: the generated test classes run with 0 unexpected failures
 *     (value-characterization tests for table-reading functions are SKIPPED,
 *     by design, not failed).
 *   - Section 4: each function reports a real line/branch coverage number
 *     (NOT "coverage deferred").  The pure branch function [uat.fn_classify]
 *     will be < 100% branch because the driver only sends happy+NULL inputs -
 *     that is expected and honest, not a bug.
 *
 * NOTE: this writes to a clean DB; Section 6 cleans up.  Comment out Section 6
 *       if you want to inspect the generated test classes afterward.
 *===========================================================================*/
SET NOCOUNT ON;
GO

IF OBJECT_ID('TestGen.GenerateTestsForObject','P') IS NULL
   OR OBJECT_ID('TestGen.RunCoverageForFunction','P') IS NULL
BEGIN
    RAISERROR('Function support not installed. Run Install_UnitAutogen.sql first.',16,1);
    SET NOEXEC ON;
END;
GO

/*============================================================================
 * SECTION 1 — sample functions, one per shape
 *===========================================================================*/
IF SCHEMA_ID('uat') IS NULL EXEC('CREATE SCHEMA uat');
GO
-- drop any leftovers from a previous run
IF OBJECT_ID('uat.fn_classify','FN')      IS NOT NULL DROP FUNCTION uat.fn_classify;
IF OBJECT_ID('uat.fn_inline','IF')        IS NOT NULL DROP FUNCTION uat.fn_inline;
IF OBJECT_ID('uat.fn_mstvf','TF')         IS NOT NULL DROP FUNCTION uat.fn_mstvf;
IF OBJECT_ID('uat.fn_count_by_color','FN') IS NOT NULL DROP FUNCTION uat.fn_count_by_color;
GO

-- (a) PURE scalar with branches  -> blessed-value + branch coverage via shadow
CREATE FUNCTION uat.fn_classify(@n INT)
RETURNS VARCHAR(10)
AS
BEGIN
    DECLARE @r VARCHAR(10);
    IF @n IS NULL  RETURN 'null';
    IF @n < 0      SET @r = 'neg';
    ELSE IF @n = 0 SET @r = 'zero';
    ELSE           SET @r = 'pos';
    RETURN @r;
END;
GO

-- (b) INLINE table-valued (one statement)
CREATE FUNCTION uat.fn_inline(@id INT)
RETURNS TABLE
AS RETURN (SELECT @id AS Id, @id * 2 AS Doubled);
GO

-- (c) MULTI-STATEMENT table-valued with a loop
CREATE FUNCTION uat.fn_mstvf(@n INT)
RETURNS @t TABLE (Seq INT, Val INT)
AS
BEGIN
    DECLARE @i INT = 1;          -- top-of-body DECLARE is fine (not in the loop)
    IF @n IS NULL SET @n = 0;
    WHILE @i <= @n
    BEGIN
        INSERT @t (Seq, Val) VALUES (@i, @i * @i);
        SET @i += 1;
    END
    RETURN;
END;
GO

-- (d) TABLE-READING scalar  -> value test becomes SkipTest; shadow coverage uses FakeTable
CREATE FUNCTION uat.fn_count_by_color(@color NVARCHAR(15))
RETURNS INT
AS
BEGIN
    DECLARE @c INT;
    SELECT @c = COUNT(*) FROM Production.Product WHERE Color = @color;
    RETURN @c;
END;
GO
PRINT 'Section 1: sample functions created in [uat].';
GO

/*============================================================================
 * SECTION 2 — shadow-transform unit check (the riskiest piece, in isolation)
 *===========================================================================*/
PRINT '';
PRINT '=== SECTION 2: shadow transform ===';
GO
DECLARE @fns TABLE (Seq INT IDENTITY, FnName SYSNAME);
INSERT @fns(FnName) VALUES ('fn_classify'),('fn_inline'),('fn_mstvf'),('fn_count_by_color');

DECLARE @i INT = 1, @max INT = (SELECT MAX(Seq) FROM @fns), @fn SYSNAME;
DECLARE @shadow SYSNAME, @status NVARCHAR(200);
WHILE @i <= @max
BEGIN
    SET @fn = (SELECT FnName FROM @fns WHERE Seq = @i);
    EXEC TestGen.BuildShadowProcForFunction
         @SchemaName = N'uat', @FunctionName = @fn,
         @ShadowName = @shadow OUTPUT, @Status = @status OUTPUT;
    PRINT '  uat.' + @fn + '  -> Status = ' + @status + '  (shadow: uat.' + ISNULL(@shadow,'?') + ')';

    IF @status = N'OK'
    BEGIN
        PRINT '  ---- shadow body ----';
        PRINT OBJECT_DEFINITION(OBJECT_ID('uat.' + @shadow));
        PRINT '  ---------------------';
        EXEC('DROP PROCEDURE uat.' + @shadow);   -- drop the probe copy after inspection
    END;
    SET @i += 1;
END;
GO

/*============================================================================
 * SECTION 3 — generate + run tests
 *===========================================================================*/
PRINT '';
PRINT '=== SECTION 3: generation + run ===';
GO
EXEC TestGen.GenerateTestsForObject @SchemaName=N'uat', @ObjectName=N'fn_classify',      @ExecuteScript=1;
EXEC TestGen.GenerateTestsForObject @SchemaName=N'uat', @ObjectName=N'fn_inline',        @ExecuteScript=1;
EXEC TestGen.GenerateTestsForObject @SchemaName=N'uat', @ObjectName=N'fn_mstvf',         @ExecuteScript=1;
EXEC TestGen.GenerateTestsForObject @SchemaName=N'uat', @ObjectName=N'fn_count_by_color', @ExecuteScript=1;
GO
EXEC tSQLt.Run 'test_fn_classify';
EXEC tSQLt.Run 'test_fn_inline';
EXEC tSQLt.Run 'test_fn_mstvf';
EXEC tSQLt.Run 'test_fn_count_by_color';
GO

/*============================================================================
 * SECTION 4 — coverage (must print a real number, not "deferred")
 *===========================================================================*/
PRINT '';
PRINT '=== SECTION 4: coverage ===';
GO
EXEC TestGen.RunCoverageForFunction @SchemaName=N'uat', @FunctionName=N'fn_classify',       @OutputMode=N'TEXT';
EXEC TestGen.RunCoverageForFunction @SchemaName=N'uat', @FunctionName=N'fn_inline',         @OutputMode=N'TEXT';
EXEC TestGen.RunCoverageForFunction @SchemaName=N'uat', @FunctionName=N'fn_mstvf',          @OutputMode=N'TEXT';
EXEC TestGen.RunCoverageForFunction @SchemaName=N'uat', @FunctionName=N'fn_count_by_color', @OutputMode=N'TEXT';
GO

/*============================================================================
 * SECTION 5 — real AdventureWorks functions (only if present)
 *   ufnGetSalesOrderStatusText : pure scalar (CASE)            -> blessed value
 *   ufnGetContactInformation   : multi-statement TVF (reads)   -> shape/determinism
 *===========================================================================*/
PRINT '';
PRINT '=== SECTION 5: real AdventureWorks functions ===';
GO
IF OBJECT_ID('dbo.ufnGetSalesOrderStatusText','FN') IS NOT NULL
BEGIN
    EXEC TestGen.GenerateTestsForObject @SchemaName=N'dbo', @ObjectName=N'ufnGetSalesOrderStatusText', @ExecuteScript=1;
    EXEC tSQLt.Run 'test_ufnGetSalesOrderStatusText';
    EXEC TestGen.RunCoverageForFunction @SchemaName=N'dbo', @FunctionName=N'ufnGetSalesOrderStatusText', @OutputMode=N'TEXT';
END
ELSE PRINT '  (skipped) dbo.ufnGetSalesOrderStatusText not found.';
GO
IF OBJECT_ID('dbo.ufnGetContactInformation','TF') IS NOT NULL
BEGIN
    EXEC TestGen.GenerateTestsForObject @SchemaName=N'dbo', @ObjectName=N'ufnGetContactInformation', @ExecuteScript=1;
    EXEC tSQLt.Run 'test_ufnGetContactInformation';
    EXEC TestGen.RunCoverageForFunction @SchemaName=N'dbo', @FunctionName=N'ufnGetContactInformation', @OutputMode=N'TEXT';
END
ELSE PRINT '  (skipped) dbo.ufnGetContactInformation not found.';
GO

/*============================================================================
 * SECTION 6 — teardown  (comment out to inspect the generated test classes)
 *===========================================================================*/
PRINT '';
PRINT '=== SECTION 6: teardown ===';
GO
IF SCHEMA_ID('test_fn_classify')       IS NOT NULL EXEC tSQLt.DropClass 'test_fn_classify';
IF SCHEMA_ID('test_fn_inline')         IS NOT NULL EXEC tSQLt.DropClass 'test_fn_inline';
IF SCHEMA_ID('test_fn_mstvf')          IS NOT NULL EXEC tSQLt.DropClass 'test_fn_mstvf';
IF SCHEMA_ID('test_fn_count_by_color') IS NOT NULL EXEC tSQLt.DropClass 'test_fn_count_by_color';
IF SCHEMA_ID('test_ufnGetSalesOrderStatusText') IS NOT NULL EXEC tSQLt.DropClass 'test_ufnGetSalesOrderStatusText';
IF SCHEMA_ID('test_ufnGetContactInformation')   IS NOT NULL EXEC tSQLt.DropClass 'test_ufnGetContactInformation';
GO
-- Sweep EVERYTHING in [uat] before dropping the schema, so any stranded
-- coverage artefact (<fn>_covfn / _covfn_cov / _covfn_orig / synonym) left by
-- an interrupted RunCoverageForFunction does not block DROP SCHEMA.
IF SCHEMA_ID('uat') IS NOT NULL
BEGIN
    DECLARE @drop NVARCHAR(MAX) = N'';
    SELECT @drop += N'DROP SYNONYM '   + QUOTENAME('uat') + N'.' + QUOTENAME(name) + N';' + CHAR(10)
    FROM sys.synonyms  WHERE schema_id = SCHEMA_ID('uat');
    SELECT @drop += N'DROP PROCEDURE ' + QUOTENAME('uat') + N'.' + QUOTENAME(name) + N';' + CHAR(10)
    FROM sys.procedures WHERE schema_id = SCHEMA_ID('uat');
    SELECT @drop += N'DROP FUNCTION '  + QUOTENAME('uat') + N'.' + QUOTENAME(name) + N';' + CHAR(10)
    FROM sys.objects   WHERE schema_id = SCHEMA_ID('uat') AND type IN ('FN','IF','TF');
    IF @drop <> N'' EXEC sys.sp_executesql @drop;
    EXEC('DROP SCHEMA uat');
END;
GO
PRINT '';
PRINT 'Verify_Functions.sql complete.  Review Sections 2-5 output above.';
GO
