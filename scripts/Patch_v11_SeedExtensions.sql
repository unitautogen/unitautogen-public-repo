/*============================================================================
 * Patch_v11_SeedExtensions.sql  —  reversed / NOT / non-numeric branch seeds
 *----------------------------------------------------------------------------
 * Run AFTER Install_UnitAutogen.sql (+ earlier v11 patches). Idempotent
 * (CREATE OR ALTER).  Extends Step-2 predicate-inversion seeding to three more
 * predicate shapes the extractor previously left as residue:
 *
 *   #2  REVERSED predicates  `literal <op> @param`  (e.g. IF 5 = @status,
 *       IF 0 < @n).  The numeric LHS is read and the operator mirrored
 *       (5 > @x  ==  @x < 5) so the param-side seed still satisfies the gate.
 *       Guarded by an lhsOk boundary flag so arithmetic / column LHS
 *       (@a+5 > @b, col5 = @w) does NOT produce a speculative seed.
 *
 *   #3  NOT IN / NOT LIKE / NOT BETWEEN.  Best-effort satisfying value:
 *       NOT BETWEEN lo AND hi -> lo-1 (num) / '' (str);  NOT IN (a,..) ->
 *       a-1 (num) / a+'~' (str);  NOT LIKE 'p' -> '' (evades prefix/substr).
 *
 *   #4  Non-numeric  < > <>  on string/ISO-date literals:  <  -> '' ;
 *       > and <> -> the literal with a trailing char appended ('M' -> 'M~').
 *
 * SAFE BY CONSTRUCTION (unchanged from Step 2): every seed EXEC and the whole
 * seed-build block in RunCoverageForFunction are TRY/CATCH'd, so an inexact
 * seed merely fails to enter its branch (honest residue) and can never break a
 * run or regress coverage.  Predicates still left as residue: reversed STRING
 * literals, parenthesised comparisons, non-literal RHS, NOT LIKE on '%'-only.
 *
 * Verify with scripts/Verify_SeedExtensions.sql.
 *==========================================================================*/
SET NOCOUNT ON;
GO
CREATE OR ALTER FUNCTION TestGen.SeedFromLeaf(@op VARCHAR(12), @lit NVARCHAR(500))
RETURNS NVARCHAR(500)
AS
BEGIN
    -- @lit is the comparand pulled from the predicate: bare digits for a numeric
    -- comparison, or a fully-quoted string literal (e.g. 'M') for text/date.
    DECLARE @isStr BIT = CASE WHEN LEFT(@lit,1)=N'''' THEN 1 ELSE 0 END;
    DECLARE @bi BIGINT, @dn DECIMAL(38,10);

    IF @op IN ('=','<=','>=','IN','BETWEEN','LIKE') RETURN @lit;   -- literal satisfies as-is
    IF @op = 'ISNULL' RETURN N'NULL';

    -- < > <> : numeric +/-1, OR (v11 #4) a lexical seed for string/date literals.
    IF @op IN ('<','>','<>')
    BEGIN
        IF @isStr = 0
        BEGIN
            SET @bi = TRY_CONVERT(BIGINT, @lit);
            IF @bi IS NOT NULL
                RETURN CONVERT(NVARCHAR(40), CASE WHEN @op='<' THEN @bi-1 ELSE @bi+1 END);
            SET @dn = TRY_CONVERT(DECIMAL(38,10), @lit);
            IF @dn IS NOT NULL
                RETURN CONVERT(NVARCHAR(50), CASE WHEN @op='<' THEN @dn-1 ELSE @dn+1 END);
            RETURN NULL;            -- unquoted non-numeric (function call etc.): residue
        END;
        -- string / ISO-date literal: smaller = empty string; larger/<> = append a char
        IF @op = '<' RETURN N'''''';                       -- '' sorts before any non-empty value
        RETURN STUFF(@lit, LEN(@lit), 1, N'~''');          -- 'M' -> 'M~'   ( > and <> )
    END;

    -- v11 #3 NOT forms: best-effort satisfying value.  A miss is harmless - each
    -- seed EXEC is TRY/CATCH'd, so an inexact value just leaves the branch as
    -- honest residue rather than breaking the driver.
    IF @op IN ('NOTBETWEEN','NOTIN')
    BEGIN
        IF @isStr = 0
        BEGIN
            SET @bi = TRY_CONVERT(BIGINT, @lit);
            IF @bi IS NOT NULL RETURN CONVERT(NVARCHAR(40), @bi-1);   -- below the low bound / before the first element
            SET @dn = TRY_CONVERT(DECIMAL(38,10), @lit);
            IF @dn IS NOT NULL RETURN CONVERT(NVARCHAR(50), @dn-1);
            RETURN NULL;
        END;
        IF @op = 'NOTBETWEEN' RETURN N'''''';              -- '' sorts below the low bound
        RETURN STUFF(@lit, LEN(@lit), 1, N'~''');          -- distinct from the first list element
    END;
    IF @op = 'NOTLIKE' RETURN N'''''';                     -- '' evades prefix/suffix/substring patterns

    RETURN NULL;                -- ISNOTNULL and anything else: no seed
END;
GO

GO
PRINT 'TestGen.SeedFromLeaf installed (SeedExtensions).';
GO
CREATE OR ALTER FUNCTION TestGen.ExtractBranchSeeds(@Body NVARCHAR(MAX), @ParamCsv NVARCHAR(MAX))
RETURNS @seeds TABLE (BranchId INT, ParamName SYSNAME, SeedLiteral NVARCHAR(500))
AS
BEGIN
    DECLARE @pset NVARCHAR(MAX) = N'|' + UPPER(REPLACE(REPLACE(REPLACE(ISNULL(@ParamCsv,N''),N' ',N''),CHAR(13),N''),CHAR(10),N'')) + N'|';
    SET @pset = REPLACE(@pset, N',', N'|');
    IF @pset = N'||' RETURN;

    DECLARE @anc  TABLE (AtDepth INT, ParamName SYSNAME, SeedLiteral NVARCHAR(500));
    DECLARE @pend TABLE (ParamName SYSNAME, SeedLiteral NVARCHAR(500));
    DECLARE @leaf TABLE (ParamName SYSNAME, SeedLiteral NVARCHAR(500));

    DECLARE @len INT = LEN(@Body), @i INT = 1, @depth INT = 0, @branch INT = 0;
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pvc NCHAR(1),@aft NCHAR(1);
    DECLARE @hasPending BIT=0, @bodyIsBegin BIT, @fw VARCHAR(6);
    DECLARE @pp INT,@psA BIT,@pcl BIT,@pbk BIT,@stop BIT,@lhsOk BIT;
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
            IF UPPER(SUBSTRING(@Body,@i,3))=N'END'
               AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @i+3<=@len THEN SUBSTRING(@Body,@i+3,1) ELSE N' ' END)=1
            BEGIN
                DELETE FROM @anc WHERE AtDepth=@depth;
                IF @depth>0 SET @depth-=1;
                SET @hasPending=0;
                SET @i += 3; CONTINUE;
            END;
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
                SET @pp=0; SET @psA=0; SET @pcl=0; SET @pbk=0; SET @stop=0; SET @bodyIsBegin=0; SET @lhsOk=1;
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
                    IF @ch=N'(' BEGIN SET @pp+=1; SET @lhsOk=1; SET @i+=1; CONTINUE; END;
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
                            SET @lhsOk=0;
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
                                    ELSE IF @w=N'NOT' BEGIN WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1; SET @w2=N''; WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w2+=SUBSTRING(@Body,@k,1); SET @k+=1; END; SET @w2=UPPER(@w2); IF @w2=N'IN' SET @op='NOTIN'; ELSE IF @w2=N'BETWEEN' SET @op='NOTBETWEEN'; ELSE IF @w2=N'LIKE' SET @op='NOTLIKE'; END
                                    ELSE IF @w=N'IN' SET @op='IN';
                                    ELSE IF @w=N'BETWEEN' SET @op='BETWEEN';
                                    ELSE IF @w=N'LIKE' SET @op='LIKE';
                                END;
                                IF @op IN ('=','<','>','<=','>=','<>','LIKE','IN','BETWEEN','NOTIN','NOTLIKE','NOTBETWEEN')
                                BEGIN
                                    IF @op IN ('IN','NOTIN') BEGIN WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1; IF SUBSTRING(@Body,@k,1)=N'(' SET @k+=1; END;
                                    WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                                    SET @kc=CASE WHEN @k<=@len THEN SUBSTRING(@Body,@k,1) ELSE N'' END;
                                    IF @kc=N'''' BEGIN SET @operand=N''''; SET @k+=1; WHILE @k<=@len BEGIN SET @kc=SUBSTRING(@Body,@k,1); IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @operand+=N''''''; SET @k+=2; CONTINUE; END; SET @operand+=@kc; SET @k+=1; IF @kc=N'''' BREAK; END; END
                                    ELSE IF @kc LIKE N'[0-9]' OR (@kc IN (N'-',N'+',N'.') AND SUBSTRING(@Body,@k+1,1) LIKE N'[0-9]') BEGIN SET @operand=N''; IF @kc IN (N'-',N'+') BEGIN SET @operand+=@kc; SET @k+=1; END; WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[0-9.]' BEGIN SET @operand+=SUBSTRING(@Body,@k,1); SET @k+=1; END; END;
                                    IF @op IN ('LIKE','NOTLIKE') AND @operand IS NOT NULL BEGIN SET @operand=REPLACE(REPLACE(@operand,N'%',N''),N'_',N''); IF @operand=N'''''' SET @operand=NULL; END;
                                END;
                                IF @op='ISNULL' INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,N'NULL');
                                ELSE IF @op IS NOT NULL AND @operand IS NOT NULL BEGIN SET @seed=TestGen.SeedFromLeaf(@op,@operand); IF @seed IS NOT NULL INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,@seed); END;
                                SET @i=@k; CONTINUE;
                            END;
                            SET @i=@k; CONTINUE;
                        END;
                        IF @lhsOk=1 AND ((@ch LIKE N'[0-9]') OR (@ch IN (N'-',N'+',N'.') AND SUBSTRING(@Body,@i+1,1) LIKE N'[0-9]'))
                        BEGIN
                            -- v11 #2: reversed predicate  literal <op> @param  (numeric LHS only).
                            -- Read the literal, then mirror the operator so the param-side seed
                            -- still satisfies the comparison (5 > @x  ==  @x < 5).
                            SET @operand=N''; SET @k=@i;
                            IF SUBSTRING(@Body,@k,1) IN (N'-',N'+') BEGIN SET @operand+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[0-9.]' BEGIN SET @operand+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                            SET @op=NULL;
                            IF SUBSTRING(@Body,@k,2) IN (N'>=',N'<=',N'<>',N'!=') BEGIN SET @op=CASE WHEN SUBSTRING(@Body,@k,2)=N'!=' THEN '<>' ELSE SUBSTRING(@Body,@k,2) END COLLATE DATABASE_DEFAULT; SET @k+=2; END
                            ELSE IF SUBSTRING(@Body,@k,1)=N'=' BEGIN SET @op='='; SET @k+=1; END
                            ELSE IF SUBSTRING(@Body,@k,1)=N'<' BEGIN SET @op='<'; SET @k+=1; END
                            ELSE IF SUBSTRING(@Body,@k,1)=N'>' BEGIN SET @op='>'; SET @k+=1; END;
                            IF @op IS NOT NULL
                            BEGIN
                                WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                                IF @k<=@len AND SUBSTRING(@Body,@k,1)=N'@'
                                BEGIN
                                    SET @tok=N'@'; SET @k+=1;
                                    WHILE @k<=@len BEGIN SET @kc=SUBSTRING(@Body,@k,1); IF @kc LIKE N'[A-Za-z0-9_@#]' BEGIN SET @tok+=@kc; SET @k+=1; END ELSE BREAK; END;
                                    IF CHARINDEX(N'|'+UPPER(@tok)+N'|',@pset)>0
                                    BEGIN
                                        SET @w2=CASE @op WHEN '<' THEN '>' WHEN '>' THEN '<' WHEN '<=' THEN '>=' WHEN '>=' THEN '<=' ELSE @op END;
                                        SET @seed=TestGen.SeedFromLeaf(@w2,@operand);
                                        IF @seed IS NOT NULL INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,@seed);
                                    END;
                                END;
                            END;
                            SET @lhsOk=0; SET @i=@k; CONTINUE;
                        END;
                        IF @ch LIKE N'[A-Za-z]'
                        BEGIN
                            SET @w=N''; SET @k=@i;
                            WHILE @k<=@len AND SUBSTRING(@Body,@k,1) LIKE N'[A-Za-z]' BEGIN SET @w+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                            SET @w=UPPER(@w);
                            IF @w IN (N'RETURN',N'SET',N'SELECT',N'INSERT',N'UPDATE',N'DELETE',N'PRINT',N'EXEC',N'EXECUTE',N'THROW',N'RAISERROR',N'BREAK',N'CONTINUE',N'WAITFOR',N'GOTO',N'DECLARE',N'MERGE',N'COMMIT',N'ROLLBACK',N'TRUNCATE')
                            BEGIN SET @stop=1; CONTINUE; END;
                            SET @lhsOk = CASE WHEN @w IN (N'AND',N'OR',N'NOT') THEN 1 ELSE 0 END;
                            SET @i=@k; CONTINUE;
                        END;
                    END;
                    SET @i+=1;
                END;

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

GO
PRINT 'TestGen.ExtractBranchSeeds installed (SeedExtensions).';
GO
