/*****************************************************************************
 * 30_Function_Support_v1.sql  —  v11 scalar / table-valued function support
 *---------------------------------------------------------------------------
 * Adds test generation AND line/branch coverage for user-defined functions:
 *   FN  scalar
 *   IF  inline table-valued
 *   TF  multi-statement table-valued
 *
 * Design: DESIGN_v11_Functions.md.  Coverage is measured via the
 * SHADOW-PROCEDURE TRANSFORM: a function body cannot host an
 * EXEC TestGen.RecordCoverageHit recorder and is unreliable to capture
 * directly (scalar-UDF statements run inside the calling statement, and
 * SQL 2019+ Froid inlining folds the body into the caller plan).  So we
 * mechanically derive a PROCEDURE whose body is the function body with only
 * the header rewritten, then drive the EXISTING InstrumentProcedure +
 * RunCoverage XEvent pipeline against that procedure — a procedure's
 * statements always fire sp_statement_completed and are never inlined.
 *
 * Object map (all in the TestGen schema):
 *   TestGen.GetFunctionKind          - classify FN/IF/TF/CLR/encrypted
 *   TestGen.RewriteScalarReturns     - RETURN <expr> -> SET @__ret=<expr>;RETURN
 *   TestGen.BuildShadowProcForFunction - create <fn>_covfn + line map
 *   TestGen.GenerateTestsForScalarFunction
 *   TestGen.GenerateTestsForTableFunction   (IF + TF)
 *   TestGen.GenerateTestsForObject   - dispatcher (P/FN/IF/TF)
 *   TestGen.RunCoverageForFunction   - shadow + RunCoverage wrapper + relabel
 *   TestGen.ShadowLineMap            - FunctionLine -> ShadowLine attribution
 *
 * IMPORTANT: kept side-by-side with the procedure pipeline; nothing here
 * alters GenerateTestsForProcedure / RunCoverage / InstrumentProcedure.
 * Re-runnable (idempotent DROP+CREATE).  Reuses TestGen helper functions:
 *   TestGen.GetSampleValueLiteral, TestGen.GetDeclareLiteralForType,
 *   dbo.TestGen_RebuildTypeName, TestGen.SafeFakeTable,
 *   TestGen.ExecuteBatchedScript.
 *
 * NOT YET VERIFIED on a live DB - regenerate + run coverage on the three
 * reference databases (AdventureWorks2025 / Northwind / WideWorldImporters)
 * and triage per CHANGES.md convention.
 *****************************************************************************/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * TestGen.ShadowLineMap - maps a function source line to the line in its
 * shadow procedure, so coverage hits recorded against the shadow attribute
 * back to the original function's source line in the report.
 *==========================================================================*/
IF OBJECT_ID('TestGen.ShadowLineMap','U') IS NULL
    CREATE TABLE TestGen.ShadowLineMap (
        MapId         INT IDENTITY(1,1) PRIMARY KEY,
        SchemaName    SYSNAME NOT NULL,
        FunctionName  SYSNAME NOT NULL,
        FunctionLine  INT     NOT NULL,
        ShadowLine    INT     NOT NULL,
        CreatedAt     DATETIME2 DEFAULT SYSDATETIME(),
        UNIQUE (SchemaName, FunctionName, ShadowLine)
    );
GO

/*===========================================================================
 * TestGen.GetFunctionKind
 *   Returns: 'FN' | 'IF' | 'TF'  (testable shapes)
 *            'FS' | 'FT' | 'AF'  (CLR - not transformable, NOT_TESTABLE)
 *            'ENCRYPTED'         (no body available)
 *            'NA'                (not a function / does not exist)
 *==========================================================================*/
IF OBJECT_ID('TestGen.GetFunctionKind','FN') IS NOT NULL
    DROP FUNCTION TestGen.GetFunctionKind;
GO
CREATE FUNCTION TestGen.GetFunctionKind
(
    @SchemaName SYSNAME,
    @FunctionName SYSNAME
)
RETURNS VARCHAR(10)
AS
BEGIN
    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@FunctionName));
    IF @ObjId IS NULL RETURN 'NA';

    DECLARE @type CHAR(2) = (SELECT type FROM sys.objects WHERE object_id = @ObjId);
    IF @type NOT IN ('FN','IF','TF','FS','FT','AF') RETURN 'NA';

    -- Encrypted bodies expose no definition - cannot transform or test.
    IF OBJECT_DEFINITION(@ObjId) IS NULL AND @type IN ('FN','IF','TF')
        RETURN 'ENCRYPTED';

    RETURN RTRIM(@type);
END;
GO
PRINT 'TestGen.GetFunctionKind installed.';
GO

/*===========================================================================
 * TestGen.RewriteScalarReturns
 *   Rewrites every  RETURN <expr>;  into  BEGIN SET @__ret = (<expr>); RETURN; END
 *   so a scalar-function body becomes legal, control-flow-equivalent
 *   procedure body.  A char walk that respects line/block comments, string
 *   literals, bracketed identifiers and paren depth so it only fires on real
 *   RETURN statements at statement scope.  Early returns keep their
 *   control-transfer semantics (BEGIN ... RETURN; END), so branch structure
 *   is preserved 1:1.
 *==========================================================================*/
IF OBJECT_ID('TestGen.RewriteScalarReturns','FN') IS NOT NULL
    DROP FUNCTION TestGen.RewriteScalarReturns;
GO
CREATE FUNCTION TestGen.RewriteScalarReturns
(
    @Body NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out      NVARCHAR(MAX) = N'';
    DECLARE @len      INT = LEN(@Body);
    DECLARE @i        INT = 1;
    DECLARE @ch       NCHAR(1);
    DECLARE @nx       NCHAR(1);
    DECLARE @inLine   BIT = 0;   -- inside  -- comment
    DECLARE @inBlock  BIT = 0;   -- inside  /* */
    DECLARE @inStr    BIT = 0;   -- inside  '...'
    DECLARE @inBr     BIT = 0;   -- inside  [...]
    DECLARE @paren    INT = 0;

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Body, @i, 1);
        SET @nx = CASE WHEN @i < @len THEN SUBSTRING(@Body, @i + 1, 1) ELSE N'' END;

        -- exit single-line comment at newline
        IF @inLine = 1
        BEGIN
            SET @out += @ch;
            IF @ch = CHAR(10) SET @inLine = 0;
            SET @i += 1; CONTINUE;
        END;
        -- exit block comment
        IF @inBlock = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N'*' AND @nx = N'/' BEGIN SET @out += @nx; SET @i += 2; SET @inBlock = 0; CONTINUE; END;
            SET @i += 1; CONTINUE;
        END;
        -- exit string literal ('' is an escaped quote -> stay in string)
        IF @inStr = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N'''' AND @nx = N'''' BEGIN SET @out += @nx; SET @i += 2; CONTINUE; END;
            IF @ch = N'''' SET @inStr = 0;
            SET @i += 1; CONTINUE;
        END;
        -- exit bracket identifier
        IF @inBr = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N']' SET @inBr = 0;
            SET @i += 1; CONTINUE;
        END;

        -- enter comment / string / bracket
        IF @ch = N'-' AND @nx = N'-' BEGIN SET @out += N'--'; SET @i += 2; SET @inLine = 1; CONTINUE; END;
        IF @ch = N'/' AND @nx = N'*' BEGIN SET @out += N'/*'; SET @i += 2; SET @inBlock = 1; CONTINUE; END;
        IF @ch = N'''' BEGIN SET @out += @ch; SET @inStr = 1; SET @i += 1; CONTINUE; END;
        IF @ch = N'[' BEGIN SET @out += @ch; SET @inBr = 1; SET @i += 1; CONTINUE; END;
        IF @ch = N'(' BEGIN SET @paren += 1; SET @out += @ch; SET @i += 1; CONTINUE; END;
        IF @ch = N')' BEGIN SET @paren = CASE WHEN @paren > 0 THEN @paren - 1 ELSE 0 END; SET @out += @ch; SET @i += 1; CONTINUE; END;

        -- detect a RETURN keyword at statement scope (word-bounded, paren depth 0)
        IF @paren = 0
           AND UPPER(SUBSTRING(@Body, @i, 6)) = N'RETURN'
           AND (@i = 1 OR PATINDEX(N'%[^A-Za-z0-9_@#]%', SUBSTRING(@Body, @i - 1, 1)) = 1)
        BEGIN
            DECLARE @after NCHAR(1) = CASE WHEN @i + 6 <= @len THEN SUBSTRING(@Body, @i + 6, 1) ELSE N' ' END;
            IF @after LIKE N'[ ' + CHAR(9) + CHAR(10) + CHAR(13) + N'(]'  -- RETURN followed by whitespace or (
               OR @i + 6 > @len
            BEGIN
                -- capture the expression up to its terminator.  Track CASE..END
                -- nesting so a CASE arm's END is not mistaken for the body's
                -- closing END; stop at a top-level END, a ';' at paren depth 0,
                -- or an unmatched ')'.  This prevents swallowing the function's
                -- own closing END when "RETURN <expr>" has no trailing semicolon
                -- (e.g. RETURN @ret  <newline>  END).
                DECLARE @j INT = @i + 6;
                DECLARE @ep INT = 0;        -- paren depth within expression
                DECLARE @es BIT = 0;        -- string within expression
                DECLARE @eb BIT = 0;        -- bracket identifier within expression
                DECLARE @ecase INT = 0;     -- CASE..END nesting within expression
                DECLARE @expr NVARCHAR(MAX) = N'';
                DECLARE @ec NCHAR(1), @en NCHAR(1), @epv NCHAR(1);
                WHILE @j <= @len
                BEGIN
                    SET @ec = SUBSTRING(@Body, @j, 1);
                    SET @en = CASE WHEN @j < @len THEN SUBSTRING(@Body, @j + 1, 1) ELSE N'' END;
                    IF @es = 1
                    BEGIN
                        SET @expr += @ec;
                        IF @ec = N'''' AND @en = N'''' BEGIN SET @expr += @en; SET @j += 2; CONTINUE; END;
                        IF @ec = N'''' SET @es = 0;
                        SET @j += 1; CONTINUE;
                    END;
                    IF @eb = 1
                    BEGIN
                        SET @expr += @ec;
                        IF @ec = N']' SET @eb = 0;
                        SET @j += 1; CONTINUE;
                    END;
                    IF @ec = N'''' BEGIN SET @expr += @ec; SET @es = 1; SET @j += 1; CONTINUE; END;
                    IF @ec = N'[' BEGIN SET @expr += @ec; SET @eb = 1; SET @j += 1; CONTINUE; END;
                    IF @ec = N'(' BEGIN SET @ep += 1; SET @expr += @ec; SET @j += 1; CONTINUE; END;
                    IF @ec = N')'
                    BEGIN
                        IF @ep = 0 BREAK;  -- closing paren that ends an enclosing block - stop
                        SET @ep -= 1; SET @expr += @ec; SET @j += 1; CONTINUE;
                    END;
                    SET @epv = CASE WHEN @j = 1 THEN N' ' ELSE SUBSTRING(@Body, @j - 1, 1) END;
                    IF UPPER(SUBSTRING(@Body, @j, 4)) = N'CASE'
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', @epv) = 1
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', SUBSTRING(@Body, @j + 4, 1)) = 1
                    BEGIN SET @ecase += 1; SET @expr += SUBSTRING(@Body, @j, 4); SET @j += 4; CONTINUE; END;
                    IF UPPER(SUBSTRING(@Body, @j, 3)) = N'END'
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', @epv) = 1
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', CASE WHEN @j + 3 <= @len THEN SUBSTRING(@Body, @j + 3, 1) ELSE N' ' END) = 1
                    BEGIN
                        IF @ecase = 0 BREAK;   -- block-closing END -> expression ends here
                        SET @ecase -= 1; SET @expr += SUBSTRING(@Body, @j, 3); SET @j += 3; CONTINUE;
                    END;
                    IF @ec = N';' AND @ep = 0 BREAK;             -- statement terminator
                    SET @expr += @ec; SET @j += 1;
                END;

                DECLARE @trim NVARCHAR(MAX) = LTRIM(RTRIM(@expr));
                IF @trim = N''
                    SET @out += N'RETURN';          -- bare RETURN - leave as-is (rare in scalar)
                ELSE
                    -- trailing space + newline so this END never fuses with a
                    -- following token (e.g. the function's own closing END ->
                    -- "ENDEND") when RETURN had no trailing ';'.
                    SET @out += NCHAR(13)+NCHAR(10)+N'BEGIN'+NCHAR(13)+NCHAR(10)+N'SET @__ret = ('+@expr+N');'+NCHAR(13)+NCHAR(10)+N'RETURN;'+NCHAR(13)+NCHAR(10)+N'END'+NCHAR(13)+NCHAR(10);

                -- advance past the consumed ';' if we stopped on one
                IF @j <= @len AND SUBSTRING(@Body, @j, 1) = N';' SET @j += 1;
                SET @i = @j;
                CONTINUE;
            END;
        END;

        SET @out += @ch;
        SET @i += 1;
    END;

    RETURN @out;
END;
GO
PRINT 'TestGen.RewriteScalarReturns installed.';
GO

/*===========================================================================
 * Small text helpers used by the shadow transform.  All do a comment- /
 * string- / bracket-aware char walk so keywords inside literals or comments
 * are never matched.
 *==========================================================================*/
IF OBJECT_ID('TestGen.FindKeyword','FN') IS NOT NULL DROP FUNCTION TestGen.FindKeyword;
GO
CREATE FUNCTION TestGen.FindKeyword
(
    @Text NVARCHAR(MAX),
    @Kw   NVARCHAR(50),
    @Start INT
)
RETURNS INT     -- 1-based position of the first standalone @Kw at/after @Start, else 0
AS
BEGIN
    DECLARE @len INT = LEN(@Text), @i INT = CASE WHEN @Start < 1 THEN 1 ELSE @Start END;
    DECLARE @kl INT = LEN(@Kw);
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@af NCHAR(1);
    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Text,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Text,@i+1,1) ELSE N'' END;
        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1 BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'[' BEGIN SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF UPPER(SUBSTRING(@Text,@i,@kl)) = UPPER(@Kw)
        BEGIN
            SET @pv = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Text,@i-1,1) END;
            SET @af = CASE WHEN @i+@kl<=@len THEN SUBSTRING(@Text,@i+@kl,1) ELSE N' ' END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@af)=1
                RETURN @i;
        END;
        SET @i+=1;
    END;
    RETURN 0;
END;
GO
PRINT 'TestGen.FindKeyword installed.';
GO

IF OBJECT_ID('TestGen.FindTopLevelAs','FN') IS NOT NULL DROP FUNCTION TestGen.FindTopLevelAs;
GO
CREATE FUNCTION TestGen.FindTopLevelAs
(
    @Def NVARCHAR(MAX)
)
RETURNS INT     -- position of the body-introducing AS (paren depth 0), else 0
AS
BEGIN
    DECLARE @len INT = LEN(@Def), @i INT = 1, @paren INT = 0;
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@af NCHAR(1);
    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Def,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Def,@i+1,1) ELSE N'' END;
        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1 BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'[' BEGIN SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'(' BEGIN SET @paren+=1; SET @i+=1; CONTINUE; END;
        IF @ch=N')' BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @i+=1; CONTINUE; END;
        IF @paren=0 AND UPPER(SUBSTRING(@Def,@i,2))=N'AS'
        BEGIN
            SET @pv = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Def,@i-1,1) END;
            SET @af = CASE WHEN @i+2<=@len THEN SUBSTRING(@Def,@i+2,1) ELSE N' ' END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@af)=1
                RETURN @i;
        END;
        SET @i+=1;
    END;
    RETURN 0;
END;
GO
PRINT 'TestGen.FindTopLevelAs installed.';
GO

IF OBJECT_ID('TestGen.StripOuterParens','FN') IS NOT NULL DROP FUNCTION TestGen.StripOuterParens;
GO
CREATE FUNCTION TestGen.StripOuterParens
(
    @Text NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @t NVARCHAR(MAX) = LTRIM(RTRIM(@Text));
    -- strip a trailing semicolon for the balance check
    IF RIGHT(@t,1) = N';' SET @t = LTRIM(RTRIM(LEFT(@t, LEN(@t)-1)));
    IF LEFT(@t,1) <> N'(' OR RIGHT(@t,1) <> N')' RETURN @Text;
    -- confirm the first '(' matches the last ')' (single enclosing pair)
    DECLARE @len INT = LEN(@t), @i INT = 1, @depth INT = 0, @ok BIT = 1;
    WHILE @i <= @len
    BEGIN
        DECLARE @c NCHAR(1) = SUBSTRING(@t,@i,1);
        IF @c=N'(' SET @depth+=1;
        ELSE IF @c=N')' BEGIN SET @depth-=1; IF @depth=0 AND @i<@len BEGIN SET @ok=0; BREAK; END; END;
        SET @i+=1;
    END;
    IF @ok=0 RETURN @Text;
    RETURN SUBSTRING(@t, 2, LEN(@t)-2);
END;
GO
PRINT 'TestGen.StripOuterParens installed.';
GO

/*===========================================================================
 * TestGen.BuildShadowProcForFunction
 *   Creates <schema>.<fn>_covfn as a PROCEDURE equivalent to the function
 *   body, suitable for the existing coverage pipeline.  Catalog-driven
 *   header synthesis (params + scalar return type from sys.parameters) plus
 *   a string transform of the body.  Populates TestGen.ShadowLineMap.
 *
 *   @Status OUTPUT:  'OK'  or  'UNSUPPORTED:<reason>'  (never emits broken
 *   DDL - on an unparseable shape it sets the status and creates nothing,
 *   so coverage is honestly deferred rather than faked).
 *==========================================================================*/
-- v11 Step1: cap every WHILE..BEGIN loop of a shadow with a local iteration
-- counter so the coverage probe can never run away.  Comment/string/bracket/
-- paren aware; conservative (only clear statement-scope WHILE..BEGIN blocks are
-- touched, on their own lines so they stay instrument-friendly; a single-stmt
-- loop body is left alone).  Returns the body unchanged if nothing was capped.
-- All walker vars are declared once at the top (DECLARE @x=expr inside a loop
-- evaluates the initializer once at parse - see CLAUDE.md).
IF OBJECT_ID('TestGen.InjectLoopGuards','FN') IS NOT NULL
    DROP FUNCTION TestGen.InjectLoopGuards;
GO
CREATE FUNCTION TestGen.InjectLoopGuards(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @CR NCHAR(2) = CHAR(13)+CHAR(10);
    DECLARE @out NVARCHAR(MAX)=N'', @decls NVARCHAR(MAX)=N'';
    DECLARE @len INT=LEN(@Body), @i INT=1, @nLoop INT=0;
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1);
    DECLARE @cp INT,@cs BIT,@cbl BIT,@cbk BIT,@done BIT,@cc NCHAR(1),@cn NCHAR(1),@cpv NCHAR(1),@k NVARCHAR(9);

    WHILE @i<=@len
    BEGIN
        SET @ch=SUBSTRING(@Body,@i,1);
        SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
        IF @inLine=1  BEGIN SET @out+=@ch; IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1   BEGIN SET @out+=@ch; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1    BEGIN SET @out+=@ch; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N''''  BEGIN SET @out+=@ch; SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'['   BEGIN SET @out+=@ch; SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'('   BEGIN SET @paren+=1; SET @out+=@ch; SET @i+=1; CONTINUE; END;
        IF @ch=N')'   BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @out+=@ch; SET @i+=1; CONTINUE; END;

        SET @pv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF @paren=0 AND UPPER(SUBSTRING(@Body,@i,5))=N'WHILE'
           AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1
           AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+5,1))=1
        BEGIN
            SET @out+=SUBSTRING(@Body,@i,5); SET @i+=5;     -- copy 'WHILE'
            SET @cp=0; SET @cs=0; SET @cbl=0; SET @cbk=0; SET @done=0;
            WHILE @i<=@len AND @done=0
            BEGIN
                SET @cc=SUBSTRING(@Body,@i,1);
                SET @cn=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
                IF @cbl=1 BEGIN SET @out+=@cc; IF @cc=CHAR(10) SET @cbl=0; SET @i+=1; CONTINUE; END;
                IF @cbk=1 BEGIN SET @out+=@cc; IF @cc=N']' SET @cbk=0; SET @i+=1; CONTINUE; END;
                IF @cs=1  BEGIN SET @out+=@cc; IF @cc=N'''' AND @cn=N'''' BEGIN SET @out+=@cn; SET @i+=2; CONTINUE; END; IF @cc=N'''' SET @cs=0; SET @i+=1; CONTINUE; END;
                IF @cc=N'-' AND @cn=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @cbl=1; CONTINUE; END;
                IF @cc=N'''' BEGIN SET @out+=@cc; SET @cs=1; SET @i+=1; CONTINUE; END;
                IF @cc=N'['  BEGIN SET @out+=@cc; SET @cbk=1; SET @i+=1; CONTINUE; END;
                IF @cc=N'('  BEGIN SET @cp+=1; SET @out+=@cc; SET @i+=1; CONTINUE; END;
                IF @cc=N')'  BEGIN SET @cp=CASE WHEN @cp>0 THEN @cp-1 ELSE 0 END; SET @out+=@cc; SET @i+=1; CONTINUE; END;
                SET @cpv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
                IF @cp=0 AND UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@cpv)=1
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+5,1))=1
                BEGIN
                    SET @nLoop+=1; SET @k=CAST(@nLoop AS NVARCHAR(9));
                    SET @out+=SUBSTRING(@Body,@i,5)                       -- 'BEGIN'
                            + @CR + N'SET @__lc'+@k+N'=@__lc'+@k+N'+1;'
                            + @CR + N'IF @__lc'+@k+N'>1000 BREAK;';
                    SET @decls += N'DECLARE @__lc'+@k+N' INT=0;'+@CR;
                    SET @i+=5; SET @done=1; CONTINUE;
                END;
                IF @cp=0 AND @cc=N';' BEGIN SET @done=1; CONTINUE; END;  -- single-stmt body: stop, no inject
                SET @out+=@cc; SET @i+=1;
            END;
            CONTINUE;
        END;

        SET @out+=@ch; SET @i+=1;
    END;

    IF @decls=N'' RETURN @Body;     -- no loop capped -> unchanged
    RETURN @decls + @out;
END;
GO
PRINT 'TestGen.InjectLoopGuards installed.';
GO

-- Gap fix: reflow a shadow body to one-statement-per-line so the line-oriented
-- instrumenter can decompose a one-line compound block (e.g.
-- `BEGIN SET @s+=@i; SET @i+=1; END`).  Only inserts newlines where a keyword
-- shares a line with code (BEGIN/END/ELSE on their own line; ';' splits), so an
-- already-multi-line body passes through byte-unchanged (no regression).
-- Comment/string/bracket/paren aware; BEGIN/END TRY/CATCH kept intact as units.
-- All walker vars declared once at the top (DECLARE @x=expr in a loop evaluates
-- the initializer once at parse - see CLAUDE.md).
IF OBJECT_ID('TestGen.NormalizeShadowBody','FN') IS NOT NULL
    DROP FUNCTION TestGen.NormalizeShadowBody;
GO
CREATE FUNCTION TestGen.NormalizeShadowBody(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @CR NCHAR(2)=CHAR(13)+CHAR(10);
    DECLARE @out NVARCHAR(MAX)=N'';
    DECLARE @len INT=LEN(@Body), @i INT=1;
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0,@dirty BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@aft NCHAR(1),@pk NCHAR(1);
    DECLARE @j INT,@adv INT,@unit NVARCHAR(20);

    WHILE @i<=@len
    BEGIN
        SET @ch=SUBSTRING(@Body,@i,1);
        SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;

        IF @inLine=1 BEGIN SET @out+=@ch; IF @ch=CHAR(10) BEGIN SET @inLine=0; SET @dirty=0; END; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;

        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlk=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @out+=@ch; SET @inStr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'['  BEGIN SET @out+=@ch; SET @inBr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'('  BEGIN SET @paren+=1; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N')'  BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;

        IF @ch=CHAR(13) BEGIN SET @out+=@ch; SET @i+=1; CONTINUE; END;
        IF @ch=CHAR(10) BEGIN SET @out+=@ch; SET @dirty=0; SET @i+=1; CONTINUE; END;

        IF @ch=N';' AND @paren=0
        BEGIN
            SET @out+=@ch; SET @i+=1;
            SET @j=@i;
            WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
            SET @pk=CASE WHEN @j<=@len THEN SUBSTRING(@Body,@j,1) ELSE N'' END;
            IF @pk<>N'' AND @pk<>CHAR(13) AND @pk<>CHAR(10)
            BEGIN SET @out+=@CR; SET @dirty=0; SET @i=@j; END;
            CONTINUE;
        END;

        SET @pv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1
        BEGIN
            SET @aft=CASE WHEN @i+5<=@len THEN SUBSTRING(@Body,@i+5,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                SET @unit=N'BEGIN'; SET @adv=5;
                SET @j=@i+5; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                IF UPPER(SUBSTRING(@Body,@j,3))=N'TRY'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+3<=@len THEN SUBSTRING(@Body,@j+3,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'BEGIN TRY'; SET @adv=@j+3-@i; END
                ELSE IF UPPER(SUBSTRING(@Body,@j,5))=N'CATCH'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+5<=@len THEN SUBSTRING(@Body,@j+5,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'BEGIN CATCH'; SET @adv=@j+5-@i; END;
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=@unit; SET @i+=@adv;
                SET @j=@i; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                SET @pk=CASE WHEN @j<=@len THEN SUBSTRING(@Body,@j,1) ELSE N'' END;
                IF @pk<>N'' AND @pk<>CHAR(13) AND @pk<>CHAR(10) BEGIN SET @out+=@CR; SET @i=@j; END;
                SET @dirty=0;
                CONTINUE;
            END;
            SET @aft=CASE WHEN @i+3<=@len THEN SUBSTRING(@Body,@i+3,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                SET @unit=N'END'; SET @adv=3;
                SET @j=@i+3; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                IF UPPER(SUBSTRING(@Body,@j,3))=N'TRY'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+3<=@len THEN SUBSTRING(@Body,@j+3,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'END TRY'; SET @adv=@j+3-@i; END
                ELSE IF UPPER(SUBSTRING(@Body,@j,5))=N'CATCH'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+5<=@len THEN SUBSTRING(@Body,@j+5,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'END CATCH'; SET @adv=@j+5-@i; END;
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=@unit; SET @i+=@adv; SET @dirty=1;
                CONTINUE;
            END;
            SET @aft=CASE WHEN @i+4<=@len THEN SUBSTRING(@Body,@i+4,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,4))=N'ELSE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=N'ELSE'; SET @i+=4; SET @dirty=1;
                CONTINUE;
            END;
        END;

        SET @out+=@ch;
        IF @ch<>N' ' AND @ch<>CHAR(9) SET @dirty=1;
        SET @i+=1;
    END;

    RETURN @out;
END;
GO
PRINT 'TestGen.NormalizeShadowBody installed.';
GO

IF OBJECT_ID('TestGen.BuildShadowProcForFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.BuildShadowProcForFunction;
GO
CREATE PROCEDURE TestGen.BuildShadowProcForFunction
    @SchemaName   SYSNAME,
    @FunctionName SYSNAME,
    @ShadowName   SYSNAME       = NULL OUTPUT,
    @Status       NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);
    SET @Status = N'OK';
    SET @ShadowName = @FunctionName + N'_covfn';

    DECLARE @kind VARCHAR(10) = TestGen.GetFunctionKind(@SchemaName, @FunctionName);
    IF @kind NOT IN ('FN','IF','TF')
    BEGIN
        SET @Status = N'UNSUPPORTED:not a T-SQL function (' + @kind + N')';
        RETURN;
    END;

    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@FunctionName));
    DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(@ObjId);
    IF @def IS NULL BEGIN SET @Status = N'UNSUPPORTED:no definition (encrypted?)'; RETURN; END;

    /* ---- synthesize the input parameter list from the catalog ---- */
    DECLARE @params NVARCHAR(MAX) = N'';
    SELECT @params = @params
         + CASE WHEN @params = N'' THEN N'' ELSE N', ' END
         + p.name + N' '
         + dbo.TestGen_RebuildTypeName(TYPE_NAME(p.user_type_id), p.max_length, p.precision, p.scale)
    FROM sys.parameters p
    WHERE p.object_id = @ObjId AND p.parameter_id > 0
    ORDER BY p.parameter_id;

    /* ---- locate the body: everything after the first top-level AS ---- */
    DECLARE @AsPos INT = TestGen.FindTopLevelAs(@def);
    IF @AsPos = 0 BEGIN SET @Status = N'UNSUPPORTED:could not locate body AS keyword'; RETURN; END;
    DECLARE @body NVARCHAR(MAX) = LTRIM(SUBSTRING(@def, @AsPos + 2, LEN(@def)));

    DECLARE @shadowFull NVARCHAR(400) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ShadowName);
    DECLARE @header NVARCHAR(MAX);
    DECLARE @procBody NVARCHAR(MAX);

    IF @kind = 'FN'
    BEGIN
        -- scalar return type from sys.parameters (parameter_id = 0)
        DECLARE @rt SYSNAME, @rml SMALLINT, @rp TINYINT, @rs TINYINT;
        SELECT @rt = TYPE_NAME(user_type_id), @rml = max_length, @rp = precision, @rs = scale
        FROM sys.parameters WHERE object_id = @ObjId AND parameter_id = 0;
        IF @rt IS NULL BEGIN SET @Status = N'UNSUPPORTED:scalar return type not found'; RETURN; END;

        DECLARE @rtName NVARCHAR(200) = dbo.TestGen_RebuildTypeName(@rt, @rml, @rp, @rs);
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' ('
                    + @params + CASE WHEN @params = N'' THEN N'' ELSE N', ' END
                    + N'@__ret ' + @rtName + N' OUTPUT) AS' + @CRLF;
        SET @procBody = TestGen.RewriteScalarReturns(@body);
    END
    ELSE IF @kind = 'TF'
    BEGIN
        -- RETURNS @var TABLE(<cols>) AS BEGIN ... RETURN END
        -- pull the table-variable name and column spec from the header text.
        DECLARE @ret2 NVARCHAR(MAX);
        DECLARE @retKw INT = TestGen.FindKeyword(@def, N'RETURNS', 1);
        IF @retKw = 0 BEGIN SET @Status = N'UNSUPPORTED:RETURNS clause not found'; RETURN; END;
        SET @ret2 = SUBSTRING(@def, @retKw + 7, @AsPos - (@retKw + 7));   -- between RETURNS and AS
        SET @ret2 = LTRIM(RTRIM(@ret2));
        -- expect: @name TABLE ( ... )
        DECLARE @atPos INT = CHARINDEX(N'@', @ret2);
        DECLARE @tblKw INT = TestGen.FindKeyword(@ret2, N'TABLE', 1);
        IF @atPos = 0 OR @tblKw = 0 BEGIN SET @Status = N'UNSUPPORTED:multi-statement TABLE() spec not parseable'; RETURN; END;
        DECLARE @tvName NVARCHAR(200) = LTRIM(RTRIM(SUBSTRING(@ret2, @atPos, @tblKw - @atPos)));
        DECLARE @colSpec NVARCHAR(MAX) = LTRIM(SUBSTRING(@ret2, @tblKw + 5, LEN(@ret2)));  -- "(...)"

        -- Wrap the function body verbatim inside an outer BEGIN/END after
        -- declaring the return table variable.  The body already contains its
        -- own BEGIN ... INSERT @tv ... RETURN END; nesting is legal and keeps
        -- the body lines byte-identical, so the line map stays a fixed offset.
        -- The trailing bare RETURN is a control-transfer statement the
        -- instrumenter records; we do not need to SELECT the table var for
        -- coverage (the driver only needs the body executed).
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' ('
                    + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF
                    + N'DECLARE ' + @tvName + N' TABLE ' + @colSpec + N';' + @CRLF;
        SET @procBody = @body + @CRLF + N'END;';
    END
    ELSE  -- IF : RETURNS TABLE AS RETURN ( SELECT ... )
    BEGIN
        -- body is:  RETURN ( SELECT ... )   (possibly with surrounding whitespace)
        DECLARE @rk INT = TestGen.FindKeyword(@body, N'RETURN', 1);
        IF @rk = 0 BEGIN SET @Status = N'UNSUPPORTED:inline RETURN not found'; RETURN; END;
        DECLARE @sel NVARCHAR(MAX) = LTRIM(SUBSTRING(@body, @rk + 6, LEN(@body)));
        -- strip one outer ( ... ) pair if present
        SET @sel = TestGen.StripOuterParens(@sel);
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' (' + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF;
        SET @procBody = @sel + @CRLF + N'END;';
    END;

    -- Gap fix: reflow one-line compound blocks to one-statement-per-line so the
    -- line-oriented instrumenter can decompose them (no-op on multi-line code).
    SET @procBody = TestGen.NormalizeShadowBody(@procBody);
    -- v11 Step1: cap every WHILE..BEGIN loop in the shadow so the coverage probe
    -- can never run away (local counter; ~nanoseconds/iteration; preserves
    -- coverage - one iteration already covers the body).
    SET @procBody = TestGen.InjectLoopGuards(@procBody);

    /* ---- (re)create the shadow procedure ---- */
    IF OBJECT_ID(@shadowFull, 'P') IS NOT NULL
        EXEC('DROP PROCEDURE ' + @shadowFull);

    DECLARE @full NVARCHAR(MAX) = @header + @procBody;
    BEGIN TRY
        EXEC sys.sp_executesql @full;
    END TRY
    BEGIN CATCH
        SET @Status = N'UNSUPPORTED:shadow compile failed: ' + ERROR_MESSAGE();
        -- diagnostic: surface the exact DDL we tried to compile so a transform
        -- edge case can be pinpointed instead of guessed at.
        PRINT '  [shadow-compile-failed] ' + QUOTENAME(@SchemaName) + N'.' + @FunctionName;
        PRINT '  ---- attempted shadow DDL ----';
        PRINT @full;
        PRINT '  ------------------------------';
        RETURN;
    END CATCH;

    /* ---- build the line map (header offset + verbatim body) ---- *
     * The body lines are copied verbatim into the shadow after a fixed
     * header-line count, so FunctionLine N maps to ShadowLine N + offset.
     * For scalar/mTVF the RETURN rewrites stay on their original lines (the
     * BEGIN..END replacement is single-line), so the offset is constant. */
    DECLARE @hdrLines INT = LEN(@header) - LEN(REPLACE(@header, CHAR(10), N''));
    DECLARE @bodyStartInDef INT =
        (SELECT LEN(SUBSTRING(@def,1,@AsPos)) - LEN(REPLACE(SUBSTRING(@def,1,@AsPos), CHAR(10), N'')));

    DELETE FROM TestGen.ShadowLineMap WHERE SchemaName=@SchemaName AND FunctionName=@FunctionName;
    ;WITH n AS (
        SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
        FROM sys.all_objects
    )
    INSERT INTO TestGen.ShadowLineMap (SchemaName, FunctionName, FunctionLine, ShadowLine)
    SELECT @SchemaName, @FunctionName, rn, rn + (@hdrLines - @bodyStartInDef)
    FROM n
    WHERE rn <= (LEN(@def) - LEN(REPLACE(@def, CHAR(10), N'')) + 1);

    RETURN;
END;
GO
PRINT 'TestGen.BuildShadowProcForFunction installed.';
GO

/*===========================================================================
 * TestGen.Fn_HasTableDependency
 *   1 if the function references any USER_TABLE, else 0.  Drives whether the
 *   generator can bless concrete return values at generation time (pure
 *   functions) or must fall back to determinism/shape + SkipTest residue.
 *==========================================================================*/
IF OBJECT_ID('TestGen.Fn_HasTableDependency','FN') IS NOT NULL DROP FUNCTION TestGen.Fn_HasTableDependency;
GO
CREATE FUNCTION TestGen.Fn_HasTableDependency
(
    @SchemaName SYSNAME, @FunctionName SYSNAME
)
RETURNS BIT
AS
BEGIN
    DECLARE @objid INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    IF @objid IS NULL RETURN 0;
    IF EXISTS (
        SELECT 1
        FROM sys.sql_expression_dependencies d
        JOIN sys.objects o ON o.object_id = d.referenced_id
        WHERE d.referencing_id = @objid AND o.type = 'U'
    ) RETURN 1;
    RETURN 0;
END;
GO
PRINT 'TestGen.Fn_HasTableDependency installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForScalarFunction
 *   Emits test_<fn> for a scalar (FN) function.  Assertions, honest:
 *     - determinism: fn() called twice is equal (real; catches NEWID/GETDATE)
 *     - blessed value (PURE functions only): fn(args) = a value captured at
 *       generation time, emitted as AssertEquals - correct because no table
 *       state can change a pure function's result
 *     - NULL-argument characterization (pure: blessed; else SkipTest)
 *   Table-dependent functions get determinism + a SkipTest value placeholder.
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForScalarFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForScalarFunction;
GO
CREATE PROCEDURE TestGen.GenerateTestsForScalarFunction
    @SchemaName      SYSNAME,
    @FunctionName    SYSNAME,
    @TestClassName   SYSNAME       = NULL,
    @ExecuteScript   BIT           = 1,
    @GeneratedScript NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2) = CHAR(13)+CHAR(10);
    IF @TestClassName IS NULL SET @TestClassName = N'test_' + @FunctionName;

    IF TestGen.GetFunctionKind(@SchemaName,@FunctionName) <> 'FN'
    BEGIN RAISERROR('%s.%s is not a scalar function.',16,1,@SchemaName,@FunctionName); RETURN; END;

    DECLARE @objid INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @fnFull NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@FunctionName);

    -- return type
    DECLARE @rt SYSNAME,@rml SMALLINT,@rp TINYINT,@rs TINYINT;
    SELECT @rt=TYPE_NAME(user_type_id),@rml=max_length,@rp=precision,@rs=scale
    FROM sys.parameters WHERE object_id=@objid AND parameter_id=0;
    DECLARE @rtName NVARCHAR(200) = dbo.TestGen_RebuildTypeName(@rt,@rml,@rp,@rs);
    DECLARE @blessable BIT = CASE WHEN LOWER(@rt) IN
        ('tinyint','smallint','int','bigint','bit','decimal','numeric','money',
         'smallmoney','float','real','char','varchar','nchar','nvarchar','date',
         'datetime','datetime2','smalldatetime','datetimeoffset','time') THEN 1 ELSE 0 END;

    -- positional literal lists (happy variant 0, and all-NULL)
    DECLARE @litHappy NVARCHAR(MAX)=N'', @litNull NVARCHAR(MAX)=N'';
    SELECT @litHappy = @litHappy + CASE WHEN @litHappy=N'' THEN N'' ELSE N', ' END
             + TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0),
           @litNull  = @litNull  + CASE WHEN @litNull=N''  THEN N'' ELSE N', ' END + N'NULL'
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0
    ORDER BY parameter_id;

    DECLARE @hasTables BIT = TestGen.Fn_HasTableDependency(@SchemaName,@FunctionName);

    -- FakeTable referenced user tables (isolation for the determinism test)
    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes = @fakes + N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                  + SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;' + @CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- bless concrete values at generation time for PURE + blessable functions
    DECLARE @blessHappy NVARCHAR(MAX)=NULL, @blessNull NVARCHAR(MAX)=NULL, @nullIsNull BIT=NULL;
    IF @hasTables=0 AND @blessable=1
    BEGIN
        DECLARE @cv NVARCHAR(MAX), @sql NVARCHAR(MAX);
        BEGIN TRY
            SET @sql=N'SELECT @v=CONVERT(NVARCHAR(MAX),'+@fnFull+N'('+@litHappy+N'),121)';
            EXEC sys.sp_executesql @sql,N'@v NVARCHAR(MAX) OUTPUT',@v=@cv OUTPUT;
            SET @blessHappy=@cv;
        END TRY BEGIN CATCH SET @blessHappy=NULL; SET @blessable=0; END CATCH;

        IF @blessable=1 AND @litNull<>N''
        BEGIN
            BEGIN TRY
                SET @sql=N'SELECT @v=CONVERT(NVARCHAR(MAX),'+@fnFull+N'('+@litNull+N'),121)';
                EXEC sys.sp_executesql @sql,N'@v NVARCHAR(MAX) OUTPUT',@v=@cv OUTPUT;
                SET @blessNull=@cv; SET @nullIsNull=CASE WHEN @cv IS NULL THEN 1 ELSE 0 END;
            END TRY BEGIN CATCH SET @blessNull=NULL; SET @nullIsNull=NULL; END CATCH;
        END;
    END;

    DECLARE @isStr BIT = CASE WHEN LOWER(@rt) IN ('char','varchar','nchar','nvarchar') THEN 1 ELSE 0 END;

    -----------------------------------------------------------------------
    -- assemble the script
    -----------------------------------------------------------------------
    DECLARE @s NVARCHAR(MAX) =
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@TestClassName+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- determinism test (always)
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' is deterministic]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    DECLARE @a '+@rtName+N', @b '+@rtName+N';'+@CRLF+
        N'    SELECT @a = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    SELECT @b = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEquals @a, @b, ''Function is not deterministic for the sample inputs.'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- blessed happy-path value test (pure + blessable) OR honest placeholder
    IF @blessHappy IS NOT NULL OR (@hasTables=0 AND @blessable=1)
    BEGIN
        DECLARE @expHappy NVARCHAR(MAX) =
            CASE WHEN @blessHappy IS NULL THEN N'NULL'
                 WHEN @isStr=1 THEN N'N'''+REPLACE(@blessHappy,N'''',N'''''')+N''''
                 ELSE N'CAST(N'''+REPLACE(@blessHappy,N'''',N'''''')+N''' AS '+@rtName+N')' END;
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns blessed value for sample inputs]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    DECLARE @expected '+@rtName+N' = '+@expHappy+N';'+@CRLF+
            N'    DECLARE @actual '+@rtName+N' = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEquals @expected, @actual;'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END
    ELSE
    BEGIN
        SET @s += N'--[@tSQLt:SkipTest](''value characterization needs a blessed baseline under seeded data'')'+@CRLF+
            N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' value characterization - needs manual bless]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    -- '+@FunctionName+N' reads tables; its return value depends on seeded data.'+@CRLF+
            N'    -- Seed the faked tables in Assemble, capture the expected value, then'+@CRLF+
            N'    -- replace this SkipTest with an AssertEquals.  Coverage is still'+@CRLF+
            N'    -- measured independently via TestGen.RunCoverageForFunction.'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END;

    -- NULL-argument test (pure + blessable only; else covered by determinism)
    IF @litNull <> N'' AND @hasTables=0 AND @blessable=1
    BEGIN
        DECLARE @expNull NVARCHAR(MAX) =
            CASE WHEN @nullIsNull=1 OR @blessNull IS NULL THEN N'NULL'
                 WHEN @isStr=1 THEN N'N'''+REPLACE(@blessNull,N'''',N'''''')+N''''
                 ELSE N'CAST(N'''+REPLACE(@blessNull,N'''',N'''''')+N''' AS '+@rtName+N')' END;
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' handles NULL arguments]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    DECLARE @expected '+@rtName+N' = '+@expNull+N';'+@CRLF+
            N'    DECLARE @actual '+@rtName+N' = '+@fnFull+N'('+@litNull+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEquals @expected, @actual;'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END;

    SET @GeneratedScript = @s;
    IF @ExecuteScript = 1
        EXEC TestGen.ExecuteBatchedScript @s;
END;
GO
PRINT 'TestGen.GenerateTestsForScalarFunction installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForTableFunction   (IF + TF)
 *   Emits test_<fn> for a table-valued function.  Assertions, honest:
 *     - result-set shape: SELECT TOP 0 * INTO #actual FROM fn(args) and assert
 *       it matches the function's catalogued RETURNS columns (real)
 *     - determinism: two materializations of fn(args) are AssertEqualsTable
 *   Row-level value blessing under seeded data is left as a SkipTest
 *   placeholder (follow-up); coverage is measured via RunCoverageForFunction.
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForTableFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForTableFunction;
GO
CREATE PROCEDURE TestGen.GenerateTestsForTableFunction
    @SchemaName      SYSNAME,
    @FunctionName    SYSNAME,
    @TestClassName   SYSNAME       = NULL,
    @ExecuteScript   BIT           = 1,
    @GeneratedScript NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2)=CHAR(13)+CHAR(10);
    IF @TestClassName IS NULL SET @TestClassName=N'test_'+@FunctionName;

    DECLARE @kind VARCHAR(10)=TestGen.GetFunctionKind(@SchemaName,@FunctionName);
    IF @kind NOT IN ('IF','TF')
    BEGIN RAISERROR('%s.%s is not a table-valued function.',16,1,@SchemaName,@FunctionName); RETURN; END;

    DECLARE @objid INT=OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @fnFull NVARCHAR(400)=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@FunctionName);

    DECLARE @litHappy NVARCHAR(MAX)=N'';
    SELECT @litHappy=@litHappy+CASE WHEN @litHappy=N'' THEN N'' ELSE N', ' END
             +TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0 ORDER BY parameter_id;

    -- catalogued return columns -> a typed empty table for the shape assertion
    DECLARE @expCols NVARCHAR(MAX)=N'';
    SELECT @expCols=@expCols+CASE WHEN @expCols=N'' THEN N'' ELSE N', ' END
             +QUOTENAME(c.name)+N' '
             +dbo.TestGen_RebuildTypeName(TYPE_NAME(c.user_type_id),c.max_length,c.precision,c.scale)
    FROM sys.columns c WHERE c.object_id=@objid ORDER BY c.column_id;

    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes=@fakes+N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                +SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;'+@CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- [item 4] PURE TVF (no table deps) -> snapshot the current output into a
    -- persistent baseline table and AssertEqualsTable against it.  Table-
    -- dependent TVFs keep the honest SkipTest below.
    DECLARE @hasTables BIT = TestGen.Fn_HasTableDependency(@SchemaName,@FunctionName);
    DECLARE @blessOK   BIT = 0;
    DECLARE @blessName SYSNAME = LEFT(N'FnBless_'+@SchemaName+N'_'+@FunctionName,128);
    DECLARE @blessFull NVARCHAR(400) = N'TestGenLog.'+QUOTENAME(@blessName);
    IF @hasTables=0
    BEGIN
        BEGIN TRY
            IF OBJECT_ID(@blessFull) IS NOT NULL EXEC('DROP TABLE '+@blessFull);
            EXEC('SELECT * INTO '+@blessFull+' FROM '+@fnFull+'('+@litHappy+')');
            SET @blessOK=1;
        END TRY BEGIN CATCH SET @blessOK=0; END CATCH;
    END;

    DECLARE @s NVARCHAR(MAX)=
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@TestClassName+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- shape test
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns the declared result shape]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    SELECT TOP 0 * INTO #actual FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    CREATE TABLE #expected ('+@expCols+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEqualsTableSchema ''#expected'', ''#actual'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- determinism test
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' is deterministic]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    SELECT * INTO #a FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    SELECT * INTO #b FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEqualsTable ''#a'', ''#b'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- [item 4] row-value test: pure TVF -> AssertEqualsTable vs the blessed
    -- snapshot; table-dependent TVF -> honest SkipTest.
    IF @blessOK=1
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns blessed rows]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    SELECT * INTO #actual FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEqualsTable '''+@blessFull+N''', ''#actual'';'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    ELSE
        SET @s += N'--[@tSQLt:SkipTest](''row-value characterization needs a blessed baseline under seeded data'')'+@CRLF+
            N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' row characterization - needs manual bless]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    -- Table-dependent: seed the faked tables, materialize '+@fnFull+N'(...),'+@CRLF+
            N'    -- and AssertEqualsTable against a blessed baseline.  Coverage is'+@CRLF+
            N'    -- measured independently via TestGen.RunCoverageForFunction.'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    SET @GeneratedScript=@s;
    IF @ExecuteScript=1 EXEC TestGen.ExecuteBatchedScript @s;
END;
GO
PRINT 'TestGen.GenerateTestsForTableFunction installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForObject  -  dispatcher
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForObject','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForObject;
GO
CREATE PROCEDURE TestGen.GenerateTestsForObject
    @SchemaName    SYSNAME,
    @ObjectName    SYSNAME,
    @ExecuteScript BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ObjectName));
    IF @id IS NULL BEGIN RAISERROR('%s.%s does not exist.',16,1,@SchemaName,@ObjectName); RETURN; END;
    DECLARE @type CHAR(2) = (SELECT type FROM sys.objects WHERE object_id=@id);

    IF @type='P'
        EXEC TestGen.GenerateTestsForProcedure @SchemaName=@SchemaName,@ProcName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE IF @type='FN'
        EXEC TestGen.GenerateTestsForScalarFunction @SchemaName=@SchemaName,@FunctionName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE IF @type IN ('IF','TF')
        EXEC TestGen.GenerateTestsForTableFunction @SchemaName=@SchemaName,@FunctionName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE
        RAISERROR('%s.%s is type %s - not a supported testable object (P/FN/IF/TF).',16,1,@SchemaName,@ObjectName,@type);
END;
GO
PRINT 'TestGen.GenerateTestsForObject installed.';
GO

/*===========================================================================
 * TestGen.RunCoverageForFunction
 *   1. build shadow proc   2. generate driver class test_<fn>_covfn
 *   3. call unchanged TestGen.RunCoverage on the shadow
 *   4. relabel CoverageResult to the function   5. clean up
 *==========================================================================*/
/*===========================================================================
 * v11 Step 2 (DESIGN_v11_BranchSeeding.md, Layer B): predicate-inversion
 * branch seeding.  SeedFromLeaf inverts one comparison leaf to a value that
 * makes the predicate TRUE; ExtractBranchSeeds pulls (param, satisfying value)
 * leaves from a function body.  RunCoverageForFunction then drives the shadow
 * once per leaf (target param satisfied, others happy), reaching value-gated
 * branches on purpose.  A wrong seed is harmless (each seed EXEC is TRY/CATCH'd
 * and the Step-1 loop cap makes it hang-proof); unsolvable predicates yield no
 * seed and stay honest residue.
 *==========================================================================*/
IF OBJECT_ID('TestGen.SeedFromLeaf','FN') IS NOT NULL
    DROP FUNCTION TestGen.SeedFromLeaf;
GO
CREATE FUNCTION TestGen.SeedFromLeaf(@op VARCHAR(12), @lit NVARCHAR(500))
RETURNS NVARCHAR(500)
AS
BEGIN
    IF @op IN ('=','<=','>=','IN','BETWEEN','LIKE') RETURN @lit;   -- literal satisfies as-is
    IF @op = 'ISNULL' RETURN N'NULL';
    IF @op IN ('<','>','<>')
    BEGIN
        DECLARE @bi BIGINT = TRY_CONVERT(BIGINT, @lit);
        IF @bi IS NOT NULL
            RETURN CONVERT(NVARCHAR(40), CASE WHEN @op='<' THEN @bi-1 ELSE @bi+1 END);
        DECLARE @dn DECIMAL(38,10) = TRY_CONVERT(DECIMAL(38,10), @lit);
        IF @dn IS NOT NULL
            RETURN CONVERT(NVARCHAR(50), CASE WHEN @op='<' THEN @dn-1 ELSE @dn+1 END);
        RETURN NULL;            -- non-numeric: cannot invert < > <>
    END;
    RETURN NULL;                -- ISNOTNULL and anything else: no seed
END;
GO
PRINT 'TestGen.SeedFromLeaf installed.';
GO
IF OBJECT_ID('TestGen.ExtractBranchSeeds','TF') IS NOT NULL
    DROP FUNCTION TestGen.ExtractBranchSeeds;
GO
CREATE FUNCTION TestGen.ExtractBranchSeeds(@Body NVARCHAR(MAX), @ParamCsv NVARCHAR(MAX))
RETURNS @seeds TABLE (ParamName SYSNAME, SeedLiteral NVARCHAR(500))
AS
BEGIN
    DECLARE @pset NVARCHAR(MAX) = N'|' + UPPER(REPLACE(REPLACE(REPLACE(ISNULL(@ParamCsv,N''),N' ',N''),CHAR(13),N''),CHAR(10),N'')) + N'|';
    SET @pset = REPLACE(@pset, N',', N'|');     -- -> |@N|@STATUS|
    IF @pset = N'||' RETURN;

    DECLARE @len INT = LEN(@Body), @i INT = 1;
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pvc NCHAR(1);
    DECLARE @tok NVARCHAR(200),@k INT,@kc NCHAR(1);
    DECLARE @op VARCHAR(12),@operand NVARCHAR(500),@seed NVARCHAR(500),@w NVARCHAR(20),@w2 NVARCHAR(10);
    DECLARE @prevWord NVARCHAR(20)=N'',@curWord NVARCHAR(40)=N'';
    DECLARE @found BIT;

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Body,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;

        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; SET @prevWord=N''; SET @curWord=N''; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlk=1; SET @prevWord=N''; SET @curWord=N''; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @i+=1; SET @inStr=1; SET @prevWord=N''; SET @curWord=N''; CONTINUE; END;
        IF @ch=N'['  BEGIN SET @i+=1; SET @inBr=1; SET @prevWord=N''; SET @curWord=N''; CONTINUE; END;

        IF @ch LIKE N'[A-Za-z]'
        BEGIN
            SET @curWord = @curWord + @ch; SET @i+=1; CONTINUE;
        END
        ELSE IF @curWord <> N''
        BEGIN
            SET @prevWord = UPPER(@curWord); SET @curWord = N'';
        END;

        IF @ch = N'@'
        BEGIN
            SET @pvc = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pvc)=1
            BEGIN
                SET @tok = N'@'; SET @k = @i+1;
                WHILE @k<=@len
                BEGIN
                    SET @kc = SUBSTRING(@Body,@k,1);
                    IF @kc LIKE N'[A-Za-z0-9_@#]' BEGIN SET @tok+=@kc; SET @k+=1; END ELSE BREAK;
                END;
                IF CHARINDEX(N'|'+UPPER(@tok)+N'|', @pset) > 0 AND @prevWord <> N'SET'
                BEGIN
                    SET @op=NULL; SET @operand=NULL; SET @found=0;
                    WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                    SET @kc = CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                    IF SUBSTRING(@Body,@k,2) IN (N'>=',N'<=',N'<>',N'!=')
                    BEGIN SET @op=CASE WHEN SUBSTRING(@Body,@k,2)=N'!=' THEN '<>' ELSE SUBSTRING(@Body,@k,2) END COLLATE DATABASE_DEFAULT; SET @k+=2; END
                    ELSE IF @kc=N'=' BEGIN SET @op='='; SET @k+=1; END
                    ELSE IF @kc=N'<' BEGIN SET @op='<'; SET @k+=1; END
                    ELSE IF @kc=N'>' BEGIN SET @op='>'; SET @k+=1; END
                    ELSE
                    BEGIN
                        SET @w=N'';
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                        SET @w=UPPER(@w);
                        IF @w=N'IS'
                        BEGIN
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                            SET @w2=N'';
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w2+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            SET @w2=UPPER(@w2);
                            IF @w2=N'NULL' SET @op='ISNULL';
                        END
                        ELSE IF @w=N'IN' SET @op='IN';
                        ELSE IF @w=N'BETWEEN' SET @op='BETWEEN';
                        ELSE IF @w=N'LIKE' SET @op='LIKE';
                    END;

                    IF @op IN ('=','<','>','<=','>=','<>','LIKE','IN','BETWEEN')
                    BEGIN
                        IF @op='IN'
                        BEGIN
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                            IF SUBSTRING(@Body,@k,1)=N'(' SET @k+=1;
                        END;
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                        SET @kc = CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                        IF @kc=N''''
                        BEGIN
                            SET @operand=N''''; SET @k+=1;
                            WHILE @k<=@len
                            BEGIN
                                SET @kc=SUBSTRING(@Body,@k,1);
                                IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @operand+=N''''''; SET @k+=2; CONTINUE; END;
                                SET @operand+=@kc; SET @k+=1;
                                IF @kc=N'''' BREAK;
                            END;
                        END
                        ELSE IF @kc LIKE N'[0-9]' OR (@kc IN (N'-',N'+',N'.') AND SUBSTRING(@Body,@k+1,1) LIKE N'[0-9]')
                        BEGIN
                            SET @operand=N'';
                            IF @kc IN (N'-',N'+') BEGIN SET @operand+=@kc; SET @k+=1; END;
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[0-9.]' BEGIN SET @operand+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                        END;

                        IF @op='LIKE' AND @operand IS NOT NULL
                        BEGIN
                            SET @operand = REPLACE(REPLACE(@operand, N'%', N''), N'_', N'');
                            IF @operand = N'''''' SET @operand = NULL;
                        END;
                    END;

                    IF @op='ISNULL'
                        INSERT @seeds(ParamName,SeedLiteral) VALUES(@tok, N'NULL');
                    ELSE IF @op IS NOT NULL AND @operand IS NOT NULL
                    BEGIN
                        SET @seed = TestGen.SeedFromLeaf(@op, @operand);
                        IF @seed IS NOT NULL
                            INSERT @seeds(ParamName,SeedLiteral) VALUES(@tok, @seed);
                    END;

                    SET @i = @k; SET @prevWord=N''; CONTINUE;
                END;
                SET @i = @k; SET @prevWord=N''; CONTINUE;
            END;
        END;

        SET @i += 1;
    END;
    RETURN;
END;
GO
PRINT 'TestGen.ExtractBranchSeeds installed.';
GO

IF OBJECT_ID('TestGen.RunCoverageForFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.RunCoverageForFunction;
GO
CREATE PROCEDURE TestGen.RunCoverageForFunction
    @SchemaName   SYSNAME,
    @FunctionName SYSNAME,
    @OutputMode   VARCHAR(10) = 'TEXT',
    @BatchId      DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2)=CHAR(13)+CHAR(10);
    DECLARE @kind VARCHAR(10)=TestGen.GetFunctionKind(@SchemaName,@FunctionName);
    IF @kind NOT IN ('FN','IF','TF')
    BEGIN
        PRINT 'RunCoverageForFunction: '+@SchemaName+'.'+@FunctionName+' is not a T-SQL function ('+@kind+'). Coverage deferred.';
        RETURN;
    END;

    -- 1. shadow
    DECLARE @shadow SYSNAME, @status NVARCHAR(200);
    EXEC TestGen.BuildShadowProcForFunction @SchemaName=@SchemaName,@FunctionName=@FunctionName,
         @ShadowName=@shadow OUTPUT,@Status=@status OUTPUT;
    IF @status <> N'OK'
    BEGIN
        PRINT '=============================================================';
        PRINT ' COVERAGE DEFERRED: '+@SchemaName+'.'+@FunctionName;
        PRINT ' '+@status;
        PRINT ' Shadow procedure could not be built - honest deferral, not a false 0%.';
        PRINT '=============================================================';
        IF @BatchId IS NOT NULL
            INSERT TestGen.CoverageResult
                (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
                 TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
                 TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
            VALUES (@BatchId,@SchemaName,@FunctionName,0,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,0,0,
                 @status,N'NOT_TESTABLE',@status,SYSUTCDATETIME());
        RETURN;
    END;

    DECLARE @objid INT=OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @shadowFull NVARCHAR(400)=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow);
    DECLARE @driverClass SYSNAME = N'test_'+@shadow;

    -- per-parameter happy literal (drives @namedHappy below + the seed args)
    DECLARE @ph TABLE (ord INT, name SYSNAME, happyLit NVARCHAR(MAX));
    INSERT @ph (ord,name,happyLit)
    SELECT parameter_id, name,
           TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0;

    DECLARE @namedHappy NVARCHAR(MAX)=N'', @namedNull NVARCHAR(MAX)=N'';
    SELECT @namedHappy=@namedHappy+name+N'='+happyLit+N', ',
           @namedNull =@namedNull +name+N'=NULL, '
    FROM @ph ORDER BY ord;

    -- FakeTable list for the driver
    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes=@fakes+N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                +SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;'+@CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- shadow OUTPUT clause for scalar
    DECLARE @ret NVARCHAR(100) = CASE WHEN @kind='FN' THEN N'@__ret=@o OUTPUT' ELSE N'' END;
    DECLARE @retDecl NVARCHAR(200)=N'';
    IF @kind='FN'
    BEGIN
        DECLARE @rt2 SYSNAME,@rml2 SMALLINT,@rp2 TINYINT,@rs2 TINYINT;
        SELECT @rt2=TYPE_NAME(user_type_id),@rml2=max_length,@rp2=precision,@rs2=scale
        FROM sys.parameters WHERE object_id=@objid AND parameter_id=0;
        SET @retDecl=N'    DECLARE @o '+dbo.TestGen_RebuildTypeName(@rt2,@rml2,@rp2,@rs2)+N';'+@CRLF;
    END;

    -- trim trailing ", " from named lists
    IF RIGHT(@namedHappy,1)=N' ' SET @namedHappy=LEFT(@namedHappy,LEN(@namedHappy)-1);
    IF RIGHT(@namedHappy,1)=N',' SET @namedHappy=LEFT(@namedHappy,LEN(@namedHappy)-1);
    IF RIGHT(@namedNull,1)=N' '  SET @namedNull=LEFT(@namedNull,LEN(@namedNull)-1);
    IF RIGHT(@namedNull,1)=N','  SET @namedNull=LEFT(@namedNull,LEN(@namedNull)-1);

    DECLARE @execHappy NVARCHAR(MAX)=N'    EXEC '+@shadowFull
        +CASE WHEN @namedHappy=N'' THEN N'' ELSE N' '+@namedHappy END
        +CASE WHEN @ret=N'' THEN N'' ELSE CASE WHEN @namedHappy=N'' THEN N' ' ELSE N', ' END+@ret END+N';';
    DECLARE @execNull NVARCHAR(MAX)=N'    EXEC '+@shadowFull
        +CASE WHEN @namedNull=N'' THEN N'' ELSE N' '+@namedNull END
        +CASE WHEN @ret=N'' THEN N'' ELSE CASE WHEN @namedNull=N'' THEN N' ' ELSE N', ' END+@ret END+N';';

    -- Step 2: predicate-inversion seed calls (one per branch leaf; target param
    -- satisfied, others happy).  Wrapped so any extractor failure is non-fatal -
    -- coverage then falls back to happy+NULL only.
    DECLARE @execSeeds NVARCHAR(MAX)=N'', @seedCount INT=0;
    BEGIN TRY
        DECLARE @fndef NVARCHAR(MAX)=OBJECT_DEFINITION(@objid);
        DECLARE @asp INT = TestGen.FindTopLevelAs(@fndef);
        DECLARE @fnbody NVARCHAR(MAX)= CASE WHEN @asp>0 THEN SUBSTRING(@fndef,@asp+2,LEN(@fndef)) ELSE @fndef END;
        DECLARE @paramCsv NVARCHAR(MAX)=N'';
        SELECT @paramCsv=@paramCsv+name+N',' FROM @ph ORDER BY ord;
        DECLARE @retClause NVARCHAR(120)=CASE WHEN @ret=N'' THEN N'' ELSE N', '+@ret END;
        ;WITH leaf AS (SELECT DISTINCT ParamName, SeedLiteral FROM TestGen.ExtractBranchSeeds(@fnbody,@paramCsv))
        SELECT @execSeeds = @execSeeds
             + N'    BEGIN TRY EXEC '+@shadowFull+N' '+ z.args + @retClause + N'; END TRY BEGIN CATCH END CATCH;'+@CRLF,
               @seedCount = @seedCount + 1
        FROM (
            SELECT l.ParamName, l.SeedLiteral,
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                        p.name + N'=' + CASE WHEN UPPER(p.name)=UPPER(l.ParamName) THEN l.SeedLiteral ELSE p.happyLit END),
                        N', ') WITHIN GROUP (ORDER BY p.ord) AS args
            FROM leaf l CROSS JOIN @ph p
            GROUP BY l.ParamName, l.SeedLiteral
        ) z;
    END TRY
    BEGIN CATCH
        SET @execSeeds = N'';
        PRINT 'RunCoverageForFunction: branch seeding skipped ('+ERROR_MESSAGE()+')';
    END CATCH;

    DECLARE @drv NVARCHAR(MAX)=
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@driverClass+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'CREATE PROCEDURE '+QUOTENAME(@driverClass)+N'.[test drive '+@shadow+N' sample inputs]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+@retDecl+
        N'    BEGIN TRY'+@CRLF+@execHappy+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        N'    BEGIN TRY'+@CRLF+@execNull+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        ISNULL(@execSeeds,N'')+
        N'    EXEC tSQLt.AssertEquals 1, 1; -- driver: execution drives coverage'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF;
    EXEC TestGen.ExecuteBatchedScript @drv;
    IF @seedCount > 0 PRINT 'RunCoverageForFunction: '+CAST(@seedCount AS VARCHAR)+' predicate-inversion seed(s) added for '+@SchemaName+'.'+@FunctionName+'.';

    -- 3. measure coverage on the shadow, capturing test outcomes so we can
    --    persist a CoverageResult row keyed by the FUNCTION (the shadow is an
    --    internal artifact).  @OutputMode='NONE' silences the per-object report
    --    when called from GenerateAndCoverDatabase.
    DECLARE @run INT=0,@pass INT=0,@fail INT=0,@errc INT=0,@skip INT=0;
    DECLARE @tot INT=0,@cov INT=0,@tb INT=0,@cb INT=0,@lp DECIMAL(5,1),@bp DECIMAL(5,1);
    BEGIN TRY
        EXEC TestGen.RunCoverage @SchemaName=@SchemaName, @ProcName=@shadow, @OutputMode=@OutputMode,
             @TestsRun=@run OUTPUT, @TestsPassed=@pass OUTPUT, @TestsFailed=@fail OUTPUT,
             @TestsErrored=@errc OUTPUT, @TestsSkipped=@skip OUTPUT;
    END TRY
    BEGIN CATCH
        PRINT 'RunCoverageForFunction: RunCoverage on shadow failed: '+ERROR_MESSAGE();
    END CATCH;

    -- 4. compute coverage from the shadow's line catalogue + hits (same rule as
    --    GenerateAndCoverDatabase) and persist a CoverageResult row under the
    --    FUNCTION name.
    ;WITH ln AS (
        SELECT cl.LineNum, cl.IsExec, cl.IsBranch,
               CASE WHEN EXISTS (SELECT 1 FROM TestGen.CoverageHits ch
                                 WHERE ch.SchemaName=cl.SchemaName AND ch.ProcName=cl.ProcName
                                   AND ch.LineNum=cl.LineNum) THEN 1 ELSE 0 END AS DirectHit
        FROM TestGen.CoverageLines cl
        WHERE cl.SchemaName=@SchemaName AND cl.ProcName=@shadow
    ),
    nx AS (
        SELECT l.LineNum,
               (SELECT TOP 1 e.LineNum FROM ln e WHERE e.IsExec=1 AND e.LineNum>l.LineNum ORDER BY e.LineNum) AS NextExecLine
        FROM ln l WHERE l.IsBranch=1
    ),
    bi AS (
        SELECT n.LineNum, ISNULL(l.DirectHit,0) AS BodyHit
        FROM nx n LEFT JOIN ln l ON l.LineNum=n.NextExecLine
    )
    SELECT @tot=ISNULL(SUM(CAST(l.IsExec AS INT)),0),
           @cov=ISNULL(SUM(CASE WHEN l.IsExec=1 AND l.DirectHit=1 THEN 1 ELSE 0 END),0),
           @tb =ISNULL(SUM(CAST(l.IsBranch AS INT)),0),
           @cb =ISNULL(SUM(CASE WHEN l.IsBranch=1 AND b.BodyHit=1 THEN 1 ELSE 0 END),0)
    FROM ln l LEFT JOIN bi b ON b.LineNum=l.LineNum;
    SET @lp = CASE WHEN @tot>0 THEN CAST(@cov AS DECIMAL(9,2))/@tot*100 ELSE 0 END;
    SET @bp = CASE WHEN @tb >0 THEN CAST(@cb  AS DECIMAL(9,2))/@tb *100 ELSE 0 END;

    -- Report the FUNCTION's assertion suite (test_<fn>: determinism / blessed
    -- value / result-shape) as its Tests counts, if that class exists - the
    -- coverage driver's single trivial AssertEquals is not meaningful.  Run it
    -- here (independent of the dropped shadow) and read tSQLt.TestResult.
    DECLARE @asclass SYSNAME = N'test_'+@FunctionName;
    IF SCHEMA_ID(@asclass) IS NOT NULL
    BEGIN
        SET @run=0; SET @pass=0; SET @fail=0; SET @errc=0; SET @skip=0;
        BEGIN TRY EXEC tSQLt.Run @asclass; END TRY BEGIN CATCH END CATCH;
        IF OBJECT_ID('tSQLt.TestResult','U') IS NOT NULL
            SELECT @run =ISNULL(COUNT(*),0),
                   @pass=ISNULL(SUM(CASE WHEN Result='Success' THEN 1 ELSE 0 END),0),
                   @fail=ISNULL(SUM(CASE WHEN Result='Failure' THEN 1 ELSE 0 END),0),
                   @errc=ISNULL(SUM(CASE WHEN Result='Error'   THEN 1 ELSE 0 END),0),
                   @skip=ISNULL(SUM(CASE WHEN Result IN ('Skipped','Skip','Ignored') THEN 1 ELSE 0 END),0)
            FROM tSQLt.TestResult WHERE Class=@asclass;
    END;
    BEGIN TRY
        INSERT TestGen.CoverageResult
            (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
             TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
             TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
        VALUES
            (ISNULL(@BatchId,SYSUTCDATETIME()),@SchemaName,@FunctionName,1,@tot,@cov,@lp,
             @tb,@cb,@bp,@run,@pass,@fail,@errc,@skip,0,NULL,N'TESTABLE',NULL,SYSUTCDATETIME());
    END TRY BEGIN CATCH END CATCH;

    -- 5. cleanup: driver class, the instrumented _cov copy, the shadow, and
    --    any stranded synonym / _orig left if RunCoverage died mid-swap.
    --    The _cov / _orig suffixes are part of the OBJECT NAME, so they must go
    --    INSIDE QUOTENAME - QUOTENAME(@shadow + N'_cov') - not @shadowFull + a
    --    suffix, which would put it outside the brackets and match nothing.
    DECLARE @covF  NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_cov');
    DECLARE @origF NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_orig');
    BEGIN TRY EXEC tSQLt.DropClass @driverClass; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'SN') IS NOT NULL EXEC('DROP SYNONYM '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@covF,'P')       IS NOT NULL EXEC('DROP PROCEDURE '+@covF);      END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'P') IS NOT NULL EXEC('DROP PROCEDURE '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@origF,'P')      IS NOT NULL EXEC('DROP PROCEDURE '+@origF);     END TRY BEGIN CATCH END CATCH;
END;
GO
PRINT 'TestGen.RunCoverageForFunction installed.';
GO

/*===========================================================================
 * v11: function-aware override of TestGen.GenerateAndCoverDatabase.
 * Identical to the base proc for stored procedures; additionally
 * enumerates user functions (FN/IF/TF) and routes them through
 * RunCoverageForFunction (shadow-procedure coverage).  Appended AFTER
 * the base definition so this version wins.
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateAndCoverDatabase','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateAndCoverDatabase;
GO
CREATE PROCEDURE TestGen.GenerateAndCoverDatabase
    @SchemaFilter   SYSNAME       = NULL,   -- NULL = every user schema
    @ExcludePattern NVARCHAR(200) = NULL,   -- LIKE pattern of proc names to skip
    @OutputMode     VARCHAR(10)   = 'HTML'  -- HTML, TEXT, or COBERTURA
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('TestGen.GenerateTestsForProcedure','P') IS NULL
       OR OBJECT_ID('TestGen.RunCoverage','P') IS NULL
    BEGIN
        RAISERROR('The tSQLt Auto-Gen framework is not fully installed in this database.',16,1);
        RETURN;
    END;

    DECLARE @BatchId DATETIME2(3) = SYSUTCDATETIME();

    -- loop variables (declared once; SET per iteration - never DECLARE = expr in a loop)
    DECLARE @Seq INT, @s SYSNAME, @p SYSNAME, @cls SYSNAME;
    DECLARE @k CHAR(2);
    DECLARE @genOK BIT, @err NVARCHAR(2000), @Total INT;
    DECLARE @run INT,@pass INT,@fail INT,@errc INT,@skip INT;
    DECLARE @tot INT,@cov INT,@tb INT,@cb INT;
    DECLARE @lp DECIMAL(5,1), @bp DECIMAL(5,1);
    DECLARE @testability VARCHAR(20), @reason NVARCHAR(400);   -- v9.4.3 testability gate
    DECLARE @pres INT;                                          -- v9.4.4 preservation count from GenerateTestsForProcedure

    -- v11: enumerate stored procedures AND user functions (FN/IF/TF).
    DECLARE @work TABLE (Seq INT IDENTITY(1,1), s SYSNAME, p SYSNAME, k CHAR(2));
    INSERT @work (s,p,k)
    SELECT SCHEMA_NAME(o.schema_id), o.name, o.type
    FROM   sys.objects o
    WHERE  o.type IN ('P','FN','IF','TF')
      AND  o.is_ms_shipped = 0
      AND  SCHEMA_NAME(o.schema_id) NOT IN ('tSQLt','TestGen','TestGenLog')
      AND  SCHEMA_NAME(o.schema_id) NOT LIKE 'test[_]%'      -- exclude generated test classes
      AND  (@SchemaFilter   IS NULL OR SCHEMA_NAME(o.schema_id) = @SchemaFilter)
      AND  (@ExcludePattern IS NULL OR o.name NOT LIKE @ExcludePattern)
      AND  o.name NOT LIKE '%[_]cov'     -- _cov instrumentation copies
      AND  o.name NOT LIKE '%[_]covfn'   -- v11 shadow procedures
      AND  o.name NOT LIKE '%[_]orig'    -- stranded _orig originals
      AND  o.name NOT LIKE 'TestGen[_]%' -- framework helper(s) placed in dbo
    ORDER  BY 1,2;

    SET @Total = (SELECT COUNT(*) FROM @work);
    PRINT 'GenerateAndCoverDatabase: ' + CAST(@Total AS VARCHAR) + ' object(s) (procedures + functions) to process.';
    PRINT '';
    PRINT 'NOTE: turn SYSTEM_VERSIONING OFF on any system-versioned temporal';
    PRINT '      tables before this run, and back ON afterwards - see the';
    PRINT '      README_v9_4 temporal prerequisite.  A procedure still';
    PRINT '      system-versioned, or using FOR SYSTEM_TIME, is reported';
    PRINT '      NOT TESTABLE.';

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Seq,s,p,k FROM @work ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @genOK=0; SET @err=NULL; SET @cls=N'test_'+@p;
        SET @run=0; SET @pass=0; SET @fail=0; SET @errc=0; SET @skip=0;
        SET @tot=0; SET @cov=0; SET @tb=0; SET @cb=0;
        SET @pres=0;   -- v9.4.4: preservation count reset per iteration

        PRINT '  [' + CAST(@Seq AS VARCHAR) + '/' + CAST(@Total AS VARCHAR) + '] ' + @s + '.' + @p;

        -- v11: functions (FN/IF/TF) route through the shadow-procedure coverage
        -- path, which persists its own CoverageResult row keyed by the function.
        IF @k <> 'P'
        BEGIN
            BEGIN TRY
                EXEC TestGen.GenerateTestsForObject @SchemaName=@s, @ObjectName=@p, @ExecuteScript=1;
            END TRY BEGIN CATCH SET @err=N'GEN: '+ERROR_MESSAGE(); END CATCH
            BEGIN TRY
                EXEC TestGen.RunCoverageForFunction @SchemaName=@s, @FunctionName=@p,
                     @OutputMode='NONE', @BatchId=@BatchId;
            END TRY BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'COV: '+ERROR_MESSAGE(); END CATCH
            PRINT '      -> function ('+@k+') coverage measured';
            FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
            CONTINUE;
        END;

        -- v9.4.3: testability gate - classify the procedure BEFORE generation.
        -- A NOT_TESTABLE procedure (no fakeable dependencies + system-catalog
        -- usage) gets the Phase 1 SkipTest marker class and a CoverageResult
        -- row with NULL coverage - it is never measured, never shown as 0%.
        SET @testability = N'TESTABLE'; SET @reason = NULL;
        BEGIN TRY
            EXEC TestGen.AssessTestability @SchemaName=@s, @ProcName=@p,
                 @Verdict=@testability OUTPUT, @Reason=@reason OUTPUT;
        END TRY
        BEGIN CATCH SET @testability = N'TESTABLE'; END CATCH

        IF @testability = N'NOT_TESTABLE'
        BEGIN
            BEGIN TRY
                EXEC TestGen.GenerateTestsForProcedure
                     @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                     @TestsPreservedCount=@pres OUTPUT;
            END TRY
            BEGIN CATCH SET @err = N'GEN: ' + ERROR_MESSAGE(); END CATCH

            INSERT TestGen.CoverageResult
                (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
                 TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
                 TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
            VALUES
                (@BatchId,@s,@p,1,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,1,@pres,@err,
                 N'NOT_TESTABLE',@reason,SYSUTCDATETIME());

            PRINT '      -> NOT TESTABLE - recorded, not measured';
            FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
            CONTINUE;
        END;


        -- 1. generate + install the test class
        BEGIN TRY
            EXEC TestGen.GenerateTestsForProcedure @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                 @TestsPreservedCount=@pres OUTPUT;
            SET @genOK=1;
        END TRY
        BEGIN CATCH SET @err=N'GEN: '+ERROR_MESSAGE(); END CATCH

        IF @genOK = 1
        BEGIN
            -- RunCoverage runs the tests ONCE (instrumented), measures coverage,
            -- AND returns the outcomes via OUTPUT params - no separate test run.
            -- Silent: 'NONE' -> GetCoverageReport emits no per-procedure report.
            BEGIN TRY
                EXEC TestGen.RunCoverage
                     @SchemaName=@s, @ProcName=@p, @OutputMode='NONE',
                     @TestsRun=@run OUTPUT, @TestsPassed=@pass OUTPUT,
                     @TestsFailed=@fail OUTPUT, @TestsErrored=@errc OUTPUT,
                     @TestsSkipped=@skip OUTPUT;
            END TRY
            BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'COV: '+ERROR_MESSAGE(); END CATCH

            -- 4. compute coverage from the line catalogue + hits (same rule as GetCoverageReport)
            ;WITH ln AS (
                SELECT cl.LineNum, cl.IsExec, cl.IsBranch,
                       CASE WHEN EXISTS (SELECT 1 FROM TestGen.CoverageHits ch
                                         WHERE ch.SchemaName=cl.SchemaName
                                           AND ch.ProcName=cl.ProcName
                                           AND ch.LineNum=cl.LineNum) THEN 1 ELSE 0 END AS DirectHit
                FROM TestGen.CoverageLines cl
                WHERE cl.SchemaName=@s AND cl.ProcName=@p
            ),
            nx AS (
                SELECT l.LineNum,
                       (SELECT TOP 1 e.LineNum FROM ln e
                        WHERE e.IsExec=1 AND e.LineNum>l.LineNum ORDER BY e.LineNum) AS NextExecLine
                FROM ln l WHERE l.IsBranch=1
            ),
            bi AS (
                SELECT n.LineNum, ISNULL(l.DirectHit,0) AS BodyHit
                FROM nx n LEFT JOIN ln l ON l.LineNum=n.NextExecLine
            )
            SELECT @tot=ISNULL(SUM(CAST(l.IsExec AS INT)),0),
                   @cov=ISNULL(SUM(CASE WHEN l.IsExec=1 AND l.DirectHit=1 THEN 1 ELSE 0 END),0),
                   @tb =ISNULL(SUM(CAST(l.IsBranch AS INT)),0),
                   @cb =ISNULL(SUM(CASE WHEN l.IsBranch=1 AND b.BodyHit=1 THEN 1 ELSE 0 END),0)
            FROM ln l LEFT JOIN bi b ON b.LineNum=l.LineNum;
        END

        SET @lp = CASE WHEN @tot>0 THEN CAST(@cov AS DECIMAL(9,2))/@tot*100 ELSE 0 END;
        SET @bp = CASE WHEN @tb >0 THEN CAST(@cb  AS DECIMAL(9,2))/@tb *100 ELSE 0 END;

        INSERT TestGen.CoverageResult
            (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
             TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
             TestsErrored,TestsSkipped,TestsPreserved,ErrorText,RunAt)
        VALUES
            (@BatchId,@s,@p,@genOK,@tot,@cov,@lp,@tb,@cb,@bp,@run,@pass,@fail,
             @errc,@skip,@pres,@err,SYSUTCDATETIME());

        FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
    END
    CLOSE cur; DEALLOCATE cur;

    /*------------------------------ aggregates ------------------------------*/
    DECLARE @gProcs INT,@gGenFail INT,@gTot INT,@gCov INT,@gTB INT,@gCB INT,
            @gRun INT,@gPass INT,@gFail INT,@gErr INT,@gSkip INT;
    DECLARE @gNotTestable INT;
    DECLARE @gPres INT;   -- v9.4.4: total preserved (developer-modified) tests across the batch
    SELECT @gProcs=COUNT(*),
           @gNotTestable=ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 1 ELSE 0 END),0),
           @gGenFail=ISNULL(SUM(CASE WHEN GenSucceeded=0 THEN 1 ELSE 0 END),0),
           @gTot=ISNULL(SUM(TotalLines),0),     @gCov=ISNULL(SUM(CoveredLines),0),
           @gTB =ISNULL(SUM(TotalBranches),0),  @gCB =ISNULL(SUM(CoveredBranches),0),
           @gRun=ISNULL(SUM(TestsRun),0),       @gPass=ISNULL(SUM(TestsPassed),0),
           @gFail=ISNULL(SUM(TestsFailed),0),   @gErr=ISNULL(SUM(TestsErrored),0),
           @gSkip=ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 0 ELSE TestsSkipped END),0),
           @gPres=ISNULL(SUM(TestsPreserved),0)
    FROM TestGen.CoverageResult WHERE BatchId=@BatchId;

    DECLARE @gLinePct DECIMAL(5,1) = CASE WHEN @gTot>0 THEN CAST(@gCov AS DECIMAL(9,2))/@gTot*100 ELSE 0 END;
    DECLARE @gBrPct   DECIMAL(5,1) = CASE WHEN @gTB >0 THEN CAST(@gCB  AS DECIMAL(9,2))/@gTB *100 ELSE 0 END;
    DECLARE @pPass DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gPass AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pFail DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gFail AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pErr  DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gErr  AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pSkip DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gSkip AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    /* v9.4.4: Autonomy % = fraction of tests the framework still owns.
       Preserved tests are developer-modified tests that survive regeneration;
       they are still procs in the test class and tSQLt runs them as part of
       @gRun, so the denominator is just @gRun.  Autonomy = (run - preserved)/run. */
    DECLARE @gAutonomy DECIMAL(5,1) =
        CASE WHEN @gRun > 0
             THEN CAST(@gRun - @gPres AS DECIMAL(9,2)) / @gRun * 100
             ELSE 100 END;

    IF @OutputMode = 'TEXT'
    BEGIN
        PRINT '';
        PRINT '============== DATABASE COVERAGE SUMMARY ('+ DB_NAME() +') ==============';
        PRINT 'Objects         : ' + CAST(@gProcs AS VARCHAR) + '   (generation failed: ' + CAST(@gGenFail AS VARCHAR) + ')';
        PRINT 'Not testable    : ' + CAST(@gNotTestable AS VARCHAR) + '   (recorded; excluded from coverage %)';
        PRINT 'Line coverage   : ' + CAST(@gCov AS VARCHAR)+'/'+CAST(@gTot AS VARCHAR)+'  -> '+CAST(@gLinePct AS VARCHAR)+'%';
        PRINT 'Branch coverage : ' + CAST(@gCB AS VARCHAR)+'/'+CAST(@gTB AS VARCHAR)+'  -> '+CAST(@gBrPct AS VARCHAR)+'%';
        PRINT 'Tests           : ' + CAST(@gRun AS VARCHAR) + ' total';
        PRINT '   passed  : ' + CAST(@gPass AS VARCHAR) + '  (' + CAST(@pPass AS VARCHAR) + '%)';
        PRINT '   failed  : ' + CAST(@gFail AS VARCHAR) + '  (' + CAST(@pFail AS VARCHAR) + '%)';
        PRINT '   errored : ' + CAST(@gErr  AS VARCHAR) + '  (' + CAST(@pErr  AS VARCHAR) + '%)';
        PRINT '   skipped : ' + CAST(@gSkip AS VARCHAR) + '  (' + CAST(@pSkip AS VARCHAR) + '%)';
        PRINT 'Autonomy        : ' + CAST(@gAutonomy AS VARCHAR) + '%   ('
            + CAST(@gRun - @gPres AS VARCHAR) + '/' + CAST(@gRun AS VARCHAR)
            + ' framework-owned, ' + CAST(@gPres AS VARCHAR) + ' user-modified)';
        PRINT '=====================================================================';
        SELECT SchemaName, ProcName, Testability, GenSucceeded, TestsRun, TestsPassed, TestsFailed,
               TestsErrored, TestsSkipped, TotalLines, CoveredLines, LinePct, BranchPct, NotTestableReason, ErrorText
        FROM   TestGen.CoverageResult
        WHERE  BatchId = @BatchId
        ORDER  BY SchemaName, ProcName;
        RETURN;
    END;

    /*------------------------------ COBERTURA ------------------------------*/
    /* Delegates to TestGen.GetCoverageCoberturaXml (module 23).                      */
    /* All existing TEXT / HTML code above is untouched.                     */
    IF @OutputMode = 'COBERTURA'
    BEGIN
        EXEC TestGen.GetCoverageCoberturaXml @BatchId = @BatchId, @SchemaFilter = @SchemaFilter;
        RETURN;
    END;

    /*-------------------------------- HTML ---------------------------------*/
    DECLARE @H NVARCHAR(MAX) = N'';
    SET @H = @H + N'<!DOCTYPE html><html><head><meta charset="utf-8"><title>tSQLt Auto-Gen Coverage</title><style>';
    SET @H = @H + N'body{font-family:Segoe UI,Arial,sans-serif;margin:20px;color:#222}';
    SET @H = @H + N'h2{margin:0 0 2px}.meta{color:#777;font-size:12px;margin:0 0 14px}';
    SET @H = @H + N'.cards{display:flex;gap:14px;margin-bottom:16px;flex-wrap:wrap}';
    SET @H = @H + N'.card{border:1px solid #ddd;border-radius:6px;padding:10px 16px;min-width:150px}';
    SET @H = @H + N'.big{font-size:30px;font-weight:bold}.lbl{font-size:12px;color:#777}';
    SET @H = @H + N'.g{color:#1a7f37}.a{color:#9a6700}.r{color:#cf222e}';
    SET @H = @H + N'table{border-collapse:collapse;width:100%;font-size:13px}';
    SET @H = @H + N'th,td{border:1px solid #ddd;padding:4px 8px;text-align:right}';
    SET @H = @H + N'th{background:#f3f3f3}td.l,th.l{text-align:left}';
    SET @H = @H + N'tr.total{font-weight:bold;background:#f3f3f3}';
    SET @H = @H + N'</style></head><body>';
    SET @H = @H + N'<h2>tSQLt Auto-Gen &mdash; Database Coverage Report</h2>';
    SET @H = @H + N'<p class="meta">' + DB_NAME() + N' &middot; ' + CONVERT(VARCHAR,@BatchId,120)
                 + N' &middot; ' + CAST(@gProcs AS VARCHAR) + N' objects ('
                 + CAST(@gGenFail AS VARCHAR) + N' failed generation, '
                 + CAST(@gNotTestable AS VARCHAR) + N' not testable)</p>';

    SET @H = @H + N'<div class="cards">';
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gLinePct>=80 THEN 'g' WHEN @gLinePct>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gLinePct AS VARCHAR) + N'%</div><div class="lbl">Line coverage<br>'
        + CAST(@gCov AS VARCHAR) + N'/' + CAST(@gTot AS VARCHAR) + N' lines</div></div>';
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gBrPct>=80 THEN 'g' WHEN @gBrPct>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gBrPct AS VARCHAR) + N'%</div><div class="lbl">Branch coverage<br>'
        + CAST(@gCB AS VARCHAR) + N'/' + CAST(@gTB AS VARCHAR) + N' branches</div></div>';
    SET @H = @H + N'<div class="card"><div class="big">' + CAST(@gRun AS VARCHAR)
        + N'</div><div class="lbl">Tests &middot; '
        + N'<span class="g">' + CAST(@gPass AS VARCHAR) + N' pass ' + CAST(@pPass AS VARCHAR) + N'%</span>, '
        + N'<span class="r">' + CAST(@gFail AS VARCHAR) + N' fail ' + CAST(@pFail AS VARCHAR) + N'%</span>, '
        + CAST(@gErr AS VARCHAR) + N' err ' + CAST(@pErr AS VARCHAR) + N'%, '
        + CAST(@gSkip AS VARCHAR) + N' skip ' + CAST(@pSkip AS VARCHAR) + N'%</div></div>';
    /* v9.4.4: Autonomy headline card.  Shows what fraction of executed tests
       the framework still owns (the complement of user-modified preserved tests). */
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gAutonomy>=80 THEN 'g' WHEN @gAutonomy>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gAutonomy AS VARCHAR) + N'%</div><div class="lbl">Autonomy<br>'
        + CAST(@gRun - @gPres AS VARCHAR) + N' of ' + CAST(@gRun AS VARCHAR)
        + N' tests framework-owned<br><span style="color:#999">'
        + CAST(@gPres AS VARCHAR) + N' user-modified</span></div></div>';
    SET @H = @H + N'</div>';

    SET @H = @H + N'<table><tr>'
        + N'<th class="l">Schema</th><th class="l">Object</th>'
        + N'<th>Testable</th><th>Gen</th>'
        + N'<th>Tests</th><th>Pass</th><th>Fail</th><th>Err</th><th>Skip</th>'
        + N'<th>Lines</th><th>Covered</th><th>Line %</th><th>Branch %</th></tr>';

    DECLARE @rS SYSNAME,@rP SYSNAME,@rGen BIT,@rRun INT,@rPass INT,@rFail INT,
            @rErr INT,@rSkip INT,@rTot INT,@rCov INT,@rLP DECIMAL(5,1),@rBP DECIMAL(5,1);
    DECLARE @rTestability VARCHAR(20), @rReason NVARCHAR(400), @rTB INT;
    DECLARE @rPres INT;   -- v9.4.4: per-proc count of preserved (developer-modified) tests
    DECLARE rc CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName,ProcName,GenSucceeded,TestsRun,TestsPassed,TestsFailed,
               TestsErrored,TestsSkipped,TotalLines,CoveredLines,LinePct,BranchPct,TotalBranches,Testability,NotTestableReason,
               TestsPreserved
        FROM TestGen.CoverageResult WHERE BatchId=@BatchId
        ORDER BY SchemaName,ProcName;
    OPEN rc;
    FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,@rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rTestability = N'NOT_TESTABLE'
            SET @H = @H + N'<tr style="background:#f6f6f6;color:#999">'
                + N'<td class="l">' + @rS + N'</td>'
                + N'<td class="l">' + @rP
                + N'<details style="margin-top:2px"><summary style="font-size:11px;color:#888;cursor:pointer;font-weight:normal">why not testable?</summary>'
                + N'<div style="font-size:12px;font-weight:normal;color:#555;margin-top:4px;white-space:normal">'
                + ISNULL(@rReason, N'no fakeable dependencies; system-catalog usage')
                + N'</div></details>'
                + N'</td>'
                + N'<td><span class="r">N</span></td>'
                + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'N' END + N'</td>'
                + N'<td>' + CAST(ISNULL(@rRun ,0) AS VARCHAR)
                    + CASE WHEN ISNULL(@rPres,0) > 0
                           THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                           ELSE N'' END
                    + N'</td>'
                + N'<td>' + CAST(ISNULL(@rPass,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rFail,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rErr ,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rSkip,0) AS VARCHAR) + N'</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'</tr>';
        ELSE
        SET @H = @H + N'<tr><td class="l">' + @rS + N'</td><td class="l">' + @rP + N'</td>'
            + N'<td><span class="g">Y</span></td>'
            + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'<span class="r">N</span>' END + N'</td>'
            + N'<td>' + CAST(@rRun AS VARCHAR)
                + CASE WHEN ISNULL(@rPres,0) > 0
                       THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                       ELSE N'' END
                + N'</td>'
            + N'<td>' + CAST(@rPass AS VARCHAR) + N'</td>'
            + N'<td>' + CASE WHEN @rFail>0 THEN N'<span class="r">'+CAST(@rFail AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
            + N'<td>' + CASE WHEN @rErr >0 THEN N'<span class="r">'+CAST(@rErr  AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
            + N'<td>' + CAST(@rSkip AS VARCHAR) + N'</td>'
            + N'<td>' + CAST(@rTot AS VARCHAR) + N'</td>'
            + N'<td>' + CAST(@rCov AS VARCHAR) + N'</td>'
            + CASE WHEN ISNULL(@rTot,0) = 0
                   THEN N'<td style="color:#999">n/a</td>'
                   ELSE N'<td class="' + CASE WHEN @rLP>=80 THEN 'g' WHEN @rLP>=50 THEN 'a' ELSE 'r' END
                        + N'">' + CAST(@rLP AS VARCHAR) + N'%</td>' END
            + CASE WHEN ISNULL(@rTB,0) = 0
                   THEN N'<td style="color:#999">n/a</td>'
                   ELSE N'<td class="' + CASE WHEN @rBP>=80 THEN 'g' WHEN @rBP>=50 THEN 'a' ELSE 'r' END
                        + N'">' + CAST(@rBP AS VARCHAR) + N'%</td>' END
            + N'</tr>';
        FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,@rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    END;
    CLOSE rc; DEALLOCATE rc;

    SET @H = @H + N'<tr class="total"><td class="l" colspan="4">TOTAL &mdash; '
        + CAST(@gProcs AS VARCHAR) + N' objects ('
        + CAST(@gProcs - @gNotTestable AS VARCHAR) + N' testable, '
        + CAST(@gNotTestable AS VARCHAR) + N' not)</td>'
        + N'<td>' + CAST(@gRun AS VARCHAR)
            + CASE WHEN @gPres > 0
                   THEN N' <span style="color:#9a6700">(' + CAST(@gPres AS VARCHAR) + N' preserved)</span>'
                   ELSE N'' END
            + N'</td>'
        + N'<td>' + CAST(@gPass AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gFail AS VARCHAR) + N'</td><td>' + CAST(@gErr AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gSkip AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gTot AS VARCHAR) + N'</td><td>' + CAST(@gCov AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gLinePct AS VARCHAR) + N'%</td><td>' + CAST(@gBrPct AS VARCHAR) + N'%</td></tr>';
    SET @H = @H + N'</table></body></html>';

    SELECT @H AS CoverageReportHTML;

    PRINT '/* =============== DATABASE COVERAGE REPORT HTML =============== */';
    DECLARE @Chunk INT = 1, @ChunkSize INT = 4000;
    WHILE @Chunk <= LEN(@H)
    BEGIN
        PRINT SUBSTRING(@H, @Chunk, @ChunkSize);
        SET @Chunk = @Chunk + @ChunkSize;
    END;
    PRINT '/* =================== END HTML =================== */';
END;
GO
PRINT 'TestGen.GenerateAndCoverDatabase (v11 function-aware) installed.';
GO

PRINT '';
PRINT '== v11 function support (30_Function_Support_v1.sql) installed ==';
PRINT '   Generate:  EXEC TestGen.GenerateTestsForObject  @SchemaName=N''dbo'', @ObjectName=N''YourFunction'';';
PRINT '   Coverage:  EXEC TestGen.RunCoverageForFunction  @SchemaName=N''dbo'', @FunctionName=N''YourFunction'';';
GO
