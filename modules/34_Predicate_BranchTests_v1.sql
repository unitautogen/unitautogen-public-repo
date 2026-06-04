/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 * GNU Affero General Public License v3.0. See LICENSE / COPYRIGHT.
 * Distributed WITHOUT ANY WARRANTY. Commercial licence: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

/*=============================================================================
 * MODULE 34 - Seeded predicate-branch test generator (v0.10)
 * The string generator (04) detects a data-shape gate as 2 branches but reaches
 * only the default arm (50%). This adds the missing arm: per gate, per direction,
 * a tSQLt test (FakeTable target + v0.10 seed + EXEC). Gates/directions it cannot
 * seed get a [@tSQLt:SkipTest] marker => reported SKIPPED, not failed.
 * Complementary: adds to the proc's test class; never edits module 04.
 * Clears its own prior "(v0.10)" tests each run, so re-runs and shape changes
 * never leave stale tests behind.
 *===========================================================================*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('TestGen.GeneratePredicateBranchTests', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GeneratePredicateBranchTests;
GO
CREATE PROCEDURE TestGen.GeneratePredicateBranchTests
    @SchemaName    SYSNAME,
    @ProcName      SYSNAME,
    @RunId         UNIQUEIDENTIFIER = NULL,
    @TestClassName SYSNAME          = NULL,
    @Execute       BIT              = 1,
    @TestsEmitted  INT              = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TestsEmitted = 0;
    IF @TestClassName IS NULL SET @TestClassName = N'test_' + @ProcName;

    DECLARE @full NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ProcName);
    IF OBJECT_ID(@full, 'P') IS NULL
    BEGIN
        RAISERROR('GeneratePredicateBranchTests: proc %s not found.', 16, 1, @full);
        RETURN;
    END;

    IF SCHEMA_ID(@TestClassName) IS NULL
        EXEC tSQLt.NewTestClass @ClassName = @TestClassName;

    DECLARE @q NCHAR(1) = NCHAR(39);
    DECLARE @crlf NCHAR(2) = NCHAR(13) + NCHAR(10);

    -- Clean slate: drop any prior v0.10 tests in this class (handles re-runs and
    -- predicate shape changes so no stale TRUE/FALSE/NOT_TESTABLE tests linger).
    IF @Execute = 1
    BEGIN
        DECLARE @cleanup NVARCHAR(MAX) = N'';
        SELECT @cleanup = @cleanup + N'DROP PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(o.name) + N';' + @crlf
        FROM   sys.procedures o
        WHERE  o.schema_id = SCHEMA_ID(@TestClassName) AND o.name LIKE '%(v0.10)';
        IF LEN(ISNULL(@cleanup, N'')) > 0 EXEC sp_executesql @cleanup;
    END;

    -- Default EXEC argument list from ALL the proc's parameters. OUTPUT
    -- parameters that have no default must still be supplied or the EXEC fails
    -- ("expects parameter '@x', which was not supplied"); they are passed BY
    -- VALUE (a sample literal, no OUTPUT keyword - the branch test only runs the
    -- proc for coverage, it does not capture outputs).
    DECLARE @args NVARCHAR(MAX) = N'';
    SELECT @args = @args + CASE WHEN @args = N'' THEN N'' ELSE N', ' END
                 + pr.name + N' = '
                 + TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
    FROM   sys.parameters pr
    JOIN   sys.types t ON t.user_type_id = pr.user_type_id
    WHERE  pr.object_id = OBJECT_ID(@full) AND pr.parameter_id > 0
    ORDER  BY pr.parameter_id;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId FROM TestGen.PredicateInbox
        WHERE SchemaName = @SchemaName AND ProcName = @ProcName
        ORDER BY CreatedAt DESC, InboxId DESC;

    DECLARE @InboxId INT, @BranchId INT, @StartLine INT, @Shape VARCHAR(32),
            @TablesJson NVARCHAR(MAX), @PredText NVARCHAR(MAX), @UnsReason NVARCHAR(400);
    DECLARE @fakes NVARCHAR(MAX), @dir VARCHAR(8), @i INT,
            @seed NVARCHAR(MAX), @sup BIT, @rsn NVARCHAR(400),
            @tname NVARCHAR(300), @body NVARCHAR(MAX), @esc NVARCHAR(MAX), @ps NVARCHAR(MAX), @eb BIT;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT InboxId, BranchId, StartLine, Shape, TargetTablesJson, PredicateText, UnsupportedReason
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
          AND  (@RunId IS NULL OR RunId = @RunId)
        ORDER  BY BranchId;
    OPEN c;
    FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Shape, @TablesJson, @PredText, @UnsReason;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @fakes = N'';
        SELECT @fakes = @fakes + N'    EXEC TestGen.SafeFakeTable N'''
             + ISNULL(JSON_VALUE([value], '$.schema'), 'dbo') + N'.' + JSON_VALUE([value], '$.table')
             + N''';' + @crlf
        FROM OPENJSON(@TablesJson)
        WHERE JSON_VALUE([value], '$.table') IS NOT NULL;

        IF @Shape = 'UNRECOGNISED'
        BEGIN
            SET @esc = REPLACE(LEFT(ISNULL(@PredText, N''), 240) + N' - '
                     + ISNULL(@UnsReason, N'outside the v0.10 predicate grammar'), @q, @q + @q);
            SET @tname = N'test ' + @ProcName + N' branch ' + CAST(@BranchId AS NVARCHAR(10))
                       + N' line ' + CAST(ISNULL(@StartLine, 0) AS NVARCHAR(10)) + N' NOT_TESTABLE (v0.10)';
            SET @body = N'--[@tSQLt:SkipTest](' + @q + N'NOT_TESTABLE: ' + @esc + @q + N')' + @crlf
                + N'CREATE PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@tname) + @crlf
                + N'AS' + @crlf + N'BEGIN SET NOCOUNT ON; /* predicate outside v0.10 grammar - see annotation */ END;';
            IF @Execute = 1 EXEC sp_executesql @body;
            SET @TestsEmitted = @TestsEmitted + 1;
        END
        ELSE
        BEGIN
            SET @i = 0;
            WHILE @i < 2
            BEGIN
                SET @dir = CASE @i WHEN 0 THEN 'TRUE' ELSE 'FALSE' END;
                EXEC TestGen.SatisfyPredicate @InboxId = @InboxId, @Direction = @dir,
                     @SeedSql = @seed OUTPUT, @Supported = @sup OUTPUT, @Reason = @rsn OUTPUT,
                     @PredicateSql = @ps OUTPUT, @ExpectedBit = @eb OUTPUT;

                SET @tname = N'test ' + @ProcName + N' branch ' + CAST(@BranchId AS NVARCHAR(10))
                           + N' line ' + CAST(ISNULL(@StartLine, 0) AS NVARCHAR(10))
                           + N' predicate ' + @dir + N' (v0.10)';

                IF @sup = 1 AND @ps IS NOT NULL
                BEGIN
                    SET @body = N'CREATE PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@tname) + @crlf
                        + N'AS' + @crlf + N'BEGIN' + @crlf + ISNULL(@fakes, N'');
                    IF @seed IS NOT NULL SET @body = @body + @seed + @crlf;
                    -- STRONG assertion: the seed must drive the gate predicate to
                    -- the intended direction (no ghost pass - a wrong seed fails here).
                    SET @body = @body
                        + N'    DECLARE @uag_actual BIT = CASE WHEN ' + @ps + N' THEN 1 ELSE 0 END;' + @crlf
                        + N'    EXEC tSQLt.AssertEquals @Expected = ' + CAST(@eb AS NVARCHAR(1)) + N', @Actual = @uag_actual,' + @crlf
                        + N'         @Message = N''v0.10 ' + @dir + N': seed did not drive the gate predicate ' + @dir + N' (branch not exercised)'';' + @crlf
                        + N'    BEGIN TRY' + @crlf
                        + N'        EXEC ' + @full + N' ' + @args + N';' + @crlf
                        + N'    END TRY BEGIN CATCH' + @crlf
                        + N'        DECLARE @e NVARCHAR(MAX) = N''v0.10 branch ' + @dir
                        + N' seed EXEC failed: '' + ERROR_MESSAGE();' + @crlf
                        + N'        EXEC tSQLt.Fail @e;' + @crlf
                        + N'    END CATCH;' + @crlf + N'END;';
                END
                ELSE
                BEGIN
                    SET @esc = REPLACE(LEFT(ISNULL(@PredText, N''), 200) + N' (' + @dir + N') - '
                             + ISNULL(@rsn, CASE WHEN @sup = 1 THEN N'seed produced but predicate could not be reconstructed to assert (skipped, not ghost-passed)' ELSE N'cannot seed this direction' END), @q, @q + @q);
                    SET @body = N'--[@tSQLt:SkipTest](' + @q + N'NOT_TESTABLE: ' + @esc + @q + N')' + @crlf
                        + N'CREATE PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@tname) + @crlf
                        + N'AS' + @crlf + N'BEGIN SET NOCOUNT ON; /* direction not seedable - see annotation */ END;';
                END;

                IF @Execute = 1 EXEC sp_executesql @body;
                SET @TestsEmitted = @TestsEmitted + 1;
                SET @i = @i + 1;
            END;
        END;
        FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Shape, @TablesJson, @PredText, @UnsReason;
    END;
    CLOSE c; DEALLOCATE c;

    PRINT 'GeneratePredicateBranchTests: emitted ' + CAST(@TestsEmitted AS NVARCHAR(10))
        + ' predicate-branch test(s) into ' + QUOTENAME(@TestClassName) + '.';
END;
GO

PRINT 'Module 34 (seeded predicate-branch test generator) installed.';
GO