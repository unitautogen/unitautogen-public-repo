/*============================================================================
 * Patch_v11_BranchSeeding.sql  —  Step 2: predicate-inversion branch seeding
 *----------------------------------------------------------------------------
 * Run AFTER Install_UnitAutogen.sql (+ earlier v11 patches). Idempotent.
 *
 * GOAL (design/DESIGN_v11_BranchSeeding.md, Layer B): reach value-gated branches of a
 * function ON PURPOSE instead of by luck.  The happy+NULL driver only covers the
 * branches those two inputs happen to land on; a branch like `IF @status = 5`
 * or `IF @n < 0` is missed.  This derives a parameter value that SATISFIES each
 * branch predicate - from the predicate's own literal - and drives the shadow
 * with it.  The Step-1 loop cap makes every such call hang-proof, so seeding is
 * free to be aggressive.
 *
 * SAFE BY CONSTRUCTION:
 *   - A wrong/over-eager seed is harmless: each seed EXEC is wrapped in
 *     TRY/CATCH and simply fails to enter its branch; nothing breaks.
 *   - The whole seed-building block in RunCoverageForFunction is itself wrapped
 *     in TRY/CATCH, so if the extractor ever errors the run silently falls back
 *     to the prior happy+NULL behaviour - Step 2 can never regress coverage.
 *   - Values come only from the code's own literals (and numeric +/-1 of them),
 *     so emitted args are always well-formed SQL.
 *
 * NEVER LIE: a predicate the extractor can't invert (function-wrapped column,
 * non-literal RHS, NOT IN, accumulated value, clock/env) yields no seed; that
 * branch stays uncovered and is reported as honest residue - never faked.
 *
 * Objects: (1) TestGen.SeedFromLeaf - inversion rules for one leaf;
 *          (2) TestGen.ExtractBranchSeeds - TVF pulling (param, satisfying value)
 *              leaves from a function body; (3) RunCoverageForFunction re-created
 *              to add one seed EXEC per leaf (target param satisfied, others happy).
 *============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * (1) TestGen.SeedFromLeaf - given a comparison operator and the literal the
 *     code compares against, return a value that makes the predicate TRUE, or
 *     NULL when it cannot be inverted (caller then leaves the branch as residue).
 *     '=','<=','>=','IN','BETWEEN','LIKE' are satisfied by the literal verbatim
 *     (caller passes the right sub-literal); '<','>','<>' need a numeric literal
 *     (+/-1); 'ISNULL' -> NULL; 'ISNOTNULL' -> NULL here (happy already covers it).
 *==========================================================================*/
CREATE OR ALTER FUNCTION TestGen.SeedFromLeaf(@op VARCHAR(12), @lit NVARCHAR(500))
RETURNS NVARCHAR(500)
AS
BEGIN
    IF @op IN ('=','<=','>=','IN','BETWEEN','LIKE') RETURN @lit;   -- literal satisfies as-is
    IF @op = 'ISNULL' RETURN N'NULL';
    -- '<','>','<>' need numeric arithmetic on the literal
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

/*===========================================================================
 * (2) TestGen.ExtractBranchSeeds - scan a function body for parameter-predicate
 *     leaves of the form  @param <op> <literal>  (and IS [NOT] NULL / IN /
 *     BETWEEN / LIKE) and return (ParamName, SeedLiteral) that reaches each.
 *     Comment/string/bracket aware.  Conservative: only clear leaves yield a
 *     seed; anything ambiguous is skipped (residue).  All walker vars declared
 *     once at the top (DECLARE @x=expr in a loop = parse-time eval, CLAUDE.md).
 *
 *     @ParamCsv: comma-separated parameter names incl. '@' (e.g. '@n,@status').
 *==========================================================================*/
CREATE OR ALTER FUNCTION TestGen.ExtractBranchSeeds(@Body NVARCHAR(MAX), @ParamCsv NVARCHAR(MAX))
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
    DECLARE @op VARCHAR(12),@operand NVARCHAR(500),@seed NVARCHAR(500),@w NVARCHAR(20);
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

        -- track the previous alphabetic word (to skip `SET @p = ...` assignments)
        IF @ch LIKE N'[A-Za-z]'
        BEGIN
            SET @curWord = @curWord + @ch; SET @i+=1; CONTINUE;
        END
        ELSE IF @curWord <> N''
        BEGIN
            SET @prevWord = UPPER(@curWord); SET @curWord = N'';
            -- fall through to re-examine @ch (do NOT advance @i here)
        END;

        IF @ch = N'@'
        BEGIN
            SET @pvc = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pvc)=1     -- left boundary
            BEGIN
                -- read the @-identifier
                SET @tok = N'@'; SET @k = @i+1;
                WHILE @k<=@len
                BEGIN
                    SET @kc = SUBSTRING(@Body,@k,1);
                    IF @kc LIKE N'[A-Za-z0-9_@#]' BEGIN SET @tok+=@kc; SET @k+=1; END ELSE BREAK;
                END;
                IF CHARINDEX(N'|'+UPPER(@tok)+N'|', @pset) > 0 AND @prevWord <> N'SET'
                BEGIN
                    -- parse operator + operand starting at @k
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
                        -- word operator: IS / IN / BETWEEN / LIKE / NOT
                        SET @w=N'';
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                        SET @w=UPPER(@w);
                        IF @w=N'IS'
                        BEGIN
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                            DECLARE @w2 NVARCHAR(10)=N'';
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w2+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            SET @w2=UPPER(@w2);
                            IF @w2=N'NULL' SET @op='ISNULL';
                            -- IS NOT NULL -> no seed (happy already non-null)
                        END
                        ELSE IF @w=N'IN' SET @op='IN';
                        ELSE IF @w=N'BETWEEN' SET @op='BETWEEN';
                        ELSE IF @w=N'LIKE' SET @op='LIKE';
                        -- NOT IN / NOT LIKE / etc. -> leave @op NULL (residue)
                    END;

                    -- read operand literal for ops that need one
                    IF @op IN ('=','<','>','<=','>=','<>','LIKE','IN','BETWEEN')
                    BEGIN
                        IF @op='IN'
                        BEGIN
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                            IF SUBSTRING(@Body,@k,1)=N'(' SET @k+=1;   -- step into the list
                        END;
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                        SET @kc = CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                        IF @kc=N''''
                        BEGIN
                            -- quoted string literal (keep quotes; handle '' escape)
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
                        -- else: operand is an identifier/@var/func -> not a literal -> @operand stays NULL

                        IF @op='LIKE' AND @operand IS NOT NULL
                        BEGIN
                            -- de-wildcard: drop % and _ but keep the quotes
                            SET @operand = REPLACE(REPLACE(@operand, N'%', N''), N'_', N'');
                            IF @operand = N'''''' SET @operand = NULL;  -- pure wildcard -> useless
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
                SET @i = @k; SET @prevWord=N''; CONTINUE;   -- a @var that isn't a target param
            END;
        END;

        SET @i += 1;
    END;
    RETURN;
END;
GO
PRINT 'TestGen.ExtractBranchSeeds installed.';
GO

/*===========================================================================
 * (3) RunCoverageForFunction - add one seed EXEC per extracted leaf (target
 *     param satisfied, all others happy), spliced into the driver after the
 *     happy+NULL calls.  Everything else unchanged.  The seed block is wrapped
 *     in TRY/CATCH so any extractor failure falls back to happy+NULL.
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

    -- per-parameter happy literal (also drives @namedHappy below)
    DECLARE @ph TABLE (ord INT, name SYSNAME, happyLit NVARCHAR(MAX));
    INSERT @ph (ord,name,happyLit)
    SELECT parameter_id, name,
           TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0;

    DECLARE @namedHappy NVARCHAR(MAX)=N'', @namedNull NVARCHAR(MAX)=N'';
    SELECT @namedHappy=@namedHappy+name+N'='+happyLit+N', ',
           @namedNull =@namedNull +name+N'=NULL, '
    FROM @ph ORDER BY ord;

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

    -- Step 2: predicate-inversion seed calls (one per branch leaf; target param
    -- satisfied, others happy).  Wrapped so any extractor failure is non-fatal.
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
        SET @execSeeds = N'';   -- non-fatal: fall back to happy+NULL only
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
PRINT 'TestGen.RunCoverageForFunction installed (Step 2: predicate-inversion seeding).';
GO
PRINT '== v11 Step 2 applied: branch coverage now reaches value-gated branches on purpose. ==';
GO
