/*============================================================================
 * Patch_v11_BatchB.sql  —  v11 function-support "Batch B" polish
 *----------------------------------------------------------------------------
 * Run AFTER Install_UnitAutogen.sql (Batch A) against your target database.
 * Idempotent: two CREATE OR ALTER procedures.
 *
 *   Item 4  GenerateTestsForTableFunction - pure-TVF row blessing.
 *           Snapshot the current output into TestGenLog.FnBless_<schema>_<fn>
 *           and AssertEqualsTable against it; table-dependent TVFs keep the
 *           honest SkipTest.
 *
 *   Item 3  (multi-variant driver seeding) was REVERTED: feeding boundary
 *           values to the coverage driver explodes parameter-bounded loops
 *           (e.g. WHILE @i <= @n with a high-boundary @n runs for ages).
 *           RunCoverageForFunction below is the safe happy+NULL driver; deeper
 *           per-branch coverage needs predicate-aware value solving (which
 *           avoids exactly this) and remains a follow-up.  This block re-asserts
 *           the safe version so a database that ran the earlier patch is fixed.
 *
 * Will be folded into modules/30_Function_Support_v1.sql + the installer once
 * the build sandbox is available.
 *============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * RunCoverageForFunction — safe happy+NULL driver (item 3 reverted)
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

    -- argument lists (happy variant + NULL only - safe for loop-bounded params)
    DECLARE @namedHappy NVARCHAR(MAX)=N'', @namedNull NVARCHAR(MAX)=N'';
    SELECT @namedHappy=@namedHappy+name+N'='
             +TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)+N', ',
           @namedNull=@namedNull+name+N'=NULL, '
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0 ORDER BY parameter_id;

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

    -- 3. measure coverage on the shadow, capturing test outcomes so we can
    --    persist a CoverageResult row keyed by the FUNCTION (the shadow is an
    --    internal artifact).  @OutputMode='NONE' silences the per-object report.
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

    -- 4. compute coverage from the shadow's line catalogue + hits and persist a
    --    CoverageResult row under the FUNCTION name.
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

    -- Report the FUNCTION's assertion suite (test_<fn>) as its Tests counts.
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

    -- 5. cleanup
    DECLARE @covF  NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_cov');
    DECLARE @origF NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_orig');
    BEGIN TRY EXEC tSQLt.DropClass @driverClass; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'SN') IS NOT NULL EXEC('DROP SYNONYM '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@covF,'P')       IS NOT NULL EXEC('DROP PROCEDURE '+@covF);      END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'P') IS NOT NULL EXEC('DROP PROCEDURE '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@origF,'P')      IS NOT NULL EXEC('DROP PROCEDURE '+@origF);     END TRY BEGIN CATCH END CATCH;
END;
GO
PRINT 'Patched: TestGen.RunCoverageForFunction (safe happy+NULL driver; item 3 reverted).';
GO

/*===========================================================================
 * Item 4 — GenerateTestsForTableFunction with pure-TVF row blessing
 *==========================================================================*/
CREATE OR ALTER PROCEDURE TestGen.GenerateTestsForTableFunction
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
PRINT 'Patched: TestGen.GenerateTestsForTableFunction (item 4 - pure-TVF row blessing).';
GO
PRINT '== v11 Batch B applied (item 4 row blessing; item 3 reverted to safe driver). ==';
GO
