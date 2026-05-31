/*============================================================================
 * Patch_v11_AncestorChaining.sql  —  Step 2.1: ancestor-chaining for seeding
 *----------------------------------------------------------------------------
 * Run AFTER Patch_v11_BranchSeeding.sql (or the folded Step 2). Idempotent.
 *
 * GOAL (DESIGN_v11_AncestorChaining.md): reach a branch nested inside ANOTHER
 * parameter's predicate.  Step 2 satisfied a branch's own leaf but left every
 * other param happy, so
 *       IF @kind = 'A' BEGIN  IF @amount > 1000 ...  END
 * never reached the inner arm when happy @kind <> 'A'.  Now the extractor tracks
 * BEGIN/END nesting and a stack of enclosing gates, and each branch's seed
 * carries its own leaves PLUS every ancestor gate's satisfying assignment.
 *
 * ExtractBranchSeeds is rewritten to be predicate-aware and now returns
 * (BranchId, ParamName, SeedLiteral) - many rows per branch.  RunCoverageForFunction
 * groups by BranchId and emits one shadow EXEC per branch (every assigned param
 * overridden, others happy).  A top-level branch with no ancestors collapses to
 * the exact Step-2 single-override call, so verified fixtures are unchanged.
 *
 * Safety is unchanged (three TRY/CATCH layers + Step-1 loop cap): a wrong seed
 * just fails to enter its branch, and any extractor error falls back to
 * happy+NULL.  ELSE-negation ancestors and non-literal predicates remain honest
 * residue (see the design doc).  SeedFromLeaf is unchanged and not re-created.
 *============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION TestGen.ExtractBranchSeeds(@Body NVARCHAR(MAX), @ParamCsv NVARCHAR(MAX))
RETURNS @seeds TABLE (BranchId INT, ParamName SYSNAME, SeedLiteral NVARCHAR(500))
AS
BEGIN
    DECLARE @pset NVARCHAR(MAX) = N'|' + UPPER(REPLACE(REPLACE(REPLACE(ISNULL(@ParamCsv,N''),N' ',N''),CHAR(13),N''),CHAR(10),N'')) + N'|';
    SET @pset = REPLACE(@pset, N',', N'|');
    IF @pset = N'||' RETURN;

    DECLARE @anc  TABLE (AtDepth INT, ParamName SYSNAME, SeedLiteral NVARCHAR(500));  -- enclosing IF/WHILE gates
    DECLARE @pend TABLE (ParamName SYSNAME, SeedLiteral NVARCHAR(500));               -- gate awaiting its BEGIN
    DECLARE @leaf TABLE (ParamName SYSNAME, SeedLiteral NVARCHAR(500));               -- leaves of the current predicate

    DECLARE @len INT = LEN(@Body), @i INT = 1, @depth INT = 0, @branch INT = 0;
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pvc NCHAR(1),@aft NCHAR(1);
    DECLARE @hasPending BIT=0, @bodyIsBegin BIT, @fw VARCHAR(6);
    DECLARE @pp INT,@psA BIT,@pcl BIT,@pbk BIT,@stop BIT;
    DECLARE @tok NVARCHAR(200),@k INT,@kc NCHAR(1),@op VARCHAR(12),@operand NVARCHAR(500),@seed NVARCHAR(500),@w NVARCHAR(20),@w2 NVARCHAR(10);

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Body,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;

        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlk=1; CONTINUE; END;
        IF @ch=N''''  BEGIN SET @i+=1; SET @inStr=1; CONTINUE; END;
        IF @ch=N'['   BEGIN SET @i+=1; SET @inBr=1; CONTINUE; END;

        SET @pvc = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pvc)=1
        BEGIN
            -- BEGIN (incl. BEGIN TRY/CATCH - all just blocks)
            IF UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN'
               AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+5<=@len THEN SUBSTRING(@Body,@i+5,1) ELSE N' ' END)=1
            BEGIN
                SET @depth += 1;
                IF @hasPending=1
                BEGIN
                    INSERT @anc (AtDepth,ParamName,SeedLiteral) SELECT @depth,ParamName,SeedLiteral FROM @pend;
                    DELETE FROM @pend; SET @hasPending=0;
                END;
                SET @i += 5; CONTINUE;
            END;
            -- END (incl. END TRY/CATCH)
            IF UPPER(SUBSTRING(@Body,@i,3))=N'END'
               AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+3<=@len THEN SUBSTRING(@Body,@i+3,1) ELSE N' ' END)=1
            BEGIN
                DELETE FROM @anc WHERE AtDepth=@depth;
                IF @depth>0 SET @depth-=1;
                SET @hasPending=0;
                SET @i += 3; CONTINUE;
            END;
            -- IF / WHILE  ->  predicate capture
            SET @fw = NULL;
            IF UPPER(SUBSTRING(@Body,@i,2))=N'IF'
               AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+2<=@len THEN SUBSTRING(@Body,@i+2,1) ELSE N' ' END)=1
                SET @fw='IF';
            ELSE IF UPPER(SUBSTRING(@Body,@i,5))=N'WHILE'
               AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+5<=@len THEN SUBSTRING(@Body,@i+5,1) ELSE N' ' END)=1
                SET @fw='WHILE';

            IF @fw IS NOT NULL
            BEGIN
                SET @i += CASE WHEN @fw='IF' THEN 2 ELSE 5 END;
                DELETE FROM @leaf;
                SET @pp=0; SET @psA=0; SET @pcl=0; SET @pbk=0; SET @stop=0; SET @bodyIsBegin=0;
                WHILE @i<=@len AND @stop=0
                BEGIN
                    SET @ch=SUBSTRING(@Body,@i,1);
                    SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
                    IF @pcl=1 BEGIN IF @ch=CHAR(10) SET @pcl=0; SET @i+=1; CONTINUE; END;
                    IF @psA=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @psA=0; SET @i+=1; CONTINUE; END;
                    IF @pbk=1 BEGIN IF @ch=N']' SET @pbk=0; SET @i+=1; CONTINUE; END;
                    IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @pcl=1; CONTINUE; END;
                    IF @ch=N'''' BEGIN SET @i+=1; SET @psA=1; CONTINUE; END;
                    IF @ch=N'[' BEGIN SET @i+=1; SET @pbk=1; CONTINUE; END;
                    IF @ch=N'(' BEGIN SET @pp+=1; SET @i+=1; CONTINUE; END;
                    IF @ch=N')' BEGIN SET @pp=CASE WHEN @pp>0 THEN @pp-1 ELSE 0 END; SET @i+=1; CONTINUE; END;

                    IF @pp=0
                    BEGIN
                        SET @pvc=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
                        IF UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@pvc)=1
                           AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+5<=@len THEN SUBSTRING(@Body,@i+5,1) ELSE N' ' END)=1
                        BEGIN SET @bodyIsBegin=1; SET @stop=1; CONTINUE; END;
                        IF @ch=N';' BEGIN SET @stop=1; CONTINUE; END;
                        IF @ch=N'@' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@pvc)=1
                        BEGIN
                            SET @tok=N'@'; SET @k=@i+1;
                            WHILE @k<=@len BEGIN SET @kc=SUBSTRING(@Body,@k,1); IF @kc LIKE N'[A-Za-z0-9_@#]' BEGIN SET @tok+=@kc; SET @k+=1; END ELSE BREAK; END;
                            IF CHARINDEX(N'|'+UPPER(@tok)+N'|',@pset)>0
                            BEGIN
                                SET @op=NULL; SET @operand=NULL;
                                WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                                SET @kc=CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                                IF SUBSTRING(@Body,@k,2) IN (N'>=',N'<=',N'<>',N'!=')
                                BEGIN SET @op=CASE WHEN SUBSTRING(@Body,@k,2)=N'!=' THEN '<>' ELSE SUBSTRING(@Body,@k,2) END COLLATE DATABASE_DEFAULT; SET @k+=2; END
                                ELSE IF @kc=N'=' BEGIN SET @op='='; SET @k+=1; END
                                ELSE IF @kc=N'<' BEGIN SET @op='<'; SET @k+=1; END
                                ELSE IF @kc=N'>' BEGIN SET @op='>'; SET @k+=1; END
                                ELSE
                                BEGIN
                                    SET @w=N''; WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w+=SUBSTRING(@Body,@k,1); SET @k+=1; END; SET @w=UPPER(@w);
                                    IF @w=N'IS' BEGIN WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1; SET @w2=N''; WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w2+=SUBSTRING(@Body,@k,1); SET @k+=1; END; SET @w2=UPPER(@w2); IF @w2=N'NULL' SET @op='ISNULL'; END
                                    ELSE IF @w=N'IN' SET @op='IN';
                                    ELSE IF @w=N'BETWEEN' SET @op='BETWEEN';
                                    ELSE IF @w=N'LIKE' SET @op='LIKE';
                                END;
                                IF @op IN ('=','<','>','<=','>=','<>','LIKE','IN','BETWEEN')
                                BEGIN
                                    IF @op='IN' BEGIN WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1; IF SUBSTRING(@Body,@k,1)=N'(' SET @k+=1; END;
                                    WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                                    SET @kc=CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                                    IF @kc=N'''' BEGIN SET @operand=N''''; SET @k+=1; WHILE @k<=@len BEGIN SET @kc=SUBSTRING(@Body,@k,1); IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @operand+=N''''''; SET @k+=2; CONTINUE; END; SET @operand+=@kc; SET @k+=1; IF @kc=N'''' BREAK; END; END
                                    ELSE IF @kc LIKE N'[0-9]' OR (@kc IN (N'-',N'+',N'.') AND SUBSTRING(@Body,@k+1,1) LIKE N'[0-9]') BEGIN SET @operand=N''; IF @kc IN (N'-',N'+') BEGIN SET @operand+=@kc; SET @k+=1; END; WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[0-9.]' BEGIN SET @operand+=SUBSTRING(@Body,@k,1); SET @k+=1; END; END;
                                    IF @op='LIKE' AND @operand IS NOT NULL BEGIN SET @operand=REPLACE(REPLACE(@operand,N'%',N''),N'_',N''); IF @operand=N'''''' SET @operand=NULL; END;
                                END;
                                IF @op='ISNULL' INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,N'NULL');
                                ELSE IF @op IS NOT NULL AND @operand IS NOT NULL BEGIN SET @seed=TestGen.SeedFromLeaf(@op,@operand); IF @seed IS NOT NULL INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,@seed); END;
                                SET @i=@k; CONTINUE;
                            END;
                            SET @i=@k; CONTINUE;
                        END;
                        IF @ch LIKE N'[A-Za-z]'
                        BEGIN
                            SET @w=N''; SET @k=@i;
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            SET @w=UPPER(@w);
                            IF @w IN (N'RETURN',N'SET',N'SELECT',N'INSERT',N'UPDATE',N'DELETE',N'PRINT',N'EXEC',N'EXECUTE',N'THROW',N'RAISERROR',N'BREAK',N'CONTINUE',N'WAITFOR',N'GOTO',N'DECLARE',N'MERGE',N'COMMIT',N'ROLLBACK',N'TRUNCATE')
                            BEGIN SET @stop=1; CONTINUE; END;
                            SET @i=@k; CONTINUE;
                        END;
                    END;
                    SET @i+=1;
                END;

                -- emit branch seed (own leaves win; deepest ancestor per param fills the rest)
                IF EXISTS (SELECT 1 FROM @leaf)
                BEGIN
                    SET @branch += 1;
                    INSERT @seeds (BranchId,ParamName,SeedLiteral) SELECT @branch,ParamName,SeedLiteral FROM @leaf;
                    INSERT @seeds (BranchId,ParamName,SeedLiteral)
                    SELECT @branch, a.ParamName, a.SeedLiteral
                    FROM @anc a
                    WHERE a.AtDepth = (SELECT MAX(a2.AtDepth) FROM @anc a2 WHERE UPPER(a2.ParamName)=UPPER(a.ParamName))
                      AND NOT EXISTS (SELECT 1 FROM @leaf l WHERE UPPER(l.ParamName)=UPPER(a.ParamName));
                END;

                IF @bodyIsBegin=1 AND EXISTS (SELECT 1 FROM @leaf)
                BEGIN DELETE FROM @pend; INSERT @pend SELECT ParamName,SeedLiteral FROM @leaf; SET @hasPending=1; END
                ELSE SET @hasPending=0;
                CONTINUE;
            END;
        END;

        SET @i += 1;
    END;
    RETURN;
END;
GO
PRINT 'TestGen.ExtractBranchSeeds installed (ancestor-chaining; returns BranchId).';
GO

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

    -- Step 2 + 2.1: per-branch seed calls (each branch = own leaves + ancestor
    -- gates).  Wrapped so any extractor failure is non-fatal (fall back to happy+NULL).
    DECLARE @execSeeds NVARCHAR(MAX)=N'', @seedCount INT=0;
    BEGIN TRY
        DECLARE @fndef NVARCHAR(MAX)=OBJECT_DEFINITION(@objid);
        DECLARE @asp INT = TestGen.FindTopLevelAs(@fndef);
        DECLARE @fnbody NVARCHAR(MAX)= CASE WHEN @asp>0 THEN SUBSTRING(@fndef,@asp+2,LEN(@fndef)) ELSE @fndef END;
        DECLARE @paramCsv NVARCHAR(MAX)=N'';
        SELECT @paramCsv=@paramCsv+name+N',' FROM @ph ORDER BY ord;
        DECLARE @retClause NVARCHAR(120)=CASE WHEN @ret=N'' THEN N'' ELSE N', '+@ret END;
        ;WITH raw AS (SELECT BranchId, ParamName, SeedLiteral FROM TestGen.ExtractBranchSeeds(@fnbody,@paramCsv)),
              asg AS (SELECT BranchId, ParamName, MAX(SeedLiteral) AS SeedLiteral FROM raw GROUP BY BranchId, ParamName)
        SELECT @execSeeds = @execSeeds
             + N'    BEGIN TRY EXEC '+@shadowFull+N' '+ z.args + @retClause + N'; END TRY BEGIN CATCH END CATCH;'+@CRLF,
               @seedCount = @seedCount + 1
        FROM (
            SELECT b.BranchId,
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                        p.name + N'=' + ISNULL(a.SeedLiteral, p.happyLit)),
                        N', ') WITHIN GROUP (ORDER BY p.ord) AS args
            FROM (SELECT DISTINCT BranchId FROM asg) b
            CROSS JOIN @ph p
            LEFT JOIN asg a ON a.BranchId=b.BranchId AND UPPER(a.ParamName)=UPPER(p.name)
            GROUP BY b.BranchId
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
    IF @seedCount > 0 PRINT 'RunCoverageForFunction: '+CAST(@seedCount AS VARCHAR)+' branch-seed driver call(s) added for '+@SchemaName+'.'+@FunctionName+'.';

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
PRINT 'TestGen.RunCoverageForFunction installed (Step 2.1: ancestor-chained seeding).';
GO
PRINT '== v11 Step 2.1 applied: nested branches reached by satisfying enclosing gates. ==';
GO
