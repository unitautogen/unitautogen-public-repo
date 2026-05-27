/*******************************************************************************
 * Branch Path Analyzer v3.1 - Full N-Level Code Coverage
 * Handles: IF EXISTS, CASE WHEN, AND/OR/BETWEEN/LIKE/IN, N-level nesting
 *
 * v3.1 change:
 *   PathID is now allocated per LOGICAL PREDICATE BLOCK, not per condition.
 *   Previously PathID was an IDENTITY column so every condition row
 *   (CustomerID=..., SubTotal=...) got a unique PathID.  The test
 *   generator's pathidcur drove one test per PathID and seedcur2 selected
 *   WHERE PathID = @GenPathID, so each test only seeded ONE column.
 *   A predicate like `CustomerID = @x AND SubTotal BETWEEN ...` therefore
 *   produced two tests, each seeding one column.  Both tests overwrote
 *   the same name and the EXISTS predicate evaluated FALSE at runtime,
 *   so the THEN branch was never exercised.
 *
 *   Now: each IF EXISTS block gets ONE PathID.  All its condition rows
 *   share it.  seedcur2 aggregates them into a single multi-column
 *   INSERT that actually matches the predicate.
 *   CASE_WHEN and CASE_ELSE still get a fresh PathID per WHEN/ELSE
 *   because each is a separate branch.
 ******************************************************************************/

/*****************************************************************************
 * TestGen.ExtractLeafDml  (v9.4)
 * ---------------------------------------------------------------------------
 * Given a branch BODY block, decide whether the body unconditionally performs
 * exactly ONE table-DML statement (an UPDATE, or an INSERT ... VALUES) and, if
 * so, hand that statement back so the test generator can "replay" it onto a
 * snapshot of the seeded table (see DESIGN_v9_4_Strong_Assertions.md).
 *
 *   @DmlKind   OUTPUT  'UPDATE' | 'INSERT' | NULL  (NULL = not a leaf body)
 *   @DmlTable  OUTPUT  bare target table name (no schema, no brackets)
 *   @DmlText   OUTPUT  the raw DML statement, with the target-table reference
 *                      rewritten to the literal token  {{TARGET}}  so the
 *                      generator can re-point the replay at a temp snapshot.
 *
 * A body counts as a "leaf" only when, after stripping -- comments:
 *   - it contains exactly one UPDATE or INSERT (and no other),
 *   - no DELETE and no MERGE,
 *   - no nested IF / WHILE (those make the DML path-dependent),
 *   - at most one BEGIN (the body's own outer BEGIN/END),
 *   - if it is an INSERT, it is not INSERT ... SELECT.
 * Anything else returns @DmlKind = NULL and the generator falls back to the
 * weaker coverage/smoke assertion.
 *****************************************************************************/
IF OBJECT_ID('TestGen.ExtractLeafDml', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ExtractLeafDml;
GO

CREATE PROCEDURE TestGen.ExtractLeafDml
    @BodyBlock NVARCHAR(MAX),
    @DmlKind   VARCHAR(10)   OUTPUT,
    @DmlTable  SYSNAME       OUTPUT,
    @DmlText   NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @DmlKind  = NULL;
    SET @DmlTable = NULL;
    SET @DmlText  = NULL;

    IF @BodyBlock IS NULL OR LEN(LTRIM(RTRIM(@BodyBlock))) = 0 RETURN;

    DECLARE @blk    NVARCHAR(MAX) = @BodyBlock;
    DECLARE @blkLen INT;
    DECLARE @pos    INT, @eol INT;
    DECLARE @u      NVARCHAR(MAX);
    DECLARE @uCnt   INT, @iCnt INT, @dCnt INT, @mCnt INT;
    DECLARE @ifCnt  INT, @whCnt INT, @bgCnt INT;
    DECLARE @kwPos  INT, @stmtEnd INT, @inQ BIT, @ch NCHAR(1);
    DECLARE @tblPos INT, @tblEnd INT;
    DECLARE @rawTbl NVARCHAR(300);

    -- 1. strip -- line comments (blank the span, keep total length stable)
    SET @pos = CHARINDEX(N'--', @blk);
    WHILE @pos > 0
    BEGIN
        SET @eol = CHARINDEX(CHAR(10), @blk, @pos);
        IF @eol = 0 SET @eol = (DATALENGTH(@blk) / 2) + 1;
        SET @blk = STUFF(@blk, @pos, @eol - @pos, REPLICATE(N' ', @eol - @pos));
        SET @pos = CHARINDEX(N'--', @blk, @pos + 1);
    END;

    SET @blkLen = DATALENGTH(@blk) / 2;

    -- 2. keyword census on an upper-cased, whitespace-flattened copy.
    --    DATALENGTH (not LEN) so trailing spaces are counted reliably.
    SET @u = REPLACE(REPLACE(REPLACE(UPPER(@blk), CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ');
    SET @uCnt  = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'UPDATE ', N''))) / (7 * 2);
    SET @iCnt  = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'INSERT ', N''))) / (7 * 2);
    SET @dCnt  = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'DELETE ', N''))) / (7 * 2);
    SET @mCnt  = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N' MERGE ', N''))) / (7 * 2);
    SET @whCnt = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'WHILE ',  N''))) / (6 * 2);
    SET @bgCnt = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'BEGIN ',  N''))) / (6 * 2);
    SET @ifCnt = (DATALENGTH(@u) - DATALENGTH(REPLACE(@u, N'IF ',     N''))) / (3 * 2);

    IF @uCnt + @iCnt <> 1 RETURN;
    IF @dCnt > 0 OR @mCnt > 0 RETURN;
    IF @ifCnt > 0 OR @whCnt > 0 RETURN;
    IF @bgCnt > 1 RETURN;

    -- 3. locate the single DML statement
    IF @uCnt = 1
    BEGIN SET @DmlKind = 'UPDATE'; SET @kwPos = CHARINDEX(N'UPDATE ', @u); END
    ELSE
    BEGIN SET @DmlKind = 'INSERT'; SET @kwPos = CHARINDEX(N'INSERT ', @u); END

    IF @kwPos = 0 BEGIN SET @DmlKind = NULL; RETURN; END;

    -- statement text: keyword .. first ';' not inside a string literal, or end
    SET @stmtEnd = @kwPos;
    SET @inQ = 0;
    WHILE @stmtEnd <= @blkLen
    BEGIN
        SET @ch = SUBSTRING(@blk, @stmtEnd, 1);
        IF @ch = N'''' SET @inQ = 1 - @inQ;
        IF @ch = N';' AND @inQ = 0 BREAK;
        SET @stmtEnd = @stmtEnd + 1;
    END;
    SET @DmlText = LTRIM(RTRIM(SUBSTRING(@blk, @kwPos, @stmtEnd - @kwPos)));

    -- 4. INSERT ... SELECT cannot be replayed as a literal VALUES insert
    IF @DmlKind = 'INSERT' AND CHARINDEX(N'SELECT', UPPER(@DmlText)) > 0
    BEGIN
        SET @DmlKind = NULL; SET @DmlText = NULL; RETURN;
    END;

    -- 5. parse the target table token (after UPDATE, or INSERT [INTO])
    SET @tblPos = @kwPos + 7;            -- past 'UPDATE ' / 'INSERT '
    WHILE @tblPos <= @blkLen AND SUBSTRING(@blk,@tblPos,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13))
        SET @tblPos = @tblPos + 1;
    IF UPPER(SUBSTRING(@blk,@tblPos,5)) = N'INTO '
    BEGIN
        SET @tblPos = @tblPos + 5;
        WHILE @tblPos <= @blkLen AND SUBSTRING(@blk,@tblPos,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13))
            SET @tblPos = @tblPos + 1;
    END;
    SET @tblEnd = @tblPos;
    WHILE @tblEnd <= @blkLen
      AND SUBSTRING(@blk,@tblEnd,1) NOT IN (N' ',CHAR(9),CHAR(10),CHAR(13),N'(',N';')
        SET @tblEnd = @tblEnd + 1;
    SET @rawTbl = LTRIM(RTRIM(SUBSTRING(@blk,@tblPos,@tblEnd-@tblPos)));

    IF @rawTbl IS NULL OR LEN(@rawTbl) = 0
    BEGIN SET @DmlKind = NULL; SET @DmlText = NULL; RETURN; END;

    SET @DmlTable = REPLACE(REPLACE(@rawTbl, N'[', N''), N']', N'');
    IF CHARINDEX(N'.', @DmlTable) > 0
        SET @DmlTable = SUBSTRING(@DmlTable, CHARINDEX(N'.',@DmlTable)+1, 300);

    IF @DmlTable IS NULL OR LEN(LTRIM(RTRIM(@DmlTable))) = 0
    BEGIN SET @DmlKind = NULL; SET @DmlText = NULL; SET @DmlTable = NULL; RETURN; END;

    -- 6. rewrite the target-table reference to the {{TARGET}} replay token
    SET @pos = CHARINDEX(@rawTbl, @DmlText);
    IF @pos > 0
        SET @DmlText = STUFF(@DmlText, @pos, LEN(@rawTbl), N'{{TARGET}}');
END;
GO

PRINT 'TestGen.ExtractLeafDml created (v9.4 - leaf body-DML capture).';
GO

IF OBJECT_ID('TestGen.AnalyzeBranchPaths', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.AnalyzeBranchPaths;
GO

CREATE PROCEDURE TestGen.AnalyzeBranchPaths
    @ProcSource  NVARCHAR(MAX),
    @ParamName   SYSNAME,
    @BranchValue NVARCHAR(500),
    @ArgList     NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Paths (
        PathID       INT           NOT NULL,
        PathType     VARCHAR(20)   NOT NULL,
        TableName    SYSNAME       NULL,
        ColumnName   SYSNAME       NULL,
        CondValue    NVARCHAR(500) NULL,
        Operator     VARCHAR(20)   NULL,
        Depth        INT           NOT NULL DEFAULT 1,
        ParentPathID INT           NULL,
        AssertTable  SYSNAME       NULL,
        AssertType   VARCHAR(20)   NULL,
        -- v9.4: strong-assertion body-DML capture (snapshot-and-replay).
        BodyDmlKind  VARCHAR(10)   NULL,   -- 'UPDATE' / 'INSERT' / NULL
        BodyDmlTable SYSNAME       NULL,   -- bare target table name
        BodyDmlText  NVARCHAR(MAX) NULL    -- statement text, target = {{TARGET}}
    );

    CREATE TABLE #Queue (
        QID          INT IDENTITY(1,1),
        Block        NVARCHAR(MAX),
        Depth        INT,
        ParentPathID INT NULL
    );

    -- v3.2: per-subquery alias map.  Populated at the start of each EXISTS
    -- block by parsing FROM/JOIN clauses.  Used when classifying WHERE
    -- conditions whose LHS uses a table alias (e.g. `st.CountryRegionCode`).
    CREATE TABLE #Aliases (
        Alias     SYSNAME NOT NULL,
        TableName SYSNAME NOT NULL
    );

    ---------------------------------------------------------------------------
    -- ALL variable declarations at top (SQL Server requires this)
    ---------------------------------------------------------------------------
    DECLARE @BranchBlock   NVARCHAR(MAX);
    DECLARE @BranchStart   INT;
    DECLARE @BeginPos      INT;
    DECLARE @Pos           INT;
    DECLARE @Depth2        INT;
    DECLARE @Pat1          NVARCHAR(1000);
    DECLARE @LE            INT;
    DECLARE @QID           INT;
    DECLARE @QBlock        NVARCHAR(MAX);
    DECLARE @QDepth        INT;
    DECLARE @QParent       INT;
    DECLARE @ScanPos       INT;
    DECLARE @FoundPos      INT;
    DECLARE @SubqStart     INT;
    DECLARE @SubqEnd       INT;
    DECLARE @PD            INT;
    DECLARE @SubqBlock     NVARCHAR(MAX);
    DECLARE @FromPos       INT;
    DECLARE @TblStart      INT;
    DECLARE @TblEnd        INT;
    DECLARE @PrimaryTbl    SYSNAME;
    DECLARE @WherePos      INT;
    DECLARE @WhereClause   NVARCHAR(MAX);
    DECLARE @CloseP        INT;
    DECLARE @Remaining     NVARCHAR(MAX);
    DECLARE @AndIdx        INT;
    DECLARE @OrIdx         INT;
    DECLARE @CondPart      NVARCHAR(500);
    DECLARE @EqIdx         INT;
    DECLARE @LHS           NVARCHAR(200);
    DECLARE @RHS           NVARCHAR(200);
    DECLARE @ColName       SYSNAME;
    DECLARE @AliasStr      NVARCHAR(50);
    DECLARE @Op            VARCHAR(20);
    DECLARE @ResolvedVal   NVARCHAR(500);
    DECLARE @PRef          NVARCHAR(200);
    DECLARE @SearchStr     NVARCHAR(300);
    DECLARE @ArgPos        INT;
    DECLARE @ValStart      INT;
    DECLARE @ValStr        NVARCHAR(500);
    DECLARE @CQ            INT;
    DECLARE @CP            INT;
    DECLARE @CondCount     INT;
    DECLARE @RHSClean      NVARCHAR(200);
    DECLARE @ci            INT;
    DECLARE @BetAnd        INT;
    DECLARE @BetweenLow    NVARCHAR(100);
    DECLARE @BetweenHigh   NVARCHAR(100);
    DECLARE @BetweenMid    NVARCHAR(100);
    DECLARE @BetweenCheck  INT;
    DECLARE @AfterBetween  INT;
    DECLARE @BetweenAndPos INT;
    DECLARE @AfterBetweenHigh INT;
    DECLARE @LikeVal       NVARCHAR(200);
    -- v3.2: alias-scan working variables
    DECLARE @ScanFrom      INT;
    DECLARE @TokEnd        INT;
    DECLARE @TableTok      NVARCHAR(300);
    DECLARE @AliasTok      NVARCHAR(50);
    DECLARE @AfterTbl      INT;
    -- v3.2: alias-resolved table (used in WHERE-condition handling)
    DECLARE @ResolvedTbl   SYSNAME;
    -- v9.2.1 (GAP A): function-wrapped-column working vars
    DECLARE @FuncName    NVARCHAR(50);
    DECLARE @InnerArg    NVARCHAR(200);
    DECLARE @FuncOpenP   INT;
    DECLARE @FuncCloseP  INT;
    DECLARE @LhsDateFunc BIT;
    -- v9.2.1 (IF_ELSE): plain-IF-with-ELSE detection working vars
    DECLARE @IfPos        INT;
    DECLARE @IfParamStart INT;
    DECLARE @IfParamEnd   INT;
    DECLARE @IfParam      NVARCHAR(128);
    DECLARE @IfEqPos      INT;
    DECLARE @IfQ1         INT;
    DECLARE @IfQ2         INT;
    DECLARE @IfLit        NVARCHAR(500);
    DECLARE @IfAfter      INT;
    DECLARE @IfDepth      INT;
    -- v9.4: leaf body-DML capture working vars
    DECLARE @LeafKind     VARCHAR(10);
    DECLARE @LeafTbl      SYSNAME;
    DECLARE @LeafTxt      NVARCHAR(MAX);
    DECLARE @ElseBodyB    NVARCHAR(MAX);
    DECLARE @EBStart      INT;
    DECLARE @EBPos        INT;
    DECLARE @EBDepth      INT;
    -- v9.2: outer-ELSE depth-walker working vars
    DECLARE @AfterLen      INT;
    DECLARE @AfterIdx      INT;
    DECLARE @AfterDepth    INT;
    DECLARE @SeenBegin     BIT;
    DECLARE @AfterCh       NCHAR(1);
    DECLARE @AfterPrev     NCHAR(1);
    DECLARE @AfterNext     NCHAR(1);
    DECLARE @InList        NVARCHAR(500);
    DECLARE @InVal         NVARCHAR(100);
    DECLARE @InComma       INT;
    DECLARE @NewPathID     INT;
    DECLARE @NextPathID    INT = 0;   -- monotonic counter; allocated per logical predicate block
    DECLARE @CurPathID     INT;       -- PathID of the predicate block currently being emitted
    DECLARE @FalsePathID   INT;       -- PathID for the EXISTS_FALSE/ELSE counterpart
    DECLARE @AfterSubq     NVARCHAR(MAX);
    DECLARE @ElsePos       INT;
    DECLARE @CharAfterElse NVARCHAR(1);
    DECLARE @ElseBlock     NVARCHAR(MAX);
    DECLARE @ElseTable     SYSNAME;
    DECLARE @ElseInsPos    INT;
    DECLARE @ElseUpdPos    INT;
    DECLARE @ElseTblPos    INT;
    DECLARE @ElseTblEnd    INT;
    DECLARE @JoinSearch    NVARCHAR(MAX);
    DECLARE @JoinPos       INT;
    DECLARE @JTblStart     INT;
    DECLARE @JTblEnd       INT;
    DECLARE @JTbl          SYSNAME;
    DECLARE @TrueBlockStart INT;
    DECLARE @TrueBlock     NVARCHAR(MAX);
    DECLARE @TBPos         INT;
    DECLARE @TBBegin       INT;
    DECLARE @TBDepth       INT;
    DECLARE @TrueAssertTbl SYSNAME;
    DECLARE @TAInsPos      INT;
    DECLARE @TAUpdPos      INT;
    DECLARE @TATblPos      INT;
    DECLARE @TATblEnd      INT;
    DECLARE @CasePos       INT;
    DECLARE @CaseEndPos    INT;
    DECLARE @CaseBlock     NVARCHAR(MAX);
    DECLARE @CaseDepth     INT;
    DECLARE @CaseVar       NVARCHAR(200);
    DECLARE @CaseAfter     NVARCHAR(500);
    DECLARE @CaseVarEnd    INT;
    DECLARE @CaseScan      INT;
    DECLARE @WhenPos       INT;
    DECLARE @ThenPos       INT;
    DECLARE @WhenVal       NVARCHAR(200);
    DECLARE @CaseElsePos   INT;
    DECLARE @CharAE        NVARCHAR(1);
    DECLARE @CaseVarClean  SYSNAME;
    DECLARE @CaseColClean  SYSNAME;
    DECLARE @NextWhen      INT;

    ---------------------------------------------------------------------------
    -- Step 1: Extract top-level branch block
    ---------------------------------------------------------------------------
    SET @BranchBlock = NULL;
    SET @Pat1 = N'IF ' + @ParamName + N' = ''' + @BranchValue + N'''';
    SET @BranchStart = CHARINDEX(@Pat1, @ProcSource);

    IF @BranchStart = 0
    BEGIN
        SET @Pat1 = N'WHEN ''' + @BranchValue + N''' THEN';
        SET @BranchStart = CHARINDEX(@Pat1, @ProcSource);
    END;

    IF @BranchStart > 0
    BEGIN
        SET @BeginPos = CHARINDEX('BEGIN', @ProcSource, @BranchStart);
        IF @BeginPos > 0
        BEGIN
            SET @Depth2 = 1; SET @Pos = @BeginPos + 5;
            WHILE @Depth2 > 0 AND @Pos < LEN(@ProcSource)
            BEGIN
                IF SUBSTRING(@ProcSource,@Pos,5) = 'BEGIN' SET @Depth2 = @Depth2 + 1;
                IF SUBSTRING(@ProcSource,@Pos,3) = 'END'
                   AND SUBSTRING(@ProcSource,@Pos+3,1) IN (' ',';',CHAR(10),CHAR(13))
                    SET @Depth2 = @Depth2 - 1;
                SET @Pos = @Pos + 1;
            END;
            SET @BranchBlock = SUBSTRING(@ProcSource, @BeginPos, @Pos - @BeginPos);
        END
        ELSE
        BEGIN
            SET @LE = CHARINDEX(CHAR(10), @ProcSource, @BranchStart);
            IF @LE = 0 SET @LE = LEN(@ProcSource);
            SET @BranchBlock = SUBSTRING(@ProcSource, @BranchStart, @LE - @BranchStart);
        END;
    END;

    IF @BranchBlock IS NULL OR LEN(LTRIM(RTRIM(@BranchBlock))) = 0
    BEGIN
        SELECT PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType,BodyDmlKind,BodyDmlTable,BodyDmlText FROM #Paths;
        DROP TABLE #Paths; DROP TABLE #Queue; DROP TABLE #Aliases; RETURN;
    END;

    INSERT #Queue (Block,Depth,ParentPathID) VALUES (@BranchBlock,1,NULL);

    ---------------------------------------------------------------------------
    -- Step 2: Process queue (replaces recursion)
    ---------------------------------------------------------------------------
    WHILE EXISTS (SELECT 1 FROM #Queue)
    BEGIN
        SELECT TOP 1 @QID=QID, @QBlock=Block, @QDepth=Depth, @QParent=ParentPathID
        FROM #Queue ORDER BY QID;
        DELETE FROM #Queue WHERE QID=@QID;

        -------------------------------------------------------------------
        -- 2A: Scan for IF EXISTS
        -------------------------------------------------------------------
        SET @ScanPos = 1;
        WHILE @ScanPos < LEN(@QBlock)
        BEGIN
            SET @FoundPos = CHARINDEX('IF EXISTS', @QBlock, @ScanPos);
            IF @FoundPos = 0 BREAK;

            -- Extract balanced subquery
            SET @SubqStart = CHARINDEX('(', @QBlock, @FoundPos);
            SET @SubqEnd = @SubqStart; SET @PD = 0;
            WHILE @SubqEnd <= LEN(@QBlock)
            BEGIN
                IF SUBSTRING(@QBlock,@SubqEnd,1)='(' SET @PD=@PD+1;
                IF SUBSTRING(@QBlock,@SubqEnd,1)=')' SET @PD=@PD-1;
                IF @PD=0 BREAK;
                SET @SubqEnd=@SubqEnd+1;
            END;
            SET @SubqBlock = SUBSTRING(@QBlock,@SubqStart,@SubqEnd-@SubqStart+1);

            -- Primary table
            SET @PrimaryTbl = NULL;
            SET @FromPos = CHARINDEX('FROM',@SubqBlock);
            IF @FromPos > 0
            BEGIN
                SET @TblStart=@FromPos+4;
                WHILE @TblStart<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@TblStart,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @TblStart=@TblStart+1;
                SET @TblEnd=@TblStart;
                WHILE @TblEnd<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@TblEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),')')
                    SET @TblEnd=@TblEnd+1;
                SET @PrimaryTbl=LTRIM(RTRIM(SUBSTRING(@SubqBlock,@TblStart,@TblEnd-@TblStart)));
                SET @PrimaryTbl=REPLACE(REPLACE(@PrimaryTbl,'[',''),']','');
                IF CHARINDEX('.',@PrimaryTbl)>0 SET @PrimaryTbl=SUBSTRING(@PrimaryTbl,CHARINDEX('.',@PrimaryTbl)+1,500);
                IF LEN(LTRIM(RTRIM(ISNULL(@PrimaryTbl,''))))=0 SET @PrimaryTbl=NULL;
            END;

            ---------------------------------------------------------------
            -- v3.2: Build alias map for THIS subquery block.
            -- Parses tokens after FROM and after each JOIN.  Recognises
            -- `Sales.Customer c`, `Sales.Customer AS c`, and bracketed
            -- variants.  Used by the alias-handling block below to keep
            -- conditions on non-primary tables (e.g. st.CountryRegionCode).
            ---------------------------------------------------------------
            DELETE FROM #Aliases;

            -- Helper: a scan loop that, given a starting position pointing
            -- to the table name, advances past the table token, then optional
            -- 'AS', then captures the alias token (if any) before hitting
            -- whitespace, comma, paren, or 'ON'/'INNER'/'LEFT'/'WHERE'/etc.
            -- (Variables hoisted to the top-of-proc DECLARE block.)

            -- FROM <table> [AS] <alias>?
            IF @FromPos > 0
            BEGIN
                SET @ScanFrom = @FromPos + 5; -- after 'FROM '
                WHILE @ScanFrom<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@ScanFrom,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @ScanFrom = @ScanFrom + 1;
                -- read table token
                SET @TokEnd = @ScanFrom;
                WHILE @TokEnd<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@TokEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),')',',')
                    SET @TokEnd = @TokEnd + 1;
                SET @TableTok = LTRIM(RTRIM(SUBSTRING(@SubqBlock,@ScanFrom,@TokEnd-@ScanFrom)));
                SET @TableTok = REPLACE(REPLACE(@TableTok,'[',''),']','');
                IF CHARINDEX('.',@TableTok)>0 SET @TableTok = SUBSTRING(@TableTok,CHARINDEX('.',@TableTok)+1,500);

                -- skip whitespace and optional AS
                SET @AfterTbl = @TokEnd;
                WHILE @AfterTbl<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@AfterTbl,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @AfterTbl = @AfterTbl + 1;
                IF @AfterTbl + 1 <= LEN(@SubqBlock)
                   AND UPPER(SUBSTRING(@SubqBlock,@AfterTbl,3)) = 'AS '
                    SET @AfterTbl = @AfterTbl + 3;

                -- next token is the alias (unless it's a keyword)
                SET @TokEnd = @AfterTbl;
                WHILE @TokEnd<=LEN(@SubqBlock) AND SUBSTRING(@SubqBlock,@TokEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),')',',')
                    SET @TokEnd = @TokEnd + 1;
                SET @AliasTok = LTRIM(RTRIM(SUBSTRING(@SubqBlock,@AfterTbl,@TokEnd-@AfterTbl)));
                SET @AliasTok = REPLACE(REPLACE(@AliasTok,'[',''),']','');

                IF LEN(@AliasTok) > 0
                   AND UPPER(@AliasTok) NOT IN ('WHERE','INNER','LEFT','RIGHT','FULL','CROSS','OUTER','JOIN','ON')
                   AND LEN(@AliasTok) <= 30
                   AND LEN(@TableTok) > 0
                BEGIN
                    INSERT #Aliases (Alias, TableName) VALUES (@AliasTok, @TableTok);
                END;
            END;

            -- For each JOIN <table> [AS] <alias>
            SET @JoinSearch = @SubqBlock;
            SET @JoinPos    = CHARINDEX('JOIN', @JoinSearch);
            WHILE @JoinPos > 0
            BEGIN
                SET @ScanFrom = @JoinPos + 4;
                WHILE @ScanFrom<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@ScanFrom,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @ScanFrom = @ScanFrom + 1;
                SET @TokEnd = @ScanFrom;
                WHILE @TokEnd<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@TokEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),')',',')
                    SET @TokEnd = @TokEnd + 1;
                SET @TableTok = LTRIM(RTRIM(SUBSTRING(@JoinSearch,@ScanFrom,@TokEnd-@ScanFrom)));
                SET @TableTok = REPLACE(REPLACE(@TableTok,'[',''),']','');
                IF CHARINDEX('.',@TableTok)>0 SET @TableTok = SUBSTRING(@TableTok,CHARINDEX('.',@TableTok)+1,500);

                SET @AfterTbl = @TokEnd;
                WHILE @AfterTbl<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@AfterTbl,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @AfterTbl = @AfterTbl + 1;
                IF @AfterTbl + 1 <= LEN(@JoinSearch)
                   AND UPPER(SUBSTRING(@JoinSearch,@AfterTbl,3)) = 'AS '
                    SET @AfterTbl = @AfterTbl + 3;

                SET @TokEnd = @AfterTbl;
                WHILE @TokEnd<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@TokEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),')',',')
                    SET @TokEnd = @TokEnd + 1;
                SET @AliasTok = LTRIM(RTRIM(SUBSTRING(@JoinSearch,@AfterTbl,@TokEnd-@AfterTbl)));
                SET @AliasTok = REPLACE(REPLACE(@AliasTok,'[',''),']','');

                IF LEN(@AliasTok) > 0
                   AND UPPER(@AliasTok) NOT IN ('WHERE','INNER','LEFT','RIGHT','FULL','CROSS','OUTER','JOIN','ON')
                   AND LEN(@AliasTok) <= 30
                   AND LEN(@TableTok) > 0
                   AND NOT EXISTS (SELECT 1 FROM #Aliases WHERE Alias = @AliasTok)
                BEGIN
                    INSERT #Aliases (Alias, TableName) VALUES (@AliasTok, @TableTok);
                END;

                SET @JoinSearch = SUBSTRING(@JoinSearch, @TokEnd, LEN(@JoinSearch));
                SET @JoinPos    = CHARINDEX('JOIN', @JoinSearch);
            END;

            -- Parse WHERE conditions
            -- Allocate ONE PathID for this entire EXISTS-predicate block so
            -- that all conditions inside the same block (joined by AND) share
            -- it.  Previously each condition got its own auto-IDENTITY PathID
            -- and downstream code (seedcur2 in 04_Test_Generator) iterates
            -- WHERE PathID = @GenPathID, so conditions were never combined
            -- into one INSERT - the seeded row matched only the LAST
            -- condition and failed the predicate at runtime.
            SET @NextPathID = @NextPathID + 1;
            SET @CurPathID  = @NextPathID;
            SET @WherePos   = CHARINDEX('WHERE',@SubqBlock);
            SET @CondCount  = 0;
            IF @WherePos>0 AND @PrimaryTbl IS NOT NULL
            BEGIN
                -- v9.2.1 (GAP D): @SubqBlock is parenthesis-balanced, so its
                -- LAST char is the subquery's own closing ')'.  The old
                -- CHARINDEX(')') grabbed the FIRST ')' - for any predicate
                -- containing "IN (...)" that is the IN-list's paren, which
                -- truncated every condition after it (e.g. dropping
                -- "AND st.CountryRegionCode = 'US'").  Take everything from
                -- after WHERE up to (not including) that final ')'.
                SET @WhereClause=SUBSTRING(@SubqBlock,@WherePos+5,
                                           LEN(@SubqBlock)-@WherePos-5);
                SET @Remaining=@WhereClause;

                WHILE LEN(LTRIM(RTRIM(@Remaining)))>0
                BEGIN
                    SET @OrIdx  = CHARINDEX(' OR ',  @Remaining);
                    SET @AndIdx = CHARINDEX(' AND ', @Remaining);

                    -- Don't split on AND that's inside a BETWEEN clause
                    SET @BetweenCheck = CHARINDEX('BETWEEN', @Remaining);
                    IF @BetweenCheck > 0 AND @AndIdx > @BetweenCheck
                    BEGIN
                        SET @AfterBetween = @BetweenCheck + 7;
                        SET @BetweenAndPos = CHARINDEX(' AND ', @Remaining, @AfterBetween);
                        IF @BetweenAndPos > 0
                        BEGIN
                            SET @AfterBetweenHigh = @BetweenAndPos + 5;
                            WHILE @AfterBetweenHigh <= LEN(@Remaining)
                              AND SUBSTRING(@Remaining, @AfterBetweenHigh, 1) NOT IN (' ',CHAR(10),CHAR(13))
                                SET @AfterBetweenHigh = @AfterBetweenHigh + 1;
                            SET @AndIdx = CHARINDEX(' AND ', @Remaining, @AfterBetweenHigh);
                        END;
                    END;

                    -- Determine split point
                    IF @OrIdx>0 AND (@AndIdx=0 OR @OrIdx<@AndIdx)
                    BEGIN
                        SET @CondPart  = LTRIM(RTRIM(SUBSTRING(@Remaining,1,@OrIdx-1)));
                        SET @Remaining = SUBSTRING(@Remaining,@OrIdx+4,LEN(@Remaining));
                    END
                    ELSE IF @AndIdx>0
                    BEGIN
                        SET @CondPart  = LTRIM(RTRIM(SUBSTRING(@Remaining,1,@AndIdx-1)));
                        SET @Remaining = SUBSTRING(@Remaining,@AndIdx+5,LEN(@Remaining));
                    END
                    ELSE
                    BEGIN
                        SET @CondPart=LTRIM(RTRIM(@Remaining));
                        SET @Remaining='';
                    END;

                    -- Detect operator
                    SET @Op='=';
                    IF @CondPart LIKE '%BETWEEN%'   SET @Op='BETWEEN';
                    ELSE IF @CondPart LIKE '%LIKE%' SET @Op='LIKE';
                    ELSE IF @CondPart LIKE '% IN %' SET @Op='IN';
                    ELSE IF @CondPart LIKE '%>=%'   SET @Op='>=';
                    ELSE IF @CondPart LIKE '%<=%'   SET @Op='<=';
                    ELSE IF @CondPart LIKE '%<>%'   SET @Op='<>';
                    ELSE IF @CondPart LIKE '%>%'    SET @Op='>';
                    ELSE IF @CondPart LIKE '%<%'    SET @Op='<';

                    -- Parse LHS/RHS
                    SET @EqIdx=CHARINDEX('=',@CondPart);
                    IF @Op NOT IN ('=','<>','>=','<=') SET @EqIdx=0;

                    IF @EqIdx>0
                    BEGIN
                        SET @LHS=LTRIM(RTRIM(SUBSTRING(@CondPart,1,@EqIdx-1)));
                        SET @RHS=LTRIM(RTRIM(SUBSTRING(@CondPart,@EqIdx+1,LEN(@CondPart))));
                    END
                    ELSE
                    BEGIN
                        SET @LHS=LTRIM(RTRIM(SUBSTRING(@CondPart,1,
                            CASE @Op
                                WHEN 'BETWEEN' THEN CHARINDEX('BETWEEN',@CondPart)-1
                                WHEN 'LIKE'    THEN CHARINDEX('LIKE',@CondPart)-1
                                WHEN 'IN'      THEN CHARINDEX(' IN ',@CondPart)-1
                                WHEN '>='      THEN CHARINDEX('>=',@CondPart)-1
                                WHEN '<='      THEN CHARINDEX('<=',@CondPart)-1
                                WHEN '<>'      THEN CHARINDEX('<>',@CondPart)-1
                                WHEN '>'       THEN CHARINDEX('>',@CondPart)-1
                                WHEN '<'       THEN CHARINDEX('<',@CondPart)-1
                                ELSE LEN(@CondPart) END)));
                        SET @RHS=LTRIM(RTRIM(SUBSTRING(@CondPart,
                            CASE @Op
                                WHEN 'BETWEEN' THEN CHARINDEX('BETWEEN',@CondPart)+7
                                WHEN 'LIKE'    THEN CHARINDEX('LIKE',@CondPart)+4
                                WHEN 'IN'      THEN CHARINDEX(' IN ',@CondPart)+4
                                WHEN '>='      THEN CHARINDEX('>=',@CondPart)+2
                                WHEN '<='      THEN CHARINDEX('<=',@CondPart)+2
                                WHEN '<>'      THEN CHARINDEX('<>',@CondPart)+2
                                WHEN '>'       THEN CHARINDEX('>',@CondPart)+1
                                WHEN '<'       THEN CHARINDEX('<',@CondPart)+1
                                ELSE 1 END, LEN(@CondPart))));
                    END;

                    -- Strip newlines/carriage returns from both LHS and RHS immediately
                    SET @LHS = LTRIM(RTRIM(REPLACE(REPLACE(@LHS, CHAR(13),''), CHAR(10),'')));
                    SET @RHS = LTRIM(RTRIM(REPLACE(REPLACE(@RHS, CHAR(13),''), CHAR(10),'')));

                    -- Strip alias
                    -- v3.2: when the LHS has a `<alias>.<col>` form, look the
                    -- alias up in #Aliases (populated from FROM/JOIN above).
                    -- If found, set @ResolvedTbl to the joined table and
                    -- emit the condition against that table.  Previously
                    -- any non-primary alias caused the condition to be
                    -- dropped, which lost important JOIN conditions like
                    -- `st.CountryRegionCode = 'US'`.
                    SET @ResolvedTbl = @PrimaryTbl;
                    SET @LhsDateFunc = 0;
                    SET @ColName=REPLACE(REPLACE(@LHS,'[',''),']','');
                    -- v9.2.1 (GAP A): the LHS may be a function call such as
                    -- YEAR(OrderDate).  The old code dropped any such
                    -- condition (ColName=NULL), so the wrapped column was
                    -- never seeded and a predicate like
                    -- YEAR(OrderDate)=YEAR(GETDATE()) was always false.
                    -- Now: if FUNC is a single-arg date part (YEAR/MONTH/DAY)
                    -- and the RHS is a GETDATE-style expression, unwrap to the
                    -- inner column and flag it so the seed value below becomes
                    -- the current datetime.  Any other function still drops.
                    IF CHARINDEX('(',@ColName) > 0
                    BEGIN
                        SET @FuncOpenP  = CHARINDEX('(',@ColName);
                        SET @FuncCloseP = CHARINDEX(')',@ColName,@FuncOpenP);
                        IF @FuncCloseP = 0 SET @FuncCloseP = LEN(@ColName)+1;
                        SET @FuncName  = UPPER(LTRIM(RTRIM(LEFT(@ColName,@FuncOpenP-1))));
                        SET @InnerArg  = LTRIM(RTRIM(SUBSTRING(@ColName,@FuncOpenP+1,
                                                    @FuncCloseP-@FuncOpenP-1)));
                        IF @FuncName IN ('YEAR','MONTH','DAY')
                           AND ( CHARINDEX('GETDATE',UPPER(@RHS))>0
                              OR CHARINDEX('SYSDATETIME',UPPER(@RHS))>0
                              OR CHARINDEX('CURRENT_TIMESTAMP',UPPER(@RHS))>0 )
                           AND LEN(@InnerArg) > 0
                        BEGIN
                            -- unwrap; any alias is resolved by the block below
                            SET @ColName     = @InnerArg;
                            SET @LhsDateFunc = 1;
                        END
                        ELSE
                            SET @ColName = NULL;
                    END;
                    IF @ColName IS NOT NULL AND CHARINDEX('.',@ColName)>0
                    BEGIN
                        SET @AliasStr=SUBSTRING(@ColName,1,CHARINDEX('.',@ColName)-1);
                        SET @ColName=SUBSTRING(@ColName,CHARINDEX('.',@ColName)+1,500);

                        -- Look up alias in the map.  If found, use the
                        -- resolved table; if not, fall back to old behaviour
                        -- (drop the column if alias doesn't match primary).
                        IF EXISTS (SELECT 1 FROM #Aliases WHERE Alias = @AliasStr)
                        BEGIN
                            SELECT @ResolvedTbl = TableName FROM #Aliases WHERE Alias = @AliasStr;
                        END
                        ELSE IF LOWER(@AliasStr)<>LOWER(LEFT(ISNULL(@PrimaryTbl,''),1)) AND LEN(@AliasStr)<=3
                            SET @ColName=NULL;
                    END;

                    SET @ResolvedVal=NULL;

                    IF @Op='BETWEEN'
                    BEGIN
                        SET @BetAnd=CHARINDEX(' AND ',@RHS);
                        IF @BetAnd>0
                        BEGIN
                            SET @BetweenLow =LTRIM(RTRIM(REPLACE(REPLACE(SUBSTRING(@RHS,1,@BetAnd-1),CHAR(13),''),CHAR(10),'')));
                            SET @BetweenHigh=LTRIM(RTRIM(REPLACE(REPLACE(SUBSTRING(@RHS,@BetAnd+5,LEN(@RHS)),CHAR(13),''),CHAR(10),'')));
                            IF ISNUMERIC(@BetweenLow)=1 AND ISNUMERIC(@BetweenHigh)=1
                                SET @BetweenMid=CAST((CAST(@BetweenLow AS FLOAT)+CAST(@BetweenHigh AS FLOAT))/2 AS NVARCHAR(50));
                            ELSE
                                SET @BetweenMid=@BetweenLow;
                            SET @ResolvedVal=@BetweenMid;
                            SET @Op='>=';
                        END;
                    END
                    ELSE IF @Op='LIKE'
                    BEGIN
                        -- LIKE: extract the literal core of the pattern so we
                        -- can seed a value that the predicate will match.
                        --
                        -- v3.2: previously LIKE was skipped entirely (ColName
                        --       set to NULL), so the column was never seeded
                        --       and the predicate evaluated false at runtime.
                        --
                        -- We handle the common patterns:
                        --   '%foo%'   -> seed 'foo'
                        --   '%foo'    -> seed 'foo'        (suffix match)
                        --   'foo%'    -> seed 'foo'        (prefix match)
                        --   '_foo_'   -> seed 'Xfoo'+'X'   (single-char wildcards)
                        --   anything containing []         -> skip (too complex)
                        --
                        -- The truncation safety net at column-max-length below
                        -- still applies, but in practice these literals are
                        -- short.
                        SET @LikeVal = REPLACE(REPLACE(@RHS, CHAR(13), ''), CHAR(10), '');
                        SET @LikeVal = LTRIM(RTRIM(@LikeVal));
                        -- strip surrounding quotes if present (RHS was already
                        -- de-quoted at line 395 above for the non-Between path,
                        -- but defensively re-strip in case the path differs)
                        IF LEN(@LikeVal) >= 2 AND LEFT(@LikeVal,1) = N'''' AND RIGHT(@LikeVal,1) = N''''
                            SET @LikeVal = SUBSTRING(@LikeVal, 2, LEN(@LikeVal) - 2);

                        IF CHARINDEX('[', @LikeVal) > 0
                        BEGIN
                            -- character classes are too complex; fall back to skipping
                            SET @ResolvedVal = NULL;
                            SET @ColName     = NULL;
                        END
                        ELSE
                        BEGIN
                            -- Strip leading and trailing wildcards (% or _) to
                            -- get the literal core.
                            WHILE LEN(@LikeVal) > 0 AND LEFT(@LikeVal, 1) IN ('%', '_')
                                SET @LikeVal = SUBSTRING(@LikeVal, 2, LEN(@LikeVal));
                            WHILE LEN(@LikeVal) > 0 AND RIGHT(@LikeVal, 1) IN ('%', '_')
                                SET @LikeVal = LEFT(@LikeVal, LEN(@LikeVal) - 1);
                            -- If there are interior wildcards (e.g. 'foo%bar'),
                            -- just use the part before the first wildcard.
                            IF CHARINDEX('%', @LikeVal) > 0
                                SET @LikeVal = LEFT(@LikeVal, CHARINDEX('%', @LikeVal) - 1);
                            IF CHARINDEX('_', @LikeVal) > 0
                                SET @LikeVal = LEFT(@LikeVal, CHARINDEX('_', @LikeVal) - 1);

                            IF LEN(LTRIM(RTRIM(@LikeVal))) > 0
                            BEGIN
                                SET @ResolvedVal = LTRIM(RTRIM(@LikeVal));
                                SET @Op = '=';  -- downstream INSERT just uses equality
                            END
                            ELSE
                            BEGIN
                                -- Pattern was '%' or '%%' - matches anything;
                                -- seed any non-null value so predicate is true.
                                SET @ResolvedVal = N'X';
                                SET @Op = '=';
                            END;
                        END;
                    END
                    ELSE IF @Op='IN'
                    BEGIN
                        SET @InList=REPLACE(REPLACE(REPLACE(REPLACE(@RHS,'(',''),')',''),'''',''),CHAR(10),'');
                        WHILE LEN(LTRIM(RTRIM(@InList)))>0
                        BEGIN
                            SET @InComma=CHARINDEX(',',@InList);
                            IF @InComma>0
                            BEGIN
                                SET @InVal =LTRIM(RTRIM(SUBSTRING(@InList,1,@InComma-1)));
                                SET @InList=SUBSTRING(@InList,@InComma+1,LEN(@InList));
                            END
                            ELSE
                            BEGIN
                                SET @InVal=LTRIM(RTRIM(@InList));
                                SET @InList='';
                            END;
                            IF @ColName IS NOT NULL AND LEN(LTRIM(RTRIM(@InVal)))>0
                            BEGIN
                                INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                                VALUES (@CurPathID,'EXISTS_TRUE',@ResolvedTbl,@ColName,@InVal,'=',@QDepth,@QParent,NULL,NULL);
                                SET @CondCount=@CondCount+1;
                            END;
                        END;
                        SET @ColName=NULL;
                    END
                    ELSE
                    BEGIN
                        SET @RHS=REPLACE(REPLACE(REPLACE(@RHS,'''',''),CHAR(13),''),CHAR(10),'');
                        SET @RHS=LTRIM(RTRIM(@RHS));
                        -- v9.2.1 (GAP C): the old char-walk built @RHSClean
                        -- char-by-char and BROKE on the first space, which
                        -- truncated multi-word string values - e.g.
                        -- 'North America' became 'North'.  Just trim and
                        -- strip a single trailing ')' if one slipped in.
                        SET @RHS=LTRIM(RTRIM(@RHS));
                        IF RIGHT(@RHS,1)=')'
                            SET @RHS=LTRIM(RTRIM(LEFT(@RHS,LEN(@RHS)-1)));

                        IF LEFT(@RHS,1)='@'
                        BEGIN
                            SET @PRef=SUBSTRING(@RHS,2,LEN(@RHS));
                            IF @ArgList IS NOT NULL
                            BEGIN
                                SET @SearchStr='@'+@PRef+' = ';
                                SET @ArgPos=CHARINDEX(@SearchStr,@ArgList);
                                IF @ArgPos>0
                                BEGIN
                                    SET @ValStart=@ArgPos+LEN(@SearchStr);
                                    SET @ValStr=LTRIM(SUBSTRING(@ArgList,@ValStart,200));
                                    IF LEFT(@ValStr,1)=''''
                                    BEGIN
                                        SET @CQ=CHARINDEX('''',@ValStr,2);
                                        IF @CQ>0 SET @ResolvedVal=SUBSTRING(@ValStr,2,@CQ-2);
                                    END
                                    ELSE
                                    BEGIN
                                        SET @CP=CHARINDEX(',',@ValStr);
                                        IF @CP>0 SET @ResolvedVal=LTRIM(RTRIM(SUBSTRING(@ValStr,1,@CP-1)));
                                        ELSE     SET @ResolvedVal=LTRIM(RTRIM(@ValStr));
                                    END;
                                END;
                            END;
                        END
                        ELSE SET @ResolvedVal=@RHS;

                        IF @Op='>' AND ISNUMERIC(@ResolvedVal)=1
                            SET @ResolvedVal=CAST(CAST(@ResolvedVal AS FLOAT)+1 AS NVARCHAR(50));
                        IF @Op='<' AND ISNUMERIC(@ResolvedVal)=1
                            SET @ResolvedVal=CAST(CAST(@ResolvedVal AS FLOAT)-1 AS NVARCHAR(50));
                    END;

                    -- v9.2.1 (GAP A): for an unwrapped date-part column the
                    -- RHS was a GETDATE-style expression, not a literal; seed
                    -- the column with the current datetime so
                    -- YEAR(col)=YEAR(GETDATE()) holds at run time.
                    IF @LhsDateFunc = 1
                        -- style 120 ('yyyy-mm-dd hh:mi:ss', no fractional
                        -- seconds): a 7-digit-fraction literal can overflow a
                        -- plain datetime column; 120 is valid for datetime,
                        -- datetime2, smalldatetime and date alike.
                        SET @ResolvedVal = CONVERT(NVARCHAR(30), SYSDATETIME(), 120);

                    IF @ColName IS NOT NULL AND @ResolvedVal IS NOT NULL AND LEN(LTRIM(RTRIM(@ResolvedVal)))>0
                    BEGIN
                        INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                        VALUES (@CurPathID,'EXISTS_TRUE',@ResolvedTbl,@ColName,@ResolvedVal,@Op,@QDepth,@QParent,NULL,NULL);
                        SET @CondCount=@CondCount+1;
                    END;
                END; -- WHILE conditions

                IF @CondCount=0
                    INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                    VALUES (@CurPathID,'EXISTS_TRUE',@PrimaryTbl,NULL,NULL,NULL,@QDepth,@QParent,NULL,NULL);
            END
            ELSE IF @PrimaryTbl IS NOT NULL
                INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                VALUES (@CurPathID,'EXISTS_TRUE',@PrimaryTbl,NULL,NULL,NULL,@QDepth,@QParent,NULL,NULL);

            SET @NewPathID = @CurPathID;

            -- JOIN tables
            SET @JoinSearch=@SubqBlock; SET @JoinPos=CHARINDEX('JOIN',@JoinSearch);
            WHILE @JoinPos>0
            BEGIN
                SET @JTblStart=@JoinPos+4;
                WHILE @JTblStart<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@JTblStart,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @JTblStart=@JTblStart+1;
                SET @JTblEnd=@JTblStart;
                WHILE @JTblEnd<=LEN(@JoinSearch) AND SUBSTRING(@JoinSearch,@JTblEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @JTblEnd=@JTblEnd+1;
                SET @JTbl=SUBSTRING(@JoinSearch,@JTblStart,@JTblEnd-@JTblStart);
                SET @JTbl=REPLACE(REPLACE(@JTbl,'[',''),']','');
                IF CHARINDEX('.',@JTbl)>0 SET @JTbl=SUBSTRING(@JTbl,CHARINDEX('.',@JTbl)+1,500);
                IF LEN(LTRIM(RTRIM(ISNULL(@JTbl,''))))>0 AND ISNULL(@JTbl,'')<>ISNULL(@PrimaryTbl,'')
                  AND NOT EXISTS (SELECT 1 FROM #Paths WHERE ParentPathID=@QParent AND TableName=@JTbl AND PathType='EXISTS_TRUE')
                BEGIN
                    INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                    VALUES (@CurPathID,'EXISTS_TRUE',@JTbl,NULL,NULL,NULL,@QDepth,@QParent,NULL,NULL);
                END;
                SET @JoinSearch=SUBSTRING(@JoinSearch,@JTblEnd,LEN(@JoinSearch));
                SET @JoinPos=CHARINDEX('JOIN',@JoinSearch);
            END;

            -- ELSE detection
            -- v9.2: previously used CHARINDEX('ELSE', @AfterSubq) which returns
            -- the FIRST 'ELSE' anywhere in the next 800 chars - typically a
            -- nested ELSE inside the THEN block.  For an outer EXISTS with
            -- nested IF EXISTS in its THEN, this captured the INNER ELSE,
            -- meaning the OUTER EXISTS_FALSE row was never emitted and the
            -- ELSE-block-target table was wrong.
            -- Now: walk the chars after the subquery, track BEGIN/END depth.
            -- The OUTER ELSE is the keyword 'ELSE' at depth 0 after the THEN
            -- block's closing END.
            -- v9.2: walk after-subquery chars tracking BEGIN/END depth (vars declared at top)
            SET @AfterSubq = SUBSTRING(@QBlock, @SubqEnd+1, 4000);
            SET @ElsePos = 0;
            SET @AfterLen   = LEN(@AfterSubq);
            SET @AfterIdx   = 1;
            SET @AfterDepth = 0;
            SET @SeenBegin  = 0;
            WHILE @AfterIdx <= @AfterLen - 2
            BEGIN
                SET @AfterCh = SUBSTRING(@AfterSubq, @AfterIdx, 1);
                IF @AfterCh = '-' AND SUBSTRING(@AfterSubq, @AfterIdx, 2) = '--'
                BEGIN
                    -- skip to end-of-line
                    WHILE @AfterIdx <= @AfterLen AND SUBSTRING(@AfterSubq, @AfterIdx, 1) NOT IN (CHAR(10), CHAR(13))
                        SET @AfterIdx = @AfterIdx + 1;
                END
                ELSE IF @AfterCh = '''' -- skip string literal
                BEGIN
                    SET @AfterIdx = @AfterIdx + 1;
                    WHILE @AfterIdx <= @AfterLen AND SUBSTRING(@AfterSubq, @AfterIdx, 1) <> ''''
                        SET @AfterIdx = @AfterIdx + 1;
                    SET @AfterIdx = @AfterIdx + 1;
                END
                ELSE IF UPPER(SUBSTRING(@AfterSubq, @AfterIdx, 5)) = 'BEGIN'
                BEGIN
                    -- ensure word boundary
                    SET @AfterPrev = CASE WHEN @AfterIdx > 1 THEN SUBSTRING(@AfterSubq, @AfterIdx - 1, 1) ELSE ' ' END;
                    SET @AfterNext = SUBSTRING(@AfterSubq, @AfterIdx + 5, 1);
                    IF @AfterPrev NOT LIKE '[A-Za-z0-9_]' AND @AfterNext NOT LIKE '[A-Za-z0-9_]'
                    BEGIN
                        SET @AfterDepth = @AfterDepth + 1;
                        SET @SeenBegin  = 1;
                        SET @AfterIdx   = @AfterIdx + 5;
                    END
                    ELSE
                        SET @AfterIdx = @AfterIdx + 1;
                END
                ELSE IF UPPER(SUBSTRING(@AfterSubq, @AfterIdx, 3)) = 'END'
                BEGIN
                    SET @AfterPrev = CASE WHEN @AfterIdx > 1 THEN SUBSTRING(@AfterSubq, @AfterIdx - 1, 1) ELSE ' ' END;
                    SET @AfterNext = SUBSTRING(@AfterSubq, @AfterIdx + 3, 1);
                    IF @AfterPrev NOT LIKE '[A-Za-z0-9_]' AND @AfterNext NOT LIKE '[A-Za-z0-9_]'
                    BEGIN
                        SET @AfterDepth = @AfterDepth - 1;
                        SET @AfterIdx   = @AfterIdx + 3;
                    END
                    ELSE
                        SET @AfterIdx = @AfterIdx + 1;
                END
                ELSE IF @SeenBegin = 1 AND @AfterDepth = 0
                       AND UPPER(SUBSTRING(@AfterSubq, @AfterIdx, 4)) = 'ELSE'
                BEGIN
                    SET @AfterPrev = CASE WHEN @AfterIdx > 1 THEN SUBSTRING(@AfterSubq, @AfterIdx - 1, 1) ELSE ' ' END;
                    SET @AfterNext = SUBSTRING(@AfterSubq, @AfterIdx + 4, 1);
                    IF @AfterPrev NOT LIKE '[A-Za-z0-9_]' AND @AfterNext NOT LIKE '[A-Za-z0-9_]'
                    BEGIN
                        SET @ElsePos = @AfterIdx;
                        BREAK;
                    END;
                    SET @AfterIdx = @AfterIdx + 1;
                END
                ELSE
                    SET @AfterIdx = @AfterIdx + 1;
            END;

            IF @ElsePos > 0
            BEGIN
                SET @CharAfterElse=SUBSTRING(@AfterSubq,@ElsePos+4,1);
                IF @CharAfterElse IN (' ',CHAR(10),CHAR(13),CHAR(9))
                BEGIN
                    SET @ElseBlock=SUBSTRING(@AfterSubq,@ElsePos+4,800);
                    SET @ElseTable=NULL;
                    SET @ElseInsPos=CHARINDEX('INSERT',@ElseBlock);
                    SET @ElseUpdPos=CHARINDEX('UPDATE',@ElseBlock);
                    SET @ElseTblPos=0;
                    IF @ElseInsPos>0 AND (@ElseUpdPos=0 OR @ElseInsPos<@ElseUpdPos) SET @ElseTblPos=@ElseInsPos+6;
                    ELSE IF @ElseUpdPos>0 SET @ElseTblPos=@ElseUpdPos+6;
                    IF @ElseTblPos>0
                    BEGIN
                        WHILE @ElseTblPos<=LEN(@ElseBlock) AND SUBSTRING(@ElseBlock,@ElseTblPos,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                            SET @ElseTblPos=@ElseTblPos+1;
                        IF SUBSTRING(@ElseBlock,@ElseTblPos,4)='INTO'
                        BEGIN
                            SET @ElseTblPos=@ElseTblPos+4;
                            WHILE @ElseTblPos<=LEN(@ElseBlock) AND SUBSTRING(@ElseBlock,@ElseTblPos,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                                SET @ElseTblPos=@ElseTblPos+1;
                        END;
                        SET @ElseTblEnd=@ElseTblPos;
                        WHILE @ElseTblEnd<=LEN(@ElseBlock) AND SUBSTRING(@ElseBlock,@ElseTblEnd,1) NOT IN (' ',CHAR(9),CHAR(10),CHAR(13),'(')
                            SET @ElseTblEnd=@ElseTblEnd+1;
                        SET @ElseTable=LTRIM(RTRIM(SUBSTRING(@ElseBlock,@ElseTblPos,@ElseTblEnd-@ElseTblPos)));
                        SET @ElseTable=REPLACE(REPLACE(@ElseTable,'[',''),']','');
                        IF CHARINDEX('.',@ElseTable)>0 SET @ElseTable=SUBSTRING(@ElseTable,CHARINDEX('.',@ElseTable)+1,500);
                        IF LEN(LTRIM(RTRIM(ISNULL(@ElseTable,''))))=0 SET @ElseTable=NULL;
                    END;
                    SET @NextPathID = @NextPathID + 1;
                    SET @FalsePathID = @NextPathID;
                    -- v9.2: TableName for EXISTS_FALSE must be the EXISTS
                    -- subquery's PRIMARY table (what the test generator must
                    -- DELETE from to force the predicate FALSE).  Previously
                    -- this was @ElseTable (what the ELSE block writes to),
                    -- which was wrong - DELETing the wrong table left the
                    -- predicate's source table populated by FK-seed, so the
                    -- predicate stayed TRUE and the ELSE never fired.
                    -- AssertTable continues to point at @ElseTable because
                    -- that's what we measure for row growth in the assertion.
                    INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                    VALUES (@FalsePathID,'EXISTS_FALSE',@PrimaryTbl,NULL,NULL,NULL,@QDepth,@QParent,@ElseTable,'GREW');

                    -- v9.4: capture the ELSE body's leaf DML for the strong
                    -- snapshot-and-replay assertion.  Extract a properly
                    -- BOUNDED ELSE body first (the @ElseBlock used for nested
                    -- scanning is a fixed 800-char window and would let the
                    -- DML census see unrelated trailing code).
                    SET @EBStart = @ElsePos + 4;
                    WHILE @EBStart <= LEN(@AfterSubq)
                      AND SUBSTRING(@AfterSubq,@EBStart,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                        SET @EBStart = @EBStart + 1;
                    SET @ElseBodyB = NULL;
                    IF UPPER(SUBSTRING(@AfterSubq,@EBStart,5)) = 'BEGIN'
                    BEGIN
                        SET @EBDepth = 1; SET @EBPos = @EBStart + 5;
                        WHILE @EBDepth > 0 AND @EBPos < LEN(@AfterSubq)
                        BEGIN
                            IF SUBSTRING(@AfterSubq,@EBPos,5) = 'BEGIN' SET @EBDepth = @EBDepth + 1;
                            IF SUBSTRING(@AfterSubq,@EBPos,3) = 'END'
                               AND SUBSTRING(@AfterSubq,@EBPos+3,1) IN (' ',';',CHAR(9),CHAR(10),CHAR(13))
                                SET @EBDepth = @EBDepth - 1;
                            SET @EBPos = @EBPos + 1;
                        END;
                        SET @ElseBodyB = SUBSTRING(@AfterSubq,@EBStart,@EBPos-@EBStart+2);
                    END
                    ELSE
                    BEGIN
                        SET @EBPos = CHARINDEX(';',@AfterSubq,@EBStart);
                        IF @EBPos = 0 SET @EBPos = LEN(@AfterSubq);
                        SET @ElseBodyB = SUBSTRING(@AfterSubq,@EBStart,@EBPos-@EBStart+1);
                    END;
                    IF @ElseBodyB IS NOT NULL
                    BEGIN
                        SET @LeafKind = NULL; SET @LeafTbl = NULL; SET @LeafTxt = NULL;
                        EXEC TestGen.ExtractLeafDml
                             @BodyBlock = @ElseBodyB,
                             @DmlKind   = @LeafKind OUTPUT,
                             @DmlTable  = @LeafTbl  OUTPUT,
                             @DmlText   = @LeafTxt  OUTPUT;
                        IF @LeafKind IS NOT NULL
                            UPDATE #Paths
                            SET BodyDmlKind  = @LeafKind,
                                BodyDmlTable = @LeafTbl,
                                BodyDmlText  = @LeafTxt,
                                AssertType   = 'REPLAY'
                            WHERE PathID = @FalsePathID;
                    END;

                    -- Enqueue ELSE block for nested scanning
                    INSERT #Queue (Block,Depth,ParentPathID) VALUES (@ElseBlock,@QDepth+1,@FalsePathID);
                END;
            END;

            -- Enqueue TRUE block for nested scanning
            SET @TrueBlockStart=@SubqEnd+1;
            SET @TrueBlock=NULL;
            SET @TBPos=@TrueBlockStart;
            SET @TBBegin=CHARINDEX('BEGIN',@QBlock,@TBPos);
            IF @TBBegin>0 AND @TBBegin<@SubqEnd+200
            BEGIN
                SET @TBDepth=1; SET @TBPos=@TBBegin+5;
                WHILE @TBDepth>0 AND @TBPos<LEN(@QBlock)
                BEGIN
                    IF SUBSTRING(@QBlock,@TBPos,5)='BEGIN' SET @TBDepth=@TBDepth+1;
                    IF SUBSTRING(@QBlock,@TBPos,3)='END'
                       AND SUBSTRING(@QBlock,@TBPos+3,1) IN (' ',';',CHAR(10),CHAR(13))
                        SET @TBDepth=@TBDepth-1;
                    SET @TBPos=@TBPos+1;
                END;
                SET @TrueBlock=SUBSTRING(@QBlock,@TBBegin,@TBPos-@TBBegin);
            END;

            -- v9.4: capture the TRUE block's leaf DML for the strong
            -- (snapshot-and-replay) assertion.  This replaces the old
            -- AssertTable text-scan, whose UPDATE/INSERT search also matched
            -- those words inside -- comments (e.g. '-- Update based on ...'
            -- yielded AssertTable = 'based').  ExtractLeafDml strips comments
            -- first and only captures genuinely unconditional single-DML
            -- bodies; a compound TRUE block leaves BodyDml* NULL and the
            -- generator falls back to the weaker row-count assertion.
            IF @TrueBlock IS NOT NULL
            BEGIN
                SET @LeafKind = NULL; SET @LeafTbl = NULL; SET @LeafTxt = NULL;
                EXEC TestGen.ExtractLeafDml
                     @BodyBlock = @TrueBlock,
                     @DmlKind   = @LeafKind OUTPUT,
                     @DmlTable  = @LeafTbl  OUTPUT,
                     @DmlText   = @LeafTxt  OUTPUT;
                IF @LeafKind IS NOT NULL
                    UPDATE #Paths
                    SET BodyDmlKind  = @LeafKind,
                        BodyDmlTable = @LeafTbl,
                        BodyDmlText  = @LeafTxt,
                        AssertTable  = @LeafTbl,
                        AssertType   = 'REPLAY'
                    WHERE PathID = @NewPathID;
                -- Enqueue TRUE block
                IF LEN(LTRIM(RTRIM(@TrueBlock)))>10
                    INSERT #Queue (Block,Depth,ParentPathID) VALUES (@TrueBlock,@QDepth+1,@NewPathID);
            END;

            SET @ScanPos=@FoundPos+9;
        END; -- WHILE IF EXISTS

        -------------------------------------------------------------------
        -- 2B: Scan for CASE WHEN
        -------------------------------------------------------------------
        SET @ScanPos=1;
        WHILE @ScanPos<LEN(@QBlock)
        BEGIN
            SET @CasePos=CHARINDEX('CASE',@QBlock,@ScanPos);
            IF @CasePos=0 BREAK;

            SET @CaseEndPos=@CasePos; SET @CaseDepth=0;
            WHILE @CaseEndPos<LEN(@QBlock)
            BEGIN
                IF SUBSTRING(@QBlock,@CaseEndPos,4)='CASE' SET @CaseDepth=@CaseDepth+1;
                IF SUBSTRING(@QBlock,@CaseEndPos,3)='END'
                   AND SUBSTRING(@QBlock,@CaseEndPos+3,1) IN (' ',CHAR(10),CHAR(13),';')
                BEGIN
                    SET @CaseDepth=@CaseDepth-1;
                    IF @CaseDepth=0 BREAK;
                END;
                SET @CaseEndPos=@CaseEndPos+1;
            END;
            SET @CaseBlock=SUBSTRING(@QBlock,@CasePos,@CaseEndPos-@CasePos+3);

            -- Detect CASE variable
            SET @CaseVar=NULL;
            SET @CaseAfter=LTRIM(SUBSTRING(@QBlock,@CasePos+4,200));
            IF LEFT(@CaseAfter,4)<>'WHEN'
            BEGIN
                SET @CaseVarEnd=CHARINDEX('WHEN',@CaseAfter);
                IF @CaseVarEnd>0 SET @CaseVar=LTRIM(RTRIM(SUBSTRING(@CaseAfter,1,@CaseVarEnd-1)));
            END;

            -- Each WHEN value
            SET @CaseScan=1;
            WHILE @CaseScan<LEN(@CaseBlock)
            BEGIN
                SET @WhenPos=CHARINDEX('WHEN',@CaseBlock,@CaseScan);
                IF @WhenPos=0 BREAK;
                SET @ThenPos=CHARINDEX('THEN',@CaseBlock,@WhenPos);
                IF @ThenPos=0 BREAK;

                -- Extract WHEN value (between WHEN and THEN)
                SET @WhenVal=LTRIM(RTRIM(SUBSTRING(@CaseBlock,@WhenPos+4,@ThenPos-@WhenPos-4)));
                SET @WhenVal=REPLACE(REPLACE(REPLACE(@WhenVal,'''',''),CHAR(13),''),CHAR(10),'');
                SET @WhenVal=LTRIM(RTRIM(@WhenVal));

                IF LEN(@WhenVal)>0
                BEGIN
                    SET @CaseColClean = CAST(LEFT(LTRIM(RTRIM(ISNULL(@CaseVar,''))),128) AS SYSNAME);
                    SET @NextPathID = @NextPathID + 1;
                    INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                    VALUES (@NextPathID,'CASE_WHEN',NULL,@CaseColClean,@WhenVal,'=',@QDepth,@QParent,NULL,NULL);
                END;

                -- Advance past this THEN clause to find the next WHEN
                SET @NextWhen = CHARINDEX('WHEN', @CaseBlock, @ThenPos+4);
                IF @NextWhen > 0
                    SET @CaseScan = @NextWhen;
                ELSE
                    BREAK;
            END;

            -- CASE ELSE
            SET @CaseElsePos=CHARINDEX('ELSE',@CaseBlock);
            IF @CaseElsePos>0
            BEGIN
                SET @CharAE=SUBSTRING(@CaseBlock,@CaseElsePos+4,1);
                IF @CharAE IN (' ',CHAR(10),CHAR(13),CHAR(9))
                BEGIN
                    SET @CaseVarClean = CAST(LEFT(LTRIM(RTRIM(ISNULL(@CaseVar,''))),128) AS SYSNAME);
                    SET @NextPathID = @NextPathID + 1;
                    INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                    VALUES (@NextPathID,'CASE_ELSE',NULL,@CaseVarClean,NULL,NULL,@QDepth,@QParent,NULL,NULL);
                END;
            END;

            SET @ScanPos=@CaseEndPos+1;
        END; -- WHILE CASE

        -------------------------------------------------------------------
        -- 2C (v9.2.1): plain  IF @param = 'literal'  that has an ELSE.
        -- The framework already tests the TRUE side of such a branch; this
        -- emits an IF_ELSE path so the generator also tests the ELSE side
        -- (the proc run with @param <> literal).  ParentPathID = @QParent
        -- links it to the enclosing EXISTS, so the generator's ancestor-
        -- chain seeding makes the nested IF reachable.
        -------------------------------------------------------------------
        SET @ScanPos = 1;
        WHILE @ScanPos < LEN(@QBlock)
        BEGIN
            SET @IfPos = CHARINDEX('IF @', @QBlock, @ScanPos);
            IF @IfPos = 0 BREAK;
            SET @ScanPos = @IfPos + 3;

            -- parameter token after 'IF '
            SET @IfParamStart = @IfPos + 3;
            SET @IfParamEnd   = @IfParamStart;
            WHILE @IfParamEnd <= LEN(@QBlock)
              AND SUBSTRING(@QBlock,@IfParamEnd,1) LIKE '[A-Za-z0-9_@]'
                SET @IfParamEnd = @IfParamEnd + 1;
            SET @IfParam = SUBSTRING(@QBlock,@IfParamStart,@IfParamEnd-@IfParamStart);

            -- whitespace, then '='
            SET @IfEqPos = @IfParamEnd;
            WHILE @IfEqPos <= LEN(@QBlock)
              AND SUBSTRING(@QBlock,@IfEqPos,1) IN (' ',CHAR(9),CHAR(13),CHAR(10))
                SET @IfEqPos = @IfEqPos + 1;
            IF SUBSTRING(@QBlock,@IfEqPos,1) <> '=' CONTINUE;

            -- the quoted literal after '='
            SET @IfQ1 = CHARINDEX('''', @QBlock, @IfEqPos);
            IF @IfQ1 = 0 CONTINUE;
            SET @IfQ2 = CHARINDEX('''', @QBlock, @IfQ1 + 1);
            IF @IfQ2 <= @IfQ1 CONTINUE;
            SET @IfLit = SUBSTRING(@QBlock,@IfQ1+1,@IfQ2-@IfQ1-1);

            -- skip the branch's own header (IF @ParamName = @BranchValue)
            IF @IfParam = @ParamName AND @IfLit = @BranchValue CONTINUE;

            -- skip compound predicates (IF @x='a' AND/OR ...)
            SET @IfAfter = @IfQ2 + 1;
            WHILE @IfAfter <= LEN(@QBlock)
              AND SUBSTRING(@QBlock,@IfAfter,1) IN (' ',CHAR(9),CHAR(13),CHAR(10))
                SET @IfAfter = @IfAfter + 1;
            IF UPPER(SUBSTRING(@QBlock,@IfAfter,4)) = 'AND '
               OR UPPER(SUBSTRING(@QBlock,@IfAfter,3)) = 'OR ' CONTINUE;

            -- locate the end of the IF body
            IF UPPER(SUBSTRING(@QBlock,@IfAfter,5)) = 'BEGIN'
            BEGIN
                SET @IfDepth = 1;
                SET @IfAfter = @IfAfter + 5;
                WHILE @IfDepth > 0 AND @IfAfter < LEN(@QBlock)
                BEGIN
                    IF SUBSTRING(@QBlock,@IfAfter,5) = 'BEGIN' SET @IfDepth = @IfDepth + 1;
                    IF SUBSTRING(@QBlock,@IfAfter,3) = 'END'
                       AND SUBSTRING(@QBlock,@IfAfter+3,1) IN (' ',';',CHAR(9),CHAR(10),CHAR(13))
                        SET @IfDepth = @IfDepth - 1;
                    SET @IfAfter = @IfAfter + 1;
                END;
                SET @IfAfter = @IfAfter + 2;
            END
            ELSE
            BEGIN
                -- bare single-statement body: ends at the next ';'
                SET @IfAfter = CHARINDEX(';', @QBlock, @IfAfter);
                IF @IfAfter = 0 SET @IfAfter = LEN(@QBlock);
                SET @IfAfter = @IfAfter + 1;
            END;

            -- is the next keyword an ELSE?
            WHILE @IfAfter <= LEN(@QBlock)
              AND SUBSTRING(@QBlock,@IfAfter,1) IN (' ',CHAR(9),CHAR(13),CHAR(10))
                SET @IfAfter = @IfAfter + 1;
            IF UPPER(SUBSTRING(@QBlock,@IfAfter,4)) = 'ELSE'
               AND SUBSTRING(@QBlock,@IfAfter+4,1) IN (' ',CHAR(9),CHAR(13),CHAR(10),';')
            BEGIN
                SET @NextPathID = @NextPathID + 1;
                INSERT #Paths (PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType)
                VALUES (@NextPathID,'IF_ELSE',NULL,@IfParam,@IfLit,'=',@QDepth,@QParent,NULL,NULL);

                -- v9.4: capture the ELSE body's leaf DML for the strong
                -- snapshot-and-replay assertion (the IF_ELSE test exercises
                -- the ELSE side, so the replayed statement is the ELSE body).
                SET @EBStart = @IfAfter + 4;
                WHILE @EBStart <= LEN(@QBlock)
                  AND SUBSTRING(@QBlock,@EBStart,1) IN (' ',CHAR(9),CHAR(10),CHAR(13))
                    SET @EBStart = @EBStart + 1;
                SET @ElseBodyB = NULL;
                IF UPPER(SUBSTRING(@QBlock,@EBStart,5)) = 'BEGIN'
                BEGIN
                    SET @EBDepth = 1; SET @EBPos = @EBStart + 5;
                    WHILE @EBDepth > 0 AND @EBPos < LEN(@QBlock)
                    BEGIN
                        IF SUBSTRING(@QBlock,@EBPos,5) = 'BEGIN' SET @EBDepth = @EBDepth + 1;
                        IF SUBSTRING(@QBlock,@EBPos,3) = 'END'
                           AND SUBSTRING(@QBlock,@EBPos+3,1) IN (' ',';',CHAR(9),CHAR(10),CHAR(13))
                            SET @EBDepth = @EBDepth - 1;
                        SET @EBPos = @EBPos + 1;
                    END;
                    SET @ElseBodyB = SUBSTRING(@QBlock,@EBStart,@EBPos-@EBStart+2);
                END
                ELSE
                BEGIN
                    SET @EBPos = CHARINDEX(';',@QBlock,@EBStart);
                    IF @EBPos = 0 SET @EBPos = LEN(@QBlock);
                    SET @ElseBodyB = SUBSTRING(@QBlock,@EBStart,@EBPos-@EBStart+1);
                END;
                IF @ElseBodyB IS NOT NULL
                BEGIN
                    SET @LeafKind = NULL; SET @LeafTbl = NULL; SET @LeafTxt = NULL;
                    EXEC TestGen.ExtractLeafDml
                         @BodyBlock = @ElseBodyB,
                         @DmlKind   = @LeafKind OUTPUT,
                         @DmlTable  = @LeafTbl  OUTPUT,
                         @DmlText   = @LeafTxt  OUTPUT;
                    IF @LeafKind IS NOT NULL
                        UPDATE #Paths
                        SET BodyDmlKind  = @LeafKind,
                            BodyDmlTable = @LeafTbl,
                            BodyDmlText  = @LeafTxt,
                            AssertType   = 'REPLAY'
                        WHERE PathID = @NextPathID;
                END;
            END;
        END;

    END; -- WHILE Queue

    SELECT PathID,PathType,TableName,ColumnName,CondValue,Operator,Depth,ParentPathID,AssertTable,AssertType,
           BodyDmlKind,BodyDmlTable,BodyDmlText
    FROM   #Paths
    ORDER  BY Depth, PathID;

    DROP TABLE #Paths;
    DROP TABLE #Queue;
    DROP TABLE #Aliases;
END;
GO

PRINT 'TestGen.AnalyzeBranchPaths created (v3.2 / v9.4 - body-DML capture for strong assertions).';
GO
