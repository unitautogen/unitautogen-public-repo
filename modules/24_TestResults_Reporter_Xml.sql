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
 * TestGen.GetTestResultsJunitXml
 *
 * Emits a JUnit-compatible XML test results document for a completed batch.
 * Consumed natively by:
 *   - Azure DevOps  "Publish Test Results" task (format: JUnit)
 *   - GitHub Actions  dorny/test-reporter, mikepenz/action-junit-report
 *   - Jenkins  JUnit Plugin
 *   - GitLab CI  junit: test-results.xml
 *   - SonarQube  sonar.junit.reportPaths
 *
 * Parameters
 * ----------
 *   @BatchId      DATETIME2(3)  -- BatchId from TestGen.CoverageResult.
 *                                  NULL = most recent batch.
 *   @SchemaFilter SYSNAME       -- Restrict to one schema. NULL = all schemas.
 *
 * Output
 * ------
 *   Single SELECT column  JUnitXml NVARCHAR(MAX)
 *
 * Typical usage (direct)
 * ----------------------
 *   EXEC TestGen.GetTestResultsJunitXml;                   -- latest batch
 *   EXEC TestGen.GetTestResultsJunitXml @SchemaFilter = 'dbo';
 *
 * Structure
 * ---------
 *   <testsuites>               one per database run (batch)
 *     <testsuite name="dbo">  one per schema
 *       <testcase .../>        one per stored procedure
 *         (no child)           all tests passed
 *         <skipped/>           procedure is NOT_TESTABLE
 *         <failure/>           one or more tSQLt tests failed
 *         <error/>             generation failed or tests errored
 *
 * Design notes
 * ------------
 *   - Reads from TestGen.CoverageResult (populated by GenerateAndCoverDatabase).
 *   - One <testcase> per stored procedure using aggregate pass/fail counts.
 *   - XML special characters in messages are escaped (&amp; &lt; &gt; etc.).
 *   - All variables declared at proc top — no DECLARE inside loops (T-SQL
 *     DECLARE initializers evaluate once at batch parse, not per iteration).
 ******************************************************************************/

IF OBJECT_ID('TestGen.GetTestResultsJunitXml','P') IS NOT NULL
    DROP PROCEDURE TestGen.GetTestResultsJunitXml;
GO

CREATE PROCEDURE TestGen.GetTestResultsJunitXml
    @BatchId      DATETIME2(3) = NULL,   -- NULL = most recent batch
    @SchemaFilter SYSNAME      = NULL    -- NULL = all schemas
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- All working variables declared at proc top (avoids DECLARE-in-loop trap)
    -- -------------------------------------------------------------------------
    DECLARE @gTests    INT, @gFail   INT, @gErr  INT, @gSkip INT;
    DECLARE @Timestamp VARCHAR(30);
    DECLARE @XML       NVARCHAR(MAX);
    DECLARE @pkgSchema SYSNAME;
    DECLARE @pkgTests  INT, @pkgFail INT, @pkgErr INT, @pkgSkip INT;
    DECLARE @clsProc   SYSNAME;
    DECLARE @clsGen    BIT,  @clsRun  INT, @clsFail INT, @clsErr INT, @clsSkip INT;
    DECLARE @clsTestability VARCHAR(20);
    DECLARE @clsReason      NVARCHAR(400);
    DECLARE @clsErrTxt      NVARCHAR(2000);
    DECLARE @safeMsg        NVARCHAR(2000);

    -- -------------------------------------------------------------------------
    -- 1. Resolve BatchId
    -- -------------------------------------------------------------------------
    IF @BatchId IS NULL
        SELECT TOP 1 @BatchId = BatchId
        FROM   TestGen.CoverageResult
        ORDER  BY BatchId DESC;

    IF @BatchId IS NULL
    BEGIN
        RAISERROR('TestGen.GetTestResultsJunitXml: no results found. Run GenerateAndCoverDatabase first.',16,1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- 2. Database-level totals — use actual tSQLt test counts so CI/CD
    --    dashboards show real numbers (e.g. tests=64) not proc counts (10).
    --    TestsRun / TestsFailed / TestsErrored / TestsSkipped are the tSQLt
    --    method-level counts stored by GenerateAndCoverDatabase per proc.
    --    NOT_TESTABLE procs contribute TestsRun=0 and TestsSkipped=1 (the
    --    [@tSQLt:SkipTest] marker), so SUM(TestsSkipped) naturally includes
    --    both tSQLt-level skips and NOT_TESTABLE marker skips.
    -- -------------------------------------------------------------------------
    SELECT
        @gTests = ISNULL(SUM(TestsRun),     0),
        @gFail  = ISNULL(SUM(TestsFailed),  0),
        @gErr   = ISNULL(SUM(TestsErrored), 0),
        @gSkip  = ISNULL(SUM(TestsSkipped), 0)
    FROM   TestGen.CoverageResult
    WHERE  BatchId = @BatchId
      AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter);

    SET @Timestamp = CONVERT(VARCHAR(30), @BatchId, 126);  -- ISO 8601

    -- -------------------------------------------------------------------------
    -- 3. Root element
    -- -------------------------------------------------------------------------
    SET @XML = N'<?xml version="1.0" encoding="UTF-8"?>' + CHAR(10);
    SET @XML = @XML
        + N'<testsuites'
        + N' name="UnitAutogen"'
        + N' tests="'    + CAST(@gTests AS VARCHAR) + N'"'
        + N' failures="' + CAST(@gFail  AS VARCHAR) + N'"'
        + N' errors="'   + CAST(@gErr   AS VARCHAR) + N'"'
        + N' skipped="'  + CAST(@gSkip  AS VARCHAR) + N'"'
        + N' timestamp="' + @Timestamp + N'"'
        + N' hostname="'  + DB_NAME()  + N'">' + CHAR(10);

    -- -------------------------------------------------------------------------
    -- 4. Loop schemas → <testsuite> elements
    -- -------------------------------------------------------------------------
    DECLARE pkg CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT SchemaName
        FROM   TestGen.CoverageResult
        WHERE  BatchId = @BatchId
          AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter)
        ORDER  BY SchemaName;
    OPEN pkg;
    FETCH NEXT FROM pkg INTO @pkgSchema;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT
            @pkgTests = ISNULL(SUM(TestsRun),     0),
            @pkgFail  = ISNULL(SUM(TestsFailed),  0),
            @pkgErr   = ISNULL(SUM(TestsErrored), 0),
            @pkgSkip  = ISNULL(SUM(TestsSkipped), 0)
        FROM   TestGen.CoverageResult
        WHERE  BatchId    = @BatchId
          AND  SchemaName = @pkgSchema;

        SET @XML = @XML
            + N'  <testsuite'
            + N' name="'     + @pkgSchema + N'"'
            + N' tests="'    + CAST(@pkgTests AS VARCHAR) + N'"'
            + N' failures="' + CAST(@pkgFail  AS VARCHAR) + N'"'
            + N' errors="'   + CAST(@pkgErr   AS VARCHAR) + N'"'
            + N' skipped="'  + CAST(@pkgSkip  AS VARCHAR) + N'"'
            + N' time="0">'  + CHAR(10);

        -- ----------------------------------------------------------------------
        -- 5. Loop procs → <testcase> elements
        -- ----------------------------------------------------------------------
        DECLARE cls CURSOR LOCAL FAST_FORWARD FOR
            SELECT ProcName, GenSucceeded,
                   TestsRun, TestsFailed, TestsErrored, TestsSkipped,
                   Testability, NotTestableReason, ErrorText
            FROM   TestGen.CoverageResult
            WHERE  BatchId    = @BatchId
              AND  SchemaName = @pkgSchema
            ORDER  BY ProcName;
        OPEN cls;
        FETCH NEXT FROM cls INTO @clsProc, @clsGen, @clsRun, @clsFail, @clsErr, @clsSkip,
                                  @clsTestability, @clsReason, @clsErrTxt;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @XML = @XML
                + N'    <testcase'
                + N' name="'      + @pkgSchema + N'.' + @clsProc + N'"'
                + N' classname="' + @pkgSchema + N'"'
                + N' time="0">';

            IF @clsTestability = N'NOT_TESTABLE'
            BEGIN
                -- NOT_TESTABLE → <skipped/> with reason as message attribute
                SET @safeMsg = ISNULL(@clsReason, N'not auto-testable');
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <skipped message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END
            ELSE IF @clsGen = 0
            BEGIN
                -- Generation failed → <error/>
                SET @safeMsg = ISNULL(@clsErrTxt, N'test generation failed');
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <error message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END
            ELSE IF @clsFail > 0
            BEGIN
                -- One or more tSQLt tests failed → <failure/>
                SET @safeMsg = CAST(@clsFail AS NVARCHAR) + N' of ' + CAST(@clsRun AS NVARCHAR)
                    + N' tests failed'
                    + CASE WHEN @clsErrTxt IS NOT NULL THEN N'. ' + @clsErrTxt ELSE N'' END;
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <failure message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END
            ELSE IF @clsErr > 0
            BEGIN
                -- One or more tSQLt tests errored → <error/>
                SET @safeMsg = CAST(@clsErr AS NVARCHAR) + N' of ' + CAST(@clsRun AS NVARCHAR)
                    + N' tests errored'
                    + CASE WHEN @clsErrTxt IS NOT NULL THEN N'. ' + @clsErrTxt ELSE N'' END;
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <error message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END;
            -- else: all tests passed — <testcase> needs no child element

            SET @XML = @XML + N'</testcase>' + CHAR(10);

            FETCH NEXT FROM cls INTO @clsProc, @clsGen, @clsRun, @clsFail, @clsErr, @clsSkip,
                                      @clsTestability, @clsReason, @clsErrTxt;
        END;
        CLOSE cls; DEALLOCATE cls;

        SET @XML = @XML + N'  </testsuite>' + CHAR(10);

        FETCH NEXT FROM pkg INTO @pkgSchema;
    END;
    CLOSE pkg; DEALLOCATE pkg;

    SET @XML = @XML + N'</testsuites>' + CHAR(10);

    SELECT @XML AS JUnitXml;
END;
GO
PRINT 'TestGen.GetTestResultsJunitXml created.';
GO
