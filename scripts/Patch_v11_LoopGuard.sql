/*============================================================================
 * Patch_v11_LoopGuard.sql  —  v11 Step 1 (v2): self-capping shadow loops
 *----------------------------------------------------------------------------
 * Run AFTER Install_UnitAutogen.sql (+ earlier v11 patches).  Idempotent.
 *
 * GOAL: a function coverage run can never hang on a runaway loop, cheaply.
 *
 * MECHANISM (replaces the earlier statement-budget version, which worked but
 * was slow - SESSION_CONTEXT per hit - and let the loop run far enough to bloat
 * the XEL file):  BuildShadowProcForFunction now injects a LOCAL iteration
 * counter into every WHILE..BEGIN loop of the shadow:
 *       WHILE (<cond>)
 *       BEGIN
 *           SET @__lcN = @__lcN + 1;      -- injected
 *           IF  @__lcN > 1000 BREAK;      -- injected
 *           <original body>
 *       END
 * A local SET/IF is ~nanoseconds, the loop stops after 1000 iterations (one
 * iteration already covers the body), and the XEL stays tiny.  Injection is
 * conservative: only clear statement-scope WHILE..BEGIN blocks are touched,
 * on their own lines (instrument-friendly); anything else is left byte-identical,
 * and BuildShadowProcForFunction's TRY/CATCH still turns any bad transform into
 * an honest "coverage deferred", never corruption.
 *
 * This patch: (1) reverts RecordCoverageHit to the plain no-op, (2) reverts
 * RunCoverageForFunction (drops the session-budget arm/disarm), (3) adds
 * TestGen.InjectLoopGuards, (4) wires it into BuildShadowProcForFunction.
 *============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * (1) RecordCoverageHit — revert to the plain no-op stub.
 *==========================================================================*/
CREATE OR ALTER PROCEDURE TestGen.RecordCoverageHit
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @LineNum    INT
AS
BEGIN
    SET NOCOUNT ON;
    -- No-op: coverage is captured via XEvent on the EXEC ...RecordCoverageHit
    -- statement text in the _cov copy.
END;
GO
PRINT 'Reverted: TestGen.RecordCoverageHit (plain no-op).';
GO

/*===========================================================================
 * (3) TestGen.InjectLoopGuards — cap every WHILE..BEGIN loop with a local
 *     iteration counter.  Comment/string/bracket/paren aware.  Conservative:
 *     only injects when the loop body is a clear depth-0 BEGIN block; stops a
 *     scan at a depth-0 ';' (single-statement body -> left uncapped, safe).
 *     Returns the body unchanged if no loop was capped.
 *==========================================================================*/
CREATE OR ALTER FUNCTION TestGen.InjectLoopGuards(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @CR NCHAR(2) = CHAR(13)+CHAR(10);
    DECLARE @out NVARCHAR(MAX)=N'', @decls NVARCHAR(MAX)=N'';
    DECLARE @len INT=LEN(@Body), @i INT=1, @nLoop INT=0;
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1);
    -- condition-scan working vars (declared once; SET per use - never DECLARE=expr in a loop)
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

/*===========================================================================
 * (4) BuildShadowProcForFunction — call InjectLoopGuards on @procBody before
 *     compiling the shadow.  (Identical to the current version except the one
 *     SET @procBody = TestGen.InjectLoopGuards(@procBody); line.)
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

    -- v11 Step1: cap every WHILE..BEGIN loop in the shadow so the coverage probe
    -- can never run away (local counter, ~nanoseconds/iteration, tiny XEL).
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
PRINT 'Patched: TestGen.BuildShadowProcForFunction (injects per-loop caps).';
GO

/*===========================================================================
 * (2) RunCoverageForFunction — revert to the safe happy+NULL driver WITHOUT
 *     the session-context budget (the per-loop cap replaces it).
 *==========================================================================*/
CREATE OR ALTER PROCEDURE TestGen.RunCoverageForFunction
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

    DECLARE @namedHappy NVARCHAR(MAX)=N'', @namedNull NVARCHAR(MAX)=N'';
    SELECT @namedHappy=@namedHappy+name+N'='
             +TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)+N', ',
           @namedNull=@namedNull+name+N'=NULL, '
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0 ORDER BY parameter_id;

    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes=@fakes+N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                +SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;'+@CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    DECLARE @ret NVARCHAR(100) = CASE WHEN @kind='FN' THEN N'@__ret=@o OUTPUT' ELSE N'' END;
    DECLARE @retDecl NVARCHAR(200)=N'';
    IF @kind='FN'
    BEGIN
        DECLARE @rt2 SYSNAME,@rml2 SMALLINT,@rp2 TINYINT,@rs2 TINYINT;
        SELECT @rt2=TYPE_NAME(user_type_id),@rml2=max_length,@rp2=precision,@rs2=scale
        FROM sys.parameters WHERE object_id=@objid AND parameter_id=0;
        SET @retDecl=N'    DECLARE @o '+dbo.TestGen_RebuildTypeName(@rt2,@rml2,@rp2,@rs2)+N';'+@CRLF;
    END;

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

    DECLARE @drv NVARCHAR(MAX)=
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@driverClass+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'CREATE PROCEDURE '+QUOTENAME(@driverClass)+N'.[test drive '+@shadow+N' sample inputs]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+@retDecl+
        N'    BEGIN TRY'+@CRLF+@execHappy+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        N'    BEGIN TRY'+@CRLF+@execNull+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        N'    EXEC tSQLt.AssertEquals 1, 1; -- driver: execution drives coverage'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF;
    EXEC TestGen.ExecuteBatchedScript @drv;

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

    DECLARE @covF  NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_cov');
    DECLARE @origF NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_orig');
    BEGIN TRY EXEC tSQLt.DropClass @driverClass; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'SN') IS NOT NULL EXEC('DROP SYNONYM '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@covF,'P')       IS NOT NULL EXEC('DROP PROCEDURE '+@covF);      END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'P') IS NOT NULL EXEC('DROP PROCEDURE '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@origF,'P')      IS NOT NULL EXEC('DROP PROCEDURE '+@origF);     END TRY BEGIN CATCH END CATCH;
END;
GO
PRINT 'Reverted: TestGen.RunCoverageForFunction (safe happy+NULL driver; budget removed).';
GO
PRINT '== v11 Step 1 (v2) applied: per-loop cap in the shadow (fast, no runaway, small XEL). ==';
GO
