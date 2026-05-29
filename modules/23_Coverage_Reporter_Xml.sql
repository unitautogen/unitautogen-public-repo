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
 * TestGen.GetCoverageCoberturaXml
 *
 * Emits a Cobertura-compatible XML coverage document for a completed batch.
 * Consumed natively by:
 *   - Azure DevOps  "Publish Code Coverage Results" task (format: Cobertura)
 *   - SonarQube / SonarCloud  sonar.coverageReportPaths
 *   - Jenkins  Cobertura Plugin
 *   - GitLab CI  coverage_report: cobertura
 *
 * Parameters
 * ----------
 *   @BatchId      DATETIME2(3)  -- BatchId from TestGen.CoverageResult.
 *                                  NULL = most recent batch.
 *   @SchemaFilter SYSNAME       -- Restrict to one schema. NULL = all schemas.
 *
 * Output
 * ------
 *   Single SELECT column  CoberturaXml NVARCHAR(MAX)
 *
 * Typical usage (direct)
 * ----------------------
 *   EXEC TestGen.GetCoverageCoberturaXml;                          -- latest batch, all schemas
 *   EXEC TestGen.GetCoverageCoberturaXml @SchemaFilter = 'dbo';
 *
 * Typical usage (via GenerateAndCoverDatabase)
 * --------------------------------------------
 *   EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'COBERTURA';
 *   EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = 'dbo', @OutputMode = 'COBERTURA';
 *
 * Design notes
 * ------------
 *   - All existing procs (GetCoverageReport, GenerateAndCoverDatabase TEXT/HTML)
 *     are untouched.  This proc is self-contained.
 *   - Branch condition-coverage uses the same EffectiveHit inference as
 *     GetCoverageReport v2: a branch line is HIT iff the next executable
 *     line after it was hit.  Each branch is modelled as 2 conditions
 *     (taken / not-taken); we report 1/2 when taken, 0/2 when not.
 *   - NOT_TESTABLE procedures are excluded from the XML (no CoverageLines rows
 *     exist for them, and their metrics are NULL in CoverageResult).
 *   - @Timestamp is Unix epoch seconds computed from @BatchId (UTC).
 ******************************************************************************/

IF OBJECT_ID('TestGen.GetCoverageCoberturaXml','P') IS NOT NULL
    DROP PROCEDURE TestGen.GetCoverageCoberturaXml;
GO

CREATE PROCEDURE TestGen.GetCoverageCoberturaXml
    @BatchId      DATETIME2(3) = NULL,   -- NULL = most recent batch
    @SchemaFilter SYSNAME      = NULL    -- NULL = all schemas
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- 1. Resolve BatchId
    -- -------------------------------------------------------------------------
    IF @BatchId IS NULL
        SELECT TOP 1 @BatchId = BatchId
        FROM   TestGen.CoverageResult
        ORDER  BY BatchId DESC;

    IF @BatchId IS NULL
    BEGIN
        RAISERROR('TestGen.GetCoverageCoberturaXml: no coverage results found. Run GenerateAndCoverDatabase first.',16,1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- 2. Database-level aggregates (excludes NOT_TESTABLE)
    -- -------------------------------------------------------------------------
    DECLARE @gTot INT, @gCov INT, @gTB INT, @gCB INT;
    SELECT @gTot = ISNULL(SUM(TotalLines),0),
           @gCov = ISNULL(SUM(CoveredLines),0),
           @gTB  = ISNULL(SUM(TotalBranches),0),
           @gCB  = ISNULL(SUM(CoveredBranches),0)
    FROM   TestGen.CoverageResult
    WHERE  BatchId     = @BatchId
      AND  Testability <> N'NOT_TESTABLE'
      AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter);

    DECLARE @gLineRate   VARCHAR(20) = CAST(CASE WHEN @gTot > 0 THEN CAST(1.0 * @gCov / @gTot AS DECIMAL(10,4)) ELSE 0 END AS VARCHAR(20));
    DECLARE @gBranchRate VARCHAR(20) = CAST(CASE WHEN @gTB  > 0 THEN CAST(1.0 * @gCB  / @gTB  AS DECIMAL(10,4)) ELSE 1 END AS VARCHAR(20));

    -- Unix epoch seconds from BatchId (UTC)
    DECLARE @Timestamp VARCHAR(20) = CAST(DATEDIFF(SECOND, CAST('1970-01-01' AS DATETIME2), @BatchId) AS VARCHAR(20));

    -- -------------------------------------------------------------------------
    -- 3. Build XML string
    -- -------------------------------------------------------------------------
    DECLARE @XML NVARCHAR(MAX);
    SET @XML = N'<?xml version="1.0" encoding="UTF-8"?>' + CHAR(10);
    SET @XML = @XML + N'<!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">' + CHAR(10);
    SET @XML = @XML
        + N'<coverage'
        + N' line-rate="'        + @gLineRate   + N'"'
        + N' branch-rate="'      + @gBranchRate + N'"'
        + N' lines-covered="'    + CAST(@gCov AS VARCHAR) + N'"'
        + N' lines-valid="'      + CAST(@gTot AS VARCHAR) + N'"'
        + N' branches-covered="' + CAST(@gCB  AS VARCHAR) + N'"'
        + N' branches-valid="'   + CAST(@gTB  AS VARCHAR) + N'"'
        + N' complexity="0"'
        + N' version="0.9.0-beta"'
        + N' timestamp="'        + @Timestamp + N'">' + CHAR(10);

    SET @XML = @XML + N'  <sources><source>.</source></sources>' + CHAR(10);
    SET @XML = @XML + N'  <packages>' + CHAR(10);

    -- -------------------------------------------------------------------------
    -- 4. Loop schemas → packages
    -- -------------------------------------------------------------------------
    DECLARE @pkgSchema   SYSNAME;
    DECLARE @pkgTot INT, @pkgCov INT, @pkgTB INT, @pkgCB INT;
    DECLARE @pkgLineRate VARCHAR(20), @pkgBranchRate VARCHAR(20);

    DECLARE pkg CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT SchemaName
        FROM   TestGen.CoverageResult
        WHERE  BatchId     = @BatchId
          AND  Testability <> N'NOT_TESTABLE'
          AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter)
        ORDER  BY SchemaName;
    OPEN pkg;
    FETCH NEXT FROM pkg INTO @pkgSchema;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @pkgTot = ISNULL(SUM(TotalLines),0),
               @pkgCov = ISNULL(SUM(CoveredLines),0),
               @pkgTB  = ISNULL(SUM(TotalBranches),0),
               @pkgCB  = ISNULL(SUM(CoveredBranches),0)
        FROM   TestGen.CoverageResult
        WHERE  BatchId     = @BatchId
          AND  SchemaName  = @pkgSchema
          AND  Testability <> N'NOT_TESTABLE';

        SET @pkgLineRate   = CAST(CASE WHEN @pkgTot > 0 THEN CAST(1.0 * @pkgCov / @pkgTot AS DECIMAL(10,4)) ELSE 0 END AS VARCHAR(20));
        SET @pkgBranchRate = CAST(CASE WHEN @pkgTB  > 0 THEN CAST(1.0 * @pkgCB  / @pkgTB  AS DECIMAL(10,4)) ELSE 1 END AS VARCHAR(20));

        SET @XML = @XML
            + N'    <package name="' + @pkgSchema + N'"'
            + N' line-rate="'   + @pkgLineRate   + N'"'
            + N' branch-rate="' + @pkgBranchRate + N'"'
            + N' complexity="0">' + CHAR(10);
        SET @XML = @XML + N'      <classes>' + CHAR(10);

        -- ----------------------------------------------------------------------
        -- 5. Loop procs → classes
        -- ----------------------------------------------------------------------
        DECLARE @clsProc SYSNAME;
        DECLARE @clsTot INT, @clsCov INT, @clsTB INT, @clsCB INT;
        DECLARE @clsLineRate VARCHAR(20), @clsBranchRate VARCHAR(20);

        DECLARE cls CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProcName,
                   ISNULL(TotalLines,0),    ISNULL(CoveredLines,0),
                   ISNULL(TotalBranches,0), ISNULL(CoveredBranches,0)
            FROM   TestGen.CoverageResult
            WHERE  BatchId     = @BatchId
              AND  SchemaName  = @pkgSchema
              AND  Testability <> N'NOT_TESTABLE'
            ORDER  BY ProcName;
        OPEN cls;
        FETCH NEXT FROM cls INTO @clsProc, @clsTot, @clsCov, @clsTB, @clsCB;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @clsLineRate   = CAST(CASE WHEN @clsTot > 0 THEN CAST(1.0 * @clsCov / @clsTot AS DECIMAL(10,4)) ELSE 0 END AS VARCHAR(20));
            SET @clsBranchRate = CAST(CASE WHEN @clsTB  > 0 THEN CAST(1.0 * @clsCB  / @clsTB  AS DECIMAL(10,4)) ELSE 1 END AS VARCHAR(20));

            SET @XML = @XML
                + N'        <class'
                + N' name="'        + @pkgSchema + N'.' + @clsProc + N'"'
                + N' filename="'    + @pkgSchema + N'/' + @clsProc + N'.sql"'
                + N' line-rate="'   + @clsLineRate   + N'"'
                + N' branch-rate="' + @clsBranchRate + N'"'
                + N' complexity="0">' + CHAR(10);
            SET @XML = @XML + N'          <methods/>' + CHAR(10);
            SET @XML = @XML + N'          <lines>' + CHAR(10);

            -- ------------------------------------------------------------------
            -- 6. Per-line detail — same EffectiveHit logic as GetCoverageReport
            -- ------------------------------------------------------------------
            DECLARE @lNum INT, @lExec BIT, @lBranch BIT, @lHit INT;

            DECLARE lns CURSOR LOCAL FAST_FORWARD FOR
                WITH lines AS (
                    SELECT cl.LineNum, cl.IsExec, cl.IsBranch,
                           CASE WHEN EXISTS (
                               SELECT 1 FROM TestGen.CoverageHits ch
                               WHERE  ch.SchemaName = cl.SchemaName
                                 AND  ch.ProcName   = cl.ProcName
                                 AND  ch.LineNum    = cl.LineNum
                           ) THEN 1 ELSE 0 END AS DirectHit
                    FROM   TestGen.CoverageLines cl
                    WHERE  cl.SchemaName = @pkgSchema
                      AND  cl.ProcName   = @clsProc
                ),
                nx AS (
                    SELECT l.LineNum,
                           ( SELECT TOP 1 e.LineNum
                             FROM   lines e
                             WHERE  e.IsExec = 1 AND e.LineNum > l.LineNum
                             ORDER  BY e.LineNum ) AS NextExecLine
                    FROM   lines l
                    WHERE  l.IsBranch = 1
                ),
                bi AS (
                    SELECT n.LineNum, ISNULL(l.DirectHit, 0) AS BodyHit
                    FROM   nx n LEFT JOIN lines l ON l.LineNum = n.NextExecLine
                )
                SELECT l.LineNum, l.IsExec, l.IsBranch,
                       CASE
                           WHEN l.IsExec   = 1 AND l.DirectHit = 1 THEN 1
                           WHEN l.IsBranch = 1 AND b.BodyHit   = 1 THEN 1
                           ELSE 0
                       END AS EffectiveHit
                FROM   lines l LEFT JOIN bi b ON b.LineNum = l.LineNum
                WHERE  l.IsExec = 1 OR l.IsBranch = 1
                ORDER  BY l.LineNum;

            OPEN lns;
            FETCH NEXT FROM lns INTO @lNum, @lExec, @lBranch, @lHit;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @lBranch = 1
                    -- Branch line: model as 2 conditions (taken / not-taken).
                    -- EffectiveHit = 1 means the body was entered (true branch taken).
                    SET @XML = @XML
                        + N'            <line number="' + CAST(@lNum AS VARCHAR)
                        + N'" hits="' + CAST(@lHit AS VARCHAR)
                        + N'" branch="true"'
                        + N' condition-coverage="'
                        + CASE WHEN @lHit = 1 THEN N'50% (1/2)' ELSE N'0% (0/2)' END
                        + N'">' + CHAR(10)
                        + N'              <conditions>'
                        + N'<condition number="0" type="jump" coverage="'
                        + CASE WHEN @lHit = 1 THEN N'50%' ELSE N'0%' END
                        + N'"/>'
                        + N'</conditions>' + CHAR(10)
                        + N'            </line>' + CHAR(10);
                ELSE
                    SET @XML = @XML
                        + N'            <line number="' + CAST(@lNum AS VARCHAR)
                        + N'" hits="' + CAST(@lHit AS VARCHAR)
                        + N'" branch="false"/>' + CHAR(10);

                FETCH NEXT FROM lns INTO @lNum, @lExec, @lBranch, @lHit;
            END;
            CLOSE lns; DEALLOCATE lns;

            SET @XML = @XML + N'          </lines>' + CHAR(10);
            SET @XML = @XML + N'        </class>' + CHAR(10);

            FETCH NEXT FROM cls INTO @clsProc, @clsTot, @clsCov, @clsTB, @clsCB;
        END;
        CLOSE cls; DEALLOCATE cls;

        SET @XML = @XML + N'      </classes>' + CHAR(10);
        SET @XML = @XML + N'    </package>' + CHAR(10);

        FETCH NEXT FROM pkg INTO @pkgSchema;
    END;
    CLOSE pkg; DEALLOCATE pkg;

    SET @XML = @XML + N'  </packages>' + CHAR(10);
    SET @XML = @XML + N'</coverage>' + CHAR(10);

    SELECT @XML AS CoberturaXml;
END;
GO
PRINT 'TestGen.GetCoverageCoberturaXml created.';
GO
