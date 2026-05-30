/*============================================================================
 * Patch_v11_OneLineNorm.sql  —  shadow body normalizer (one-stmt-per-line)
 *----------------------------------------------------------------------------
 * Run AFTER Install_UnitAutogen.sql (+ earlier v11 patches incl. LoopGuard).
 * Idempotent (CREATE OR ALTER).
 *
 * PROBLEM: TestGen.InstrumentProcedure is a strictly LINE-ORIENTED walker - it
 * classifies one physical line at a time.  A function whose loop/branch body is
 * written on ONE line, e.g.
 *       WHILE @i < 100000000 BEGIN SET @s += @i; SET @i += 1; END
 * yields a shadow line `BEGIN SET @s += @i; SET @i += 1; END` carrying a BEGIN,
 * two statements and an END at once; the instrumenter cannot decompose it and
 * emits a non-compiling _cov ("Incorrect syntax near ';'").  Coverage for that
 * function is then a false 0% / deferral.
 *
 * FIX (in the shadow transform, NOT the shared instrumenter): before
 * instrumenting, reflow the shadow body so each BEGIN / END / ELSE sits on its
 * own line and ';'-separated statements are split onto separate lines.  The
 * instrumenter then sees the clean one-statement-per-line shape it already
 * handles.  TestGen.ShadowLineMap is dormant (nothing reads it), so reflowing
 * the shadow is safe.
 *
 * SAFE BY CONSTRUCTION: the normalizer ONLY inserts newlines, and only where a
 * keyword shares a line with other content (it checks "is there code before me
 * on this line" / "is there code after me on this line").  On an already-multi-
 * line body - BEGIN alone, END alone, one statement per line - every rule is a
 * no-op, so existing working shadows pass through byte-unchanged (no
 * regression).  Comment / string / bracket / paren aware.  BEGIN TRY / BEGIN
 * CATCH / END TRY / END CATCH are kept intact as units.
 *
 * This patch: (1) adds TestGen.NormalizeShadowBody; (2) re-creates
 * BuildShadowProcForFunction to call NormalizeShadowBody, then InjectLoopGuards,
 * before compiling the shadow.
 *============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * (1) TestGen.NormalizeShadowBody — reflow to one-statement-per-line.
 *     Rules (only fire at the top level, outside string/comment/bracket):
 *       - ';'   : if followed by code on the same line -> newline after it.
 *       - BEGIN  (or BEGIN TRY / BEGIN CATCH): newline before if the line
 *                already has code; newline after if code follows on the line.
 *       - END    (or END TRY / END CATCH): newline before if the line has code.
 *       - ELSE   : newline before if the line has code.
 *     All walker vars declared once at the top (DECLARE @x=expr in a loop
 *     evaluates the initializer once at parse - CLAUDE.md).
 *==========================================================================*/
CREATE OR ALTER FUNCTION TestGen.NormalizeShadowBody(@Body NVARCHAR(MAX))
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

        -- inside line comment / block comment / string / bracket: copy verbatim
        IF @inLine=1 BEGIN SET @out+=@ch; IF @ch=CHAR(10) BEGIN SET @inLine=0; SET @dirty=0; END; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;

        -- enter comment / string / bracket
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlk=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @out+=@ch; SET @inStr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'['  BEGIN SET @out+=@ch; SET @inBr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'('  BEGIN SET @paren+=1; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N')'  BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;

        -- newlines reset the line-dirty flag
        IF @ch=CHAR(13) BEGIN SET @out+=@ch; SET @i+=1; CONTINUE; END;
        IF @ch=CHAR(10) BEGIN SET @out+=@ch; SET @dirty=0; SET @i+=1; CONTINUE; END;

        -- top-level ';' : split if code follows on the same line
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

        -- keyword detection only at a left word boundary
        SET @pv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1
        BEGIN
            -- BEGIN [TRY|CATCH]
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
                -- newline after if code follows on this line
                SET @j=@i; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                SET @pk=CASE WHEN @j<=@len THEN SUBSTRING(@Body,@j,1) ELSE N'' END;
                IF @pk<>N'' AND @pk<>CHAR(13) AND @pk<>CHAR(10) BEGIN SET @out+=@CR; SET @i=@j; END;
                SET @dirty=0;
                CONTINUE;
            END;
            -- END [TRY|CATCH]
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
            -- ELSE
            SET @aft=CASE WHEN @i+4<=@len THEN SUBSTRING(@Body,@i+4,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,4))=N'ELSE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=N'ELSE'; SET @i+=4; SET @dirty=1;
                CONTINUE;
            END;
        END;

        -- default character
        SET @out+=@ch;
        IF @ch<>N' ' AND @ch<>CHAR(9) SET @dirty=1;
        SET @i+=1;
    END;

    RETURN @out;
END;
GO
PRINT 'TestGen.NormalizeShadowBody installed.';
GO

/*===========================================================================
 * (2) BuildShadowProcForFunction — normalize the body, then cap its loops,
 *     before compiling the shadow.  (Identical to the v11 LoopGuard version
 *     except the added SET @procBody = TestGen.NormalizeShadowBody(@procBody);
 *     line ahead of the InjectLoopGuards call.)
 *==========================================================================*/
CREATE OR ALTER PROCEDURE TestGen.BuildShadowProcForFunction
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

    DECLARE @params NVARCHAR(MAX) = N'';
    SELECT @params = @params
         + CASE WHEN @params = N'' THEN N'' ELSE N', ' END
         + p.name + N' '
         + dbo.TestGen_RebuildTypeName(TYPE_NAME(p.user_type_id), p.max_length, p.precision, p.scale)
    FROM sys.parameters p
    WHERE p.object_id = @ObjId AND p.parameter_id > 0
    ORDER BY p.parameter_id;

    DECLARE @AsPos INT = TestGen.FindTopLevelAs(@def);
    IF @AsPos = 0 BEGIN SET @Status = N'UNSUPPORTED:could not locate body AS keyword'; RETURN; END;
    DECLARE @body NVARCHAR(MAX) = LTRIM(SUBSTRING(@def, @AsPos + 2, LEN(@def)));

    DECLARE @shadowFull NVARCHAR(400) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ShadowName);
    DECLARE @header NVARCHAR(MAX);
    DECLARE @procBody NVARCHAR(MAX);

    IF @kind = 'FN'
    BEGIN
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
        DECLARE @ret2 NVARCHAR(MAX);
        DECLARE @retKw INT = TestGen.FindKeyword(@def, N'RETURNS', 1);
        IF @retKw = 0 BEGIN SET @Status = N'UNSUPPORTED:RETURNS clause not found'; RETURN; END;
        SET @ret2 = SUBSTRING(@def, @retKw + 7, @AsPos - (@retKw + 7));
        SET @ret2 = LTRIM(RTRIM(@ret2));
        DECLARE @atPos INT = CHARINDEX(N'@', @ret2);
        DECLARE @tblKw INT = TestGen.FindKeyword(@ret2, N'TABLE', 1);
        IF @atPos = 0 OR @tblKw = 0 BEGIN SET @Status = N'UNSUPPORTED:multi-statement TABLE() spec not parseable'; RETURN; END;
        DECLARE @tvName NVARCHAR(200) = LTRIM(RTRIM(SUBSTRING(@ret2, @atPos, @tblKw - @atPos)));
        DECLARE @colSpec NVARCHAR(MAX) = LTRIM(SUBSTRING(@ret2, @tblKw + 5, LEN(@ret2)));

        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' ('
                    + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF
                    + N'DECLARE ' + @tvName + N' TABLE ' + @colSpec + N';' + @CRLF;
        SET @procBody = @body + @CRLF + N'END;';
    END
    ELSE  -- IF
    BEGIN
        DECLARE @rk INT = TestGen.FindKeyword(@body, N'RETURN', 1);
        IF @rk = 0 BEGIN SET @Status = N'UNSUPPORTED:inline RETURN not found'; RETURN; END;
        DECLARE @sel NVARCHAR(MAX) = LTRIM(SUBSTRING(@body, @rk + 6, LEN(@body)));
        SET @sel = TestGen.StripOuterParens(@sel);
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' (' + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF;
        SET @procBody = @sel + @CRLF + N'END;';
    END;

    -- Gap fix: reflow one-line compound blocks to one-statement-per-line so the
    -- line-oriented instrumenter can decompose them (no-op on multi-line code).
    SET @procBody = TestGen.NormalizeShadowBody(@procBody);
    -- v11 Step1: cap every WHILE..BEGIN loop so the coverage probe can't run away.
    SET @procBody = TestGen.InjectLoopGuards(@procBody);

    IF OBJECT_ID(@shadowFull, 'P') IS NOT NULL
        EXEC('DROP PROCEDURE ' + @shadowFull);

    DECLARE @full NVARCHAR(MAX) = @header + @procBody;
    BEGIN TRY
        EXEC sys.sp_executesql @full;
    END TRY
    BEGIN CATCH
        SET @Status = N'UNSUPPORTED:shadow compile failed: ' + ERROR_MESSAGE();
        PRINT '  [shadow-compile-failed] ' + QUOTENAME(@SchemaName) + N'.' + @FunctionName;
        PRINT '  ---- attempted shadow DDL ----';
        PRINT @full;
        PRINT '  ------------------------------';
        RETURN;
    END CATCH;

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
PRINT 'Patched: TestGen.BuildShadowProcForFunction (normalize one-line blocks, then cap loops).';
GO
PRINT '== Gap fix applied: one-line compound loop/branch bodies now instrument. ==';
GO
