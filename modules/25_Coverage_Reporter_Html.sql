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
 * TestGen.GetCoverageHtmlReport
 *
 * Emits the UnitAutogen database-wide HTML coverage report for a completed
 * batch.  Output is identical to GenerateAndCoverDatabase @OutputMode='HTML'
 * but reads from the already-populated TestGen.CoverageResult — no re-run.
 *
 * Parameters
 * ----------
 *   @BatchId      DATETIME2(3)  -- BatchId from TestGen.CoverageResult.
 *                                  NULL = most recent batch.
 *   @SchemaFilter SYSNAME       -- Restrict report to one schema. NULL = all.
 *
 * Output
 * ------
 *   Single SELECT column  CoverageReportHTML NVARCHAR(MAX)
 *   (self-contained HTML file — open directly in any browser)
 *
 * Typical usage (direct)
 * ----------------------
 *   EXEC TestGen.GetCoverageHtmlReport;                   -- latest batch
 *   EXEC TestGen.GetCoverageHtmlReport @SchemaFilter = 'dbo';
 *
 * Typical usage (via PowerShell wrapper)
 * --------------------------------------
 *   Export-CoverageHtmlReport -ServerInstance 'sql01' -Database 'Northwind' `
 *       -OutputFile './artifacts/coverage-report.html'
 *
 * Design notes
 * ------------
 *   - All HTML, CSS and data are inline — the file is self-contained.
 *   - Layout is pixel-identical to the HTML produced by
 *     GenerateAndCoverDatabase @OutputMode='HTML'.
 *   - All variables declared at proc top (T-SQL DECLARE-in-loop gotcha).
 *   - NOT_TESTABLE procedures are shown greyed-out with a collapsible reason.
 ******************************************************************************/

IF OBJECT_ID('TestGen.GetCoverageHtmlReport','P') IS NOT NULL
    DROP PROCEDURE TestGen.GetCoverageHtmlReport;
GO

CREATE PROCEDURE TestGen.GetCoverageHtmlReport
    @BatchId      DATETIME2(3) = NULL,   -- NULL = most recent batch
    @SchemaFilter SYSNAME      = NULL    -- NULL = all schemas
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- All working variables at proc top (avoids DECLARE-in-loop trap)
    -- -------------------------------------------------------------------------
    DECLARE @gProcs      INT, @gNotTestable INT, @gGenFail INT;
    DECLARE @gTot        INT, @gCov         INT, @gTB      INT, @gCB  INT;
    DECLARE @gRun        INT, @gPass        INT, @gFail    INT, @gErr INT;
    DECLARE @gSkip       INT, @gPres        INT;
    DECLARE @gLinePct    DECIMAL(5,1), @gBrPct    DECIMAL(5,1);
    DECLARE @pPass       DECIMAL(5,1), @pFail      DECIMAL(5,1);
    DECLARE @pErr        DECIMAL(5,1), @pSkip      DECIMAL(5,1);
    DECLARE @gAutonomy   DECIMAL(5,1);
    DECLARE @H           NVARCHAR(MAX);
    DECLARE @rS          SYSNAME,  @rP    SYSNAME;
    DECLARE @rGen        BIT,      @rRun  INT,          @rPass INT,   @rFail INT;
    DECLARE @rErr        INT,      @rSkip INT,          @rTot  INT,   @rCov  INT;
    DECLARE @rLP         DECIMAL(5,1), @rBP DECIMAL(5,1), @rTB INT;
    DECLARE @rTestability VARCHAR(20), @rReason NVARCHAR(400), @rPres INT;

    -- -------------------------------------------------------------------------
    -- 1. Resolve BatchId
    -- -------------------------------------------------------------------------
    IF @BatchId IS NULL
        SELECT TOP 1 @BatchId = BatchId
        FROM   TestGen.CoverageResult
        ORDER  BY BatchId DESC;

    IF @BatchId IS NULL
    BEGIN
        RAISERROR('TestGen.GetCoverageHtmlReport: no results found. Run GenerateAndCoverDatabase first.',16,1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- 2. Aggregates from CoverageResult
    -- -------------------------------------------------------------------------
    SELECT
        @gProcs       = COUNT(*),
        @gNotTestable = ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 1 ELSE 0 END),0),
        @gGenFail     = ISNULL(SUM(CASE WHEN GenSucceeded=0 THEN 1 ELSE 0 END),0),
        @gTot         = ISNULL(SUM(TotalLines),0),
        @gCov         = ISNULL(SUM(CoveredLines),0),
        @gTB          = ISNULL(SUM(TotalBranches),0),
        @gCB          = ISNULL(SUM(CoveredBranches),0),
        @gRun         = ISNULL(SUM(TestsRun),0),
        @gPass        = ISNULL(SUM(TestsPassed),0),
        @gFail        = ISNULL(SUM(TestsFailed),0),
        @gErr         = ISNULL(SUM(TestsErrored),0),
        @gSkip        = ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 0 ELSE TestsSkipped END),0),
        @gPres        = ISNULL(SUM(TestsPreserved),0)
    FROM   TestGen.CoverageResult
    WHERE  BatchId = @BatchId
      AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter);

    SET @gLinePct  = CASE WHEN @gTot>0 THEN CAST(@gCov  AS DECIMAL(9,2))/@gTot*100 ELSE 0 END;
    SET @gBrPct    = CASE WHEN @gTB >0 THEN CAST(@gCB   AS DECIMAL(9,2))/@gTB *100 ELSE 0 END;
    SET @pPass     = CASE WHEN @gRun>0 THEN CAST(@gPass  AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    SET @pFail     = CASE WHEN @gRun>0 THEN CAST(@gFail  AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    SET @pErr      = CASE WHEN @gRun>0 THEN CAST(@gErr   AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    SET @pSkip     = CASE WHEN @gRun>0 THEN CAST(@gSkip  AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    SET @gAutonomy = CASE WHEN @gRun>0
                     THEN CAST(@gRun - @gPres AS DECIMAL(9,2)) / @gRun * 100
                     ELSE 100 END;

    -- -------------------------------------------------------------------------
    -- 3. Build HTML (identical layout to GenerateAndCoverDatabase HTML mode)
    -- -------------------------------------------------------------------------
    SET @H = N'';
    SET @H = @H + N'<!DOCTYPE html><html><head><meta charset="utf-8"><title>UnitAutogen Coverage Report</title><style>';
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
    SET @H = @H + N'<h2>UnitAutogen &mdash; Database Coverage Report</h2>';
    SET @H = @H + N'<p class="meta">' + DB_NAME() + N' &middot; ' + CONVERT(VARCHAR,@BatchId,120)
                 + N' &middot; ' + CAST(@gProcs AS VARCHAR) + N' objects ('
                 + CAST(@gGenFail AS VARCHAR) + N' failed generation, '
                 + CAST(@gNotTestable AS VARCHAR) + N' not testable)</p>';

    -- Summary cards
    SET @H = @H + N'<div class="cards">';
    SET @H = @H + N'<div class="card"><div class="big '
        + CASE WHEN @gLinePct>=80 THEN 'g' WHEN @gLinePct>=50 THEN 'a' ELSE 'r' END
        + N'">' + CAST(@gLinePct AS VARCHAR) + N'%</div><div class="lbl">Line coverage<br>'
        + CAST(@gCov AS VARCHAR) + N'/' + CAST(@gTot AS VARCHAR) + N' lines</div></div>';
    SET @H = @H + N'<div class="card"><div class="big '
        + CASE WHEN @gBrPct>=80 THEN 'g' WHEN @gBrPct>=50 THEN 'a' ELSE 'r' END
        + N'">' + CAST(@gBrPct AS VARCHAR) + N'%</div><div class="lbl">Branch coverage<br>'
        + CAST(@gCB AS VARCHAR) + N'/' + CAST(@gTB AS VARCHAR) + N' branches</div></div>';
    SET @H = @H + N'<div class="card"><div class="big">' + CAST(@gRun AS VARCHAR)
        + N'</div><div class="lbl">Tests &middot; '
        + N'<span class="g">' + CAST(@gPass AS VARCHAR) + N' pass ' + CAST(@pPass AS VARCHAR) + N'%</span>, '
        + N'<span class="r">' + CAST(@gFail AS VARCHAR) + N' fail ' + CAST(@pFail AS VARCHAR) + N'%</span>, '
        + CAST(@gErr AS VARCHAR) + N' err ' + CAST(@pErr AS VARCHAR) + N'%, '
        + CAST(@gSkip AS VARCHAR) + N' skip ' + CAST(@pSkip AS VARCHAR) + N'%</div></div>';
    SET @H = @H + N'<div class="card"><div class="big '
        + CASE WHEN @gAutonomy>=80 THEN 'g' WHEN @gAutonomy>=50 THEN 'a' ELSE 'r' END
        + N'">' + CAST(@gAutonomy AS VARCHAR) + N'%</div><div class="lbl">Autonomy<br>'
        + CAST(@gRun - @gPres AS VARCHAR) + N' of ' + CAST(@gRun AS VARCHAR)
        + N' tests framework-owned<br><span style="color:#999">'
        + CAST(@gPres AS VARCHAR) + N' user-modified</span></div></div>';
    SET @H = @H + N'</div>';

    -- Per-procedure table
    SET @H = @H + N'<table><tr>'
        + N'<th class="l">Schema</th><th class="l">Object</th>'
        + N'<th>Testable</th><th>Gen</th>'
        + N'<th>Tests</th><th>Pass</th><th>Fail</th><th>Err</th><th>Skip</th>'
        + N'<th>Lines</th><th>Covered</th><th>Line %</th><th>Branch %</th></tr>';

    DECLARE rc CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName, ProcName, GenSucceeded,
               TestsRun, TestsPassed, TestsFailed, TestsErrored, TestsSkipped,
               TotalLines, CoveredLines, LinePct, BranchPct, TotalBranches,
               Testability, NotTestableReason, TestsPreserved
        FROM   TestGen.CoverageResult
        WHERE  BatchId = @BatchId
          AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter)
        ORDER  BY SchemaName, ProcName;
    OPEN rc;
    FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,
                             @rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rTestability = N'NOT_TESTABLE'
            SET @H = @H + N'<tr style="background:#f6f6f6;color:#999">'
                + N'<td class="l">' + @rS + N'</td>'
                + N'<td class="l">' + @rP
                + N'<details style="margin-top:2px"><summary style="font-size:11px;color:#888;cursor:pointer;font-weight:normal">why not testable?</summary>'
                + N'<div style="font-size:12px;font-weight:normal;color:#555;margin-top:4px;white-space:normal">'
                + ISNULL(@rReason, N'no fakeable dependencies; system-catalog usage')
                + N'</div></details></td>'
                + N'<td><span class="r">N</span></td>'
                + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'N' END + N'</td>'
                + N'<td>' + CAST(ISNULL(@rRun,0)  AS VARCHAR)
                    + CASE WHEN ISNULL(@rPres,0)>0
                           THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                           ELSE N'' END + N'</td>'
                + N'<td>' + CAST(ISNULL(@rPass,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rFail,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rErr,0)  AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rSkip,0) AS VARCHAR) + N'</td>'
                + N'<td style="color:#999">n/a</td><td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td><td style="color:#999">n/a</td>'
                + N'</tr>';
        ELSE
            SET @H = @H + N'<tr>'
                + N'<td class="l">' + @rS + N'</td>'
                + N'<td class="l">' + @rP + N'</td>'
                + N'<td><span class="g">Y</span></td>'
                + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'<span class="r">N</span>' END + N'</td>'
                + N'<td>' + CAST(@rRun AS VARCHAR)
                    + CASE WHEN ISNULL(@rPres,0)>0
                           THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                           ELSE N'' END + N'</td>'
                + N'<td>' + CAST(@rPass AS VARCHAR) + N'</td>'
                + N'<td>' + CASE WHEN @rFail>0 THEN N'<span class="r">'+CAST(@rFail AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
                + N'<td>' + CASE WHEN @rErr >0 THEN N'<span class="r">'+CAST(@rErr  AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
                + N'<td>' + CAST(@rSkip AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(@rTot AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(@rCov AS VARCHAR) + N'</td>'
                + CASE WHEN ISNULL(@rTot,0)=0
                       THEN N'<td style="color:#999">n/a</td>'
                       ELSE N'<td class="' + CASE WHEN @rLP>=80 THEN 'g' WHEN @rLP>=50 THEN 'a' ELSE 'r' END
                            + N'">' + CAST(@rLP AS VARCHAR) + N'%</td>' END
                + CASE WHEN ISNULL(@rTB,0)=0
                       THEN N'<td style="color:#999">n/a</td>'
                       ELSE N'<td class="' + CASE WHEN @rBP>=80 THEN 'g' WHEN @rBP>=50 THEN 'a' ELSE 'r' END
                            + N'">' + CAST(@rBP AS VARCHAR) + N'%</td>' END
                + N'</tr>';

        FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,
                                 @rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    END;
    CLOSE rc; DEALLOCATE rc;

    -- Totals row
    SET @H = @H + N'<tr class="total"><td class="l" colspan="4">TOTAL &mdash; '
        + CAST(@gProcs AS VARCHAR) + N' objects ('
        + CAST(@gProcs - @gNotTestable AS VARCHAR) + N' testable, '
        + CAST(@gNotTestable AS VARCHAR) + N' not)</td>'
        + N'<td>' + CAST(@gRun AS VARCHAR)
            + CASE WHEN @gPres>0
                   THEN N' <span style="color:#9a6700">(' + CAST(@gPres AS VARCHAR) + N' preserved)</span>'
                   ELSE N'' END + N'</td>'
        + N'<td>' + CAST(@gPass AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gFail AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gErr  AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gSkip AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gTot  AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gCov  AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gLinePct AS VARCHAR) + N'%</td>'
        + N'<td>' + CAST(@gBrPct   AS VARCHAR) + N'%</td></tr>';
    SET @H = @H + N'</table></body></html>';

    SELECT @H AS CoverageReportHTML;
END;
GO
PRINT 'TestGen.GetCoverageHtmlReport created.';
GO
