/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License v3.0 as published
 * by the Free Software Foundation. See the LICENSE file at the repository
 * root for the full text, and COPYRIGHT for the author's notice.
 *
 * Distributed WITHOUT ANY WARRANTY, even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * A separate commercial licence (AGPL-free) is available from the copyright
 * holder. Contact: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

/*******************************************************************************
 * TestGen.InstrumentProcedure v5.3  (replaces v5.2)
 *
 * v5.3 NEW (vs v5.2):
 *   - A bare branch body with NO terminating ';' is now closed correctly.
 *     v5.1 wraps a bare (non-BEGIN) IF/WHILE/ELSE body in a synthetic
 *     BEGIN/END so the injected RecordCoverageHit stays inside the branch, but
 *     it only emitted the closing END when the body reached a ';'.  Semicolon-
 *     free bodies in the AdventureWorks house style - e.g. ufnGetStock's
 *     "IF (@ret IS NULL) SET @ret = 0" with no ';' - left the synthetic BEGIN
 *     open until a LATER ';' fired the END deep inside the next block, so the
 *     rebuilt _cov was unbalanced and FAILED TO COMPILE (Msg 102), reporting a
 *     false 0% coverage.  v5.3 closes the wrap at the structural token that
 *     actually ends a bare single-statement body: the next BEGIN/END block
 *     boundary or branch header (handled BEFORE the line is emitted), and the
 *     next statement opener on the no-';' boundary path.  Bodies that DO end
 *     with ';' instrument byte-identically to v5.2.  Verified on dbo.ufnGetStock
 *     (now 100% line + branch).
 *
 * v5.2 NEW (vs v5.1):
 *   - BEGIN TRY / BEGIN CATCH / END TRY / END CATCH are now recognised as
 *     STRUCTURAL keywords (like a bare BEGIN / END), not executable statements.
 *     Previously the walker treated "BEGIN TRY" as a normal statement that
 *     "opened" and waited for a ';' to terminate it.  The first body line of a
 *     TRY block is often a DECLARE (classified as noise) so the open-statement
 *     pointer stayed parked on BEGIN TRY; the next ';'-terminated line - e.g.
 *     EXECUTE(@SQL); - then closed that stale statement, so ITS coverage hit
 *     was misattributed to the BEGIN TRY line and the real line was registered
 *     IsExec=0.  "END TRY" likewise stranded the first statement of the CATCH
 *     block.  Now these four lines are classified IsExec=0 / IsBranch=0, and
 *     BEGIN TRY / BEGIN CATCH push a block marker (END TRY / END CATCH pop it
 *     via the existing END-keyword scan), so statements inside a TRY/CATCH are
 *     counted against their own lines.  A procedure body containing none of
 *     these four keywords is instrumented byte-identically to v5.1.
 *     NOTE: a multi-line statement with no terminating ';' (e.g. a DECLARE
 *     whose initializer wraps across lines) is still merged with the next
 *     statement - that is a line-walker limitation, not addressed here.
 *
 * v5.1 NEW (vs v5):
 *   - Bare (non-BEGIN/END) branch bodies are now wrapped in a synthetic
 *     BEGIN/END in _cov.  Previously "IF cond <stmt>; EXEC hit;" placed the
 *     injected RecordCoverageHit OUTSIDE the IF (the hit fired
 *     unconditionally), and "IF cond <stmt>; EXEC hit; ELSE ..." detached the
 *     ELSE entirely so _cov failed to compile (Msg 156, "Incorrect syntax
 *     near 'ELSE'").  Fix: when a branch body is a bare statement, emit a
 *     synthetic "BEGIN" before it and "END" after its hit.  See @StmtWrap.
 *
 * v5 NEW (vs v4.4):
 *   - Control-transfer statements (RETURN, THROW, RAISERROR, GOTO, BREAK,
 *     CONTINUE) get their RecordCoverageHit injected BEFORE the line instead
 *     of after.  Once control transfers, no after-statement injection can
 *     ever fire.  Previously these lines were marked IsExec=1 but unhittable,
 *     capping max coverage below 100%.
 *
 * v4.4 bug fix (vs v4.3):
 *   - The unconditional `SET @Body = @Body + ...` at the top of the cursor
 *     loop appended HEADER lines (CREATE PROCEDURE, params, AS) into the
 *     rebuilt body too.  The generated _cov proc therefore had its own
 *     CREATE PROCEDURE synthetic header followed by the ORIGINAL
 *     CREATE PROCEDURE inside its body - syntax error.  Now appends only
 *     when @IH = 0 (body lines only).
 *
 * v4.3 bug fix (vs v4.2):
 *   - LEN-trailing-spaces bug in paren counting.
 *
 * v4.2 bug fixes (vs v4.1):
 *   - Mid-loop `DECLARE @x = expr` initializers don't re-execute per
 *     iteration in T-SQL.  All loop-scoped variables now declared at
 *     proc top with SET assignments inside the loop.
 *
 * v4.1 bug fixes (vs v4):
 *   - STRING_SPLIT doesn't guarantee row order; replaced with deterministic
 *     CHARINDEX walk.
 *   - Tightened AS-boundary detector.
 *
 * Goal: registry and injected hits describe the SAME set of lines so the
 *       coverage ratio is meaningful.
 *
 * v3 problems (low coverage):
 *   - IsExec was set on every non-blank/non-comment line  -> denominator
 *     inflated with lines that could never be hit (continuations).
 *   - Hit was recorded at the ';'-terminator line, but the registry's
 *     executable line was usually a different (earlier) line  -> mismatched
 *     key, hit was orphaned.
 *   - Branch headers got their own IsExec=1 even though SQL Server does NOT
 *     fire sp_statement_completed for an IF predicate.
 *
 * v4 model:
 *   We walk the body once.  Per line we maintain:
 *     - @StmtStart   : start-line of the logical statement currently being
 *                      collected, or NULL between statements.
 *     - @ParenDepth  : (...) depth, so ';' inside a subquery doesn't terminate.
 *     - @PendingBody : we just saw an IF/ELSE/WHILE header and are waiting
 *                      for its body's first line.
 *     - @CtxStack    : a NVARCHAR(MAX) string of 'B' (BLOCK from BEGIN) and
 *                      'C' (CASE) markers.  Pushed on BEGIN / CASE keyword,
 *                      popped on END keyword.  Used to disambiguate ELSE
 *                      (inside CASE = not a branch) and to delay statement
 *                      termination (a ';' inside an open CASE doesn't end
 *                      the outer SET).
 *
 *   Classification per body line:
 *     blank / comment / pure BEGIN / pure END / pure END; / GO /
 *     SET NOCOUNT / DECLARE              -> IsExec=0, IsBranch=0
 *
 *     IF/WHILE always, ELSE when top-of-stack != 'C'
 *                                        -> IsBranch=1, IsExec=0,
 *                                           @PendingBody := 1
 *                                           (NO change to @StmtStart)
 *
 *     anything else:
 *       if @PendingBody and @ParenDepth > 0   -> continuation of IF predicate
 *       elif @PendingBody                     -> body's first line, IsExec=1,
 *                                                @StmtStart := this line,
 *                                                @PendingBody := 0
 *       elif @StmtStart IS NULL               -> new statement, IsExec=1,
 *                                                @StmtStart := this line
 *       else                                  -> continuation, IsExec=0
 *
 *   BEGIN closes @PendingBody (body about to start in this block) and pushes 'B'.
 *
 *   Termination:
 *     @StmtStart IS NOT NULL AND line trims to RTRIM-ends with ';'
 *     AND @ParenDepth-after == 0
 *     AND top-of-stack-after is NOT 'C'
 *       -> inject RecordCoverageHit at @StmtStart, clear @StmtStart.
 *
 *   Branch coverage in the report is then:
 *     "for each IsBranch=1 line, was the next IsExec=1 line at LineNum > B hit?"
 *   See TestGen.GetCoverageReport v2 (companion file).
 ******************************************************************************/

IF OBJECT_ID('TestGen.InstrumentProcedure','P') IS NOT NULL
    DROP PROCEDURE TestGen.InstrumentProcedure;
GO

CREATE PROCEDURE TestGen.InstrumentProcedure
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FullName   NVARCHAR(300) = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName);
    DECLARE @InstrName  SYSNAME       = @ProcName + '_cov';
    DECLARE @InstrFull  NVARCHAR(300) = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@InstrName);
    DECLARE @ProcSource NVARCHAR(MAX);
    DECLARE @CountDecl  BIT = 0;   -- flip to 1 if you want DECLAREs counted in the denominator

    SELECT @ProcSource = OBJECT_DEFINITION(OBJECT_ID(@FullName));
    IF @ProcSource IS NULL
    BEGIN
        RAISERROR('Procedure %s not found.', 16, 1, @FullName);
        RETURN;
    END;

    SET @ProcSource = REPLACE(@ProcSource, CHAR(13)+CHAR(10), CHAR(10));
    SET @ProcSource = REPLACE(@ProcSource, CHAR(13), CHAR(10));

    ---------------------------------------------------------------------------
    -- Split into lines, preserving order DETERMINISTICALLY.
    -- STRING_SPLIT does NOT guarantee row order, so we use a CHARINDEX walk.
    ---------------------------------------------------------------------------
    CREATE TABLE #Lines (
        LineNum  INT IDENTITY(1,1) PRIMARY KEY,
        LineText NVARCHAR(MAX) NULL,
        InHeader BIT NOT NULL DEFAULT 1
    );

    DECLARE @Pos      INT = 1;
    DECLARE @NlPos    INT;
    DECLARE @SrcLen   INT = LEN(@ProcSource);
    DECLARE @ChunkTxt NVARCHAR(MAX);

    -- Force trailing newline so the final line is captured by the loop.
    IF RIGHT(@ProcSource, 1) <> CHAR(10)
        SET @ProcSource = @ProcSource + CHAR(10);
    SET @SrcLen = LEN(@ProcSource);

    WHILE @Pos <= @SrcLen
    BEGIN
        SET @NlPos = CHARINDEX(CHAR(10), @ProcSource, @Pos);
        IF @NlPos = 0 SET @NlPos = @SrcLen + 1;
        SET @ChunkTxt = SUBSTRING(@ProcSource, @Pos, @NlPos - @Pos);
        INSERT #Lines (LineText) VALUES (@ChunkTxt);
        SET @Pos = @NlPos + 1;
    END;

    ---------------------------------------------------------------------------
    -- Find the AS-BEGIN boundary.  Be strict: an "AS" line is one whose
    -- trimmed text is exactly "AS" OR ends with " AS" (rare inline form).
    -- This avoids false matches on identifiers that happen to start with AS.
    ---------------------------------------------------------------------------
    DECLARE @BodyStart INT, @InlineBegin BIT = 0;
    SELECT TOP 1 @BodyStart = LineNum
    FROM   #Lines
    WHERE  UPPER(LTRIM(RTRIM(LineText))) = 'AS'
        OR UPPER(LTRIM(RTRIM(LineText))) LIKE '% AS'
        -- v9.4.3: also recognise "AS BEGIN" written on a single line.  The
        -- detector previously matched only a bare "AS" or "... AS", so a
        -- procedure whose body opened with "AS BEGIN" yielded @BodyStart = NULL,
        -- the whole procedure was treated as header, and the instrumented copy
        -- was emitted with an empty body (0 instrumented lines, plus a spurious
        -- "invokes its dependent procedures" failure - the empty copy calls
        -- nothing).
        OR UPPER(LTRIM(RTRIM(LineText))) = 'AS BEGIN'
        OR UPPER(LTRIM(RTRIM(LineText))) LIKE 'AS BEGIN[ ;]%'
    ORDER BY LineNum;

    IF @BodyStart IS NULL
    BEGIN
        -- Fallback: first line whose trimmed text starts with BEGIN at column 0.
        SELECT TOP 1 @BodyStart = LineNum
        FROM   #Lines
        WHERE  UPPER(LTRIM(RTRIM(LineText))) = 'BEGIN'
        ORDER BY LineNum;
        -- We treat the BEGIN line itself as inside the body, so InHeader=0 from this line on:
        IF @BodyStart IS NOT NULL
            SET @BodyStart = @BodyStart - 1;
    END;

    IF @BodyStart IS NOT NULL
        UPDATE #Lines SET InHeader = 0 WHERE LineNum > @BodyStart;

    -- v9.4.3: if the body STILL cannot be located, do NOT proceed.  Emitting an
    -- instrumented copy now would produce one with an EMPTY body (every line was
    -- treated as header) - silently dropping the procedure's code and making the
    -- coverage run report phantom pass/fail results.  Fail loudly and explicitly
    -- instead.  TestGen.AssessTestability runs the same body-locate check up
    -- front and normally classifies such a procedure NOT_TESTABLE before it ever
    -- reaches here; this guard covers a direct RunCoverage call past that gate.
    IF @BodyStart IS NULL
    BEGIN
        IF OBJECT_ID('tempdb..#Lines') IS NOT NULL DROP TABLE #Lines;
        DECLARE @v943BodyErr NVARCHAR(2000) =
            N'TestGen.InstrumentProcedure: could not locate the body of '
          + @SchemaName + N'.' + @ProcName
          + N' - no line marking the AS / BEGIN boundary (where the executable '
          + N'body begins) was found, so the procedure cannot be instrumented. '
          + N'This is a parser limitation in tSQLtAutoGen, NOT a defect in the '
          + N'procedure; please report this procedure''s header style to the '
          + N'tSQLtAutoGen maintainers as a bug.';
        RAISERROR(@v943BodyErr, 16, 1);
        RETURN;
    END;

    -- v9.4.3: when the body-start line is "AS BEGIN" on ONE line, the
    -- procedure's opening BEGIN sits on that (header) line and is NOT emitted
    -- into @Body - but the procedure's closing END still is.  That would leave
    -- the rebuilt _cov with one BEGIN and two ENDs, so it fails to compile.
    -- Flag it here; a compensating synthetic BEGIN is prepended to @Body after
    -- the build loop, restoring the same balanced shape a normal
    -- "AS" + separate-"BEGIN" procedure produces.
    IF EXISTS (SELECT 1 FROM #Lines
               WHERE LineNum = @BodyStart
                 AND UPPER(LTRIM(RTRIM(LineText))) IN (N'AS BEGIN', N'AS BEGIN;'))
        SET @InlineBegin = 1;

    ---------------------------------------------------------------------------
    -- Ensure registry tables exist.
    ---------------------------------------------------------------------------
    IF OBJECT_ID('TestGen.CoverageLines','U') IS NULL
        CREATE TABLE TestGen.CoverageLines (
            CoverageID  INT IDENTITY(1,1) PRIMARY KEY,
            SchemaName  SYSNAME NOT NULL,
            ProcName    SYSNAME NOT NULL,
            LineNum     INT NOT NULL,
            LineText    NVARCHAR(MAX) NOT NULL,
            IsExec      BIT NOT NULL DEFAULT 0,
            IsBranch    BIT NOT NULL DEFAULT 0,
            CreatedAt   DATETIME2 DEFAULT SYSDATETIME(),
            UNIQUE (SchemaName, ProcName, LineNum)
        );

    IF OBJECT_ID('TestGen.CoverageHits','U') IS NULL
    BEGIN
        CREATE TABLE TestGen.CoverageHits (
            HitID       INT IDENTITY(1,1) PRIMARY KEY,
            SchemaName  SYSNAME NOT NULL,
            ProcName    SYSNAME NOT NULL,
            LineNum     INT NOT NULL,
            HitAt       DATETIME2 DEFAULT SYSDATETIME()
        );
        CREATE INDEX IX_CovHits ON TestGen.CoverageHits(SchemaName,ProcName,LineNum);
    END;

    DELETE FROM TestGen.CoverageLines
    WHERE  SchemaName = @SchemaName AND ProcName = @ProcName;

    ---------------------------------------------------------------------------
    -- Pre-compute per-line static flags.
    ---------------------------------------------------------------------------
    DECLARE @Cls TABLE (
        LineNum         INT PRIMARY KEY,
        LineText        NVARCHAR(MAX),
        InHeader        BIT,
        IsBlank         BIT,
        IsComment       BIT,
        IsPureBegin     BIT,
        IsPureEnd       BIT,
        IsHdrIfWhile    BIT,    -- IF/WHILE branch header (always a branch when active)
        IsHdrElse       BIT,    -- ELSE branch header (only when not in CASE)
        IsNoise         BIT,
        IsTerminalStart BIT,    -- line starts with RETURN/THROW/RAISERROR/GOTO/BREAK/CONTINUE
        OpenParens      INT,
        CloseParens     INT,
        EndsWithSemi    BIT
    );

    INSERT @Cls
    SELECT
        l.LineNum,
        l.LineText,
        l.InHeader,
        CASE WHEN LEN(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 0 THEN 1 ELSE 0 END,
        CASE WHEN LTRIM(ISNULL(l.LineText,N'')) LIKE '--%' THEN 1 ELSE 0 END,
        -- v5.2: TRY/CATCH block keywords count as structural (pure BEGIN/END),
        -- never as executable statements.
        CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) IN ('BEGIN','BEGIN TRY','BEGIN CATCH') THEN 1 ELSE 0 END,
        CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) IN ('END','END;','END TRY','END TRY;','END CATCH','END CATCH;') THEN 1 ELSE 0 END,
        CASE WHEN UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'IF %'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'IF('
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'WHILE %'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'WHILE('
             THEN 1 ELSE 0 END,
        CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'ELSE'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'ELSE %'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'ELSE IF%'
             THEN 1 ELSE 0 END,
        CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'GO'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'SET NOCOUNT%'
                OR (@CountDecl = 0 AND UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'DECLARE %')
             THEN 1 ELSE 0 END,
        -- IsTerminalStart: line's first keyword transfers control unconditionally.
        -- For these, the hit MUST be injected BEFORE the line (after-line hits
        -- never fire because control has already transferred).
        CASE WHEN UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'RETURN%'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'THROW%'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'RAISERROR%'
                OR UPPER(LTRIM(ISNULL(l.LineText,N''))) LIKE 'GOTO %'
                OR UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'BREAK'
                OR UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'BREAK;'
                OR UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'CONTINUE'
                OR UPPER(LTRIM(RTRIM(ISNULL(l.LineText,N'')))) = 'CONTINUE;'
             THEN 1 ELSE 0 END,
        -- IMPORTANT: LEN() ignores trailing spaces, so counting parens via
        --   LEN(text) - LEN(REPLACE(text,'(',''))
        -- gives WRONG counts when the line ends with one or more spaces.
        -- Example: '        IF EXISTS ( '   LEN=19  REPLACE result LEN=17
        --          => "count = 2" but the real answer is 1.
        -- DATALENGTH counts bytes (including trailing spaces); divide by 2
        -- because LineText is NVARCHAR (2 bytes per character).
        (DATALENGTH(ISNULL(l.LineText,N''))
         - DATALENGTH(REPLACE(ISNULL(l.LineText,N''),N'(',N''))) / 2,
        (DATALENGTH(ISNULL(l.LineText,N''))
         - DATALENGTH(REPLACE(ISNULL(l.LineText,N''),N')',N''))) / 2,
        CASE WHEN RTRIM(ISNULL(l.LineText,N'')) LIKE '%;' THEN 1 ELSE 0 END
    FROM #Lines l;

    ---------------------------------------------------------------------------
    -- Walk and produce: registry rows + the instrumented body.
    ---------------------------------------------------------------------------
    DECLARE @Body       NVARCHAR(MAX) = N'';
    DECLARE @StmtStart  INT           = NULL;
    DECLARE @ParenDepth INT           = 0;
    DECLARE @Pending    BIT           = 0;       -- waiting for branch body to start
    DECLARE @CtxStack   NVARCHAR(MAX) = N'';     -- 'B' = BEGIN block, 'C' = CASE expr

    DECLARE @LN INT, @LT NVARCHAR(MAX), @IH BIT;
    DECLARE @Blank BIT, @Cmnt BIT, @PB BIT, @PE BIT, @HdrIW BIT, @HdrElse BIT, @Noise BIT;
    DECLARE @Terminal BIT;          -- IsTerminalStart for current line
    DECLARE @StmtIsTerminal BIT = 0; -- the current OPEN statement is terminal
    DECLARE @StmtWrap       BIT = 0; -- current OPEN statement is a BARE branch
                                     -- body needing a synthetic BEGIN/END wrap
    DECLARE @Op INT, @Cp INT, @Semi BIT;
    DECLARE @InCaseBefore BIT;
    DECLARE @DepthAfter INT;
    DECLARE @RegIsExec BIT, @RegIsBranch BIT;
    DECLARE @i INT, @kw NVARCHAR(20);
    DECLARE @Scrub NVARCHAR(MAX);   -- LineText with line-comment stripped for keyword scan
    DECLARE @CommentPos INT;
    -- v10.0.4: multi-statement state machine locals
    DECLARE @OpenStmt      VARCHAR(10);    -- SELECT/INSERT/UPDATE/DELETE/MERGE/WITH/SETVAR/DECLARE/EXEC/SIMPLE/NULL
    DECLARE @InsertMode    VARCHAR(10);    -- HEADER/VALUES/SELECT/EXEC when @OpenStmt='INSERT'
    DECLARE @UnionPending  BIT;            -- prior line ended with set operator (UNION/EXCEPT/INTERSECT)
    DECLARE @FirstWord     NVARCHAR(50);   -- first significant token of current line, uppercase
    DECLARE @LineHasSetOp  BIT;            -- current line contains UNION/EXCEPT/INTERSECT
    DECLARE @IsContinuation BIT;           -- per-line lookup result
    DECLARE @PatPos        INT;            -- scratch for PATINDEX
    DECLARE @Trimmed       NVARCHAR(MAX);  -- v10.0.5: UPPER-LTRIM of @LT, hoisted out of loop body
    DECLARE @StringOpen    BIT;            -- v10.0.7: we are inside a single-quoted string literal
    DECLARE @BlockCmtOpen  BIT;            -- v10.0.8: we are inside a /* ... */ block comment
    DECLARE @BracketDepth  INT;            -- v10.0.8: net depth of [...] quoted identifiers
    DECLARE @DQuoteOpen    BIT;            -- v10.0.8: we are inside a "..." quoted identifier
    DECLARE @BCScan        NVARCHAR(MAX);  -- v10.0.8: scratch for block-comment scan
    DECLARE @BCPos         INT;            -- v10.0.8: scratch for block-comment scan
    DECLARE @BCState       BIT;            -- v10.0.8: scratch for block-comment scan
    DECLARE @BracketDelta  INT;            -- v10.0.8: per-line bracket net delta
    -- Static continuation keyword sets (pipe-delimited for CHARINDEX lookup)
    DECLARE @ContSelect    NVARCHAR(400) = N'|FROM|WHERE|GROUP|HAVING|ORDER|UNION|EXCEPT|INTERSECT|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|APPLY|ON|AND|OR|NOT|OPTION|FOR|INTO|OUTPUT|';
    DECLARE @ContInsertHdr NVARCHAR(200) = N'|INTO|SELECT|VALUES|DEFAULT|EXEC|EXECUTE|OUTPUT|OPTION|WITH|';
    DECLARE @ContInsertVal NVARCHAR(100) = N'|OUTPUT|OPTION|INTO|';
    DECLARE @ContInsertExe NVARCHAR(100) = N'|OUTPUT|OPTION|';
    DECLARE @ContUpdate    NVARCHAR(400) = N'|SET|FROM|WHERE|OUTPUT|OPTION|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|APPLY|ON|AND|OR|NOT|';
    DECLARE @ContDelete    NVARCHAR(400) = N'|FROM|WHERE|OUTPUT|OPTION|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|APPLY|ON|AND|OR|NOT|';
    DECLARE @ContMerge     NVARCHAR(400) = N'|INTO|USING|ON|WHEN|MATCHED|NOT|AND|OR|THEN|INSERT|UPDATE|DELETE|VALUES|SET|OUTPUT|OPTION|BY|SOURCE|TARGET|';
    DECLARE @ContWith      NVARCHAR(400) = N'|AS|SELECT|INSERT|UPDATE|DELETE|MERGE|FROM|WHERE|GROUP|HAVING|ORDER|UNION|EXCEPT|INTERSECT|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|APPLY|ON|AND|OR|NOT|OPTION|FOR|OUTPUT|';
    -- v10.0.8: continuation table for DECLARE state.  Handles
    --   DECLARE c CURSOR LOCAL FORWARD_ONLY FOR
    --   SELECT ... FROM ... WHERE ...
    -- where the SELECT body lives on subsequent lines.  Superset
    -- of cursor-attribute keywords plus all SELECT continuation
    -- keywords so the SELECT body matches naturally.
    DECLARE @ContDeclare   NVARCHAR(800) = N'|CURSOR|LOCAL|GLOBAL|FORWARD_ONLY|SCROLL|STATIC|KEYSET|DYNAMIC|FAST_FORWARD|READ_ONLY|SCROLL_LOCKS|OPTIMISTIC|TYPE_WARNING|FOR|SELECT|UPDATE|OF|FROM|WHERE|GROUP|HAVING|ORDER|UNION|EXCEPT|INTERSECT|JOIN|INNER|LEFT|RIGHT|FULL|CROSS|OUTER|APPLY|ON|AND|OR|NOT|OPTION|INTO|OUTPUT|';
    -- v10.0.6: only fire a boundary when @FirstWord is a RECOGNISED opener.
    -- Cursor keywords (FETCH/OPEN/CLOSE/DEALLOCATE), DDL inside dynamic SQL,
    -- and anything else outside this list defaults to continuation - same
    -- behaviour as v10.0.3 for those lines.
    -- v10.0.8: extended with DDL verbs (CREATE/ALTER/DROP/GRANT/
    -- REVOKE/DENY) and cursor verbs (OPEN/FETCH/CLOSE/DEALLOCATE).
    -- Previously these defaulted to continuation, causing them to
    -- merge into the prior statement's IsExec row.
    DECLARE @StmtOpeners   NVARCHAR(600) = N'|SELECT|INSERT|UPDATE|DELETE|MERGE|WITH|SET|DECLARE|EXEC|EXECUTE|PRINT|RETURN|RAISERROR|THROW|BREAK|CONTINUE|GOTO|COMMIT|ROLLBACK|WAITFOR|TRUNCATE|CREATE|ALTER|DROP|GRANT|REVOKE|DENY|OPEN|FETCH|CLOSE|DEALLOCATE|';
    -- IMPORTANT: T-SQL evaluates `DECLARE @x = expr` initializers ONLY ONCE at
    -- batch parse time, not per iteration of an enclosing loop.  All loop-
    -- scoped working variables must be declared here and assigned with SET
    -- inside the loop, otherwise values leak across iterations.
    DECLARE @IsBranchHeader BIT;
    DECLARE @InCaseAfter    BIT;
    DECLARE @ScanPos        INT;
    DECLARE @ScanLen        INT;
    DECLARE @ChNext         NCHAR(1);
    DECLARE @ChPrev         NCHAR(1);
    DECLARE @HitText        NVARCHAR(MAX); -- the RecordCoverageHit text to emit
    DECLARE @LineToWrite    NVARCHAR(MAX); -- the body chunk for this iteration

    DECLARE wcur CURSOR LOCAL FAST_FORWARD FOR
        SELECT LineNum, LineText, InHeader,
               IsBlank, IsComment, IsPureBegin, IsPureEnd, IsHdrIfWhile, IsHdrElse,
               IsNoise, IsTerminalStart,
               OpenParens, CloseParens, EndsWithSemi
        FROM   @Cls
        ORDER BY LineNum;
    -- v10.0.4: initialise state machine before cursor walk
    SET @OpenStmt     = NULL;
    SET @InsertMode   = NULL;
    SET @UnionPending = 0;
    SET @StringOpen   = 0;          -- v10.0.7
    SET @BlockCmtOpen = 0;          -- v10.0.8
    SET @BracketDepth = 0;          -- v10.0.8
    SET @DQuoteOpen   = 0;          -- v10.0.8

    OPEN wcur;
    FETCH NEXT FROM wcur INTO @LN, @LT, @IH,
        @Blank, @Cmnt, @PB, @PE, @HdrIW, @HdrElse, @Noise, @Terminal,
        @Op, @Cp, @Semi;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @IH = 0
        BEGIN
            SET @InCaseBefore = CASE WHEN LEN(@CtxStack) > 0
                                       AND SUBSTRING(@CtxStack, LEN(@CtxStack), 1) = 'C'
                                     THEN 1 ELSE 0 END;
            SET @DepthAfter   = @ParenDepth + @Op - @Cp;
            SET @RegIsExec    = 0;
            SET @RegIsBranch  = 0;

            -- v10.0.4: extract the leading keyword of this line and flag whether
            -- the line contains a set operator (for UNION'd SELECT continuation).
            SET @FirstWord = N'';
            IF @Blank = 0 AND @Cmnt = 0 AND @PB = 0 AND @PE = 0 AND @Noise = 0
            BEGIN
                SET @Trimmed = UPPER(LTRIM(ISNULL(@LT,N'')));
                SET @PatPos = PATINDEX(N'%[^A-Z_]%', @Trimmed);
                IF @PatPos = 0
                    SET @FirstWord = @Trimmed;
                ELSE
                    SET @FirstWord = LEFT(@Trimmed, @PatPos - 1);
            END;
            SET @LineHasSetOp =
                CASE WHEN UPPER(N' ' + ISNULL(@LT,N'') + N' ') LIKE N'% UNION %'
                       OR UPPER(N' ' + ISNULL(@LT,N'') + N' ') LIKE N'% EXCEPT %'
                       OR UPPER(N' ' + ISNULL(@LT,N'') + N' ') LIKE N'% INTERSECT %'
                     THEN 1 ELSE 0 END;

            -- v10.0.7: track single-quote-delimited string literal state across
            -- lines.  Count single quotes on the line; odd parity means we
            -- crossed a string boundary.  Naive count handles SQL's '' escape
            -- (two quotes => no toggle) correctly.  Keywords inside an open
            -- string literal (e.g. SET @SQL = N'WITH ... RETURN ...') must
            -- NOT trigger boundary detection.
            IF ((LEN(ISNULL(@LT,N'')) - LEN(REPLACE(ISNULL(@LT,N''), N'''', N''))) % 2) = 1
                SET @StringOpen = 1 - @StringOpen;

            -- Determine if this line acts as a branch header.
            -- IF/WHILE always; ELSE only when not inside a CASE.
            SET @IsBranchHeader = CASE
                WHEN @Blank = 1 OR @Cmnt = 1 THEN 0
                WHEN @HdrIW = 1 THEN 1
                WHEN @HdrElse = 1 AND @InCaseBefore = 0 THEN 1
                ELSE 0
            END;

            -- v5.3: close an open bare-branch wrap whose statement never reached a
            -- ';'.  A bare branch body is a single statement, so the next structural
            -- token - a BEGIN/END block boundary or a new branch header - ENDS it.
            -- Inject the pending hit and the matching synthetic END here, BEFORE this
            -- line is emitted, so the wrap stays balanced and _cov compiles.
            -- Without this, semicolon-free AdventureWorks bodies (e.g. ufnGetStock's
            -- "IF (@ret IS NULL) SET @ret = 0" with no ';') left the wrap open until
            -- a later ';' fired the END inside the next block -> Msg 102.
            IF @StmtWrap = 1 AND @StmtStart IS NOT NULL AND @StmtStart <> @LN
               AND (@PB = 1 OR @PE = 1 OR @IsBranchHeader = 1)
            BEGIN
                SET @Body = @Body
                    + N'    EXEC TestGen.RecordCoverageHit '''
                    + REPLACE(@SchemaName,'''','''''') + N''','''
                    + REPLACE(@ProcName  ,'''','''''') + N''','
                    + CAST(@StmtStart AS NVARCHAR(10)) + N';' + CHAR(10)
                    + N'    END' + CHAR(10);
                SET @StmtStart      = NULL;
                SET @StmtWrap       = 0;
                SET @StmtIsTerminal = 0;
                SET @OpenStmt       = NULL;
                SET @InsertMode     = NULL;
            END;

            IF @Blank = 0 AND @Cmnt = 0 AND @PB = 0 AND @PE = 0 AND @Noise = 0
            BEGIN
                IF @IsBranchHeader = 1
                BEGIN
                    SET @RegIsBranch = 1;
                    SET @Pending     = 1;
                    -- do NOT touch @StmtStart
                END
                ELSE
                BEGIN
                    IF @Pending = 1
                    BEGIN
                        IF @ParenDepth > 0
                        BEGIN
                            -- continuation of the IF/WHILE predicate
                            SET @RegIsExec = 0;
                        END
                        ELSE
                        BEGIN
                            SET @Pending = 0;
                            IF @StmtStart IS NULL
                            BEGIN
                                SET @RegIsExec  = 1;
                                SET @StmtStart  = @LN;
                                -- Remember whether the OPEN statement is a
                                -- control-transfer (RETURN/THROW/...).  This
                                -- decides whether the hit injection sits
                                -- BEFORE the line or AFTER it.
                                SET @StmtIsTerminal = @Terminal;
                                -- This statement is a branch (IF/WHILE/ELSE)
                                -- body reached with @Pending still 1, i.e. it
                                -- was NOT opened by a BEGIN (the BEGIN handler
                                -- clears @Pending first).  So it is a BARE
                                -- single-statement body: flag it so the
                                -- emitter wraps it in a synthetic BEGIN/END,
                                -- keeping the injected hit inside the branch.
                                SET @StmtWrap = 1;
                                -- v10.0.4: also set @OpenStmt for bare-branch body
                                SET @OpenStmt = CASE @FirstWord
                                    WHEN N'SELECT'   THEN N'SELECT'
                                    WHEN N'INSERT'   THEN N'INSERT'
                                    WHEN N'UPDATE'   THEN N'UPDATE'
                                    WHEN N'DELETE'   THEN N'DELETE'
                                    WHEN N'MERGE'    THEN N'MERGE'
                                    WHEN N'WITH'     THEN N'WITH'
                                    WHEN N'SET'      THEN CASE WHEN UPPER(LTRIM(ISNULL(@LT,N''))) LIKE N'SET @%' THEN N'SETVAR' ELSE NULL END
                                    WHEN N'DECLARE'  THEN N'DECLARE'
                                    WHEN N'EXEC'     THEN N'EXEC'
                                    WHEN N'EXECUTE'  THEN N'EXEC'
                                    WHEN N'PRINT'    THEN N'SIMPLE'
                                    WHEN N'RETURN'   THEN N'SIMPLE'
                                    WHEN N'RAISERROR' THEN N'SIMPLE'
                                    WHEN N'THROW'    THEN N'SIMPLE'
                                    WHEN N'BREAK'    THEN N'SIMPLE'
                                    WHEN N'CONTINUE' THEN N'SIMPLE'
                                    WHEN N'GOTO'     THEN N'SIMPLE'
                                    WHEN N'COMMIT'   THEN N'SIMPLE'
                                    WHEN N'ROLLBACK' THEN N'SIMPLE'
                                    WHEN N'WAITFOR'  THEN N'SIMPLE'
                                    WHEN N'TRUNCATE' THEN N'SIMPLE'
                                    -- v10.0.8: DDL + cursor verbs
                                    WHEN N'CREATE'   THEN N'SIMPLE'
                                    WHEN N'ALTER'    THEN N'SIMPLE'
                                    WHEN N'DROP'     THEN N'SIMPLE'
                                    WHEN N'GRANT'    THEN N'SIMPLE'
                                    WHEN N'REVOKE'   THEN N'SIMPLE'
                                    WHEN N'DENY'     THEN N'SIMPLE'
                                    WHEN N'OPEN'     THEN N'SIMPLE'
                                    WHEN N'FETCH'    THEN N'SIMPLE'
                                    WHEN N'CLOSE'    THEN N'SIMPLE'
                                    WHEN N'DEALLOCATE' THEN N'SIMPLE'
                                    ELSE NULL
                                END;
                                IF @OpenStmt = N'INSERT'
                                    SET @InsertMode = N'HEADER';
                            END;
                        END;
                    END
                    ELSE
                    BEGIN
                        /* v10.0.4: multi-statement state machine.
                           Decide whether this line continues @OpenStmt or
                           opens a new statement.  Paren-depth gate + per-
                           state continuation lookup, with sub-state for
                           INSERT (HEADER/VALUES/SELECT/EXEC) and tracking
                           of UNION/EXCEPT/INTERSECT for set-op'd SELECT. */
                        SET @IsContinuation =
                            CASE
                                WHEN @ParenDepth > 0 THEN 1
                                WHEN @StmtStart IS NULL THEN 0
                                WHEN @FirstWord = N'' THEN 1
                                -- SELECT state
                                WHEN @OpenStmt = N'SELECT' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContSelect) > 0 THEN 1
                                WHEN @OpenStmt = N'SELECT' AND @FirstWord = N'SELECT' AND @UnionPending = 1 THEN 1
                                -- INSERT state - HEADER mode
                                WHEN @OpenStmt = N'INSERT' AND @InsertMode = N'HEADER' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContInsertHdr) > 0 THEN 1
                                -- INSERT state - SELECT mode (post-SELECT, body of INSERT...SELECT)
                                WHEN @OpenStmt = N'INSERT' AND @InsertMode = N'SELECT' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContSelect) > 0 THEN 1
                                WHEN @OpenStmt = N'INSERT' AND @InsertMode = N'SELECT' AND @FirstWord = N'SELECT' AND @UnionPending = 1 THEN 1
                                -- INSERT state - VALUES mode (post-VALUES)
                                WHEN @OpenStmt = N'INSERT' AND @InsertMode = N'VALUES' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContInsertVal) > 0 THEN 1
                                -- INSERT state - EXEC mode (post-EXEC)
                                WHEN @OpenStmt = N'INSERT' AND @InsertMode = N'EXEC' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContInsertExe) > 0 THEN 1
                                -- UPDATE state
                                WHEN @OpenStmt = N'UPDATE' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContUpdate) > 0 THEN 1
                                -- DELETE state
                                WHEN @OpenStmt = N'DELETE' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContDelete) > 0 THEN 1
                                -- MERGE state
                                WHEN @OpenStmt = N'MERGE' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContMerge) > 0 THEN 1
                                -- WITH state (CTE)
                                WHEN @OpenStmt = N'WITH' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContWith) > 0 THEN 1
                                WHEN @OpenStmt = N'WITH' AND @FirstWord = N'SELECT' AND @UnionPending = 1 THEN 1
                                -- v10.0.8: DECLARE state (covers DECLARE c CURSOR FOR <SELECT> across lines)
                                WHEN @OpenStmt = N'DECLARE' AND CHARINDEX(N'|' + @FirstWord + N'|', @ContDeclare) > 0 THEN 1
                                ELSE 0
                            END;

                        -- Boundary: prior statement ends here without ';' and
                        -- this line opens a new one.  v10.0.6: only fire on
                        -- recognised opener keywords; unknown keywords default
                        -- to continuation, same as v10.0.3 baseline.
                        -- v10.0.7: also require we are NOT inside an open
                        -- string literal (keywords inside SET @SQL = N'...'
                        -- multi-line strings must not trigger boundaries).
                        -- v10.0.8: additionally require we are NOT inside
                        -- an open /* ... */ block comment, a [...] quoted
                        -- identifier, or a "..." quoted identifier.  All
                        -- three can carry SQL-looking keywords that must
                        -- NOT trigger boundary detection.
                        IF @StmtStart IS NOT NULL
                           AND @StmtStart <> @LN
                           AND @ParenDepth = 0
                           AND @StringOpen = 0
                           AND @BlockCmtOpen = 0
                           AND @BracketDepth = 0
                           AND @DQuoteOpen = 0
                           AND @IsContinuation = 0
                           AND @FirstWord <> N''
                           AND CHARINDEX(N'|' + @FirstWord + N'|', @StmtOpeners) > 0
                        BEGIN
                            SET @Body = @Body + N'    EXEC TestGen.RecordCoverageHit '''
                                + REPLACE(@SchemaName,'''','''''') + N''','''
                                + REPLACE(@ProcName  ,'''','''''') + N''','
                                + CAST(@StmtStart AS NVARCHAR(10)) + N';' + CHAR(10);
                            -- v5.3: if the statement that just ended (without ';') was
                            -- a synthetic-wrapped bare branch body, close its wrap now.
                            IF @StmtWrap = 1
                            BEGIN
                                SET @Body = @Body + N'    END' + CHAR(10);
                                SET @StmtWrap = 0;
                            END;
                            SET @StmtStart      = NULL;
                            SET @StmtIsTerminal = 0;
                            SET @OpenStmt       = NULL;
                            SET @InsertMode     = NULL;
                        END;

                        -- Open a new statement if none open.
                        IF @StmtStart IS NULL
                        BEGIN
                            SET @RegIsExec = 1;
                            SET @StmtStart = @LN;
                            SET @StmtIsTerminal = @Terminal;
                            -- Transition @OpenStmt
                            SET @OpenStmt = CASE @FirstWord
                                WHEN N'SELECT'   THEN N'SELECT'
                                WHEN N'INSERT'   THEN N'INSERT'
                                WHEN N'UPDATE'   THEN N'UPDATE'
                                WHEN N'DELETE'   THEN N'DELETE'
                                WHEN N'MERGE'    THEN N'MERGE'
                                WHEN N'WITH'     THEN N'WITH'
                                WHEN N'SET'      THEN CASE WHEN UPPER(LTRIM(ISNULL(@LT,N''))) LIKE N'SET @%' THEN N'SETVAR' ELSE NULL END
                                WHEN N'DECLARE'  THEN N'DECLARE'
                                WHEN N'EXEC'     THEN N'EXEC'
                                WHEN N'EXECUTE'  THEN N'EXEC'
                                WHEN N'PRINT'    THEN N'SIMPLE'
                                WHEN N'RETURN'   THEN N'SIMPLE'
                                WHEN N'RAISERROR' THEN N'SIMPLE'
                                WHEN N'THROW'    THEN N'SIMPLE'
                                WHEN N'BREAK'    THEN N'SIMPLE'
                                WHEN N'CONTINUE' THEN N'SIMPLE'
                                WHEN N'GOTO'     THEN N'SIMPLE'
                                WHEN N'COMMIT'   THEN N'SIMPLE'
                                WHEN N'ROLLBACK' THEN N'SIMPLE'
                                WHEN N'WAITFOR'  THEN N'SIMPLE'
                                WHEN N'TRUNCATE' THEN N'SIMPLE'
                                -- v10.0.8: DDL + cursor verbs
                                WHEN N'CREATE'   THEN N'SIMPLE'
                                WHEN N'ALTER'    THEN N'SIMPLE'
                                WHEN N'DROP'     THEN N'SIMPLE'
                                WHEN N'GRANT'    THEN N'SIMPLE'
                                WHEN N'REVOKE'   THEN N'SIMPLE'
                                WHEN N'DENY'     THEN N'SIMPLE'
                                WHEN N'OPEN'     THEN N'SIMPLE'
                                WHEN N'FETCH'    THEN N'SIMPLE'
                                WHEN N'CLOSE'    THEN N'SIMPLE'
                                WHEN N'DEALLOCATE' THEN N'SIMPLE'
                                ELSE NULL
                            END;
                            IF @OpenStmt = N'INSERT'
                                SET @InsertMode = N'HEADER';
                            ELSE
                                SET @InsertMode = NULL;
                        END
                        ELSE IF @IsContinuation = 1
                             AND @OpenStmt = N'INSERT'
                             AND @InsertMode = N'HEADER'
                        BEGIN
                            -- Transition INSERT sub-state on the carrier keyword.
                            SET @InsertMode = CASE @FirstWord
                                WHEN N'SELECT'   THEN N'SELECT'
                                WHEN N'VALUES'   THEN N'VALUES'
                                WHEN N'EXEC'     THEN N'EXEC'
                                WHEN N'EXECUTE'  THEN N'EXEC'
                                ELSE @InsertMode
                            END;
                        END;
                        -- else: continuation, IsExec stays 0
                    END;
                END;
            END;

            INSERT TestGen.CoverageLines
                (SchemaName, ProcName, LineNum, LineText, IsExec, IsBranch)
            VALUES
                (@SchemaName, @ProcName, @LN, ISNULL(@LT,N''), @RegIsExec, @RegIsBranch);

            -- BEGIN closes pending body and pushes a BLOCK marker
            IF @PB = 1
            BEGIN
                SET @Pending  = 0;
                SET @CtxStack = @CtxStack + N'B';
            END;

            -- Scan keywords on the line for CASE/END.  Strip line comments first.
            SET @Scrub      = ISNULL(@LT, N'');
            SET @CommentPos = CHARINDEX(N'--', @Scrub);
            IF @CommentPos > 0
                SET @Scrub = LEFT(@Scrub, @CommentPos - 1);

            -- Tokenise: pad with non-word chars so word boundaries are clean
            SET @Scrub = N' ' + UPPER(@Scrub) + N' ';

            -- For each CASE token, push 'C'.  Token-scan loop.
            SET @ScanPos = 1;
            SET @ScanLen = LEN(@Scrub);

            WHILE @ScanPos <= @ScanLen - 3
            BEGIN
                IF SUBSTRING(@Scrub, @ScanPos, 4) = N'CASE'
                BEGIN
                    SET @ChPrev = SUBSTRING(@Scrub, @ScanPos - 1, 1);
                    SET @ChNext = SUBSTRING(@Scrub, @ScanPos + 4, 1);
                    IF @ChPrev NOT LIKE N'[A-Z0-9_]'
                       AND @ChNext NOT LIKE N'[A-Z0-9_]'
                        SET @CtxStack = @CtxStack + N'C';
                    SET @ScanPos = @ScanPos + 4;
                END
                ELSE IF SUBSTRING(@Scrub, @ScanPos, 3) = N'END'
                BEGIN
                    SET @ChPrev = SUBSTRING(@Scrub, @ScanPos - 1, 1);
                    SET @ChNext = SUBSTRING(@Scrub, @ScanPos + 3, 1);
                    IF @ChPrev NOT LIKE N'[A-Z0-9_]'
                       AND @ChNext NOT LIKE N'[A-Z0-9_]'
                    BEGIN
                        IF LEN(@CtxStack) > 0
                            SET @CtxStack = LEFT(@CtxStack, LEN(@CtxStack) - 1);
                    END;
                    SET @ScanPos = @ScanPos + 3;
                END
                ELSE
                    SET @ScanPos = @ScanPos + 1;
            END;

            -- After-line state
            SET @InCaseAfter = CASE WHEN LEN(@CtxStack) > 0
                                      AND SUBSTRING(@CtxStack, LEN(@CtxStack), 1) = 'C'
                                    THEN 1 ELSE 0 END;

            ---------------------------------------------------------------
            -- Emit this body line, possibly with a RecordCoverageHit hit
            -- placed BEFORE the line (terminal stmt) or AFTER the line
            -- (default).  We compose @LineToWrite then append once.
            ---------------------------------------------------------------
            SET @HitText = N'';
            IF @StmtStart IS NOT NULL
               AND @Semi = 1
               AND @DepthAfter = 0
               AND @InCaseAfter = 0
            BEGIN
                -- Statement terminates here.  Build the hit text.
                SET @HitText =
                    N'    EXEC TestGen.RecordCoverageHit '''
                    + REPLACE(@SchemaName,'''','''''') + N''','''
                    + REPLACE(@ProcName  ,'''','''''') + N''','
                    + CAST(@StmtStart AS NVARCHAR(10)) + N';' + CHAR(10);
            END;

            IF @HitText <> N'' AND @StmtIsTerminal = 1
                -- BEFORE: hit goes ahead of the line so it fires before
                -- control transfers out (RETURN/THROW/RAISERROR/GOTO/...).
                SET @LineToWrite = @HitText + ISNULL(@LT, N'') + CHAR(10);
            ELSE IF @HitText <> N''
                -- AFTER: default - hit follows the terminating statement.
                SET @LineToWrite = ISNULL(@LT, N'') + CHAR(10) + @HitText;
            ELSE
                -- No hit on this line.
                SET @LineToWrite = ISNULL(@LT, N'') + CHAR(10);

            -- Bare branch body: wrap it in a synthetic BEGIN/END so the
            -- injected RecordCoverageHit stays INSIDE the branch.  Without
            -- this, "IF cond <stmt>; EXEC hit;" leaves the EXEC outside the
            -- IF, and "IF cond <stmt>; EXEC hit; ELSE ..." detaches the ELSE
            -- (Msg 156 - _cov fails to compile).
            -- Open the wrap before the body's FIRST line (@StmtStart = @LN).
            IF @StmtWrap = 1 AND @StmtStart = @LN
                SET @LineToWrite = N'    BEGIN' + CHAR(10) + @LineToWrite;
            -- Close the wrap once the wrapped statement terminates.
            IF @HitText <> N'' AND @StmtWrap = 1
            BEGIN
                SET @LineToWrite = @LineToWrite + N'    END' + CHAR(10);
                SET @StmtWrap = 0;
            END;

            SET @Body = @Body + @LineToWrite;

            -- Reset state if this statement terminated.
            IF @HitText <> N''
            BEGIN
                SET @StmtStart      = NULL;
                SET @StmtIsTerminal = 0;
                -- v10.0.4: also reset state machine
                SET @OpenStmt       = NULL;
                SET @InsertMode     = NULL;
            END;

            SET @ParenDepth = @DepthAfter;
            -- v10.0.4: propagate set-op flag to next iteration.
            -- v10.0.7: only update on non-blank, non-comment lines so a
            -- blank line between UNION ALL and the next SELECT does not
            -- wipe the flag.
            IF @Blank = 0 AND @Cmnt = 0
                SET @UnionPending = @LineHasSetOp;

            -- v10.0.8: update block-comment / bracket / double-quote state
            -- AFTER the boundary check, so the next iteration sees the
            -- correct entering state for THIS line's tail.
            --
            -- Block comment: iterative scan for /* and */ in order.
            -- Handles balanced single-line /* ... */ (state unchanged)
            -- and unclosed /* (state -> 1) or unmatched */ (state -> 0).
            -- Limitation: a line of the form `*/ text /*` (close then
            -- re-open) is approximated; in practice T-SQL block comments
            -- don't interleave with code on the same line.
            SET @BCScan  = ISNULL(@LT, N'');
            SET @BCState = @BlockCmtOpen;
            WHILE LEN(@BCScan) > 0
            BEGIN
                IF @BCState = 0
                BEGIN
                    SET @BCPos = CHARINDEX(N'/*', @BCScan);
                    IF @BCPos = 0 BREAK;
                    SET @BCState = 1;
                    SET @BCScan  = SUBSTRING(@BCScan, @BCPos + 2, LEN(@BCScan));
                END
                ELSE
                BEGIN
                    SET @BCPos = CHARINDEX(N'*/', @BCScan);
                    IF @BCPos = 0 BREAK;
                    SET @BCState = 0;
                    SET @BCScan  = SUBSTRING(@BCScan, @BCPos + 2, LEN(@BCScan));
                END
            END;
            SET @BlockCmtOpen = @BCState;

            -- Bracket identifier depth: count [ minus ] occurrences.
            -- Limitation: `]]` (escape for literal ] inside an identifier)
            -- counts as 2 closes; in practice bracket identifiers are
            -- single-line so multi-line ]] does not arise.  Clamp to >=0
            -- so stray ] tokens don't poison the gate forever.
            SET @BracketDelta = (LEN(ISNULL(@LT,N'')) - LEN(REPLACE(ISNULL(@LT,N''), N'[', N''))) -
                                (LEN(ISNULL(@LT,N'')) - LEN(REPLACE(ISNULL(@LT,N''), N']', N'')));
            SET @BracketDepth = @BracketDepth + @BracketDelta;
            IF @BracketDepth < 0 SET @BracketDepth = 0;

            -- Double-quote identifier parity (QUOTED_IDENTIFIER ON).
            -- "" inside an identifier counts as 2 quotes -> parity
            -- unchanged, same trick as single quotes.
            IF ((LEN(ISNULL(@LT,N'')) - LEN(REPLACE(ISNULL(@LT,N''), N'"', N''))) % 2) = 1
                SET @DQuoteOpen = 1 - @DQuoteOpen;
        END;

        FETCH NEXT FROM wcur INTO @LN, @LT, @IH,
            @Blank, @Cmnt, @PB, @PE, @HdrIW, @HdrElse, @Noise, @Terminal,
            @Op, @Cp, @Semi;
    END;
    CLOSE wcur; DEALLOCATE wcur;

    -- v9.4.4: Bodyless proc / unterminated final statement.
    -- If the cursor ended with @StmtStart still set, the body's last
    -- statement never reached a terminating semicolon, so the standard
    -- semi-driven injector inside the loop never fired for it.
    -- Common case: Northwind-style
    --     CREATE PROCEDURE CustOrderHist @CustomerID nchar(5) AS
    --     SELECT ProductName, ...
    --     FROM ...
    --     GROUP BY ProductName
    -- with no BEGIN/END and no terminator.  Emit the missing hit now,
    -- at the end of @Body, using @StmtStart as the line number.  Placed
    -- BEFORE the @StmtWrap safety-net END so a bare unterminated branch
    -- body still has its hit inside the synthetic BEGIN/END wrap.
    IF @StmtStart IS NOT NULL
    BEGIN
        SET @Body = @Body + N'    EXEC TestGen.RecordCoverageHit '''
            + REPLACE(@SchemaName,'''','''''') + N''','''
            + REPLACE(@ProcName  ,'''','''''') + N''','
            + CAST(@StmtStart AS NVARCHAR(10)) + N';' + CHAR(10);
        SET @StmtStart      = NULL;
        SET @StmtIsTerminal = 0;
        SET @OpenStmt       = NULL;
        SET @InsertMode     = NULL;
    END;

    -- Safety net: if a bare branch body never reached its terminating ';',
    -- the synthetic BEGIN above was emitted with no matching END.  Close it
    -- so _cov stays balanced.
    IF @StmtWrap = 1
    BEGIN
        SET @Body = @Body + N'    END' + CHAR(10);
        SET @StmtWrap = 0;
    END;

    -- v9.4.3: compensate for an "AS BEGIN" one-line body opener (flag set at
    -- body detection).  The procedure's opening BEGIN was on the header line
    -- and never emitted, while its closing END is already at the end of @Body;
    -- prepend a synthetic BEGIN so the block is balanced and the rebuilt _cov
    -- compiles - matching the shape of a normal AS / BEGIN procedure.
    IF @InlineBegin = 1
        SET @Body = N'    BEGIN' + CHAR(10) + @Body;

    ---------------------------------------------------------------------------
    -- Build parameter list (same as v3).
    ---------------------------------------------------------------------------
    DECLARE @ParamList   NVARCHAR(MAX) = N'';
    DECLARE @pname       SYSNAME;
    DECLARE @ptype       SYSNAME;
    DECLARE @pmax        SMALLINT;
    DECLARE @pprec       TINYINT;
    DECLARE @pscale      TINYINT;
    DECLARE @phasdef     BIT;
    DECLARE @pout        BIT;
    DECLARE @pSuffix     NVARCHAR(50);

    DECLARE pcov CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.name, t.name, p.max_length, p.precision, p.scale, p.has_default_value, p.is_output
        FROM   sys.parameters p
        JOIN   sys.types t ON p.user_type_id = t.user_type_id
        WHERE  p.object_id = OBJECT_ID(@FullName) AND p.parameter_id > 0
        ORDER BY p.parameter_id;
    OPEN pcov;
    FETCH NEXT FROM pcov INTO @pname, @ptype, @pmax, @pprec, @pscale, @phasdef, @pout;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @pSuffix = N'';
        IF @ptype IN ('varchar','nvarchar','char','nchar')
            SET @pSuffix = N'(' + CASE WHEN @pmax=-1 THEN N'MAX'
                WHEN @ptype IN ('nvarchar','nchar') THEN CAST(@pmax/2 AS NVARCHAR(10))
                ELSE CAST(@pmax AS NVARCHAR(10)) END + N')';
        ELSE IF @ptype IN ('decimal','numeric')
            SET @pSuffix = N'('+CAST(@pprec AS NVARCHAR(5))+N','+CAST(@pscale AS NVARCHAR(5))+N')';

        IF LEN(@ParamList) > 0 SET @ParamList = @ParamList + N',' + CHAR(10);
        SET @ParamList = @ParamList + N'    ' + @pname + N' ' + @ptype + @pSuffix;
        IF @phasdef = 1 SET @ParamList = @ParamList + N' = NULL';
        IF @pout    = 1 SET @ParamList = @ParamList + N' OUTPUT';

        FETCH NEXT FROM pcov INTO @pname, @ptype, @pmax, @pprec, @pscale, @phasdef, @pout;
    END;
    CLOSE pcov; DEALLOCATE pcov;

    ---------------------------------------------------------------------------
    -- Create instrumented procedure
    ---------------------------------------------------------------------------
    DECLARE @DropSQL   NVARCHAR(500);
    DECLARE @CreateSQL NVARCHAR(MAX);

    IF OBJECT_ID(@InstrFull,'P') IS NOT NULL
    BEGIN
        SET @DropSQL = N'DROP PROCEDURE ' + @InstrFull;
        EXEC(@DropSQL);
    END;

    SET @CreateSQL = N'CREATE PROCEDURE ' + @InstrFull + CHAR(10);
    IF LEN(@ParamList) > 0
        SET @CreateSQL = @CreateSQL + @ParamList + CHAR(10);
    SET @CreateSQL = @CreateSQL + N'AS' + CHAR(10) + N'BEGIN' + CHAR(10);
    SET @CreateSQL = @CreateSQL + N'    SET NOCOUNT ON;' + CHAR(10);
    SET @CreateSQL = @CreateSQL + @Body;
    SET @CreateSQL = @CreateSQL + CHAR(10) + N'END;';

    DECLARE @CreateOK BIT = 1;
    DECLARE @CreateErr NVARCHAR(2000) = N'';
    BEGIN TRY
        EXEC(@CreateSQL);
    END TRY
    BEGIN CATCH
        SET @CreateOK = 0;
        SET @CreateErr = ERROR_MESSAGE();
    END CATCH;
    DROP TABLE #Lines;

    ---------------------------------------------------------------------------
    -- Verify
    ---------------------------------------------------------------------------
    DECLARE @TrackCount INT = 0;
    SELECT @TrackCount = (LEN(@CreateSQL) - LEN(REPLACE(@CreateSQL,'RecordCoverageHit','')))
                         / LEN('RecordCoverageHit');

    DECLARE @RegExec INT, @RegBranch INT;
    SELECT @RegExec   = SUM(CAST(IsExec   AS INT)),
           @RegBranch = SUM(CAST(IsBranch AS INT))
    FROM   TestGen.CoverageLines
    WHERE  SchemaName = @SchemaName AND ProcName = @ProcName;

    IF @CreateOK = 1
        PRINT 'Instrumented procedure created: ' + @InstrFull;
    ELSE
    BEGIN
        PRINT '!! Instrumented procedure FAILED to compile: ' + @InstrFull;
        PRINT '   Error: ' + @CreateErr;
        PRINT '   The CREATE PROCEDURE text is in @CreateSQL inside this batch.';
    END;
    PRINT 'RecordCoverageHit injections   : ' + CAST(@TrackCount AS VARCHAR);
    PRINT 'Registry IsExec lines          : ' + CAST(ISNULL(@RegExec,0)   AS VARCHAR);
    PRINT 'Registry IsBranch lines        : ' + CAST(ISNULL(@RegBranch,0) AS VARCHAR);

    IF @TrackCount <> ISNULL(@RegExec,0)
        PRINT 'WARNING: injection count differs from IsExec count - check for unterminated statements.';
END;
GO
PRINT 'TestGen.InstrumentProcedure v5.3 created (bare no-semicolon branch-body wrap-close fix).';
GO
