/*******************************************************************************
 * TestGen.GetCoverageReport v2
 *
 * Companion to InstrumentProcedure v4.  Single change vs v1:
 *
 *   Branch coverage is no longer "branch-header line was hit" (it can never
 *   be, because sp_statement_completed does not fire for IF predicates).
 *
 *   New rule:  a branch (IsBranch=1) line is considered HIT iff the next
 *              IsExec=1 line at LineNum > branch's LineNum was hit.
 *
 *   That "next executable line" is the first statement inside the branch's
 *   body.  If that statement fired, control entered the branch.
 *
 * Everything else (HTML/TEXT output, line coverage math, uncovered list)
 * is unchanged in shape.
 ******************************************************************************/

IF OBJECT_ID('TestGen.GetCoverageReport','P') IS NOT NULL
    DROP PROCEDURE TestGen.GetCoverageReport;
GO

CREATE PROCEDURE TestGen.GetCoverageReport
    @SchemaName  SYSNAME,
    @ProcName    SYSNAME,
    @OutputMode  VARCHAR(10) = 'TEXT'  -- TEXT or HTML
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FullName    NVARCHAR(300) = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName);
    DECLARE @TotalExec   INT, @TotalBranch INT;
    DECLARE @HitExec     INT, @HitBranch   INT;
    DECLARE @LinePct     DECIMAL(5,1), @BranchPct DECIMAL(5,1);
    DECLARE @MissedLine  INT, @MissedText  NVARCHAR(MAX);
    DECLARE @LineClass   VARCHAR(5),  @BranchClass VARCHAR(5);
    DECLARE @LNum        INT,  @LTxt NVARCHAR(MAX), @LExec BIT, @LBranch BIT, @LHit INT;
    DECLARE @RowClass    VARCHAR(10), @BadgeTxt NVARCHAR(4), @BadgeClass VARCHAR(20);
    DECLARE @BranchTxt   NVARCHAR(4), @SafeCode NVARCHAR(MAX);
    DECLARE @HTML        NVARCHAR(MAX);
    DECLARE @Chunk       INT,  @ChunkSize INT;

    -----------------------------------------------------------------------
    /* v9.4.3: testability gate - skip the report for a NOT_TESTABLE procedure
       (no fakeable dependencies + system-catalog usage); show a clear banner
       instead of a misleading 0% / 100%. */
    DECLARE @v943Verdict VARCHAR(20), @v943Reason NVARCHAR(400);
    BEGIN TRY
        EXEC TestGen.AssessTestability @SchemaName=@SchemaName, @ProcName=@ProcName,
             @Verdict=@v943Verdict OUTPUT, @Reason=@v943Reason OUTPUT;
    END TRY
    BEGIN CATCH SET @v943Verdict = 'TESTABLE'; END CATCH

    IF @v943Verdict = 'NOT_TESTABLE'
    BEGIN
        IF @OutputMode <> 'NONE'
        BEGIN
            PRINT '';
            PRINT '=== NOT TESTABLE: ' + @SchemaName + '.' + @ProcName + ' ===';
            PRINT ISNULL(@v943Reason, N'no fakeable dependencies; system-catalog usage');
            PRINT 'No coverage is reported for this procedure.';
        END;
        RETURN;
    END;

    -- Build a per-line "effective hit" view that knows about branches.
    -- For each line we record:
    --   EffectiveHit = 1 if (IsExec=1 AND that line had a CoverageHits row)
    --                 OR if (IsBranch=1 AND the next IsExec=1 line by
    --                       LineNum was hit).
    -----------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#LineView') IS NOT NULL DROP TABLE #LineView;

    ;WITH lines AS (
        SELECT cl.LineNum, cl.LineText, cl.IsExec, cl.IsBranch,
               CASE WHEN EXISTS (
                        SELECT 1 FROM TestGen.CoverageHits ch
                        WHERE  ch.SchemaName = cl.SchemaName
                          AND  ch.ProcName   = cl.ProcName
                          AND  ch.LineNum    = cl.LineNum
                    ) THEN 1 ELSE 0 END AS DirectHit
        FROM   TestGen.CoverageLines cl
        WHERE  cl.SchemaName = @SchemaName AND cl.ProcName = @ProcName
    ),
    next_exec AS (
        SELECT  l.LineNum,
                ( SELECT TOP 1 e.LineNum
                  FROM   lines e
                  WHERE  e.IsExec = 1 AND e.LineNum > l.LineNum
                  ORDER  BY e.LineNum ) AS NextExecLine
        FROM lines l
        WHERE l.IsBranch = 1
    ),
    branch_inferred AS (
        SELECT n.LineNum,
               ISNULL(l.DirectHit, 0) AS BodyHit
        FROM   next_exec n
        LEFT   JOIN lines l ON l.LineNum = n.NextExecLine
    )
    SELECT  l.LineNum,
            l.LineText,
            l.IsExec,
            l.IsBranch,
            l.DirectHit,
            CASE
              WHEN l.IsExec = 1 AND l.DirectHit = 1               THEN 1
              WHEN l.IsBranch = 1 AND b.BodyHit = 1               THEN 1
              ELSE 0
            END AS EffectiveHit
    INTO    #LineView
    FROM    lines l
    LEFT    JOIN branch_inferred b ON b.LineNum = l.LineNum;

    SELECT @TotalExec   = SUM(CAST(IsExec   AS INT)) FROM #LineView;
    SELECT @TotalBranch = SUM(CAST(IsBranch AS INT)) FROM #LineView;

    SELECT @HitExec   = SUM(CASE WHEN IsExec   = 1 AND EffectiveHit = 1 THEN 1 ELSE 0 END) FROM #LineView;
    SELECT @HitBranch = SUM(CASE WHEN IsBranch = 1 AND EffectiveHit = 1 THEN 1 ELSE 0 END) FROM #LineView;

    SET @TotalExec   = ISNULL(@TotalExec,0);
    SET @TotalBranch = ISNULL(@TotalBranch,0);
    SET @HitExec     = ISNULL(@HitExec,0);
    SET @HitBranch   = ISNULL(@HitBranch,0);

    SET @LinePct   = CASE WHEN @TotalExec   > 0 THEN CAST(@HitExec   AS DECIMAL(5,1)) / @TotalExec   * 100 ELSE 0 END;
    SET @BranchPct = CASE WHEN @TotalBranch > 0 THEN CAST(@HitBranch AS DECIMAL(5,1)) / @TotalBranch * 100 ELSE 0 END;

    /* v9.4.3: a procedure with no branches has nothing to measure - branch
       coverage is shown as 'n/a', not a misleading 0%.  To instead treat
       "no branch" as one covered branch (1/1 = 100%), change 'n/a' below
       to '100.0%' - this is the single decision point. */
    DECLARE @BranchPctDisplay VARCHAR(12) =
        CASE WHEN @TotalBranch > 0 THEN CAST(@BranchPct AS VARCHAR) + '%'
             ELSE 'n/a' END;

    IF @OutputMode = 'TEXT'
    BEGIN
        PRINT '+==============================================================+';
        PRINT '|           CODE COVERAGE REPORT                               |';
        PRINT '+==============================================================+';
        PRINT '|  Procedure : ' + @FullName;
        PRINT '|  Generated : ' + CONVERT(VARCHAR,SYSDATETIME(),120);
        PRINT '+--------------------------------------------------------------+';
        PRINT '|  LINE COVERAGE   : ' + CAST(@HitExec   AS VARCHAR) + '/' + CAST(@TotalExec   AS VARCHAR) + ' lines    -> ' + CAST(@LinePct   AS VARCHAR) + '%';
        PRINT '|  BRANCH COVERAGE : ' + CAST(@HitBranch AS VARCHAR) + '/' + CAST(@TotalBranch AS VARCHAR) + ' branches -> ' + @BranchPctDisplay;
        PRINT '+--------------------------------------------------------------+';
        PRINT '|  UNCOVERED LINES:';

        DECLARE mcur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LineNum, LineText
            FROM   #LineView
            WHERE  IsExec = 1 AND EffectiveHit = 0
            ORDER  BY LineNum;
        OPEN mcur;
        FETCH NEXT FROM mcur INTO @MissedLine, @MissedText;
        WHILE @@FETCH_STATUS=0
        BEGIN
            PRINT '|  Line ' + RIGHT('   '+CAST(@MissedLine AS VARCHAR),4) + ': ' + LEFT(LTRIM(@MissedText),55);
            FETCH NEXT FROM mcur INTO @MissedLine, @MissedText;
        END;
        CLOSE mcur; DEALLOCATE mcur;

        PRINT '|  UNCOVERED BRANCHES:';
        DECLARE bcur CURSOR LOCAL FAST_FORWARD FOR
            SELECT LineNum, LineText
            FROM   #LineView
            WHERE  IsBranch = 1 AND EffectiveHit = 0
            ORDER  BY LineNum;
        OPEN bcur;
        FETCH NEXT FROM bcur INTO @MissedLine, @MissedText;
        WHILE @@FETCH_STATUS=0
        BEGIN
            PRINT '|  Line ' + RIGHT('   '+CAST(@MissedLine AS VARCHAR),4) + ': ' + LEFT(LTRIM(@MissedText),55);
            FETCH NEXT FROM bcur INTO @MissedLine, @MissedText;
        END;
        CLOSE bcur; DEALLOCATE bcur;

        PRINT '+==============================================================+';
    END;

    IF @OutputMode = 'HTML'
    BEGIN
        SET @HTML = N'';
        SET @HTML = @HTML + N'<!DOCTYPE html><html><head><meta charset="utf-8">';
        SET @HTML = @HTML + N'<title>Coverage: ' + @FullName + N'</title>';
        SET @HTML = @HTML + N'<style>';
        SET @HTML = @HTML + N'body{font-family:Consolas,monospace;background:#1e1e1e;color:#d4d4d4;margin:0;padding:20px}';
        SET @HTML = @HTML + N'h1{color:#569cd6;font-size:18px}';
        SET @HTML = @HTML + N'.stats{background:#252526;padding:12px;border-radius:4px;margin-bottom:16px;display:flex;gap:32px}';
        SET @HTML = @HTML + N'.stat-box{text-align:center;min-width:180px}';
        SET @HTML = @HTML + N'.stat-pct{font-size:36px;font-weight:bold}';
        SET @HTML = @HTML + N'.stat-pct.good{color:#4ec9b0}.stat-pct.warn{color:#dcdcaa}.stat-pct.bad{color:#f44747}';
        SET @HTML = @HTML + N'.stat-label{font-size:12px;color:#858585}';
        SET @HTML = @HTML + N'.bar-bg{background:#3e3e42;height:8px;border-radius:4px;margin:6px 0}';
        SET @HTML = @HTML + N'.bar-fill{height:8px;border-radius:4px}';
        SET @HTML = @HTML + N'.bar-fill.good{background:#4ec9b0}.bar-fill.warn{background:#dcdcaa}.bar-fill.bad{background:#f44747}';
        SET @HTML = @HTML + N'table{width:100%;border-collapse:collapse;font-size:13px}';
        SET @HTML = @HTML + N'tr.hit{background:#1a2e1a}tr.miss{background:#2e1a1a}tr.noexec{background:#1e1e1e;opacity:0.5}';
        SET @HTML = @HTML + N'tr.branch-hit{background:#1a2a2e}tr.branch-miss{background:#2e2a1a}';
        SET @HTML = @HTML + N'tr:hover{filter:brightness(1.2)}';
        SET @HTML = @HTML + N'td.lnum{color:#858585;text-align:right;padding:2px 12px 2px 4px;width:40px;border-right:2px solid #3e3e42}';
        SET @HTML = @HTML + N'td.badge{width:20px;text-align:center;font-size:11px}';
        SET @HTML = @HTML + N'td.code{padding:2px 8px;white-space:pre}';
        SET @HTML = @HTML + N'.hit-badge{color:#4ec9b0}.miss-badge{color:#f44747}.branch-badge{color:#dcdcaa;font-size:9px}';
        SET @HTML = @HTML + N'</style></head><body>';

        SET @HTML = @HTML + N'<h1>Code Coverage &mdash; ' + @FullName + N'</h1>';
        SET @HTML = @HTML + N'<p style="color:#858585;font-size:12px">Generated: ' + CONVERT(VARCHAR,SYSDATETIME(),120) + N'</p>';

        SET @LineClass   = CASE WHEN @LinePct  >=80 THEN 'good' WHEN @LinePct  >=60 THEN 'warn' ELSE 'bad' END;
        SET @BranchClass = CASE WHEN @TotalBranch = 0 THEN 'good' WHEN @BranchPct>=80 THEN 'good' WHEN @BranchPct>=60 THEN 'warn' ELSE 'bad' END;

        SET @HTML = @HTML + N'<div class="stats">';
        SET @HTML = @HTML + N'<div class="stat-box"><div class="stat-pct ' + @LineClass + N'">' + CAST(@LinePct AS VARCHAR) + N'%</div>';
        SET @HTML = @HTML + N'<div class="bar-bg"><div class="bar-fill ' + @LineClass + N'" style="width:' + CAST(@LinePct AS VARCHAR) + N'%"></div></div>';
        SET @HTML = @HTML + N'<div class="stat-label">Line Coverage (' + CAST(@HitExec AS VARCHAR) + N'/' + CAST(@TotalExec AS VARCHAR) + N' lines)</div></div>';
        SET @HTML = @HTML + N'<div class="stat-box"><div class="stat-pct ' + @BranchClass + N'">' + @BranchPctDisplay + N'</div>';
        SET @HTML = @HTML + N'<div class="bar-bg"><div class="bar-fill ' + @BranchClass + N'" style="width:' + CAST(@BranchPct AS VARCHAR) + N'%"></div></div>';
        SET @HTML = @HTML + N'<div class="stat-label">Branch Coverage (' + CAST(@HitBranch AS VARCHAR) + N'/' + CAST(@TotalBranch AS VARCHAR) + N' branches)</div></div>';
        SET @HTML = @HTML + N'</div>';

        SET @HTML = @HTML + N'<table>';

        DECLARE lcov CURSOR LOCAL FAST_FORWARD FOR
            SELECT LineNum, LineText, IsExec, IsBranch, EffectiveHit
            FROM   #LineView
            ORDER  BY LineNum;
        OPEN lcov;
        FETCH NEXT FROM lcov INTO @LNum, @LTxt, @LExec, @LBranch, @LHit;
        WHILE @@FETCH_STATUS=0
        BEGIN
            -- Row class
            IF @LExec = 0 AND @LBranch = 0
                SET @RowClass = 'noexec';
            ELSE IF @LBranch = 1
                SET @RowClass = CASE WHEN @LHit = 1 THEN 'branch-hit' ELSE 'branch-miss' END;
            ELSE
                SET @RowClass = CASE WHEN @LHit = 1 THEN 'hit' ELSE 'miss' END;

            -- Badge
            IF @LExec = 0 AND @LBranch = 0
            BEGIN
                SET @BadgeTxt   = N'';
                SET @BadgeClass = '';
            END
            ELSE IF @LHit = 1
            BEGIN
                SET @BadgeTxt   = N'&#10003;';
                SET @BadgeClass = 'hit-badge';
            END
            ELSE
            BEGIN
                SET @BadgeTxt   = N'&#10007;';
                SET @BadgeClass = 'miss-badge';
            END;

            SET @BranchTxt  = CASE WHEN @LBranch = 1 THEN N'B' ELSE N'' END;
            SET @SafeCode   = REPLACE(REPLACE(REPLACE(ISNULL(@LTxt,N''),'&','&amp;'),'<','&lt;'),'>','&gt;');

            SET @HTML = @HTML + N'<tr class="' + @RowClass + N'"><td class="lnum">' + CAST(@LNum AS VARCHAR) +
                N'</td><td class="badge"><span class="' + @BadgeClass + N'">' + @BadgeTxt +
                N'</span></td><td class="badge"><span class="branch-badge">' + @BranchTxt +
                N'</span></td><td class="code">' + @SafeCode + N'</td></tr>';

            FETCH NEXT FROM lcov INTO @LNum, @LTxt, @LExec, @LBranch, @LHit;
        END;
        CLOSE lcov; DEALLOCATE lcov;

        SET @HTML = @HTML + N'</table></body></html>';

        SELECT @HTML AS CoverageHTML;

        PRINT '/* =================== COVERAGE REPORT HTML =================== */';
        PRINT '/* Copy everything between the markers, save as coverage.html    */';
        PRINT '/* then open in your browser.                                    */';
        PRINT '/* ============================================================= */';
        SET @ChunkSize = 4000;
        SET @Chunk = 1;
        WHILE @Chunk <= LEN(@HTML)
        BEGIN
            PRINT SUBSTRING(@HTML, @Chunk, @ChunkSize);
            SET @Chunk = @Chunk + @ChunkSize;
        END;
        PRINT '/* =================== END HTML =================== */';
    END;

    IF OBJECT_ID('tempdb..#LineView') IS NOT NULL DROP TABLE #LineView;
END;
GO
PRINT 'TestGen.GetCoverageReport v2 created.';
GO
