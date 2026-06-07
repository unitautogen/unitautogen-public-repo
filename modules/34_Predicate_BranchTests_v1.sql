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

    -- v0.11 boundary-effect target. When the proc has EXACTLY ONE gate AND EXACTLY
    -- ONE fakeable updated (base) table, the FALSE/boundary test can additionally
    -- assert the guarded write did NOT happen - which catches operator-loosening
    -- (e.g. > changed to >=). Strictly conservative: if anything is ambiguous,
    -- @TargetTable stays NULL and the generated tests are byte-for-byte unchanged
    -- (no new assertion, no new failure risk). See CHANGES 2026-06-07.
    DECLARE @TargetTable NVARCHAR(300) = NULL, @TargetPlain NVARCHAR(300) = NULL,
            @TargetSchema SYSNAME = NULL, @TargetName SYSNAME = NULL;
    DECLARE @tgtFake NVARCHAR(MAX) = N'', @tgtBefore NVARCHAR(MAX) = N'', @tgtAssert NVARCHAR(MAX) = N'', @preSeed NVARCHAR(MAX) = NULL;
    DECLARE @GateCount INT = (SELECT COUNT(*) FROM TestGen.PredicateInbox
                              WHERE SchemaName = @SchemaName AND ProcName = @ProcName
                                AND (@RunId IS NULL OR RunId = @RunId));
    IF @GateCount = 1
    BEGIN
        BEGIN TRY
            SELECT @TargetSchema = MAX(referenced_schema_name),
                   @TargetName   = MAX(referenced_entity_name)
            FROM   sys.dm_sql_referenced_entities(@full, N'OBJECT')
            WHERE  is_updated = 1 AND referenced_entity_name IS NOT NULL
              AND  ISNULL(referenced_schema_name, N'') NOT IN (N'sys', N'INFORMATION_SCHEMA')
            HAVING COUNT(DISTINCT ISNULL(referenced_schema_name, N'dbo') + N'.' + referenced_entity_name) = 1;
        END TRY BEGIN CATCH SET @TargetName = NULL; END CATCH;

        IF @TargetName IS NOT NULL
        BEGIN
            IF OBJECT_ID(QUOTENAME(ISNULL(@TargetSchema, N'dbo')) + N'.' + QUOTENAME(@TargetName), 'U') IS NOT NULL
            BEGIN
                SET @TargetPlain = ISNULL(@TargetSchema, N'dbo') + N'.' + @TargetName;
                SET @TargetTable = QUOTENAME(ISNULL(@TargetSchema, N'dbo')) + N'.' + QUOTENAME(@TargetName);
            END;
        END;
    END;

    DECLARE @InboxId INT, @BranchId INT, @StartLine INT, @Shape VARCHAR(32),
            @TablesJson NVARCHAR(MAX), @PredText NVARCHAR(MAX), @UnsReason NVARCHAR(400),
            @BodyDmlSeedJson NVARCHAR(MAX);
    DECLARE @fakes NVARCHAR(MAX), @dir VARCHAR(8), @i INT,
            @seed NVARCHAR(MAX), @sup BIT, @rsn NVARCHAR(400),
            @tname NVARCHAR(300), @body NVARCHAR(MAX), @esc NVARCHAR(MAX), @ps NVARCHAR(MAX), @eb BIT;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT InboxId, BranchId, StartLine, Shape, TargetTablesJson, PredicateText, UnsupportedReason, BodyDmlSeedJson
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
          AND  (@RunId IS NULL OR RunId = @RunId)
        ORDER  BY BranchId;
    OPEN c;
    FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Shape, @TablesJson, @PredText, @UnsReason, @BodyDmlSeedJson;
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
                    -- v0.11: the FALSE/boundary direction can also assert the guarded
                    -- write did NOT fire (catches > -> >= style operator loosening).
                    -- Reset per iteration (vars hoisted to proc top; never DECLARE in loop).
                    SET @tgtFake = N''; SET @tgtBefore = N''; SET @tgtAssert = N''; SET @preSeed = NULL;
                    -- v0.11.1: assert the guarded write (INSERT / UPDATE / DELETE) did NOT fire
                    -- on the boundary seed. Only when T is a separate write target (not a gate
                    -- source). Pre-seed T with sample rows so UPDATE/DELETE have something to act
                    -- on, then compare full content before/after: a row-count change catches
                    -- INSERT/DELETE; AssertEqualsTable catches UPDATE. Mutating > to >= makes the
                    -- gate true at the boundary, the write fires, the content differs, test fails.
                    IF @dir = 'FALSE' AND @TargetTable IS NOT NULL
                       AND CHARINDEX(N'N''' + @TargetPlain + N'''', ISNULL(@fakes, N'')) = 0
                    BEGIN
                        -- v0.12: when the parser lifted seed overrides from the guarded
                        -- DML's WHERE (col=literal / col IN(...)), seed rows that satisfy it
                        -- so a selective UPDATE/DELETE actually hits them. Else generic seed.
                        SET @preSeed = TestGen.BuildSeedInsert(@TargetSchema, @TargetName,
                            CASE WHEN @BodyDmlSeedJson IS NOT NULL
                                      AND JSON_VALUE(@BodyDmlSeedJson, N'$.table') = @TargetName
                                      AND ISNULL(JSON_VALUE(@BodyDmlSeedJson, N'$.schema'), N'dbo') = ISNULL(@TargetSchema, N'dbo')
                                 THEN JSON_QUERY(@BodyDmlSeedJson, N'$.overrides') ELSE NULL END, 3);
                        SET @tgtFake = N'    EXEC TestGen.SafeFakeTable N''' + REPLACE(@TargetPlain, @q, @q + @q) + N''';' + @crlf
                                     + ISNULL(N'    ' + @preSeed + @crlf, N'');
                        SET @tgtBefore = N'    SELECT * INTO #uag_tgt_before FROM ' + @TargetTable + N';' + @crlf;
                        SET @tgtAssert = N'    SELECT * INTO #uag_tgt_after FROM ' + @TargetTable + N';' + @crlf
                            + N'    DECLARE @uag_cb INT = (SELECT COUNT(*) FROM #uag_tgt_before);' + @crlf
                            + N'    DECLARE @uag_ca INT = (SELECT COUNT(*) FROM #uag_tgt_after);' + @crlf
                            + N'    EXEC tSQLt.AssertEquals @Expected = @uag_cb, @Actual = @uag_ca,' + @crlf
                            + N'         @Message = N''v0.11 boundary: gate is FALSE with this seed but the guarded write to '
                            + REPLACE(@TargetPlain, @q, @q + @q) + N' changed its row count - the comparison operator may have been loosened (e.g. > to >=).'';' + @crlf
                            + N'    EXEC tSQLt.AssertEqualsTable ''#uag_tgt_before'', ''#uag_tgt_after'';' + @crlf;
                    END;

                    SET @body = N'CREATE PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@tname) + @crlf
                        + N'AS' + @crlf + N'BEGIN' + @crlf + ISNULL(@fakes, N'') + @tgtFake;
                    IF @seed IS NOT NULL SET @body = @body + @seed + @crlf;
                    -- STRONG assertion: the seed must drive the gate predicate to
                    -- the intended direction (no ghost pass - a wrong seed fails here).
                    SET @body = @body
                        + N'    DECLARE @uag_actual BIT = CASE WHEN ' + @ps + N' THEN 1 ELSE 0 END;' + @crlf
                        + N'    EXEC tSQLt.AssertEquals @Expected = ' + CAST(@eb AS NVARCHAR(1)) + N', @Actual = @uag_actual,' + @crlf
                        + N'         @Message = N''v0.10 ' + @dir + N': seed did not drive the gate predicate ' + @dir + N' (branch not exercised)'';' + @crlf
                        + @tgtBefore
                        + N'    BEGIN TRY' + @crlf
                        + N'        EXEC ' + @full + N' ' + @args + N';' + @crlf
                        + N'    END TRY BEGIN CATCH' + @crlf
                        + N'        DECLARE @e NVARCHAR(MAX) = N''v0.10 branch ' + @dir
                        + N' seed EXEC failed: '' + ERROR_MESSAGE();' + @crlf
                        + N'        EXEC tSQLt.Fail @e;' + @crlf
                        + N'    END CATCH;' + @crlf + @tgtAssert + N'END;';
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
        FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Shape, @TablesJson, @PredText, @UnsReason, @BodyDmlSeedJson;
    END;
    CLOSE c; DEALLOCATE c;

    PRINT 'GeneratePredicateBranchTests: emitted ' + CAST(@TestsEmitted AS NVARCHAR(10))
        + ' predicate-branch test(s) into ' + QUOTENAME(@TestClassName) + '.';
END;
GO

PRINT 'Module 34 (seeded predicate-branch test generator) installed.';
GO