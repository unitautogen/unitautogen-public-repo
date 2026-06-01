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

/*****************************************************************************
 * TestGen.GenerateTestsForProcedure
 * -----------------------------------------------------------------------------
 * The main entry point of the framework. Given a schema-qualified stored
 * procedure, it emits a complete tSQLt test class (as a single CREATE SCHEMA +
 * CREATE PROCEDURE script). It also optionally executes that script so the
 * tests become immediately runnable.
 *
 * Tests it generates (when applicable):
 *   1. test_<Proc>_executes_with_valid_inputs        (smoke)
 *   2. test_<Proc>_accepts_boundary_values           (low / high samples)
 *   3. test_<Proc>_handles_nulls_in_nullable_params  (every nullable param)
 *   4. test_<Proc>_does_not_modify_referenced_tables_when_inputs_invalid
 *      (uses FakeTable on every referenced table)
 *   5. test_<Proc>_calls_dependent_procedures        (uses SpyProcedure)
 *   6. test_<Proc>_returns_assigned_output_parameters
 *   7. test_<Proc>_assertNoSideEffects               (asserts row counts stable)
 *
 * Mocking strategy (uses tSQLt internals):
 *   - For every referenced TABLE / VIEW -> tSQLt.FakeTable @PreserveColumns = 1
 *     so the proc still compiles but writes go to an isolated copy.
 *   - For every referenced PROCEDURE    -> tSQLt.SpyProcedure to capture calls
 *     in a generated <proc>_SpyProcedureLog table without executing real code.
 *   - For every referenced FUNCTION     -> a tSQLt.FakeFunction stub is
 *     emitted as a TODO comment (functions are harder to mock generically).
 *
 * Parameters:
 *   @SchemaName       Schema of the target procedure
 *   @ProcName         Name of the target procedure
 *   @TestClassName    Name of the tSQLt test class/schema to create.
 *                     Default: 'test_' + @ProcName
 *   @ExecuteScript    1 = run the generated script (creates the tests).
 *                     0 = only return the script as @GeneratedScript output.
 *   @GeneratedScript  OUTPUT - the full CREATE script.
 *   @RunId            OUTPUT - the row ID written to TestGenLog.GenerationRun.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GenerateTestsForProcedure', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForProcedure;
GO

CREATE PROCEDURE TestGen.GenerateTestsForProcedure
    @SchemaName                    SYSNAME,
    @ProcName                      SYSNAME,
    @TestClassName                 SYSNAME       = NULL,
    @ExecuteScript                 BIT           = 1,
    @CaptureRows                   BIT           = 1,    -- golden-row baseline ON: matched key args now align with the seed (procs return rows), so the captured baseline is meaningful (validated: CustOrderHist -> 1 row on Northwind).
    @EmitNegativeTests             BIT           = 1,    -- when 1, scan source for RAISERROR/THROW and emit ExpectException tests
    @AssertExceptionOnInvalidInputs BIT          = 1,    -- when 1, boundary + NULL-for-matched-param tests expect an exception (only if the proc has detected error paths)
    @EmitNullChecks                BIT           = 1,    -- when 0, do not emit the NULL-rejection tests
    @EmitScaffold                  BIT           = 1,    -- when 0, do not emit the set-based characterization scaffold
    @GeneratedScript               NVARCHAR(MAX) = NULL OUTPUT,
    @RunId                         INT           = NULL OUTPUT,
    @TestsPreservedCount           INT           = 0 OUTPUT  -- v9.4.4: count of developer-modified tests carried across this regen
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);
    SET @TestsPreservedCount = 0;   -- v9.4.4: reset every call

    IF @TestClassName IS NULL
        SET @TestClassName = N'test_' + @ProcName;

    -- Validate target exists
    IF OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName), 'P') IS NULL
    BEGIN
        RAISERROR('Stored procedure %s.%s does not exist.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    -- Log run start
    INSERT TestGenLog.GenerationRun (TargetSchema, TargetProcedure, TestClassName)
    VALUES (@SchemaName, @ProcName, @TestClassName);
    SET @RunId = SCOPE_IDENTITY();

    /* v9.4.4 Phase 2: preservation snapshot.  Shared by both the NOT_TESTABLE
       and the main emission branches.  A test is "preserved" when the current
       proc body's SHA2_256 hash differs from the OriginalBodyHash we logged
       on its last emit - i.e. the developer modified it.  The original log
       row is intentionally kept so future regens still detect divergence. */
    DECLARE @Preserved TABLE
    (
        TestProcName  SYSNAME       NOT NULL PRIMARY KEY,
        PreservedBody NVARCHAR(MAX) NOT NULL
    );

    BEGIN TRY
        /* ------------------------------------------------------------------
         * 1. Collect parameter metadata
         * -----------------------------------------------------------------*/
        DECLARE @Params TABLE
        (
            ParamId          INT,
            ParamName        SYSNAME,
            SqlTypeName      SYSNAME,
            MaxLength        SMALLINT,
            [Precision]      TINYINT,
            Scale            TINYINT,
            IsOutput         BIT,
            IsNullable       BIT,
            HasDefault       BIT,
            DefaultValueSql  NVARCHAR(MAX),
            IsTableType      BIT,
            TypeSchema       SYSNAME
        );

        INSERT @Params
        EXEC TestGen.GetProcedureParameters @SchemaName, @ProcName;

        -- snapshot
        INSERT TestGenLog.ProcedureSnapshot (RunId, Kind, ItemName, ItemDetail)
        SELECT @RunId, 'Parameter', ParamName,
               CONCAT(SqlTypeName, ' out=', IsOutput, ' null=', IsNullable, ' default=', HasDefault)
        FROM @Params;

        /* ------------------------------------------------------------------
         * 1b. Load the procedure source.
         *
         * @ProcSource is reused below for branch detection and other source
         * scans.  Full-text search usage (CONTAINSTABLE / FREETEXTTABLE /
         * CONTAINS / FREETEXT) is now detected by TestGen.AssessTestability
         * and classified NOT_TESTABLE - see the 1c testability gate below.
         * -----------------------------------------------------------------*/
        DECLARE @ProcSource NVARCHAR(MAX);
        DECLARE @SourceTable TABLE (SourceText NVARCHAR(MAX));
        INSERT @SourceTable
        EXEC TestGen.GetProcedureSource @SchemaName, @ProcName;
        SELECT @ProcSource = SourceText FROM @SourceTable;

        /* ------------------------------------------------------------------
         * 1c. Testability gate (v9.4.3)
         *
         * If the procedure cannot be meaningfully auto-tested - it has no
         * fakeable table/view dependencies and relies on system catalog
         * objects (sys schema) that tSQLt.FakeTable cannot fake - do NOT
         * emit the generic tests (they would only error against live data).
         * Emit ONE test carrying the --[@tSQLt:SkipTest] annotation so the
         * procedure is reported honestly in tSQLt's SKIPPED column, with a
         * reason, and the developer is pointed at a hand-written custom class.
         * -----------------------------------------------------------------*/
        DECLARE @TestabilityVerdict VARCHAR(20), @TestabilityReason NVARCHAR(400);
        EXEC TestGen.AssessTestability
             @SchemaName = @SchemaName,
             @ProcName   = @ProcName,
             @Verdict    = @TestabilityVerdict OUTPUT,
             @Reason     = @TestabilityReason  OUTPUT;

        IF @TestabilityVerdict = 'NOT_TESTABLE'
        BEGIN
            DECLARE @NotTestableScript NVARCHAR(MAX) =
                N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = N''' + @TestClassName + N''')' + @CRLF +
                N'    EXEC tSQLt.DropClass ''' + @TestClassName + N''';' + @CRLF +
                N'GO' + @CRLF + @CRLF +
                N'EXEC tSQLt.NewTestClass ''' + @TestClassName + N''';' + @CRLF +
                N'GO' + @CRLF + @CRLF +
                N'--[@tSQLt:SkipTest](''NOT TESTABLE: ' + @TestabilityReason + N''')' + @CRLF +
                N'CREATE PROCEDURE ' + QUOTENAME(@TestClassName) + N'.[test ' + @ProcName + N' is not auto-testable]' + @CRLF +
                N'AS' + @CRLF +
                N'BEGIN' + @CRLF +
                N'    SET NOCOUNT ON;' + @CRLF +
                N'    -- Classified NOT TESTABLE by TestGen.AssessTestability.' + @CRLF +
                N'    -- Reason: ' + @TestabilityReason + @CRLF +
                N'    -- The auto-generator cannot build a meaningful test for this' + @CRLF +
                N'    -- procedure, so this test carries the [@tSQLt:SkipTest]' + @CRLF +
                N'    -- annotation above and is reported SKIPPED - not passed,' + @CRLF +
                N'    -- not failed.  To unit-test it, hand-write tests in a' + @CRLF +
                N'    -- developer-owned class (RunCoverage runs it alongside' + @CRLF +
                N'    -- this one):' + @CRLF +
                N'    --   EXEC TestGen.EnsureCustomTestClass @SchemaName=N''' + @SchemaName + N''', @ProcName=N''' + @ProcName + N''';' + @CRLF +
                N'END;' + @CRLF +
                N'GO' + @CRLF;

            SET @GeneratedScript = @NotTestableScript;

            UPDATE TestGenLog.GenerationRun
            SET GeneratedScript    = @GeneratedScript,
                GeneratedTestCount = 1,
                Status             = 'NotTestable',
                CompletedAt        = GETDATE()
            WHERE RunId = @RunId;

            IF @ExecuteScript = 1
            BEGIN
                /* v9.4.4 Phase 2: SNAPSHOT preserved tests in this class BEFORE
                   the destructive DropClass + NewTestClass + CREATE flow. */
                IF OBJECT_ID('TestGenLog.GeneratedTest','U') IS NOT NULL
                   AND SCHEMA_ID(@TestClassName) IS NOT NULL
                BEGIN
                    ;WITH latest AS (
                        SELECT gt.TestClassName, gt.TestProcName,
                               gt.OriginalBodyHash,
                               ROW_NUMBER() OVER (PARTITION BY gt.TestClassName, gt.TestProcName
                                                  ORDER BY gt.RunId DESC) AS rn
                        FROM   TestGenLog.GeneratedTest gt
                        WHERE  gt.TestClassName = @TestClassName
                    )
                    INSERT INTO @Preserved (TestProcName, PreservedBody)
                    SELECT p.name, m.definition
                    FROM   sys.procedures p
                    JOIN   sys.sql_modules m ON m.object_id = p.object_id
                    JOIN   latest l ON l.TestClassName = @TestClassName
                                  AND l.TestProcName  = p.name
                                  AND l.rn = 1
                    WHERE  p.schema_id = SCHEMA_ID(@TestClassName)
                      AND  l.OriginalBodyHash <> HASHBYTES('SHA2_256', m.definition);
                END;
                SET @TestsPreservedCount = (SELECT COUNT(*) FROM @Preserved);

                EXEC TestGen.ExecuteBatchedScript @GeneratedScript;

                /* v9.4.4 Phase 2: RESTORE preserved tests.  Drop the framework's
                   same-named proc (just created by the destructive flow) and
                   replay the developer's saved body verbatim. */
                IF EXISTS (SELECT 1 FROM @Preserved)
                BEGIN
                    DECLARE @prNameNT SYSNAME, @prBodyNT NVARCHAR(MAX), @prDropNT NVARCHAR(MAX);
                    DECLARE prcurNT CURSOR LOCAL FAST_FORWARD FOR
                        SELECT TestProcName, PreservedBody FROM @Preserved;
                    OPEN prcurNT;
                    FETCH NEXT FROM prcurNT INTO @prNameNT, @prBodyNT;
                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        IF OBJECT_ID(QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@prNameNT), 'P') IS NOT NULL
                        BEGIN
                            SET @prDropNT = N'DROP PROCEDURE ' + QUOTENAME(@TestClassName) + N'.' + QUOTENAME(@prNameNT) + N';';
                            EXEC sys.sp_executesql @prDropNT;
                        END;
                        EXEC sys.sp_executesql @prBodyNT;
                        PRINT '  preserved developer-modified test: [' + @TestClassName + '].[' + @prNameNT + ']';
                        FETCH NEXT FROM prcurNT INTO @prNameNT, @prBodyNT;
                    END;
                    CLOSE prcurNT; DEALLOCATE prcurNT;
                END;

                /* v9.4.4: capture the SkipTest stub too.  This is THE test the
                   developer is most likely to modify (remove the SkipTest
                   annotation, write real test logic) - so Phase 2's
                   preservation detection only works if we logged the original
                   body here.  Same shape as the main capture block. */
                IF OBJECT_ID('TestGenLog.GeneratedTest','U') IS NOT NULL
                BEGIN
                    INSERT TestGenLog.GeneratedTest
                        (RunId, SchemaName, ProcName, TestClassName, TestProcName, OriginalBody)
                    SELECT @RunId, @SchemaName, @ProcName, @TestClassName, p.name, m.definition
                    FROM   sys.procedures p
                    JOIN   sys.sql_modules m ON m.object_id = p.object_id
                    WHERE  p.schema_id = SCHEMA_ID(@TestClassName)
                      AND  p.is_ms_shipped = 0;

                    /* v9.4.4 Phase 2: PRUNE log rows just inserted for
                       preserved tests so the OLD log row remains the latest -
                       future hash comparisons still detect the developer's
                       divergence. */
                    IF EXISTS (SELECT 1 FROM @Preserved)
                    BEGIN
                        DELETE gt
                        FROM   TestGenLog.GeneratedTest gt
                        JOIN   @Preserved pr ON pr.TestProcName = gt.TestProcName
                        WHERE  gt.RunId = @RunId AND gt.TestClassName = @TestClassName;
                    END;
                END;
            END;

            PRINT 'NOT TESTABLE: ' + @SchemaName + '.' + @ProcName;
            PRINT '  Reason: ' + @TestabilityReason;
            PRINT '  Emitted one [@tSQLt:SkipTest] marker test in [' + @TestClassName + '] (reported SKIPPED, not failed).';

            RETURN;
        END;

        /* ------------------------------------------------------------------
         * 2. Collect dependency metadata
         * -----------------------------------------------------------------*/
        DECLARE @Deps TABLE
        (
            DepKind     VARCHAR(20),
            SchemaName  SYSNAME,
            ObjectName  SYSNAME,
            IsAmbiguous BIT
        );

        INSERT @Deps
        EXEC TestGen.GetProcedureDependencies @SchemaName, @ProcName;

        INSERT TestGenLog.ProcedureSnapshot (RunId, Kind, ItemName, ItemDetail)
        SELECT @RunId,
               CASE DepKind WHEN 'PROCEDURE' THEN 'ProcDep' ELSE 'TableDep' END,
               SchemaName + '.' + ObjectName,
               DepKind
        FROM @Deps;

        /* ------------------------------------------------------------------
         * 2a. v9.4.4: Resolve view dependencies to underlying base tables.
         *
         * tSQLt.FakeTable can fake a VIEW, but the framework's seed step
         * then runs INSERT INTO <view>, which SQL Server rejects when the
         * view has computed / derived columns or aggregates (Msg 4406:
         * "Update or insert of view ... failed because it contains a
         * derived or constant field").  Example: dbo.[Order Subtotals] in
         * Northwind has a SUM() column.
         *
         * Replace each VIEW dependency with its underlying USER TABLES,
         * walked recursively (a view can reference another view).  The
         * original view stays in the database; the proc still reads from
         * it at test time, and the view's computation runs over the
         * faked base table rows naturally.
         *
         * Snapshot logging above already records the ORIGINAL view dep for
         * audit; we add a ViewResolved snapshot row for the resolution. */
        IF EXISTS (SELECT 1 FROM @Deps WHERE DepKind = 'VIEW')
        BEGIN
            DECLARE @ViewBaseTables TABLE
            (
                SchemaName SYSNAME NOT NULL,
                ObjectName SYSNAME NOT NULL,
                PRIMARY KEY (SchemaName, ObjectName)
            );

            ;WITH src AS (
                SELECT OBJECT_ID(QUOTENAME(SchemaName) + N'.' + QUOTENAME(ObjectName)) AS RefId
                FROM   @Deps WHERE DepKind = 'VIEW'
            ),
            walk AS (
                SELECT s.RefId, 1 AS depth FROM src s WHERE s.RefId IS NOT NULL
                UNION ALL
                SELECT d.referenced_id, w.depth + 1
                FROM   walk w
                JOIN   sys.objects o ON o.object_id = w.RefId AND o.type = 'V'
                JOIN   sys.sql_expression_dependencies d ON d.referencing_id = w.RefId
                WHERE  d.referenced_id IS NOT NULL
                  AND  w.depth < 10
            )
            INSERT @ViewBaseTables (SchemaName, ObjectName)
            SELECT DISTINCT OBJECT_SCHEMA_NAME(w.RefId), OBJECT_NAME(w.RefId)
            FROM   walk w
            JOIN   sys.objects o ON o.object_id = w.RefId
            WHERE  o.type = 'U'   -- terminal USER_TABLE only
            OPTION (MAXRECURSION 20);

            -- Merge resolved base tables into @Deps as TABLE deps (skip dupes)
            INSERT @Deps (DepKind, SchemaName, ObjectName, IsAmbiguous)
            SELECT 'TABLE', vbt.SchemaName, vbt.ObjectName, 0
            FROM   @ViewBaseTables vbt
            WHERE  NOT EXISTS (
                SELECT 1 FROM @Deps d
                WHERE  d.DepKind   = 'TABLE'
                  AND  d.SchemaName = vbt.SchemaName
                  AND  d.ObjectName = vbt.ObjectName
            );

            -- Remove the original VIEW deps now that their base tables are in
            DELETE FROM @Deps WHERE DepKind = 'VIEW';

            -- Audit the resolution
            INSERT TestGenLog.ProcedureSnapshot (RunId, Kind, ItemName, ItemDetail)
            SELECT @RunId, 'ViewResolved',
                   vbt.SchemaName + N'.' + vbt.ObjectName,
                   N'expanded from view dependency'
            FROM   @ViewBaseTables vbt;
        END;

        /* ------------------------------------------------------------------
         * 2b. Extract error paths once, up front.
         *
         * Hoisted out of the negative-test block so the boundary and
         * NULL-injection tests can also know whether the proc validates
         * inputs - if so, those tests use tSQLt.ExpectException instead
         * of asserting "did not throw".
         * -----------------------------------------------------------------*/
        DECLARE @Errors TABLE
        (
            ErrorOrdinal    INT,
            Keyword         VARCHAR(10),
            MessagePattern  NVARCHAR(2000) NULL,
            SeverityLiteral INT NULL,
            SourceFragment  NVARCHAR(2000)
        );

        IF @EmitNegativeTests = 1 OR @AssertExceptionOnInvalidInputs = 1
        BEGIN
            BEGIN TRY
                INSERT @Errors (ErrorOrdinal, Keyword, MessagePattern, SeverityLiteral, SourceFragment)
                EXEC TestGen.ExtractErrorPaths @SchemaName = @SchemaName, @ProcName = @ProcName;
            END TRY
            BEGIN CATCH
                PRINT 'Error-path extraction skipped: ' + ERROR_MESSAGE();
            END CATCH;
        END;

        DECLARE @HasErrorPaths BIT =
            CASE WHEN EXISTS (SELECT 1 FROM @Errors) THEN 1 ELSE 0 END;

        DECLARE @UseExpectExceptionForInvalid BIT =
            CASE WHEN @AssertExceptionOnInvalidInputs = 1 AND @HasErrorPaths = 1
                 THEN 1 ELSE 0 END;

        /* ------------------------------------------------------------------
         * 3. Build EXEC argument list for happy-path test
         *
         * IMPORTANT: if a parameter shares a name with a PRIMARY KEY or
         * FOREIGN KEY column on any faked table, we override the type-based
         * "sample value" with a value that the seeder is known to insert.
         * The seeder writes integer columns with values 1..@RowCount, so we
         * pin matched int params to 1.
         *
         * We specifically check PK/FK columns because those are the ones
         * procs typically validate ("customer must exist"). Data columns
         * like Total, Notes, Description rarely trip validation on NULL.
         *
         * Without this, a proc that validates "row must exist in faked
         * table" will reject the happy-path call. With it, the happy-path
         * value lines up with seeded data automatically.
         * -----------------------------------------------------------------*/
        DECLARE @ParamMatchedColumns TABLE
        (
            ParamName SYSNAME PRIMARY KEY
        );

        -- Populate with params whose names match PK or FK columns.
        INSERT @ParamMatchedColumns (ParamName)
        SELECT DISTINCT p.ParamName
        FROM @Params p
        WHERE p.IsOutput = 0
          AND EXISTS
          (
              SELECT 1
              FROM @Deps d
              JOIN sys.columns c
                ON c.object_id = OBJECT_ID(QUOTENAME(d.SchemaName) + '.' + QUOTENAME(d.ObjectName))
              WHERE d.DepKind IN ('TABLE','VIEW')
                -- Name match (case-insensitive, with/without @ prefix)
                AND (
                       LOWER(c.name) = LOWER(p.ParamName)
                    OR LOWER(c.name) = LOWER(STUFF(p.ParamName, 1, 1, ''))
                )
                -- Column is part of a PK or is an FK column
                AND (
                       -- PK column?
                       EXISTS (
                           SELECT 1 FROM sys.index_columns ic
                           JOIN sys.indexes i ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                           WHERE ic.object_id = c.object_id
                             AND ic.column_id = c.column_id
                             AND i.is_primary_key = 1
                       )
                       -- FK column?
                    OR EXISTS (
                           SELECT 1 FROM sys.foreign_key_columns fkc
                           WHERE fkc.parent_object_id = c.object_id
                             AND fkc.parent_column_id = c.column_id
                       )
                )
          );

        /* ------------------------------------------------------------------
         * 3b. Extract branch conditions to use realistic values in smoke test
         *     (Inlined to avoid nested INSERT EXEC issue)
         * -----------------------------------------------------------------*/
        IF OBJECT_ID('tempdb..#BranchValues') IS NOT NULL DROP TABLE #BranchValues;
        CREATE TABLE #BranchValues (
            ParamName SYSNAME,
            BranchValue NVARCHAR(500)
        );

        -- v9.2: when the proc has  `SET @LocalVar = CASE @Param WHEN x THEN y ... END`
        -- or  `SELECT @LocalVar = CASE @Param WHEN x THEN y ... END`,
        -- a branch test on the LOCAL variable needs to know which procedure
        -- parameter (and value) drives a given result.  We record the mapping
        -- here so the arglist builder can pick @Param = WhenValue when the
        -- branch test wants @LocalVar = ResultValue.
        IF OBJECT_ID('tempdb..#CaseLocalAssigns') IS NOT NULL DROP TABLE #CaseLocalAssigns;
        CREATE TABLE #CaseLocalAssigns (
            LocalVar    SYSNAME,
            SourceParam SYSNAME,
            WhenValue   NVARCHAR(500),
            ResultValue NVARCHAR(500)
        );

        -- Reuse @ProcSource and @SourceTable already loaded above for full-text detection
        -- (Variables declared at line ~109, populated at line ~112)
        
        -- Normalize whitespace
        SET @ProcSource = REPLACE(@ProcSource, CHAR(13) + CHAR(10), CHAR(10));
        SET @ProcSource = REPLACE(@ProcSource, CHAR(13), CHAR(10));
        SET @ProcSource = REPLACE(@ProcSource, CHAR(9), ' ');

        -- Extract simple IF @Param = 'literal' patterns
        DECLARE @Line NVARCHAR(MAX), @ParamStart INT, @ParamEnd INT, @ValueStart INT, @ValueEnd INT;
        DECLARE @Param SYSNAME, @Value NVARCHAR(500);
        DECLARE @CurrentPos INT, @QuoteStart INT, @QuoteEnd INT;
        DECLARE @InClauseStart INT, @InClauseEnd INT, @InClause NVARCHAR(MAX);
        DECLARE @Operator VARCHAR(5), @OperatorPos INT, @NumValue NVARCHAR(50);
        DECLARE @CaseStart INT, @CasePos INT, @CaseEnd INT, @CaseBlock NVARCHAR(MAX), @WhenPos INT, @HasElse BIT;
        DECLARE @WVStart INT, @WVThen INT, @WVRaw NVARCHAR(200);
        -- v9.2: variables used by the local-var assignment look-back and
        -- by THEN-result capture
        DECLARE @CaseLocalVar  SYSNAME;
        DECLARE @CaseLookback  INT;
        DECLARE @CaseLocalEnd  INT;
        DECLARE @WVThenEnd     INT;
        DECLARE @WVResult      NVARCHAR(500);
        DECLARE @ElsePosInCase INT;
        
        -- Split into lines and process each
        DECLARE @LineNum INT = 1;
        DECLARE @LineStart INT = 1;
        DECLARE @LineEnd INT;
        
        WHILE @LineStart <= LEN(@ProcSource)
        BEGIN
            SET @LineEnd = CHARINDEX(CHAR(10), @ProcSource, @LineStart);
            IF @LineEnd = 0 SET @LineEnd = LEN(@ProcSource) + 1;
            
            SET @Line = LTRIM(RTRIM(SUBSTRING(@ProcSource, @LineStart, @LineEnd - @LineStart)));
            
            -- Pattern: IF @Param = 'literal'
            IF @Line LIKE '%IF%@%=%''%''%' AND @Line NOT LIKE '--%IF%'
            BEGIN
                SET @ParamStart = CHARINDEX('@', @Line);
                IF @ParamStart > 0
                BEGIN
                    SET @ParamEnd = @ParamStart + 1;
                    WHILE @ParamEnd <= LEN(@Line) 
                      AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', '=', ')', ',', CHAR(10))
                        SET @ParamEnd = @ParamEnd + 1;
                    
                    SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
                    
                    SET @ValueStart = CHARINDEX('=', @Line, @ParamStart);
                    IF @ValueStart > 0
                    BEGIN
                        SET @ValueStart = CHARINDEX('''', @Line, @ValueStart);
                        IF @ValueStart > 0
                        BEGIN
                            SET @ValueEnd = CHARINDEX('''', @Line, @ValueStart + 1);
                            IF @ValueEnd > 0
                            BEGIN
                                SET @Value = SUBSTRING(@Line, @ValueStart + 1, @ValueEnd - @ValueStart - 1);
                                INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, @Value);
                            END;
                        END;
                    END;
                END;
            END;
            
            -- Pattern: CASE @Param WHEN 'literal'
            IF @Line LIKE '%CASE%@%WHEN%''%''%' AND @Line NOT LIKE '--%CASE%'
            BEGIN
                SET @ParamStart = CHARINDEX('@', @Line, CHARINDEX('CASE', @Line));
                IF @ParamStart > 0
                BEGIN
                    SET @ParamEnd = @ParamStart + 1;
                    WHILE @ParamEnd <= LEN(@Line) 
                      AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', CHAR(10))
                        SET @ParamEnd = @ParamEnd + 1;
                    
                    SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
                    
                    -- Extract WHEN values
                    SET @CurrentPos = CHARINDEX('WHEN', @Line);
                    
                    WHILE @CurrentPos > 0
                    BEGIN
                        SET @QuoteStart = CHARINDEX('''', @Line, @CurrentPos);
                        IF @QuoteStart = 0 BREAK;
                        
                        SET @QuoteEnd = CHARINDEX('''', @Line, @QuoteStart + 1);
                        IF @QuoteEnd = 0 BREAK;
                        
                        SET @Value = SUBSTRING(@Line, @QuoteStart + 1, @QuoteEnd - @QuoteStart - 1);
                        INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, @Value);
                        
                        SET @CurrentPos = CHARINDEX('WHEN', @Line, @CurrentPos + 4);
                    END;
                END;
            END;
            
            -- Pattern: IF @Param IN ('val1', 'val2', ...)
            IF @Line LIKE '%IF%@%IN%(%''%''%)%' AND @Line NOT LIKE '--%IF%'
            BEGIN
                SET @ParamStart = CHARINDEX('@', @Line);
                IF @ParamStart > 0
                BEGIN
                    SET @ParamEnd = @ParamStart + 1;
                    WHILE @ParamEnd <= LEN(@Line) 
                      AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', ')', ',', CHAR(10))
                        SET @ParamEnd = @ParamEnd + 1;
                    
                    SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
                    
                    -- Find IN clause content between ( and )
                    SET @InClauseStart = CHARINDEX('(', @Line, CHARINDEX('IN', @Line, @ParamStart));
                    SET @InClauseEnd = CHARINDEX(')', @Line, @InClauseStart);
                    
                    IF @InClauseStart > 0 AND @InClauseEnd > @InClauseStart
                    BEGIN
                        SET @InClause = SUBSTRING(@Line, @InClauseStart + 1, @InClauseEnd - @InClauseStart - 1);
                        
                        -- Extract each quoted value from IN clause
                        SET @CurrentPos = 1;
                        WHILE @CurrentPos <= LEN(@InClause)
                        BEGIN
                            SET @QuoteStart = CHARINDEX('''', @InClause, @CurrentPos);
                            IF @QuoteStart = 0 BREAK;
                            
                            SET @QuoteEnd = CHARINDEX('''', @InClause, @QuoteStart + 1);
                            IF @QuoteEnd = 0 BREAK;
                            
                            SET @Value = SUBSTRING(@InClause, @QuoteStart + 1, @QuoteEnd - @QuoteStart - 1);
                            INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, @Value);
                            
                            SET @CurrentPos = @QuoteEnd + 1;
                        END;
                    END;
                END;
            END;
            
            -- Pattern: Numeric comparisons - IF @Param > 100, IF @Param >= 500, etc.
            IF (@Line LIKE '%IF%@%>%[0-9]%' OR @Line LIKE '%IF%@%<%[0-9]%' 
                OR @Line LIKE '%IF%@%>=%[0-9]%' OR @Line LIKE '%IF%@%<=%[0-9]%')
               AND @Line NOT LIKE '--%IF%'
            BEGIN
                SET @ParamStart = CHARINDEX('@', @Line);
                IF @ParamStart > 0
                BEGIN
                    SET @ParamEnd = @ParamStart + 1;
                    WHILE @ParamEnd <= LEN(@Line) 
                      AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', '>', '<', '=', CHAR(10))
                        SET @ParamEnd = @ParamEnd + 1;
                    
                    SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
                    
                    -- Find operator and numeric value
                    SET @Operator = NULL;
                    SET @OperatorPos = NULL;
                    
                    IF CHARINDEX('>=', @Line, @ParamEnd) > 0 AND CHARINDEX('>=', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                    BEGIN
                        SET @Operator = '>=';
                        SET @OperatorPos = CHARINDEX('>=', @Line, @ParamEnd);
                    END
                    ELSE IF CHARINDEX('<=', @Line, @ParamEnd) > 0 AND CHARINDEX('<=', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                    BEGIN
                        SET @Operator = '<=';
                        SET @OperatorPos = CHARINDEX('<=', @Line, @ParamEnd);
                    END
                    ELSE IF CHARINDEX('>', @Line, @ParamEnd) > 0 AND CHARINDEX('>', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                    BEGIN
                        SET @Operator = '>';
                        SET @OperatorPos = CHARINDEX('>', @Line, @ParamEnd);
                    END
                    ELSE IF CHARINDEX('<', @Line, @ParamEnd) > 0 AND CHARINDEX('<', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                    BEGIN
                        SET @Operator = '<';
                        SET @OperatorPos = CHARINDEX('<', @Line, @ParamEnd);
                    END;
                    
                    IF @Operator IS NOT NULL
                    BEGIN
                        -- Extract numeric value after operator
                        SET @ValueStart = @OperatorPos + LEN(@Operator);
                        
                        -- Skip whitespace
                        WHILE @ValueStart <= LEN(@Line) AND SUBSTRING(@Line, @ValueStart, 1) = ' '
                            SET @ValueStart = @ValueStart + 1;
                        
                        SET @ValueEnd = @ValueStart;
                        WHILE @ValueEnd <= LEN(@Line) 
                          AND SUBSTRING(@Line, @ValueEnd, 1) IN ('0','1','2','3','4','5','6','7','8','9','.')
                            SET @ValueEnd = @ValueEnd + 1;
                        
                        SET @NumValue = SUBSTRING(@Line, @ValueStart, @ValueEnd - @ValueStart);
                        
                        IF ISNUMERIC(@NumValue) = 1
                        BEGIN
                            INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, @NumValue);
                        END;
                    END;
                END;
            END;
            
            SET @LineStart = @LineEnd + 1;
        END;

        /* ------------------------------------------------------------------
         * 3c. Multi-line CASE detection (after line-by-line processing)
         *     Handles: CASE @Param
         *              WHEN 'val1' THEN ...
         *              WHEN 'val2' THEN ...
         * -----------------------------------------------------------------*/
        -- Search for CASE @Param patterns in the full source
        SET @CaseStart = 1;
        
        WHILE @CaseStart <= LEN(@ProcSource)
        BEGIN
            SET @CasePos = CHARINDEX('CASE', @ProcSource, @CaseStart);
            IF @CasePos = 0 BREAK;
            
            -- Check if there's a @ parameter after CASE
            SET @ParamStart = @CasePos + 4; -- After 'CASE'
            WHILE @ParamStart <= LEN(@ProcSource) AND SUBSTRING(@ProcSource, @ParamStart, 1) = ' '
                SET @ParamStart = @ParamStart + 1;
            
            IF @ParamStart <= LEN(@ProcSource) AND SUBSTRING(@ProcSource, @ParamStart, 1) = '@'
            BEGIN
                -- Extract parameter name
                SET @ParamEnd = @ParamStart + 1;
                WHILE @ParamEnd <= LEN(@ProcSource) 
                  AND SUBSTRING(@ProcSource, @ParamEnd, 1) NOT IN (' ', CHAR(10), CHAR(13))
                    SET @ParamEnd = @ParamEnd + 1;
                
                SET @Param = SUBSTRING(@ProcSource, @ParamStart, @ParamEnd - @ParamStart);

                ---------------------------------------------------------------
                -- v9.2: look back from CASE for `SET @LocalVar = ` or
                -- `SELECT @LocalVar = ` so we can record the mapping from
                -- (CASE @Param, WHEN value) -> assigned local var value.
                ---------------------------------------------------------------
                SET @CaseLocalVar = NULL;
                SET @CaseLookback = @CasePos - 1;
                -- skip whitespace immediately before CASE
                WHILE @CaseLookback > 0
                      AND SUBSTRING(@ProcSource, @CaseLookback, 1) IN (' ', CHAR(9), CHAR(10), CHAR(13))
                    SET @CaseLookback = @CaseLookback - 1;
                -- expect '='
                IF @CaseLookback > 0 AND SUBSTRING(@ProcSource, @CaseLookback, 1) = '='
                BEGIN
                    SET @CaseLookback = @CaseLookback - 1;
                    WHILE @CaseLookback > 0
                          AND SUBSTRING(@ProcSource, @CaseLookback, 1) IN (' ', CHAR(9), CHAR(10), CHAR(13))
                        SET @CaseLookback = @CaseLookback - 1;
                    -- now scan back over the variable name (alnum and _)
                    SET @CaseLocalEnd = @CaseLookback;
                    WHILE @CaseLookback > 0
                          AND SUBSTRING(@ProcSource, @CaseLookback, 1) LIKE '[A-Za-z0-9_]'
                        SET @CaseLookback = @CaseLookback - 1;
                    -- expect '@'
                    IF @CaseLookback > 0 AND SUBSTRING(@ProcSource, @CaseLookback, 1) = '@'
                        SET @CaseLocalVar = SUBSTRING(@ProcSource, @CaseLookback, @CaseLocalEnd - @CaseLookback + 1);
                END;
                
                -- Find the END for this CASE
                SET @CaseEnd = CHARINDEX('END', @ProcSource, @ParamEnd);
                IF @CaseEnd > 0
                BEGIN
                    SET @CaseBlock = SUBSTRING(@ProcSource, @CasePos, @CaseEnd - @CasePos + 3);
                    
                    -- Extract all WHEN values from this CASE block
                    SET @CurrentPos = 1;
                    SET @HasElse = 0;
                    
                    WHILE @CurrentPos <= LEN(@CaseBlock)
                    BEGIN
                        SET @WhenPos = CHARINDEX('WHEN', @CaseBlock, @CurrentPos);
                        IF @WhenPos = 0 BREAK;
                        
                        -- Skip whitespace after WHEN
                        SET @WVStart = @WhenPos + 4;
                        WHILE @WVStart <= LEN(@CaseBlock) AND SUBSTRING(@CaseBlock, @WVStart, 1) = ' '
                            SET @WVStart = @WVStart + 1;
                        
                        -- Find THEN position
                        SET @WVThen = CHARINDEX('THEN', @CaseBlock, @WVStart);
                        IF @WVThen = 0 BREAK;
                        
                        -- Extract value between WHEN and THEN
                        SET @WVRaw = LTRIM(RTRIM(SUBSTRING(@CaseBlock, @WVStart, @WVThen - @WVStart)));
                        SET @WVRaw = REPLACE(REPLACE(REPLACE(@WVRaw, '''', ''), CHAR(10), ''), CHAR(13), '');
                        SET @WVRaw = LTRIM(RTRIM(@WVRaw));
                        
                        IF LEN(@WVRaw) > 0
                            INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, @WVRaw);

                        ---------------------------------------------------------------
                        -- v9.2: also capture the THEN result so we know the mapping
                        -- WHEN <x> -> @LocalVar = <result>.  The result lives
                        -- between (THEN + 4) and the next WHEN/ELSE/END.
                        ---------------------------------------------------------------
                        IF @CaseLocalVar IS NOT NULL AND LEN(@WVRaw) > 0
                        BEGIN
                            -- Find the boundary of the THEN result
                            SET @WVThenEnd = CHARINDEX('WHEN', @CaseBlock, @WVThen + 4);
                            SET @ElsePosInCase = CHARINDEX('ELSE', @CaseBlock, @WVThen + 4);
                            IF @ElsePosInCase > 0 AND (@WVThenEnd = 0 OR @ElsePosInCase < @WVThenEnd)
                                SET @WVThenEnd = @ElsePosInCase;
                            IF @WVThenEnd = 0
                                SET @WVThenEnd = LEN(@CaseBlock) + 1;
                            SET @WVResult = LTRIM(RTRIM(SUBSTRING(@CaseBlock, @WVThen + 4, @WVThenEnd - @WVThen - 4)));
                            SET @WVResult = REPLACE(REPLACE(@WVResult, CHAR(10), ' '), CHAR(13), ' ');
                            SET @WVResult = LTRIM(RTRIM(@WVResult));
                            -- strip surrounding single-quotes if string literal
                            IF LEN(@WVResult) >= 2 AND LEFT(@WVResult,1) = '''' AND RIGHT(@WVResult,1) = ''''
                                SET @WVResult = SUBSTRING(@WVResult, 2, LEN(@WVResult) - 2);
                            IF LEN(@WVResult) > 0
                            BEGIN
                                INSERT #CaseLocalAssigns (LocalVar, SourceParam, WhenValue, ResultValue)
                                VALUES (@CaseLocalVar, @Param, @WVRaw, @WVResult);
                            END;
                        END;

                        SET @CurrentPos = @WhenPos + 4;
                    END;
                    
                    -- Check if CASE has ELSE branch
                    IF CHARINDEX('ELSE', @CaseBlock) > 0
                    BEGIN
                        -- Generate a test value that doesn't match any WHEN clause
                        -- Use '_ELSE_CASE_' as a marker value that represents "anything else"
                        INSERT #BranchValues (ParamName, BranchValue) VALUES (@Param, '_ELSE_CASE_');
                        -- v9.4 (Phase B): also record the CASE ELSE result so the
                        -- result-set assertion knows @LocalVar's value when no
                        -- WHEN matched.
                        IF @CaseLocalVar IS NOT NULL
                        BEGIN
                            SET @ElsePosInCase = CHARINDEX('ELSE', @CaseBlock);
                            SET @WVThenEnd = CHARINDEX('END', @CaseBlock, @ElsePosInCase);
                            IF @WVThenEnd = 0 SET @WVThenEnd = LEN(@CaseBlock) + 1;
                            SET @WVResult = LTRIM(RTRIM(SUBSTRING(@CaseBlock, @ElsePosInCase + 4,
                                            @WVThenEnd - @ElsePosInCase - 4)));
                            SET @WVResult = LTRIM(RTRIM(REPLACE(REPLACE(@WVResult, CHAR(10), ' '), CHAR(13), ' ')));
                            IF LEN(@WVResult) >= 2 AND LEFT(@WVResult,1) = '''' AND RIGHT(@WVResult,1) = ''''
                                SET @WVResult = SUBSTRING(@WVResult, 2, LEN(@WVResult) - 2);
                            IF LEN(@WVResult) > 0
                                INSERT #CaseLocalAssigns (LocalVar, SourceParam, WhenValue, ResultValue)
                                VALUES (@CaseLocalVar, @Param, '_ELSE_CASE_', @WVResult);
                        END;
                    END;
                    
                    SET @CaseStart = @CaseEnd + 3;
                END
                ELSE
                    SET @CaseStart = @CasePos + 4;
            END
            ELSE
                SET @CaseStart = @CasePos + 4;
        END;

        DECLARE @ArgListHappy    NVARCHAR(MAX) = N'';

        DECLARE @ArgListBoundary NVARCHAR(MAX) = N'';
        DECLARE @ArgListHighBnd  NVARCHAR(MAX) = N'';
        DECLARE @OutputDecls     NVARCHAR(MAX) = N'';
        DECLARE @HasOutput       BIT = 0;

        DECLARE @pname SYSNAME, @ptype SYSNAME, @pmax SMALLINT, @pprec TINYINT, @pscale TINYINT,
                @pout BIT, @pnull BIT, @pid INT;

        -- These must live outside the loop body. T-SQL evaluates a
        -- DECLARE @x = <expr> initializer ONCE, on first encounter,
        -- and subsequent loop iterations keep the prior value.
        DECLARE @matched  BIT;
        DECLARE @happyVal NVARCHAR(400);
        DECLARE @mCharLen INT, @mTarget INT, @mRaw NVARCHAR(220);   -- v11.x: matched-key arg row-1 seed value

        DECLARE pcur CURSOR LOCAL FAST_FORWARD FOR
            SELECT ParamId, ParamName, SqlTypeName, MaxLength, [Precision], Scale, IsOutput, IsNullable
            FROM @Params
            ORDER BY ParamId;
        OPEN pcur;
        FETCH NEXT FROM pcur INTO @pid, @pname, @ptype, @pmax, @pprec, @pscale, @pout, @pnull;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @pout = 1
            BEGIN
                SET @HasOutput = 1;
                SET @OutputDecls = @OutputDecls + N'    DECLARE ' + @pname + N'_out '
                                 + TestGen.GetDeclareLiteralForType(@ptype, @pmax, @pprec, @pscale) + N';' + @CRLF;
                SET @ArgListHappy    = @ArgListHappy    + N', ' + @pname + N' = ' + @pname + N'_out OUTPUT';
                SET @ArgListBoundary = @ArgListBoundary + N', ' + @pname + N' = ' + @pname + N'_out OUTPUT';
                SET @ArgListHighBnd  = @ArgListHighBnd  + N', ' + @pname + N' = ' + @pname + N'_out OUTPUT';
            END
            ELSE
            BEGIN
                -- Did this param's name match a faked-table column?
                SET @matched =
                    CASE WHEN EXISTS (SELECT 1 FROM @ParamMatchedColumns WHERE ParamName = @pname)
                         THEN 1 ELSE 0 END;

                IF @matched = 1
                BEGIN
                    -- v11.x: line the happy arg up with the SEEDER's ROW-1 value for
                    -- this matched key column, so  WHERE col = @param  matches a seeded
                    -- row and the proc returns rows.  Previously string keys fell back
                    -- to the generic 'Sam', which never matched the seed 'Samp1' (=> 0
                    -- rows).  The formula here mirrors the seeder's row-1 logic exactly.
                    IF LOWER(@ptype) IN ('int','bigint','smallint','tinyint')
                        SET @happyVal = N'1';
                    ELSE IF LOWER(@ptype) IN ('char','varchar','nchar','nvarchar')
                    BEGIN
                        SET @mCharLen = CASE WHEN @pmax = -1 THEN 200
                                             WHEN LOWER(@ptype) IN ('nchar','nvarchar') THEN @pmax / 2
                                             ELSE @pmax END;
                        IF @mCharLen IS NULL OR @mCharLen < 1 SET @mCharLen = 1;
                        IF @mCharLen >= 3
                        BEGIN
                            SET @mTarget = CASE WHEN @mCharLen > 12 THEN 12 ELSE @mCharLen END;
                            SET @mRaw = STUFF(LEFT(N'SampleText_1' + REPLICATE(N'X', @mTarget), @mTarget), @mTarget, 1, N'1');
                        END
                        ELSE
                            SET @mRaw = RIGHT(REPLICATE(N'0', @mCharLen) + N'1', @mCharLen);
                        SET @happyVal = N'''' + @mRaw + N'''';
                    END
                    ELSE
                        SET @happyVal = TestGen.GetSampleValueLiteral(@ptype, @pmax, @pprec, @pscale, 0);
                END
                ELSE
                BEGIN
                    -- Check if we detected a branch value for this parameter
                    DECLARE @DetectedBranchValue NVARCHAR(500);
                    SELECT TOP 1 @DetectedBranchValue = BranchValue
                    FROM #BranchValues
                    WHERE ParamName = @pname
                      AND BranchValue <> '_ELSE_CASE_'  -- skip placeholder
                    ORDER BY BranchValue;

                    IF @DetectedBranchValue IS NOT NULL
                    BEGIN
                        -- Use the first detected branch value with proper quoting
                        IF LOWER(@ptype) IN ('char','varchar','nchar','nvarchar','text','ntext')
                            SET @happyVal = N'''' + REPLACE(@DetectedBranchValue, '''', '''''') + N'''';
                        ELSE
                            SET @happyVal = @DetectedBranchValue;
                    END
                    ELSE
                    BEGIN
                        -- No branch detected, use generic sample
                        SET @happyVal = TestGen.GetSampleValueLiteral(@ptype, @pmax, @pprec, @pscale, 0);
                    END;

                    -- Reset for next iteration
                    SET @DetectedBranchValue = NULL;
                END;

                SET @ArgListHappy    = @ArgListHappy    + N', ' + @pname + N' = ' + @happyVal;
                SET @ArgListBoundary = @ArgListBoundary + N', ' + @pname + N' = '
                                       + TestGen.GetSampleValueLiteral(@ptype, @pmax, @pprec, @pscale, 1);
                SET @ArgListHighBnd  = @ArgListHighBnd  + N', ' + @pname + N' = '
                                       + TestGen.GetSampleValueLiteral(@ptype, @pmax, @pprec, @pscale, 2);
            END;
            FETCH NEXT FROM pcur INTO @pid, @pname, @ptype, @pmax, @pprec, @pscale, @pout, @pnull;
        END;
        CLOSE pcur; DEALLOCATE pcur;

        -- strip leading ', '  (v9.4.3: STUFF returns NULL when the arg list is
        -- the empty string - a zero-parameter procedure - and a later unguarded
        -- concat would poison the whole generated script to NULL; ISNULL guards it)
        SET @ArgListHappy    = ISNULL(STUFF(@ArgListHappy,    1, 2, ''), N'');
        SET @ArgListBoundary = ISNULL(STUFF(@ArgListBoundary, 1, 2, ''), N'');
        SET @ArgListHighBnd  = ISNULL(STUFF(@ArgListHighBnd,  1, 2, ''), N'');

        /* ------------------------------------------------------------------
         * 4. Build the "Arrange" mocking block
         * -----------------------------------------------------------------*/
        DECLARE @MockBlock NVARCHAR(MAX) = N'';

        /* ------------------------------------------------------------------
         * Emit ClearSchemaBoundReferences calls for the DISTINCT set of
         * referenced tables that have schema-bound dependents. The helper
         * skips referents already dropped by a sibling call, so noise is
         * suppressed when two faked tables share a schema-bound view.
         * -----------------------------------------------------------------*/
        SELECT @MockBlock = @MockBlock
            + N'    EXEC TestGen.ClearSchemaBoundReferences N''' + d.SchemaName + N'.' + d.ObjectName + N''';' + @CRLF
        FROM @Deps d
        WHERE d.DepKind IN ('TABLE','VIEW')
          AND EXISTS
          (
              SELECT 1
              FROM sys.sql_expression_dependencies sed
              WHERE sed.referenced_id = OBJECT_ID(QUOTENAME(d.SchemaName) + N'.' + QUOTENAME(d.ObjectName))
                AND sed.is_schema_bound_reference = 1
          );

        /* ------------------------------------------------------------------
         * Inbound-FK cascade expansion.
         *
         * tSQLt.FakeTable works by renaming the real table.  SQL Server
         * rejects the rename (Msg 15336) when other tables have enforced
         * FK constraints pointing AT the target - e.g. many tables FK into
         * [Production].[Product] so faking Product directly fails.
         *
         * Fix: BFS from each primary TABLE dep, collecting every table that
         * has an inbound enforced FK (directly or transitively).  Emit
         * SafeFakeTable calls for those tables BEFORE the primary deps,
         * deepest inbound level first.  The fake copies carry no FK
         * constraints, so the primary dep can then be renamed freely.
         *
         * These extra tables are faked only - no seed data is emitted for
         * them.  Cursor guarantees deepest-first ordering (critical for
         * multi-level FK chains such as Product <- WorkOrder <- WorkOrderRouting).
         * -----------------------------------------------------------------*/
        DECLARE @IFKTables TABLE
        (
            SchemaName SYSNAME NOT NULL,
            ObjectName SYSNAME NOT NULL,
            FakeLevel  INT     NOT NULL,
            PRIMARY KEY (SchemaName, ObjectName)
        );
        DECLARE @IFKBatch TABLE
        (
            SchemaName SYSNAME NOT NULL,
            ObjectName SYSNAME NOT NULL,
            PRIMARY KEY (SchemaName, ObjectName)
        );
        DECLARE @IFKLevelCur INT = 0;
        DECLARE @IFKAdded    INT = 1;

        WHILE @IFKAdded > 0 AND @IFKLevelCur < 10
        BEGIN
            SET @IFKLevelCur += 1;
            DELETE @IFKBatch;

            IF @IFKLevelCur = 1
                -- Level 1: direct inbound FKs of primary TABLE deps
                INSERT @IFKBatch (SchemaName, ObjectName)
                SELECT DISTINCT SCHEMA_NAME(r.schema_id), r.name
                FROM   @Deps d
                JOIN   sys.objects t
                       ON  t.object_id = OBJECT_ID(QUOTENAME(d.SchemaName) + N'.' + QUOTENAME(d.ObjectName))
                       AND t.type = 'U'
                JOIN   sys.foreign_keys fk
                       ON  fk.referenced_object_id = t.object_id
                       AND fk.is_disabled          = 0
                JOIN   sys.objects r
                       ON  r.object_id = fk.parent_object_id
                       AND r.type      = 'U'
                WHERE  d.DepKind = 'TABLE'
                  AND  SCHEMA_NAME(r.schema_id) NOT IN (N'tSQLt', N'TestGen', N'TestGenLog')
                  AND  SCHEMA_NAME(r.schema_id) NOT LIKE 'test[_]%'
                  AND  NOT EXISTS (SELECT 1 FROM @Deps d2
                                   WHERE  d2.DepKind IN ('TABLE','VIEW')
                                     AND  d2.SchemaName = SCHEMA_NAME(r.schema_id)
                                     AND  d2.ObjectName = r.name)
                  AND  NOT EXISTS (SELECT 1 FROM @IFKTables x
                                   WHERE  x.SchemaName = SCHEMA_NAME(r.schema_id)
                                     AND  x.ObjectName = r.name);
            ELSE
                -- Level N: inbound FKs of the previous level's newly added tables
                INSERT @IFKBatch (SchemaName, ObjectName)
                SELECT DISTINCT SCHEMA_NAME(r.schema_id), r.name
                FROM   @IFKTables f
                JOIN   sys.objects t
                       ON  t.object_id = OBJECT_ID(QUOTENAME(f.SchemaName) + N'.' + QUOTENAME(f.ObjectName))
                       AND t.type = 'U'
                JOIN   sys.foreign_keys fk
                       ON  fk.referenced_object_id = t.object_id
                       AND fk.is_disabled          = 0
                JOIN   sys.objects r
                       ON  r.object_id = fk.parent_object_id
                       AND r.type      = 'U'
                WHERE  f.FakeLevel = @IFKLevelCur - 1
                  AND  SCHEMA_NAME(r.schema_id) NOT IN (N'tSQLt', N'TestGen', N'TestGenLog')
                  AND  SCHEMA_NAME(r.schema_id) NOT LIKE 'test[_]%'
                  AND  NOT EXISTS (SELECT 1 FROM @IFKTables x
                                   WHERE  x.SchemaName = SCHEMA_NAME(r.schema_id)
                                     AND  x.ObjectName = r.name)
                  AND  NOT EXISTS (SELECT 1 FROM @Deps d2
                                   WHERE  d2.DepKind IN ('TABLE','VIEW')
                                     AND  d2.SchemaName = SCHEMA_NAME(r.schema_id)
                                     AND  d2.ObjectName = r.name);

            INSERT @IFKTables (SchemaName, ObjectName, FakeLevel)
            SELECT SchemaName, ObjectName, @IFKLevelCur FROM @IFKBatch;
            SET @IFKAdded = @@ROWCOUNT;
        END;

        /* Emit SafeFakeTable for inbound-FK tables deepest-first (highest
           FakeLevel first) so each level's FK constraints are gone before
           the next level is renamed. */
        IF EXISTS (SELECT 1 FROM @IFKTables)
        BEGIN
            DECLARE @IFKSchema SYSNAME, @IFKObj SYSNAME;
            DECLARE ifk_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT SchemaName, ObjectName
                FROM   @IFKTables
                ORDER  BY FakeLevel DESC, SchemaName, ObjectName;
            OPEN ifk_cur;
            FETCH NEXT FROM ifk_cur INTO @IFKSchema, @IFKObj;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @MockBlock = @MockBlock
                    + N'    EXEC TestGen.SafeFakeTable N''' + @IFKSchema + N'.' + @IFKObj
                    + N''';  -- cascade-faked: inbound-FK dep' + @CRLF;
                FETCH NEXT FROM ifk_cur INTO @IFKSchema, @IFKObj;
            END;
            CLOSE ifk_cur; DEALLOCATE ifk_cur;
        END;

        /* ------------------------------------------------------------------
         * Emit FakeTable calls via TestGen.SafeFakeTable, which tries
         * @SchemaBoundDependencies = 1 first and falls back to the older
         * signature if that argument isn't recognised. This avoids any
         * tSQLt-version probing in the generator itself.
         * -----------------------------------------------------------------*/
        SELECT @MockBlock = @MockBlock
            + N'    EXEC TestGen.SafeFakeTable N''' + SchemaName + N'.' + ObjectName + N''';' + @CRLF
        FROM @Deps
        WHERE DepKind IN ('TABLE','VIEW');

        SELECT @MockBlock = @MockBlock
            + N'    EXEC tSQLt.SpyProcedure @ProcedureName = N''' + SchemaName + N'.' + ObjectName + N''';'
            + @CRLF
        FROM @Deps
        WHERE DepKind = 'PROCEDURE';

        SELECT @MockBlock = @MockBlock
            + N'    -- TODO: tSQLt.FakeFunction is needed for ' + SchemaName + N'.' + ObjectName
            + N' (no generic auto-mock available).' + @CRLF
        FROM @Deps
        WHERE DepKind = 'FUNCTION';

        -- After the FakeTable calls, inline static seed-data INSERTs so
        -- every generated test is self-documenting: a future reader can
        -- see exactly which rows are populated without resolving any
        -- framework procedures. We still use TestGen.BuildSeedInsertForTable
        -- to compose each INSERT - the procedure that owned the runtime
        -- seeding behaviour - but we call it at generation time and embed
        -- its output verbatim.
        IF EXISTS (SELECT 1 FROM @Deps WHERE DepKind IN ('TABLE','VIEW'))
        BEGIN
            -- Comma-separated list of tables for FK lookup inside BuildSeedInsertForTable.
            DECLARE @SeedList NVARCHAR(MAX) = N'';
            SELECT @SeedList = @SeedList + N',' + SchemaName + N'.' + ObjectName
            FROM @Deps WHERE DepKind IN ('TABLE','VIEW');
            SET @SeedList = STUFF(@SeedList, 1, 1, N'');

            -- Topo-sort dependencies so parents (referenced FK targets) come first.
            -- This is a per-generation topo sort - identical algorithm to the one
            -- in TestGen.SeedFakedTables, but executed at generation time.
            DECLARE @TableOrder TABLE
            (
                SeedOrder INT IDENTITY(1,1) PRIMARY KEY,
                ObjId     INT,
                FullName  NVARCHAR(300)
            );
            DECLARE @Pending TABLE
            (
                ObjId    INT PRIMARY KEY,
                FullName NVARCHAR(300)
            );
            DECLARE @Edges2 TABLE
            (
                ChildId   INT,
                ParentId  INT
            );

            INSERT @Pending (ObjId, FullName)
            SELECT DISTINCT
                   OBJECT_ID(QUOTENAME(d.SchemaName) + N'.' + QUOTENAME(d.ObjectName)),
                   d.SchemaName + N'.' + d.ObjectName
            FROM @Deps d
            WHERE d.DepKind IN ('TABLE','VIEW');

            INSERT @Edges2 (ChildId, ParentId)
            SELECT DISTINCT fkc.parent_object_id, fkc.referenced_object_id
            FROM sys.foreign_key_columns fkc
            WHERE fkc.parent_object_id     IN (SELECT ObjId FROM @Pending)
              AND fkc.referenced_object_id IN (SELECT ObjId FROM @Pending)
              AND fkc.parent_object_id <> fkc.referenced_object_id;

            DECLARE @nextObjId INT, @nextName NVARCHAR(300);
            WHILE EXISTS (SELECT 1 FROM @Pending)
            BEGIN
                SET @nextObjId = NULL;

                SELECT TOP 1 @nextObjId = p.ObjId, @nextName = p.FullName
                FROM @Pending p
                WHERE NOT EXISTS
                (
                    SELECT 1 FROM @Edges2 e
                    WHERE e.ChildId = p.ObjId
                      AND e.ParentId IN (SELECT ObjId FROM @Pending)
                )
                ORDER BY p.ObjId;

                IF @nextObjId IS NULL  -- FK cycle: break it arbitrarily
                    SELECT TOP 1 @nextObjId = ObjId, @nextName = FullName
                    FROM @Pending ORDER BY ObjId;

                INSERT @TableOrder (ObjId, FullName) VALUES (@nextObjId, @nextName);
                DELETE FROM @Pending WHERE ObjId = @nextObjId;
            END;

            -- Now build each INSERT in topo order and append to the mock block.
            DECLARE @soId INT, @soName NVARCHAR(300), @insertSql NVARCHAR(MAX);
            DECLARE seed_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT ObjId, FullName FROM @TableOrder ORDER BY SeedOrder;
            OPEN seed_cur;
            FETCH NEXT FROM seed_cur INTO @soId, @soName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC TestGen.BuildSeedInsertForTable
                     @ObjectId        = @soId,
                     @TableSet        = @SeedList,
                     @RowCount        = 5,
                     @SkipSafetyCheck = 1,
                     @InsertSql       = @insertSql OUTPUT;

                -- Indent the embedded INSERT so it reads nicely under "Arrange".
                SET @MockBlock = @MockBlock
                    + N'    -- Seed: ' + @soName + @CRLF
                    + N'    ' + REPLACE(@insertSql, CHAR(10), CHAR(10) + N'    ')
                    + @CRLF;

                FETCH NEXT FROM seed_cur INTO @soId, @soName;
            END;
            CLOSE seed_cur; DEALLOCATE seed_cur;
        END;

        IF LEN(@MockBlock) = 0
            SET @MockBlock = N'    -- No external tables/procedures referenced - no mocks required.' + @CRLF;

        /* ------------------------------------------------------------------
         * v9.4.3: build a copy of the source with BEGIN CATCH...END CATCH
         * blocks removed, so a dependency referenced ONLY inside a CATCH
         * block (an error handler) can be told apart from one called on the
         * normal path.  Simple forward pairing - adequate for the (near
         * universal) non-nested TRY/CATCH case.
         * -----------------------------------------------------------------*/
        DECLARE @SrcU       NVARCHAR(MAX) = UPPER(ISNULL(@ProcSource, N''));
        DECLARE @SrcNoCatch NVARCHAR(MAX) = @SrcU;
        DECLARE @CatchText  NVARCHAR(MAX) = N'';
        DECLARE @bcPos INT, @ecEnd INT;
        WHILE 1 = 1
        BEGIN
            SET @bcPos = CHARINDEX(N'BEGIN CATCH', @SrcNoCatch);
            IF @bcPos = 0 BREAK;
            SET @ecEnd = CHARINDEX(N'END CATCH', @SrcNoCatch, @bcPos);
            IF @ecEnd = 0 BREAK;
            SET @ecEnd = @ecEnd + 9;   -- length of 'END CATCH'
            SET @CatchText  = @CatchText + N' '
                            + SUBSTRING(@SrcNoCatch, @bcPos, @ecEnd - @bcPos)
                            + N' ';
            SET @SrcNoCatch = STUFF(@SrcNoCatch, @bcPos, @ecEnd - @bcPos, N'');
        END;


        /* ------------------------------------------------------------------
         * 5. Build the dependency-call assertions block
         * -----------------------------------------------------------------*/
        DECLARE @SpyAssertions      NVARCHAR(MAX) = N'';
        DECLARE @CatchSpyAssertions NVARCHAR(MAX) = N'';
        DECLARE @HasCatchOnlyDep    BIT = 0;
        DECLARE @dschema SYSNAME, @dname SYSNAME, @dIsCatchOnly BIT,
                @oneSpyAssert NVARCHAR(MAX);
        DECLARE dcur CURSOR LOCAL FAST_FORWARD FOR
            SELECT SchemaName, ObjectName FROM @Deps WHERE DepKind = 'PROCEDURE';
        OPEN dcur;
        FETCH NEXT FROM dcur INTO @dschema, @dname;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            /* v9.4.3: a dependency referenced ONLY inside a CATCH block is an
               error-path call - it is NOT invoked on a happy-path run, so
               asserting it in the normal Test 5 false-fails a correct proc.
               Such dependencies are routed to the forced-error test instead. */
            SET @dIsCatchOnly =
                CASE WHEN CHARINDEX(UPPER(@dname), @SrcNoCatch) = 0
                       AND CHARINDEX(UPPER(@dname), @SrcU) > 0
                     THEN 1 ELSE 0 END;
            SET @oneSpyAssert =
                  N'    IF (SELECT COUNT(*) FROM '
                + QUOTENAME(@dschema) + N'.' + QUOTENAME(@dname + N'_SpyProcedureLog')
                + N') = 0' + @CRLF
                + N'        EXEC tSQLt.Fail ''Expected dependent procedure '
                + @dschema + N'.' + @dname + N' to have been called.'';' + @CRLF;
            IF @dIsCatchOnly = 1
            BEGIN
                SET @CatchSpyAssertions = @CatchSpyAssertions + @oneSpyAssert;
                SET @HasCatchOnlyDep    = 1;
            END
            ELSE
                SET @SpyAssertions = @SpyAssertions + @oneSpyAssert;
            FETCH NEXT FROM dcur INTO @dschema, @dname;
        END;
        CLOSE dcur; DEALLOCATE dcur;

        /* ------------------------------------------------------------------
         * 6. Assemble the script
         * -----------------------------------------------------------------*/
        DECLARE @FullProc NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ProcName);
        DECLARE @TC SYSNAME = @TestClassName;
        DECLARE @S NVARCHAR(MAX) = N'';

        -- v11.x: a procedure that NEVER changes row counts (read-only OR UPDATE-only
        -- - an UPDATE rewrites existing rows, it adds/removes none) is "count-stable".
        -- Only INSERT/DELETE/MERGE change counts.  Every per-input test of a count-
        -- stable proc captures each faked table's row count before and after the EXEC
        -- and asserts they are EQUAL - replacing the old trivial 1=1 placeholder with a
        -- real before/after check that FAILS if the proc adds or removes rows.
        DECLARE @v94CountStable BIT =
            CASE WHEN N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]INSERT[^A-Z0-9_]%'
                   OR N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]DELETE[^A-Z0-9_]%'
                   OR N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]MERGE[^A-Z0-9_]%'
                 THEN 0 ELSE 1 END;
        DECLARE @PreCnt  NVARCHAR(MAX) = N'';
        DECLARE @PostCnt NVARCHAR(MAX) = N'';
        IF @v94CountStable = 1 AND EXISTS (SELECT 1 FROM @Deps WHERE DepKind IN ('TABLE','VIEW'))
        BEGIN
            SET @PreCnt  = N'    -- Before/after row-count guard (count-stable proc: adds/removes no rows)' + @CRLF
                         + N'    CREATE TABLE #rcB (TableName SYSNAME, [RowCount] INT);' + @CRLF
                         + N'    CREATE TABLE #rcA (TableName SYSNAME, [RowCount] INT);' + @CRLF;
            DECLARE @cgs SYSNAME, @cgn SYSNAME, @cgf NVARCHAR(300);
            DECLARE cgcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT SchemaName, ObjectName FROM @Deps WHERE DepKind IN ('TABLE','VIEW');
            OPEN cgcur;
            FETCH NEXT FROM cgcur INTO @cgs, @cgn;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @cgf = QUOTENAME(@cgs) + N'.' + QUOTENAME(@cgn);
                SET @PreCnt  = @PreCnt  + N'    INSERT #rcB SELECT ''' + @cgn + N''', COUNT(*) FROM ' + @cgf + N';' + @CRLF;
                SET @PostCnt = @PostCnt + N'    INSERT #rcA SELECT ''' + @cgn + N''', COUNT(*) FROM ' + @cgf + N';' + @CRLF;
                FETCH NEXT FROM cgcur INTO @cgs, @cgn;
            END;
            CLOSE cgcur; DEALLOCATE cgcur;
            SET @PostCnt = @PostCnt + N'    EXEC tSQLt.AssertEqualsTable ''#rcB'', ''#rcA'';' + @CRLF;
        END;

        SET @S = @S + N'/* ======================================================================' + @CRLF;
        SET @S = @S + N' * Auto-generated tSQLt test class for ' + @FullProc + @CRLF;
        SET @S = @S + N' * Generated on ' + CONVERT(VARCHAR(30), SYSUTCDATETIME(), 126) + N' UTC' + @CRLF;
        SET @S = @S + N' * By: tSQLtAutoGen framework (TestGen.GenerateTestsForProcedure)' + @CRLF;
        SET @S = @S + N' * Run ID: ' + CAST(@RunId AS NVARCHAR(10)) + @CRLF;
        SET @S = @S + N' * ====================================================================== */' + @CRLF;
        SET @S = @S + N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = N''' + @TC + N''')' + @CRLF;
        SET @S = @S + N'    EXEC tSQLt.DropClass ''' + @TC + N''';' + @CRLF;
        SET @S = @S + N'GO' + @CRLF;
        SET @S = @S + N'EXEC tSQLt.NewTestClass ''' + @TC + N''';' + @CRLF;
        SET @S = @S + N'GO' + @CRLF + @CRLF;

        /* -- Test 1: happy path ----------------------------------------- */
        SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC) + N'.[test ' + @ProcName + N' executes with valid inputs]' + @CRLF;
        SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF;
        SET @S = @S + N'    -- Arrange' + @CRLF + @MockBlock + @CRLF;
        SET @S = @S + ISNULL(@OutputDecls, N'');
        SET @S = @S + @PreCnt;
        SET @S = @S + N'    -- Act + Assert: run under faked + seeded deps.  A throw fails the test;' + @CRLF;
        SET @S = @S + N'    -- for a count-stable proc the before/after row-count guard then asserts' + @CRLF;
        SET @S = @S + N'    -- no rows were added or removed.' + @CRLF;
        SET @S = @S + N'    BEGIN TRY' + @CRLF;
        SET @S = @S + N'        EXEC ' + @FullProc;
        IF LEN(@ArgListHappy) > 0
            SET @S = @S + N' ' + @ArgListHappy;
        SET @S = @S + N';' + @CRLF;
        SET @S = @S + N'    END TRY' + @CRLF;
        SET @S = @S + N'    BEGIN CATCH' + @CRLF;
        SET @S = @S + N'        DECLARE @failMsg NVARCHAR(MAX) = N''Procedure raised an error on valid inputs: '' + ERROR_MESSAGE();' + @CRLF;
        SET @S = @S + N'        EXEC tSQLt.Fail @failMsg;' + @CRLF;
        SET @S = @S + N'    END CATCH;' + @CRLF;
        SET @S = @S + @PostCnt;
        SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

        /* -- Test 2: low / high boundary -------------------------------- */
        IF EXISTS (SELECT 1 FROM @Params WHERE IsOutput = 0)
        BEGIN
            -- The verb in the test name tells the reader what the test
            -- asserts: "accepts" means the proc should run cleanly with
            -- boundary inputs; "rejects" means the proc has validation
            -- that fires on those inputs and we're confirming it does.
            DECLARE @boundaryVerb NVARCHAR(20) =
                CASE WHEN @UseExpectExceptionForInvalid = 1 THEN N'rejects' ELSE N'accepts' END;

            -- Test 2a: low boundary
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' ' + @boundaryVerb
                       + N' low boundary values]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            IF @UseExpectExceptionForInvalid = 1
            BEGIN
                SET @S = @S + N'    -- Proc has input validation; boundary values are expected to be rejected.' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.ExpectException;' + @CRLF;
                SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListBoundary + N';' + @CRLF;
            END
            ELSE
            BEGIN
                SET @S = @S + @PreCnt;
                SET @S = @S + N'    BEGIN TRY' + @CRLF;
                SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgListBoundary + N';' + @CRLF;
                SET @S = @S + N'    END TRY' + @CRLF;
                SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                SET @S = @S + N'        DECLARE @failMsg NVARCHAR(MAX) = N''Procedure raised an error on low-boundary inputs: '' + ERROR_MESSAGE();' + @CRLF;
                SET @S = @S + N'        EXEC tSQLt.Fail @failMsg;' + @CRLF;
                SET @S = @S + N'    END CATCH;' + @CRLF;
                SET @S = @S + @PostCnt;
            END;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

            -- Test 2b: high boundary
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' ' + @boundaryVerb
                       + N' high boundary values]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            IF @UseExpectExceptionForInvalid = 1
            BEGIN
                SET @S = @S + N'    -- Proc has input validation; boundary values are expected to be rejected.' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.ExpectException;' + @CRLF;
                SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListHighBnd + N';' + @CRLF;
            END
            ELSE
            BEGIN
                SET @S = @S + @PreCnt;
                SET @S = @S + N'    BEGIN TRY' + @CRLF;
                SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgListHighBnd + N';' + @CRLF;
                SET @S = @S + N'    END TRY' + @CRLF;
                SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                SET @S = @S + N'        DECLARE @failMsg NVARCHAR(MAX) = N''Procedure raised an error on high-boundary inputs: '' + ERROR_MESSAGE();' + @CRLF;
                SET @S = @S + N'        EXEC tSQLt.Fail @failMsg;' + @CRLF;
                SET @S = @S + N'    END CATCH;' + @CRLF;
                SET @S = @S + @PostCnt;
            END;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
        END;

        /* -- Test 3: NULL injection per nullable, non-output param ------ */
        DECLARE @nullParamId INT, @nullParamName SYSNAME;
        -- These two must be DECLARE'd outside the loop. T-SQL only runs
        -- a DECLARE @x = <expr> initializer the FIRST time the statement
        -- is encountered; subsequent loop iterations do not re-evaluate
        -- it, so the variable would stick at iteration-1's value.
        DECLARE @IsMatchedParamBeingNulled BIT;
        DECLARE @NullVerb                  NVARCHAR(20);
        DECLARE @ArgsNull NVARCHAR(MAX);
        DECLARE @phStart  INT, @phEnd INT;
        DECLARE @v943HasNullGuard BIT;
        DECLARE @v943ScanPos      INT;
        DECLARE @v943IfPos        INT;
        DECLARE @v943Window       NVARCHAR(MAX);
        /* v10.0.1: locals for Pattern-B structural containment scan. */
        DECLARE @v100PredOpen     INT;
        DECLARE @v100PredClose    INT;
        DECLARE @v100Depth        INT;
        DECLARE @v100Scan         INT;
        DECLARE @v100Char         NCHAR(1);
        DECLARE ncur CURSOR LOCAL FAST_FORWARD FOR
            SELECT ParamId, ParamName FROM @Params
            WHERE IsNullable = 1 AND IsOutput = 0 AND @EmitNullChecks = 1;
        OPEN ncur;
        FETCH NEXT FROM ncur INTO @nullParamId, @nullParamName;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- v9.4.3 (refined): derive @ArgsNull from @ArgListHappy by replacing
            -- only the null'd parameter's value with NULL.  Reusing @ArgListHappy
            -- means non-null'd parameters take the SAME valid happy-path values
            -- (including branch-detected ones like @OrderType = 'Express') that
            -- Test 1 uses, instead of generic GetSampleValueLiteral defaults
            -- that fail proc-specific validation - e.g. dbo.uspProcessSalesOrder
            -- raises "Invalid order type" for a 'Sam' @OrderType.
            SET @ArgsNull = @ArgListHappy;
            SET @phStart  = CHARINDEX(@nullParamName + N' = ', @ArgsNull);
            IF @phStart > 0
            BEGIN
                SET @phEnd = CHARINDEX(N', @', @ArgsNull, @phStart);
                IF @phEnd = 0 SET @phEnd = LEN(@ArgsNull) + 1;
                SET @ArgsNull = STUFF(@ArgsNull, @phStart,
                                     @phEnd - @phStart,
                                     @nullParamName + N' = NULL');
            END;

            -- v9.4.3: the NULL-injection verb is decided PER PARAMETER.  A hard
            -- "rejects NULL" (ExpectException) is emitted only when the
            -- procedure has detected error paths (@UseExpectExceptionForInvalid)
            -- AND this specific parameter is one the procedure keys on - a
            -- PK/FK-matched parameter (@IsMatchedParamBeingNulled), where a NULL
            -- reliably fails the lookup.  A non-key parameter is not validated
            -- just because the procedure validates some OTHER parameter, so its
            -- NULL test is an "accepts NULL" smoke test - otherwise it
            -- false-fails a correct procedure (e.g. dbo.PlaceOrder @Total /
            -- @Notes, where only @CustomerId is validated).
            SET @IsMatchedParamBeingNulled =
                CASE WHEN EXISTS (SELECT 1 FROM @ParamMatchedColumns m
                                  WHERE m.ParamName = @nullParamName)
                     THEN 1 ELSE 0 END;
            -- v9.4.3 (refined further): emit a "rejects NULL" test only when the
            -- procedure has error paths AND the framework has actual evidence
            -- the procedure null-checks this parameter.  PK/FK match alone is
            -- NOT enough - e.g. uspProcessSalesOrderRealistic's @CustomerID
            -- is FK-matched but the procedure inserts NULL without raising.
            -- Two evidence patterns are accepted:
            --   (a) an explicit  IF @<param> IS NULL  guard, or
            --   (b) an  IF NOT EXISTS (...)  with the parameter name and a
            --       RAISERROR / THROW within a 500-character proximity window
            --       (the typical FK-existence-check pattern - dbo.PlaceOrder
            --       for @CustomerId).
            -- Procs with no error paths still get the "accepts NULL" smoke.
            SET @v943HasNullGuard = 0;
            IF @UseExpectExceptionForInvalid = 0
                SET @v943HasNullGuard = 1;
            ELSE
            BEGIN
                IF @SrcU LIKE N'%IF ' + UPPER(@nullParamName) + N' IS NULL%'
                    SET @v943HasNullGuard = 1;
                IF @v943HasNullGuard = 0
                BEGIN
                    SET @v943ScanPos = 1;
                    WHILE 1 = 1
                    BEGIN
                        SET @v943IfPos = CHARINDEX(N'IF NOT EXISTS', @SrcU, @v943ScanPos);
                        IF @v943IfPos = 0 BREAK;

                        /* v10.0.1: tighten Pattern B from 500-char proximity
                           to structural containment.  Prior version produced
                           false positives for params that just happen to
                           appear in the next INSERT after an unrelated guard
                           (dbo.PlaceOrder @Notes / @Total).  Now require:
                             - @<param> inside the IF NOT EXISTS (...) predicate, AND
                             - RAISERROR / THROW within 200 chars after the
                               predicate's matching closing paren (i.e. in
                               the IF's body, not somewhere later in the proc).
                        */
                        SET @v100PredOpen = CHARINDEX(N'(', @SrcU, @v943IfPos);
                        IF @v100PredOpen = 0
                        BEGIN
                            SET @v943ScanPos = @v943IfPos + 1;
                            CONTINUE;
                        END;

                        -- Walk forward counting parens to find the predicate's
                        -- matching close.
                        SET @v100Depth     = 0;
                        SET @v100Scan      = @v100PredOpen;
                        SET @v100PredClose = 0;
                        WHILE @v100Scan <= LEN(@SrcU)
                        BEGIN
                            SET @v100Char = SUBSTRING(@SrcU, @v100Scan, 1);
                            IF @v100Char = N'(' SET @v100Depth = @v100Depth + 1;
                            ELSE IF @v100Char = N')'
                            BEGIN
                                SET @v100Depth = @v100Depth - 1;
                                IF @v100Depth = 0
                                BEGIN
                                    SET @v100PredClose = @v100Scan;
                                    BREAK;
                                END;
                            END;
                            SET @v100Scan = @v100Scan + 1;
                        END;

                        IF @v100PredClose = 0
                        BEGIN
                            SET @v943ScanPos = @v943IfPos + 1;
                            CONTINUE;
                        END;

                        -- @v943Window now holds the predicate text (inside parens).
                        SET @v943Window = SUBSTRING(@SrcU, @v100PredOpen + 1,
                                                    @v100PredClose - @v100PredOpen - 1);
                        IF CHARINDEX(UPPER(@nullParamName), @v943Window) = 0
                        BEGIN
                            SET @v943ScanPos = @v943IfPos + 1;
                            CONTINUE;
                        END;

                        -- Body window: 200 chars after the predicate's close.
                        SET @v943Window = SUBSTRING(@SrcU, @v100PredClose + 1, 200);
                        IF CHARINDEX(N'RAISERROR', @v943Window) > 0
                           OR CHARINDEX(N'THROW',     @v943Window) > 0
                        BEGIN
                            SET @v943HasNullGuard = 1;
                            BREAK;
                        END;

                        SET @v943ScanPos = @v943IfPos + 1;
                    END;
                END;
            END;

            IF @v943HasNullGuard = 0
            BEGIN
                FETCH NEXT FROM ncur INTO @nullParamId, @nullParamName;
                CONTINUE;
            END;

            SET @NullVerb = CASE WHEN @UseExpectExceptionForInvalid = 1
                                 THEN N'rejects' ELSE N'accepts' END;

            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' ' + @NullVerb
                       + N' NULL for ' + @nullParamName + N']' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');

            IF @UseExpectExceptionForInvalid = 1
            BEGIN
                SET @S = @S + N'    -- This parameter is one the procedure keys on, and the' + @CRLF;
                SET @S = @S + N'    -- procedure has input-validation error paths; a NULL is' + @CRLF;
                SET @S = @S + N'    -- expected to be rejected.' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.ExpectException;' + @CRLF;
                SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgsNull + N';' + @CRLF;
            END
            ELSE
            BEGIN
                SET @S = @S + N'    -- This parameter is not one the procedure is known to validate,' + @CRLF;
                SET @S = @S + N'    -- so a NULL is not expected to raise.  Run it; the before/after' + @CRLF;
                SET @S = @S + N'    -- row-count guard asserts no rows were added or removed.' + @CRLF;
                SET @S = @S + @PreCnt;
                SET @S = @S + N'    BEGIN TRY' + @CRLF;
                SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgsNull + N';' + @CRLF;
                SET @S = @S + N'    END TRY' + @CRLF;
                SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                SET @S = @S + N'        DECLARE @failMsg NVARCHAR(MAX) = N''Procedure raised an error on a NULL parameter: '' + ERROR_MESSAGE();' + @CRLF;
                SET @S = @S + N'        EXEC tSQLt.Fail @failMsg;' + @CRLF;
                SET @S = @S + N'    END CATCH;' + @CRLF;
                SET @S = @S + @PostCnt;
            END;

            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

            FETCH NEXT FROM ncur INTO @nullParamId, @nullParamName;
        END;
        CLOSE ncur; DEALLOCATE ncur;

        /* -- Test 4: side-effect isolation on referenced tables --------- */
        IF EXISTS (SELECT 1 FROM @Deps WHERE DepKind IN ('TABLE','VIEW'))
        BEGIN
            -- v11.x: a procedure that NEVER changes row counts (read-only OR
            -- UPDATE-only - an UPDATE rewrites existing rows, it does not add or
            -- remove any) gets the strong before/after row-count assertion below.
            -- Only INSERT / DELETE / MERGE change counts by design, so ONLY those
            -- are excluded.  (Previously UPDATE was wrongly grouped with them,
            -- which silently dropped the assertion from every UPDATE proc's test.)
            -- @v94CountStable is computed once near the top of this procedure.
            -- v11.x: an UPDATE-only proc additionally asserts that content actually
            -- CHANGED (count held is necessary but not sufficient).  A hash of each
            -- directly-referenced table's comparable columns is captured before and
            -- after; at least one must differ.
            DECLARE @v94HasUpdate BIT =
                CASE WHEN @v94CountStable = 1
                      AND N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]UPDATE[^A-Z0-9_]%'
                     THEN 1 ELSE 0 END;
            DECLARE @v94CcCols NVARCHAR(MAX);
            -- This is an isolation test.  A count-stable procedure (read-only or
            -- UPDATE-only) additionally gets a strong per-table "row counts held"
            -- assertion below; an INSERT/DELETE/MERGE procedure legitimately
            -- changes its (faked) tables' counts, so for it this is an isolation
            -- smoke test - it must run cleanly against faked + seeded copies of
            -- every dependency (the EXEC below is TRY/CATCH-guarded).
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' touches only mocked tables]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- Capture row counts before execution' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #v94_RcBefore (TableName SYSNAME, [RowCount] INT);' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #v94_RcAfter  (TableName SYSNAME, [RowCount] INT);' + @CRLF;
            IF @v94HasUpdate = 1
            BEGIN
                SET @S = @S + N'    CREATE TABLE #v94_HashBefore (TableName SYSNAME, ContentHash INT);' + @CRLF;
                SET @S = @S + N'    CREATE TABLE #v94_HashAfter  (TableName SYSNAME, ContentHash INT);' + @CRLF;
            END;
            
            -- Build row count capture for each table dependency
            DECLARE @TableSchema SYSNAME, @TableName SYSNAME, @FullTable NVARCHAR(300);
            DECLARE tcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT SchemaName, ObjectName 
                FROM @Deps 
                WHERE DepKind IN ('TABLE','VIEW');
            
            OPEN tcur;
            FETCH NEXT FROM tcur INTO @TableSchema, @TableName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @FullTable = QUOTENAME(@TableSchema) + N'.' + QUOTENAME(@TableName);
                SET @S = @S + N'    INSERT #v94_RcBefore SELECT ''' + @TableName + N''', COUNT(*) FROM ' + @FullTable + N';' + @CRLF;
                IF @v94HasUpdate = 1
                BEGIN
                    SET @v94CcCols = N'';
                    SELECT @v94CcCols = @v94CcCols + N', ' + QUOTENAME(c.name)
                    FROM sys.columns c JOIN sys.types t ON c.user_type_id = t.user_type_id
                    WHERE c.object_id = OBJECT_ID(@FullTable)
                      AND t.name NOT IN ('xml','text','ntext','image','geography','geometry','hierarchyid')
                    ORDER BY c.column_id;
                    IF LEN(ISNULL(@v94CcCols,N'')) > 0
                    BEGIN
                        SET @v94CcCols = STUFF(@v94CcCols,1,2,N'');
                        SET @S = @S + N'    INSERT #v94_HashBefore SELECT ''' + @TableName + N''', CHECKSUM_AGG(BINARY_CHECKSUM(' + @v94CcCols + N')) FROM ' + @FullTable + N';' + @CRLF;
                    END;
                END;
                FETCH NEXT FROM tcur INTO @TableSchema, @TableName;
            END;
            CLOSE tcur;
            
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    -- Execute the procedure.  The TRY/CATCH is the isolation assertion:' + @CRLF;
            SET @S = @S + N'    -- the procedure must run without error against faked, seeded copies' + @CRLF;
            SET @S = @S + N'    -- of every table dependency.' + @CRLF;
            SET @S = @S + N'    BEGIN TRY' + @CRLF;
            SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgListHappy + N';' + @CRLF;
            SET @S = @S + N'    END TRY' + @CRLF;
            SET @S = @S + N'    BEGIN CATCH' + @CRLF;
            SET @S = @S + N'        DECLARE @v94IsoErr NVARCHAR(MAX);' + @CRLF;
            SET @S = @S + N'        SET @v94IsoErr = N''Isolation failure: the procedure raised an error when run with all table dependencies faked and seeded - '' + ERROR_MESSAGE();' + @CRLF;
            SET @S = @S + N'        EXEC tSQLt.Fail @v94IsoErr;' + @CRLF;
            SET @S = @S + N'    END CATCH;' + @CRLF;
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    -- Capture row counts after execution' + @CRLF;
            
            -- Reuse cursor for after counts
            OPEN tcur;
            FETCH NEXT FROM tcur INTO @TableSchema, @TableName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @FullTable = QUOTENAME(@TableSchema) + N'.' + QUOTENAME(@TableName);
                SET @S = @S + N'    INSERT #v94_RcAfter SELECT ''' + @TableName + N''', COUNT(*) FROM ' + @FullTable + N';' + @CRLF;
                IF @v94HasUpdate = 1
                BEGIN
                    SET @v94CcCols = N'';
                    SELECT @v94CcCols = @v94CcCols + N', ' + QUOTENAME(c.name)
                    FROM sys.columns c JOIN sys.types t ON c.user_type_id = t.user_type_id
                    WHERE c.object_id = OBJECT_ID(@FullTable)
                      AND t.name NOT IN ('xml','text','ntext','image','geography','geometry','hierarchyid')
                    ORDER BY c.column_id;
                    IF LEN(ISNULL(@v94CcCols,N'')) > 0
                    BEGIN
                        SET @v94CcCols = STUFF(@v94CcCols,1,2,N'');
                        SET @S = @S + N'    INSERT #v94_HashAfter SELECT ''' + @TableName + N''', CHECKSUM_AGG(BINARY_CHECKSUM(' + @v94CcCols + N')) FROM ' + @FullTable + N';' + @CRLF;
                    END;
                END;
                FETCH NEXT FROM tcur INTO @TableSchema, @TableName;
            END;
            CLOSE tcur;
            DEALLOCATE tcur;
            
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    -- v9.4.2: per-table isolation check (was a cross-table SUM,' + @CRLF;
            SET @S = @S + N'    --         which hid offsetting changes and was never asserted).' + @CRLF;
            IF @v94CountStable = 1
            BEGIN
                SET @S = @S + N'    -- Count-stable procedure (read-only or UPDATE-only): an UPDATE' + @CRLF;
                SET @S = @S + N'    -- rewrites existing rows, it never adds or removes any, so every' + @CRLF;
                SET @S = @S + N'    -- faked table''s row count must be identical before and after.' + @CRLF;
                SET @S = @S + N'    -- AssertEqualsTable compares the two capture tables row-for-row,' + @CRLF;
                SET @S = @S + N'    -- so a change in ANY single table is caught.' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.AssertEqualsTable ''#v94_RcBefore'', ''#v94_RcAfter'';' + @CRLF;
                IF @v94HasUpdate = 1
                BEGIN
                    SET @S = @S + N'    -- UPDATE procedure: count held above is necessary but not sufficient;' + @CRLF;
                    SET @S = @S + N'    -- the proc must also MODIFY content - at least one referenced table''s' + @CRLF;
                    SET @S = @S + N'    -- comparable-column hash must differ before vs after.  (The seed is' + @CRLF;
                    SET @S = @S + N'    -- arranged so the UPDATE''s WHERE matches and its SET changes a value;' + @CRLF;
                    SET @S = @S + N'    -- CLR / LOB columns are excluded from the hash.)' + @CRLF;
                    SET @S = @S + N'    IF EXISTS (SELECT 1 FROM #v94_HashBefore)' + @CRLF;
                    SET @S = @S + N'    BEGIN' + @CRLF;
                    SET @S = @S + N'        DECLARE @v94ContentChanged INT =' + @CRLF;
                    SET @S = @S + N'            (SELECT COUNT(*) FROM #v94_HashBefore b' + @CRLF;
                    SET @S = @S + N'             JOIN #v94_HashAfter a ON a.TableName = b.TableName' + @CRLF;
                    SET @S = @S + N'             WHERE ISNULL(a.ContentHash, -2147483648) <> ISNULL(b.ContentHash, -2147483648));' + @CRLF;
                    -- v9.4.3: a CASE expression is NOT a legal EXEC parameter value
                    -- (raises 'Incorrect syntax near CASE'); compute it into a BIT
                    -- variable first, then pass the variable to AssertEquals.
                    SET @S = @S + N'        DECLARE @v94Changed INT = CASE WHEN @v94ContentChanged > 0 THEN 1 ELSE 0 END;' + @CRLF;
                    SET @S = @S + N'        EXEC tSQLt.AssertEquals' + @CRLF;
                    SET @S = @S + N'             @Expected = 1,' + @CRLF;
                    SET @S = @S + N'             @Actual   = @v94Changed,' + @CRLF;
                    SET @S = @S + N'             @Message  = ''UPDATE procedure must modify row content in at least one faked table (before <> after).'';' + @CRLF;
                    SET @S = @S + N'    END;' + @CRLF;
                END;
            END
            ELSE
            BEGIN
                SET @S = @S + N'    -- INSERT/DELETE/MERGE procedure: row counts change by design, so a' + @CRLF;
                SET @S = @S + N'    -- counts-held assertion would false-fail.  The isolation assertion is' + @CRLF;
                SET @S = @S + N'    -- the TRY/CATCH around the EXEC above; the per-table delta below is' + @CRLF;
                SET @S = @S + N'    -- printed for reference (exact content effect: see characterization scaffold).' + @CRLF;
                SET @S = @S + N'    DECLARE @v94IsoMsg NVARCHAR(MAX) = N'''';' + @CRLF;
                SET @S = @S + N'    SELECT @v94IsoMsg = @v94IsoMsg + b.TableName + N'': '' + CAST(b.[RowCount] AS NVARCHAR(12))' + @CRLF;
                SET @S = @S + N'                       + N'' -> '' + CAST(a.[RowCount] AS NVARCHAR(12)) + N''    ''' + @CRLF;
                SET @S = @S + N'    FROM #v94_RcBefore b JOIN #v94_RcAfter a ON a.TableName = b.TableName;' + @CRLF;
                SET @S = @S + N'    PRINT ''Faked-table row counts (before -> after): '' + ISNULL(@v94IsoMsg, N''(none)'');' + @CRLF;
            END;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
        END;

        /* -- Test 5: dependent procedure calls (via SpyProcedure) -------
         * v9.4.3: only dependencies invoked on the NORMAL path are asserted
         * here.  CATCH-block (error-handler) dependencies were routed to
         * @CatchSpyAssertions and are verified by the forced-error test
         * below, so this test no longer false-fails a correct procedure
         * whose dependency is called only from a CATCH. */
        IF LEN(@SpyAssertions) > 0
        BEGIN
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' invokes its dependent procedures]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- Asserts the dependencies called on a normal (non-error) run.' + @CRLF;
            SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListHappy + N';' + @CRLF;
            SET @S = @S + @SpyAssertions;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
        END;

        /* -- Test 5b: forced-error test - exercise the CATCH block -------
         * v9.4.3: for a procedure that has a CATCH-block dependency, does DML
         * and has a fakeable table dependency, this forces the TRY block to
         * fail (an AFTER trigger on each faked table raises a runtime error),
         * so the procedure's own CATCH executes, and asserts the CATCH-block
         * dependency was actually invoked.  Removes the old false failure AND
         * gives real coverage of the error-handling code.  Skipped when the
         * TRY block contains a RETURN - the DML may then be unreachable
         * (e.g. dbo.uspLogError gates its body on ERROR_NUMBER()). */
        DECLARE @v943ForceErrOK BIT = 0;
        IF @HasCatchOnlyDep = 1
           AND EXISTS (SELECT 1 FROM @Deps WHERE DepKind = 'TABLE')
        BEGIN
            DECLARE @v943Pad NVARCHAR(MAX) = N' ' + @SrcU + N' ';
            DECLARE @v943DoesDml BIT =
                CASE WHEN @v943Pad LIKE N'%[^A-Z0-9_]INSERT[^A-Z0-9_]%'
                       OR @v943Pad LIKE N'%[^A-Z0-9_]UPDATE[^A-Z0-9_]%'
                       OR @v943Pad LIKE N'%[^A-Z0-9_]DELETE[^A-Z0-9_]%'
                       OR @v943Pad LIKE N'%[^A-Z0-9_]MERGE[^A-Z0-9_]%'
                     THEN 1 ELSE 0 END;
            DECLARE @v943Bt INT = CHARINDEX(N'BEGIN TRY', @SrcU);
            DECLARE @v943Et INT = CASE WHEN @v943Bt > 0
                                       THEN CHARINDEX(N'END TRY', @SrcU, @v943Bt)
                                       ELSE 0 END;
            DECLARE @v943TryHasReturn BIT = 0;
            IF @v943Bt > 0 AND @v943Et > @v943Bt
            BEGIN
                DECLARE @v943Try NVARCHAR(MAX) =
                    N' ' + SUBSTRING(@SrcU, @v943Bt, @v943Et - @v943Bt) + N' ';
                IF @v943Try LIKE N'%[^A-Z0-9_]RETURN[^A-Z0-9_]%'
                    SET @v943TryHasReturn = 1;
            END;
            -- v9.4.3 (refined): exclude procedures whose CATCH block contains
            -- ROLLBACK TRANSACTION / ROLLBACK TRAN.  An unnamed ROLLBACK inside
            -- a tSQLt test rolls back the framework's outer transaction (which
            -- holds the spy and FakeTable setup), so the spy log table is gone
            -- by the time the assertion runs - e.g. HumanResources.
            -- uspUpdateEmployeeHireInfo.  Named savepoint rollbacks are excluded
            -- too out of caution; rare in practice.
            DECLARE @v943CatchRollback BIT =
                CASE WHEN @CatchText LIKE N'%[^A-Z0-9_]ROLLBACK[^A-Z0-9_]%'
                     THEN 1 ELSE 0 END;
            IF @v943DoesDml = 1
               AND @v943TryHasReturn = 0
               AND @v943CatchRollback = 0
                SET @v943ForceErrOK = 1;
        END;

        IF @v943ForceErrOK = 1
        BEGIN
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' exercises its error-handling path]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- v9.4.3: force the procedure into its CATCH block.  An AFTER' + @CRLF;
            SET @S = @S + N'    -- trigger on each faked table dependency raises a runtime error,' + @CRLF;
            SET @S = @S + N'    -- so the TRY block''s DML throws and the procedure''s own CATCH' + @CRLF;
            SET @S = @S + N'    -- block executes.  The spy assertion confirms the CATCH ran.' + @CRLF;
            DECLARE @feSchema SYSNAME, @feTable SYSNAME, @feFull NVARCHAR(300);
            DECLARE fecur CURSOR LOCAL FAST_FORWARD FOR
                SELECT SchemaName, ObjectName FROM @Deps WHERE DepKind = 'TABLE';
            OPEN fecur;
            FETCH NEXT FROM fecur INTO @feSchema, @feTable;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @feFull = QUOTENAME(@feSchema) + N'.' + QUOTENAME(@feTable);
                -- v9.4.3 (refined): WITH NOCHECK ADD CONSTRAINT CHECK (1 = 0)
                -- on each faked table - a CHECK constraint violation (Msg 547)
                -- is a normal error that does NOT doom the transaction, so the
                -- procedure's CATCH can still write to its spy log table.  An
                -- earlier attempt used an AFTER trigger doing divide-by-zero;
                -- that error dooms the transaction and tSQLt's spy INSERTs are
                -- then blocked ("Uncommitable transaction detected!").
                SET @S = @S + N'    EXEC(''ALTER TABLE ' + @feFull
                            + N' WITH NOCHECK ADD CONSTRAINT '
                            + QUOTENAME(N'tSQLtAutoGen_FE_' + @feTable)
                            + N' CHECK (1 = 0)'');' + @CRLF;
                FETCH NEXT FROM fecur INTO @feSchema, @feTable;
            END;
            CLOSE fecur; DEALLOCATE fecur;
            SET @S = @S + N'    BEGIN TRY' + @CRLF;
            SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgListHappy + N';' + @CRLF;
            SET @S = @S + N'    END TRY' + @CRLF;
            SET @S = @S + N'    BEGIN CATCH' + @CRLF;
            SET @S = @S + N'        -- a re-raise from the procedure''s own CATCH is expected;' + @CRLF;
            SET @S = @S + N'        -- the spy assertion below is the real check.' + @CRLF;
            SET @S = @S + N'    END CATCH;' + @CRLF;
            SET @S = @S + @CatchSpyAssertions;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
        END;

        /* -- Test 6: OUTPUT parameter shape ----------------------------- */
        IF @HasOutput = 1
        BEGIN
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' assigns its OUTPUT parameters]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + @PreCnt;
            SET @S = @S + N'    BEGIN TRY' + @CRLF;
            SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ArgListHappy + N';' + @CRLF;
            SET @S = @S + N'    END TRY' + @CRLF;
            SET @S = @S + N'    BEGIN CATCH' + @CRLF;
            SET @S = @S + N'        DECLARE @failMsg NVARCHAR(MAX) = N''Procedure raised an error on valid inputs: '' + ERROR_MESSAGE();' + @CRLF;
            SET @S = @S + N'        EXEC tSQLt.Fail @failMsg;' + @CRLF;
            SET @S = @S + N'    END CATCH;' + @CRLF;
            SET @S = @S + @PostCnt;
            SET @S = @S + N'    -- TODO: add type-appropriate AssertEquals checks per OUTPUT parameter value.' + @CRLF;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
        END;

        /* ------------------------------------------------------------------
         * Test 7 & 8: result-set shape + (optional) baseline rows.
         *
         * We use sys.dm_exec_describe_first_result_set to determine whether
         * the proc returns a result set at all - if it does, we emit both
         * a shape-stability test and (when @CaptureRows=1) a row-equality
         * test against the captured baseline.
         *
         * The shape test calls TestGen.AssertResultShape, passing the
         * proc's EXEC string so the helper can re-describe it against the
         * saved baseline.
         *
         * The rows test captures actuals INTO a temp table whose columns
         * are taken from the shape DMV at generation time, runs the proc,
         * and calls TestGen.AssertResultRowsMatchBaseline.
         * -----------------------------------------------------------------*/
        DECLARE @ResultCols TABLE
        (
            ColumnOrdinal INT,
            ColumnName    SYSNAME    NULL,
            SqlTypeName   SYSNAME    NOT NULL,
            IsNullable    BIT        NOT NULL
        );

        DECLARE @describeSql NVARCHAR(MAX) = N'EXEC ' + @FullProc;
        IF LEN(@ArgListHappy) > 0
            SET @describeSql = @describeSql + N' ' + @ArgListHappy;

        BEGIN TRY
            INSERT @ResultCols (ColumnOrdinal, ColumnName, SqlTypeName, IsNullable)
            SELECT column_ordinal, name, system_type_name, is_nullable
            FROM sys.dm_exec_describe_first_result_set(@describeSql, NULL, 0)
            WHERE name IS NOT NULL OR system_type_name IS NOT NULL;
        END TRY
        BEGIN CATCH
            -- Some procs cannot be statically described (dynamic SQL,
            -- conditional result sets). In that case the table stays
            -- empty and we just skip the result-set tests.
        END CATCH;

        /* ------------------------------------------------------------------
         * v9.4 (Phase B): result-set characterization.
         *
         * If a CASE-assigned local variable is surfaced as a result-set
         * column (e.g. SELECT @Priority AS Priority), every branch test can
         * assert that column - its value is fully determined by the parameter
         * the CASE switches on, and each test passes a known literal for that
         * parameter, so the expected value is known at generation time.  This
         * gives a real assertion to branch tests whose body writes no table.
         * -----------------------------------------------------------------*/
        DECLARE @v94RsActive   BIT           = 0;
        DECLARE @v94RsCol      SYSNAME       = NULL;
        DECLARE @v94RsLocal    SYSNAME       = NULL;
        DECLARE @v94RsParam    SYSNAME       = NULL;
        DECLARE @v94RsColDDL   NVARCHAR(MAX) = NULL;
        DECLARE @v94RsExp      NVARCHAR(4000);
        DECLARE @v94RsScan     INT;
        DECLARE @v94RsAliasEnd INT;
        DECLARE @v94RsAlias    SYSNAME;
        DECLARE @v94RsAPos     INT;
        DECLARE @v94RsAStart   INT;
        DECLARE @v94RsAEnd     INT;
        DECLARE @v94RsAVal     NVARCHAR(MAX);

        IF EXISTS (SELECT 1 FROM @ResultCols) AND EXISTS (SELECT 1 FROM #CaseLocalAssigns)
        BEGIN
            -- find a CASE-local that is surfaced as  @local AS <resultcolumn>
            DECLARE clacur CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT LocalVar, SourceParam FROM #CaseLocalAssigns;
            OPEN clacur;
            FETCH NEXT FROM clacur INTO @v94RsLocal, @v94RsParam;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @v94RsScan = CHARINDEX(@v94RsLocal + N' AS ', @ProcSource);
                IF @v94RsScan > 0
                BEGIN
                    SET @v94RsScan = @v94RsScan + LEN(@v94RsLocal) + 4;
                    WHILE @v94RsScan <= LEN(@ProcSource)
                      AND SUBSTRING(@ProcSource,@v94RsScan,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13))
                        SET @v94RsScan = @v94RsScan + 1;
                    SET @v94RsAliasEnd = @v94RsScan;
                    WHILE @v94RsAliasEnd <= LEN(@ProcSource)
                      AND SUBSTRING(@ProcSource,@v94RsAliasEnd,1) LIKE '[A-Za-z0-9_]'
                        SET @v94RsAliasEnd = @v94RsAliasEnd + 1;
                    SET @v94RsAlias = SUBSTRING(@ProcSource,@v94RsScan,@v94RsAliasEnd-@v94RsScan);
                    IF LEN(@v94RsAlias) > 0
                       AND EXISTS (SELECT 1 FROM @ResultCols WHERE ColumnName = @v94RsAlias)
                    BEGIN
                        SET @v94RsCol = @v94RsAlias;   -- @v94RsLocal/@v94RsParam hold the match
                        BREAK;
                    END;
                END;
                FETCH NEXT FROM clacur INTO @v94RsLocal, @v94RsParam;
            END;
            CLOSE clacur; DEALLOCATE clacur;

            IF @v94RsCol IS NOT NULL
            BEGIN
                -- build the #v94rs capture-table DDL from the described shape
                SET @v94RsColDDL = N'';
                SELECT @v94RsColDDL = @v94RsColDDL
                    + N', ' + QUOTENAME(ISNULL(ColumnName, N'Col' + CAST(ColumnOrdinal AS NVARCHAR(5))))
                    + N' ' + SqlTypeName
                FROM @ResultCols ORDER BY ColumnOrdinal;
                IF LEN(ISNULL(@v94RsColDDL,N'')) > 0
                BEGIN
                    SET @v94RsColDDL = STUFF(@v94RsColDDL,1,2,N'');
                    SET @v94RsActive = 1;
                END;
            END;
        END;

        IF EXISTS (SELECT 1 FROM @ResultCols)
        BEGIN
            -- Test 7: shape stability
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' returns a stable result-set shape]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- Build the describe-input string with the same args used elsewhere.' + @CRLF;
            SET @S = @S + N'    DECLARE @cmd NVARCHAR(MAX) = N''EXEC ' + @FullProc;
            IF LEN(@ArgListHappy) > 0
                SET @S = @S + N' ' + REPLACE(@ArgListHappy, N'''', N'''''');
            SET @S = @S + N''';' + @CRLF;
            SET @S = @S + N'    EXEC TestGen.AssertResultShape @TestClass = ''' + @TC + N''', @ExecSql = @cmd;' + @CRLF;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

            -- v11.x: a golden-master ROW baseline only makes sense for a
            -- DETERMINISTIC result.  A proc whose output embeds GETDATE/NEWID/
            -- RAND drifts between the capture run and later runs, so its baseline
            -- assertion would flap.  Emit the row-baseline test only when the proc
            -- body has no such non-deterministic source (the shape test + the
            -- characterization scaffold still apply to non-deterministic procs).
            DECLARE @v94Deterministic BIT =
                CASE WHEN UPPER(@ProcSource) LIKE N'%GETDATE%'
                       OR UPPER(@ProcSource) LIKE N'%SYSDATETIME%'
                       OR UPPER(@ProcSource) LIKE N'%SYSUTCDATETIME%'
                       OR UPPER(@ProcSource) LIKE N'%GETUTCDATE%'
                       OR UPPER(@ProcSource) LIKE N'%CURRENT_TIMESTAMP%'
                       OR UPPER(@ProcSource) LIKE N'%NEWID%'
                       OR UPPER(@ProcSource) LIKE N'%NEWSEQUENTIALID%'
                       OR UPPER(@ProcSource) LIKE N'%RAND(%'
                     THEN 0 ELSE 1 END;
            IF @CaptureRows = 1 AND @v94Deterministic = 1
            BEGIN
                -- Test 8: golden rows.
                -- Build the #ActualResult column list from the captured shape.
                DECLARE @actualCols NVARCHAR(MAX) = N'';
                SELECT @actualCols = @actualCols
                    + N',' + QUOTENAME(ISNULL(ColumnName, N'Col' + CAST(ColumnOrdinal AS NVARCHAR(5))))
                    + N' ' + SqlTypeName + CASE WHEN IsNullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
                FROM @ResultCols ORDER BY ColumnOrdinal;
                SET @actualCols = STUFF(@actualCols, 1, 1, N'');

                SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                           + N'.[test ' + @ProcName + N' returns rows matching baseline]' + @CRLF;
                SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
                SET @S = @S + N'    CREATE TABLE #ActualResult (' + @actualCols + N');' + @CRLF;
                SET @S = @S + N'    INSERT #ActualResult' + @CRLF;
                SET @S = @S + N'    EXEC ' + @FullProc;
                IF LEN(@ArgListHappy) > 0
                    SET @S = @S + N' ' + @ArgListHappy;
                SET @S = @S + N';' + @CRLF;
                SET @S = @S + N'    IF NOT EXISTS (SELECT 1 FROM #ActualResult)' + @CRLF;
                SET @S = @S + N'        PRINT ''NOTE: result set is EMPTY for the generated seed/args - the baseline comparison is trivial; design a seed that returns rows.'';' + @CRLF;
                SET @S = @S + N'    EXEC TestGen.AssertResultRowsMatchBaseline @TestClass = ''' + @TC + N''';' + @CRLF;
                SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

                -- v11.x: persist the EXPECTED baseline NOW (generation time, outside
                -- any tSQLt rollback) so the row-baseline test above ASSERTS the proc's
                -- seeded output instead of capturing-and-passing (the in-test capture
                -- is undone by tSQLt's per-test rollback).
                IF @ExecuteScript = 1
                BEGIN TRY
                    EXEC TestGen.CaptureResultBaseline @TestClass = @TC, @MockSql = @MockBlock, @ExecSql = @describeSql;
                END TRY BEGIN CATCH PRINT 'CaptureResultBaseline skipped for ' + @TC + ': ' + ERROR_MESSAGE(); END CATCH;
            END;

            IF @EmitScaffold = 1
            BEGIN
            -- Test 9: characterization scaffold (set-based / CTE result verification).
            -- The shape and baseline tests above guard column types and drift but do
            -- not verify the result VALUES are correct for a known input.  This
            -- scaffold is where that is done: a designed seed in, a hand-built
            -- expected result out, compared with AssertEqualsTable.  It is emitted
            -- with the tSQLt SkipTest annotation so it reports Skipped until the
            -- developer fills the two data sets and removes the annotation.
            DECLARE @v94CharCols NVARCHAR(MAX) = N'';
            SELECT @v94CharCols = @v94CharCols
                + N',' + QUOTENAME(ISNULL(ColumnName, N'Col' + CAST(ColumnOrdinal AS NVARCHAR(5))))
                + N' ' + SqlTypeName + CASE WHEN IsNullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
            FROM @ResultCols ORDER BY ColumnOrdinal;
            SET @v94CharCols = STUFF(@v94CharCols, 1, 1, N'');

            SET @S = @S + N'--[@tSQLt:SkipTest](''MANUAL TEST REQUIRED: characterization scaffold - replace the auto-seed with a small designed dataset, fill #Expected with the hand-computed result, then remove the SkipTest annotation above to activate this test.'')' + @CRLF;
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' result set matches a hand-built expectation]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- ===================================================================' + @CRLF;
            SET @S = @S + N'    -- CHARACTERIZATION TEST SCAFFOLD  (set-based / CTE result verification)' + @CRLF;
            SET @S = @S + N'    -- The dependency tables above are faked and given a generic auto-seed.' + @CRLF;
            SET @S = @S + N'    --   1. Replace that seed with a SMALL, DESIGNED dataset that exercises' + @CRLF;
            SET @S = @S + N'    --      the query - e.g. >= 2 levels for a recursive CTE, and rows the' + @CRLF;
            SET @S = @S + N'    --      WHERE / date filter should both INCLUDE and EXCLUDE.' + @CRLF;
            SET @S = @S + N'    --   2. Fill #Expected with the result you expect for that seed.' + @CRLF;
            SET @S = @S + N'    --   3. Adjust the EXEC arguments below if the designed seed needs it.' + @CRLF;
            SET @S = @S + N'    --   4. Remove the SkipTest annotation above CREATE PROCEDURE to activate.' + @CRLF;
            SET @S = @S + N'    -- ===================================================================' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #Expected (' + @v94CharCols + N');' + @CRLF;
            SET @S = @S + N'    -- INSERT #Expected (...) VALUES (...);   <-- fill in the expected rows' + @CRLF;
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #Actual (' + @v94CharCols + N');' + @CRLF;
            SET @S = @S + N'    INSERT #Actual' + @CRLF;
            SET @S = @S + N'    EXEC ' + @FullProc;
            IF LEN(@ArgListHappy) > 0
                SET @S = @S + N' ' + @ArgListHappy;
            SET @S = @S + N';' + @CRLF;
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    EXEC tSQLt.AssertEqualsTable ''#Expected'', ''#Actual'';' + @CRLF;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
            END;
        END;

        /* ------------------------------------------------------------------
         * Test 9: negative tests via tSQLt.ExpectException
         *
         * For each RAISERROR/THROW discovered by TestGen.ExtractErrorPaths,
         * emit a test that:
         *   - sets up the same mocks/seeds the happy-path tests use,
         *   - calls tSQLt.ExpectException with the extracted message pattern,
         *   - runs the proc with NULL / negative / empty-string inputs.
         *
         * The strategy for "what inputs trigger this error" is intentionally
         * naive: we substitute the FIRST non-output parameter with NULL (if
         * it's not nullable, that often hits a validation branch), or with a
         * value of the opposite sign for integer params. Tests where the
         * input strategy doesn't actually trigger the targeted error will
         * surface as test failures - which is the desired "you need to tune
         * this input" signal.
         * -----------------------------------------------------------------*/
        IF @EmitNegativeTests = 1
        BEGIN
            -- @Errors was populated earlier (hoisted) so both this block and
            -- the boundary/NULL tests can see whether the proc has error
            -- paths.

            -- Build a "bad-inputs" arg list once, reused per error path:
            --   - non-output INT/BIGINT/SMALLINT/TINYINT param: negative
            --     (the literal -2147483648, which the value helper would
            --      produce for "low boundary" - the most likely to flunk
            --      range validation).
            --   - non-output string/date param: '' or '1900-01-01'.
            --   - first nullable param overall: NULL.
            -- Output params keep their _out names.
            DECLARE @ArgListBad NVARCHAR(MAX) = N'';
            DECLARE @badParamId INT, @badName SYSNAME, @badType SYSNAME,
                    @badMax SMALLINT, @badPrec TINYINT, @badScale TINYINT,
                    @badIsOut BIT, @badIsNull BIT;
            DECLARE @forcedOneNull BIT = 0;

            DECLARE bcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT ParamId, ParamName, SqlTypeName, MaxLength, [Precision], Scale, IsOutput, IsNullable
                FROM @Params
                ORDER BY ParamId;
            OPEN bcur;
            FETCH NEXT FROM bcur INTO @badParamId, @badName, @badType, @badMax, @badPrec, @badScale, @badIsOut, @badIsNull;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @badIsOut = 1
                    SET @ArgListBad = @ArgListBad + N', ' + @badName + N' = ' + @badName + N'_out OUTPUT';
                ELSE IF @badIsNull = 1 AND @forcedOneNull = 0
                BEGIN
                    SET @ArgListBad = @ArgListBad + N', ' + @badName + N' = NULL';
                    SET @forcedOneNull = 1;
                END
                ELSE
                    -- variant 1 = "low boundary" which is the most likely value
                    -- to trip range/sign validation.
                    SET @ArgListBad = @ArgListBad + N', ' + @badName + N' = '
                                    + TestGen.GetSampleValueLiteral(@badType, @badMax, @badPrec, @badScale, 1);
                FETCH NEXT FROM bcur INTO @badParamId, @badName, @badType, @badMax, @badPrec, @badScale, @badIsOut, @badIsNull;
            END;
            CLOSE bcur; DEALLOCATE bcur;
            SET @ArgListBad = STUFF(@ArgListBad, 1, 2, N'');

            -- Emit one negative test per discovered error path.
            DECLARE @errOrd INT, @errKw VARCHAR(10), @errPat NVARCHAR(2000), @errSev INT;
            DECLARE ecur CURSOR LOCAL FAST_FORWARD FOR
                SELECT ErrorOrdinal, Keyword, MessagePattern, SeverityLiteral FROM @Errors;
            OPEN ecur;
            FETCH NEXT FROM ecur INTO @errOrd, @errKw, @errPat, @errSev;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Test name; use a short hash of the pattern so re-running
                -- the generator produces stable names per error path.
                DECLARE @methodName SYSNAME =
                    N'test ' + @ProcName + N' raises error path '
                    + RIGHT('00' + CAST(@errOrd AS VARCHAR(3)), 3);

                SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC) + N'.[' + @methodName + N']' + @CRLF;
                SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF;
                SET @S = @S + N'    -- Detected ' + @errKw + N' in source:' + @CRLF;
                SET @S = @S + N'    -- ' + REPLACE(LEFT(ISNULL(@errPat, N'<dynamic>'), 200), CHAR(10), N' ') + @CRLF;
                SET @S = @S + @MockBlock + ISNULL(@OutputDecls, N'');

                IF @errPat IS NULL
                BEGIN
                    -- Dynamic message: accept any error.
                    SET @S = @S + N'    -- Message was built dynamically in the proc; accepting any error.' + @CRLF;
                    SET @S = @S + N'    EXEC tSQLt.ExpectException;' + @CRLF;
                END
                ELSE
                BEGIN
                    -- Escape single quotes in the pattern for embedding as a literal.
                    DECLARE @patLit NVARCHAR(2010) = REPLACE(@errPat, N'''', N'''''');
                    SET @S = @S + N'    EXEC tSQLt.ExpectException @ExpectedMessagePattern = N''' + @patLit + N'''';
                    IF @errSev IS NOT NULL
                        SET @S = @S + N', @ExpectedSeverity = ' + CAST(@errSev AS VARCHAR(5));
                    SET @S = @S + N';' + @CRLF;
                END;

                SET @S = @S + N'    EXEC ' + @FullProc;
                IF LEN(@ArgListBad) > 0
                    SET @S = @S + N' ' + @ArgListBad;
                SET @S = @S + N';' + @CRLF;
                SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

                FETCH NEXT FROM ecur INTO @errOrd, @errKw, @errPat, @errSev;
            END;
            CLOSE ecur; DEALLOCATE ecur;
        END;

        /* ------------------------------------------------------------------
         * Test 10: Branch coverage tests (v8.0)
         *
         * For each detected branch condition (IF/ELSE/CASE), generate a test
         * that uses the specific branch value to ensure that code path executes.
         * -----------------------------------------------------------------*/
        IF EXISTS (SELECT 1 FROM #BranchValues)
        BEGIN
            DECLARE @BranchParam SYSNAME, @BranchVal NVARCHAR(500);
            DECLARE @BranchArgList NVARCHAR(MAX);
            DECLARE @BranchTestName NVARCHAR(500);
            
            -- Get distinct parameter/value combinations
            DECLARE brcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT ParamName, BranchValue
                FROM #BranchValues
                ORDER BY ParamName, BranchValue;
            
            OPEN brcur;
            FETCH NEXT FROM brcur INTO @BranchParam, @BranchVal;
            
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Build argument list with branch value for this parameter
                SET @BranchArgList = N'';
                
                DECLARE @brParamId INT, @brName SYSNAME, @brType SYSNAME,
                        @brMax SMALLINT, @brPrec TINYINT, @brScale TINYINT,
                        @brIsOut BIT;
                
                DECLARE brpcur CURSOR LOCAL FAST_FORWARD FOR
                    SELECT ParamId, ParamName, SqlTypeName, MaxLength, [Precision], Scale, IsOutput
                    FROM @Params
                    WHERE IsOutput = 0
                    ORDER BY ParamId;
                
                OPEN brpcur;
                FETCH NEXT FROM brpcur INTO @brParamId, @brName, @brType, @brMax, @brPrec, @brScale, @brIsOut;
                
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF @brName = @BranchParam
                    BEGIN
                        -- Use the branch value for this parameter
                        IF @BranchVal = '_ELSE_CASE_'
                        BEGIN
                            -- CASE ELSE: use a value that won't match any WHEN clause
                            -- Use 999 for numeric, 'ELSE_DEFAULT' for strings
                            IF LOWER(@brType) IN ('int','bigint','smallint','tinyint')
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = 999';
                            ELSE IF LOWER(@brType) IN ('char','varchar','nchar','nvarchar','text','ntext')
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ''ELSE_DEFAULT''';
                            ELSE
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + TestGen.GetSampleValueLiteral(@brType, @brMax, @brPrec, @brScale, 0);
                        END
                        ELSE IF LOWER(@brType) IN ('char','varchar','nchar','nvarchar','text','ntext')
                            SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ''' + REPLACE(@BranchVal, '''', '''''') + N'''';
                        ELSE
                            SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + @BranchVal;
                    END
                    ELSE
                    BEGIN
                        -- v9.2: BEFORE falling back to "first branch value or
                        -- generic sample", check whether the OUTER branch
                        -- (e.g. @Priority=High) is a CASE-derived local that
                        -- depends on THIS parameter (@Status).  If so, set
                        -- THIS parameter to the WHEN value that yields the
                        -- wanted local-var result.
                        DECLARE @CLAWhen NVARCHAR(500) = NULL;
                        SELECT TOP 1 @CLAWhen = WhenValue
                        FROM #CaseLocalAssigns
                        WHERE LocalVar    = @BranchParam
                          AND ResultValue = @BranchVal
                          AND SourceParam = @brName;

                        IF @CLAWhen IS NOT NULL
                        BEGIN
                            IF LOWER(@brType) IN ('char','varchar','nchar','nvarchar','text','ntext')
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ''' + REPLACE(@CLAWhen, '''', '''''') + N'''';
                            ELSE IF ISNUMERIC(@CLAWhen) = 1
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + @CLAWhen;
                            ELSE
                                SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + TestGen.GetSampleValueLiteral(@brType, @brMax, @brPrec, @brScale, 0);
                            SET @CLAWhen = NULL;
                        END
                        ELSE
                        BEGIN
                            -- Use first branch value if available, otherwise generic sample
                            DECLARE @OtherBranchVal NVARCHAR(500);
                            SELECT TOP 1 @OtherBranchVal = BranchValue
                            FROM #BranchValues
                            WHERE ParamName = @brName
                            ORDER BY BranchValue;
                            
                            IF @OtherBranchVal IS NOT NULL AND @OtherBranchVal <> '_ELSE_CASE_'
                            BEGIN
                                IF LOWER(@brType) IN ('char','varchar','nchar','nvarchar','text','ntext')
                                    SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ''' + REPLACE(@OtherBranchVal, '''', '''''') + N'''';
                                ELSE IF ISNUMERIC(@OtherBranchVal) = 1
                                    SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + @OtherBranchVal;
                                ELSE
                                    SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + TestGen.GetSampleValueLiteral(@brType, @brMax, @brPrec, @brScale, 0);
                                SET @OtherBranchVal = NULL;
                            END
                            ELSE
                            BEGIN
                                -- No branch value, use generic sample
                                IF LOWER(@brType) IN ('int','bigint','smallint','tinyint')
                                    SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = 1';
                                ELSE
                                    SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + TestGen.GetSampleValueLiteral(@brType, @brMax, @brPrec, @brScale, 0);
                            END;
                        END;
                    END;
                    
                    FETCH NEXT FROM brpcur INTO @brParamId, @brName, @brType, @brMax, @brPrec, @brScale, @brIsOut;
                END;
                CLOSE brpcur;
                DEALLOCATE brpcur;
                
                SET @BranchArgList = STUFF(@BranchArgList, 1, 2, N'');
                
                -- Create test name describing the branch
                SET @BranchTestName = @BranchParam + N' = ' + @BranchVal + N' path';
                
                -- ---------------------------------------------------------------
                -- Analyze branch paths using new v2.0 schema
                -- PathID | PathType | TableName | ColumnName | CondValue | Operator
                -- ---------------------------------------------------------------
                CREATE TABLE #BranchPaths (
                    PathID       INT           NOT NULL,
                    PathType     VARCHAR(20)   NOT NULL,
                    TableName    SYSNAME       NULL,
                    ColumnName   SYSNAME       NULL,
                    CondValue    NVARCHAR(500) NULL,
                    Operator     VARCHAR(20)   NULL,
                    Depth        INT           NULL,
                    ParentPathID INT           NULL,
                    AssertTable  SYSNAME       NULL,
                    AssertType   VARCHAR(20)   NULL,
                    -- v9.4: body-DML capture for strong snapshot-and-replay
                    BodyDmlKind  VARCHAR(10)   NULL,
                    BodyDmlTable SYSNAME       NULL,
                    BodyDmlText  NVARCHAR(MAX) NULL
                );

                INSERT #BranchPaths
                EXEC TestGen.AnalyzeBranchPaths @ProcSource, @BranchParam, @BranchVal, @BranchArgList;

                -- Declare ALL variables before any loops (SQL Server requirement)
                DECLARE @GenPathID      INT;
                DECLARE @GenPathType    VARCHAR(20);
                DECLARE @GenTestSuffix  NVARCHAR(200);
                DECLARE @ThisSeedBlock  NVARCHAR(MAX);
                DECLARE @AssertFullName NVARCHAR(500);
                -- v9.2: for EXISTS_FALSE rows, @AssertFullName is the EXISTS
                -- predicate's PRIMARY table (we DELETE from this to force
                -- predicate FALSE).  But the row-growth check ('did the ELSE
                -- write happen?') needs to read from the ELSE block's
                -- target table - which lives in the analyzer's AssertTable
                -- column.  This separate var holds that read target.
                DECLARE @AssertReadFullName NVARCHAR(500);
                DECLARE @AssertReadSchema   SYSNAME;
                DECLARE @AssertReadTbl      SYSNAME;
                DECLARE @bpTable        SYSNAME;
                DECLARE @bpCol          SYSNAME;
                DECLARE @bpVal          NVARCHAR(500);
                DECLARE @bpOp           VARCHAR(20);
                DECLARE @bpType         VARCHAR(20);
                DECLARE @bpCurTbl       SYSNAME;
                DECLARE @bpCurFull      NVARCHAR(500);
                DECLARE @bpCols         NVARCHAR(MAX);
                DECLARE @bpVals         NVARCHAR(MAX);
                DECLARE @bpFull         NVARCHAR(500);
                DECLARE @bpSch          SYSNAME;
                DECLARE @bpObj          SYSNAME;
                DECLARE @GenTestCount   INT = 0;
                DECLARE @FallbackName   NVARCHAR(500);
                DECLARE @ExecArgList    NVARCHAR(MAX);
                DECLARE @CWCol          SYSNAME;
                DECLARE @CWVal          NVARCHAR(500);
                DECLARE @CWSearch       NVARCHAR(300);
                DECLARE @CWPos          INT;
                DECLARE @CWAfter        INT;
                DECLARE @CWOldVal       NVARCHAR(500);
                DECLARE @CWComma        INT;
                DECLARE @bpColMax       INT;
                DECLARE @bpValTrunc     NVARCHAR(500);
                -- v9.2: SET-clause accumulator for the UPDATE that pairs with
                -- each INSERT.  Format: "[col1] = val1, [col2] = val2"
                DECLARE @bpSetClause    NVARCHAR(MAX);
                DECLARE @bpValLit       NVARCHAR(MAX);
                DECLARE @bpIsIdent      BIT;
                DECLARE @bpIsComp       BIT;
                DECLARE @bpIsRowVer     BIT;
                DECLARE @bpIsPK         BIT;
                -- v9.4: strong-assertion (snapshot-and-replay) working vars
                DECLARE @BodyDmlKind    VARCHAR(10);
                DECLARE @BodyDmlTable   SYSNAME;
                DECLARE @BodyDmlText    NVARCHAR(MAX);
                DECLARE @v94Replayable  BIT;
                DECLARE @v94TargetFull  NVARCHAR(500);
                DECLARE @v94ReplaySql   NVARCHAR(MAX);
                DECLARE @v94DetCols     NVARCHAR(MAX);
                DECLARE @v94CpPos       INT;            -- v9.4.2+: SkipTest-annotation insert point
                DECLARE @v94SkipReason  NVARCHAR(MAX);  -- v9.4.2+: reason when a branch cannot be auto-asserted
                DECLARE @v94Sch         SYSNAME;
                DECLARE @v94RU          NVARCHAR(MAX);
                DECLARE @v94pName       SYSNAME;
                DECLARE @v94avPos       INT;
                DECLARE @v94avStart     INT;
                DECLARE @v94avEnd       INT;
                DECLARE @v94avVal       NVARCHAR(MAX);
                -- v9.4.1: non-deterministic-function handling
                DECLARE @v94WherePos    INT;
                DECLARE @v94NdInWhere   BIT;
                DECLARE @v94HasClock    BIT;
                DECLARE @v94HasNewid    BIT;
                DECLARE @v94HasRand     BIT;
                -- v9.4.2: before/after delta assertion working vars
                DECLARE @v94HasBodyDml  BIT;
                DECLARE @v94d_Cols      NVARCHAR(MAX);
                -- v9.4.2: INSERT-branch column-list restriction for the table compare
                DECLARE @v94InsNorm     NVARCHAR(MAX);
                DECLARE @v94InsOp       INT;
                DECLARE @v94InsCp       INT;

                DECLARE pathidcur CURSOR LOCAL FAST_FORWARD FOR
                    -- v9.2: only iterate the OUTERMOST EXISTS_FALSE PathID
                    -- (lowest Depth).  Inner EXISTS_FALSEs share the test
                    -- name "@Branch = Val ELSE path" with the outer one
                    -- and would overwrite it.  But the inner's "ELSE" isn't
                    -- semantically the outer-branch's ELSE - it's the
                    -- inner-predicate's ELSE, covered separately when the
                    -- inner predicate's branch param is iterated.
                    -- v9.4.2: a nested IF...ELSE is detected once per block
                    -- the analyzer scans, so the SAME branch can surface as
                    -- several IF_ELSE PathIDs - one per enclosing scope.
                    -- Only the copy whose ParentPathID is the innermost
                    -- enclosing EXISTS is seedable (seedcur2 walks
                    -- ParentPathID up the ancestor chain); a copy with a
                    -- NULL/outer ParentPathID is a phantom - the procedure
                    -- never reaches the branch and the test fails.  So per
                    -- distinct (ColumnName,CondValue) IF_ELSE branch keep
                    -- exactly one row: the one with the best parent (highest
                    -- ParentPathID, NULL treated as worst; PathID breaks ties).
                    SELECT DISTINCT bp.PathID, bp.PathType
                    FROM #BranchPaths bp
                    WHERE (bp.PathType <> 'EXISTS_FALSE'
                           OR bp.PathID IN (
                                SELECT MIN(PathID) FROM #BranchPaths
                                WHERE PathType = 'EXISTS_FALSE'
                                  AND Depth = (SELECT MIN(Depth) FROM #BranchPaths WHERE PathType = 'EXISTS_FALSE')
                           ))
                      AND (bp.PathType <> 'IF_ELSE'
                           OR NOT EXISTS (
                                SELECT 1 FROM #BranchPaths o
                                WHERE o.PathType = 'IF_ELSE'
                                  AND o.PathID <> bp.PathID
                                  AND ISNULL(o.ColumnName,N'') = ISNULL(bp.ColumnName,N'')
                                  AND ISNULL(o.CondValue ,N'') = ISNULL(bp.CondValue ,N'')
                                  AND ( ISNULL(o.ParentPathID,-1) > ISNULL(bp.ParentPathID,-1)
                                     OR (ISNULL(o.ParentPathID,-1) = ISNULL(bp.ParentPathID,-1)
                                         AND o.PathID < bp.PathID) )
                           ))
                    ORDER BY bp.PathID, bp.PathType DESC;

                OPEN pathidcur;
                FETCH NEXT FROM pathidcur INTO @GenPathID, @GenPathType;

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Reset per-path variables
                    SET @ThisSeedBlock      = N'';
                    SET @AssertFullName     = NULL;
                    SET @AssertReadFullName = NULL;
                    SET @AssertReadSchema   = NULL;
                    SET @AssertReadTbl      = NULL;
                    SET @bpCurTbl           = NULL;
                    SET @bpCurFull          = NULL;
                    SET @bpCols             = N'';
                    SET @bpVals             = N'';
                    SET @bpSetClause        = N'';

                    -- v9.4: per-path strong-assertion state.  BodyDml* is set
                    -- by the analyzer only for replayable leaf branch bodies.
                    SET @BodyDmlKind   = NULL;
                    SET @BodyDmlTable  = NULL;
                    SET @BodyDmlText   = NULL;
                    SET @v94Replayable = 0;
                    SET @v94TargetFull = NULL;
                    SET @v94ReplaySql  = NULL;
                    SET @v94DetCols    = NULL;
                    SET @v94HasBodyDml = 0;
                    SET @v94d_Cols     = NULL;
                    SET @v94InsNorm    = NULL;
                    SELECT TOP 1
                        @BodyDmlKind  = BodyDmlKind,
                        @BodyDmlTable = BodyDmlTable,
                        @BodyDmlText  = BodyDmlText
                    FROM #BranchPaths
                    WHERE PathID = @GenPathID AND BodyDmlText IS NOT NULL;

                    -- v9.2: resolve the EXISTS_FALSE row-growth read target
                    -- from #BranchPaths.AssertTable (the ELSE block's INSERT
                    -- target).  seedcur2 doesn't fetch AssertTable, so do
                    -- it in one lookup here.
                    IF @GenPathType = 'EXISTS_FALSE'
                    BEGIN
                        SELECT TOP 1 @AssertReadTbl = AssertTable
                        FROM #BranchPaths
                        WHERE PathID = @GenPathID
                          AND PathType = 'EXISTS_FALSE'
                          AND AssertTable IS NOT NULL;

                        IF @AssertReadTbl IS NOT NULL
                        BEGIN
                            -- Look up the schema for the read target via
                            -- the dependency table (same lookup pattern used
                            -- elsewhere in this proc).
                            SELECT TOP 1 @AssertReadSchema = SchemaName
                            FROM @Deps
                            WHERE ObjectName = @AssertReadTbl
                              AND DepKind IN ('TABLE','VIEW');
                            IF @AssertReadSchema IS NOT NULL
                                SET @AssertReadFullName =
                                    QUOTENAME(@AssertReadSchema) + N'.' + QUOTENAME(@AssertReadTbl);
                        END;
                    END;

                    -- v9.2.1 (Phase 3): seed not only @GenPathID's own
                    -- conditions but every ANCESTOR predicate's too, by
                    -- walking ParentPathID via a recursive CTE.  A nested
                    -- EXISTS (e.g. pred-2 inside pred-1's THEN block) is only
                    -- reachable when every enclosing EXISTS is also TRUE;
                    -- seeding the whole chain in one test - combined with the
                    -- UPDATE-all-rows seed and the FK-linked rows - satisfies
                    -- them together.  PathDistinct collapses #BranchPaths to
                    -- one row per PathID so the recursive member stays legal
                    -- (DISTINCT/TOP are not allowed in a recursive member).
                    DECLARE seedcur2 CURSOR LOCAL FAST_FORWARD FOR
                        WITH PathDistinct AS (
                            SELECT DISTINCT PathID, ParentPathID FROM #BranchPaths
                        ),
                        PathChain AS (
                            SELECT PathID, ParentPathID
                            FROM   PathDistinct
                            WHERE  PathID = @GenPathID
                            UNION ALL
                            SELECT d.PathID, d.ParentPathID
                            FROM   PathDistinct d
                            JOIN   PathChain pc ON d.PathID = pc.ParentPathID
                        )
                        SELECT PathType, TableName, ColumnName, CondValue, Operator
                        FROM #BranchPaths
                        WHERE PathID IN (SELECT PathID FROM PathChain)
                          -- v9.2.1 (IF_ELSE): an IF_ELSE test must seed its
                          -- ancestor EXISTS_TRUE conditions (to reach the
                          -- nested IF).  For every other path type the
                          -- filter is exactly PathType = @GenPathType, so
                          -- their behaviour is unchanged.
                          AND (PathType = @GenPathType
                               OR (@GenPathType = 'IF_ELSE' AND PathType = 'EXISTS_TRUE'))
                        ORDER BY TableName, ColumnName;

                    OPEN seedcur2;
                    FETCH NEXT FROM seedcur2 INTO @bpType, @bpTable, @bpCol, @bpVal, @bpOp;

                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        -- Resolve full qualified name from @Deps
                        SET @bpFull = NULL;
                        SET @bpSch  = NULL;
                        SET @bpObj  = NULL;

                        SELECT TOP 1 @bpSch = SchemaName, @bpObj = ObjectName
                        FROM @Deps
                        WHERE ObjectName = @bpTable AND DepKind IN ('TABLE','VIEW');

                        IF @bpSch IS NULL
                            SELECT TOP 1 @bpSch = SchemaName, @bpObj = ObjectName
                            FROM @Deps
                            WHERE LOWER(ObjectName) = LOWER(ISNULL(@bpTable,'')) AND DepKind IN ('TABLE','VIEW');

                        IF @bpSch IS NOT NULL
                            SET @bpFull = QUOTENAME(@bpSch) + N'.' + QUOTENAME(@bpObj);

                        IF @bpFull IS NULL
                        BEGIN
                            FETCH NEXT FROM seedcur2 INTO @bpType, @bpTable, @bpCol, @bpVal, @bpOp;
                            CONTINUE;
                        END;

                        -- Track assert table (first resolved table)
                        IF @AssertFullName IS NULL
                            SET @AssertFullName = @bpFull;

                        IF @bpType = 'EXISTS_FALSE'
                        BEGIN
                            FETCH NEXT FROM seedcur2 INTO @bpType, @bpTable, @bpCol, @bpVal, @bpOp;
                            CONTINUE;
                        END;

                        -- New table → flush previous accumulation
                        IF @bpCurTbl IS NOT NULL AND @bpTable <> @bpCurTbl
                        BEGIN
                            IF LEN(@bpCols) > 0
                            BEGIN
                                SET @ThisSeedBlock = @ThisSeedBlock + N'    INSERT ' + @bpCurFull + N' (' + @bpCols + N') VALUES (' + @bpVals + N');' + @CRLF;
                                -- v9.2: also UPDATE existing rows to satisfy
                                -- the predicate.  Critical for JOIN predicates
                                -- (Customer/SalesTerritory linked via FK seed)
                                -- and useful generally.  Wrapped in TRY/CATCH
                                -- because some columns we can't predict (e.g.
                                -- tSQLt's FakeTable behaviour around identity
                                -- varies across versions) may be unupdatable
                                -- at runtime.  Failure here is non-fatal.
                                IF LEN(@bpSetClause) > 0
                                BEGIN
                                    SET @ThisSeedBlock = @ThisSeedBlock + N'    BEGIN TRY' + @CRLF;
                                    SET @ThisSeedBlock = @ThisSeedBlock
                                        + N'        UPDATE ' + @bpCurFull
                                        + N' SET ' + @bpSetClause + N';' + @CRLF;
                                    SET @ThisSeedBlock = @ThisSeedBlock + N'    END TRY BEGIN CATCH END CATCH;' + @CRLF;
                                END;
                            END
                            ELSE
                            BEGIN
                                SET @ThisSeedBlock = @ThisSeedBlock + N'    INSERT ' + @bpCurFull + N' DEFAULT VALUES;' + @CRLF;
                            END;
                            SET @bpCols = N'';
                            SET @bpVals = N'';
                            SET @bpSetClause = N'';
                        END;

                        SET @bpCurTbl  = @bpTable;
                        SET @bpCurFull = @bpFull;

                        IF @bpCol IS NOT NULL AND @bpVal IS NOT NULL AND LEN(LTRIM(RTRIM(@bpCol))) > 0
                        BEGIN
                            -- Dedupe: if this column is already accumulated for
                            -- the current table, skip.  This handles IN-lists
                            -- (Status IN (1,2,3) produces 3 rows, all with
                            -- ColumnName='Status') which would otherwise yield
                            -- INSERT ([Status],[Status],[Status]) VALUES (...)
                            -- - SQL error 264 "column specified more than once".
                            -- The IN list is satisfied by ANY one value, so
                            -- picking the first is correct.
                            IF CHARINDEX(N'[' + @bpCol + N']', @bpCols) > 0
                            BEGIN
                                FETCH NEXT FROM seedcur2 INTO @bpType, @bpTable, @bpCol, @bpVal, @bpOp;
                                CONTINUE;
                            END;

                            -- v9.2: accumulate the literal form (for both
                            -- VALUES list and SET clause).  Compute it once
                            -- in @bpValLit, then append to both @bpVals (the
                            -- INSERT VALUES list) and @bpSetClause (the
                            -- paired UPDATE SET clause).  Identity / computed /
                            -- rowversion columns can be INSERTed (FakeTable's
                            -- shadow accepts them) but NOT UPDATEd via SET,
                            -- so we skip them in @bpSetClause.
                            -- (@bpValLit declared at proc top)

                            -- Check column properties.
                            -- (vars declared at proc top)
                            SET @bpIsIdent  = 0;
                            SET @bpIsComp   = 0;
                            SET @bpIsRowVer = 0;
                            SET @bpIsPK     = 0;
                            SELECT TOP 1
                                @bpIsIdent  = c.is_identity,
                                @bpIsComp   = c.is_computed,
                                @bpIsRowVer = CASE WHEN t.name IN ('timestamp','rowversion') THEN 1 ELSE 0 END
                            FROM @Deps d
                            JOIN sys.columns c ON c.object_id = OBJECT_ID(d.SchemaName + '.' + d.ObjectName)
                                AND c.name = @bpCol
                            JOIN sys.types t ON c.user_type_id = t.user_type_id
                            WHERE d.ObjectName = @bpTable AND d.DepKind IN ('TABLE','VIEW');

                            -- Skip UPDATE for any PK column.  UPDATEing PKs
                            -- is allowed when no identity, but tSQLt's
                            -- FakeTable can be inconsistent across versions
                            -- about whether identity is preserved.  Safest
                            -- to never UPDATE a PK column.
                            SELECT TOP 1 @bpIsPK = 1
                            FROM @Deps d
                            JOIN sys.indexes i ON i.object_id = OBJECT_ID(d.SchemaName + '.' + d.ObjectName)
                                AND i.is_primary_key = 1
                            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                            JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                AND c.name = @bpCol
                            WHERE d.ObjectName = @bpTable AND d.DepKind IN ('TABLE','VIEW');

                            IF LEN(@bpCols) > 0
                            BEGIN
                                SET @bpCols = @bpCols + N', ';
                                SET @bpVals = @bpVals + N', ';
                            END;
                            SET @bpCols = @bpCols + QUOTENAME(@bpCol);
                            IF ISNUMERIC(@bpVal) = 1
                                SET @bpValLit = @bpVal;
                            ELSE
                            BEGIN
                                -- Look up column max length to avoid truncation
                                SET @bpColMax = NULL;
                                SELECT TOP 1 @bpColMax =
                                    CASE
                                        -- v9.2.1: only CHARACTER columns have a
                                        -- char-length limit worth enforcing.
                                        -- For datetime/numeric/etc the column's
                                        -- byte length (e.g. 8 for datetime) is
                                        -- NOT a char count - truncating a
                                        -- datetime literal to 8 chars yielded
                                        -- '2026-05-' and a conversion error.
                                        -- NULL here = do not truncate.
                                        WHEN t.name NOT IN ('char','varchar','nchar','nvarchar') THEN NULL
                                        WHEN c.max_length = -1 THEN 200
                                        WHEN t.name IN ('nchar','nvarchar') THEN c.max_length / 2
                                        ELSE c.max_length
                                    END
                                FROM @Deps d
                                JOIN sys.columns c ON c.object_id = OBJECT_ID(d.SchemaName + '.' + d.ObjectName)
                                    AND c.name = @bpCol
                                JOIN sys.types t ON c.user_type_id = t.user_type_id
                                WHERE d.ObjectName = @bpTable AND d.DepKind IN ('TABLE','VIEW');

                                SET @bpValTrunc = @bpVal;
                                IF @bpColMax IS NOT NULL AND LEN(@bpVal) > @bpColMax
                                    SET @bpValTrunc = LEFT(@bpVal, @bpColMax);

                                SET @bpValLit = N'''' + REPLACE(@bpValTrunc, N'''', N'''''') + N'''';
                            END;
                            SET @bpVals = @bpVals + @bpValLit;

                            -- Append to SET clause only if updatable
                            IF @bpIsIdent = 0 AND @bpIsComp = 0 AND @bpIsRowVer = 0 AND @bpIsPK = 0
                            BEGIN
                                IF LEN(@bpSetClause) > 0
                                    SET @bpSetClause = @bpSetClause + N', ';
                                SET @bpSetClause = @bpSetClause + QUOTENAME(@bpCol) + N' = ' + @bpValLit;
                            END;
                        END;

                        FETCH NEXT FROM seedcur2 INTO @bpType, @bpTable, @bpCol, @bpVal, @bpOp;
                    END; -- seedcur2

                    -- Flush last table
                    IF @bpCurTbl IS NOT NULL AND @bpType = 'EXISTS_TRUE'
                    BEGIN
                        IF LEN(@bpCols) > 0
                        BEGIN
                            SET @ThisSeedBlock = @ThisSeedBlock + N'    INSERT ' + @bpCurFull + N' (' + @bpCols + N') VALUES (' + @bpVals + N');' + @CRLF;
                            IF LEN(@bpSetClause) > 0
                            BEGIN
                                SET @ThisSeedBlock = @ThisSeedBlock + N'    BEGIN TRY' + @CRLF;
                                SET @ThisSeedBlock = @ThisSeedBlock
                                    + N'        UPDATE ' + @bpCurFull
                                    + N' SET ' + @bpSetClause + N';' + @CRLF;
                                SET @ThisSeedBlock = @ThisSeedBlock + N'    END TRY BEGIN CATCH END CATCH;' + @CRLF;
                            END;
                        END
                        ELSE
                            SET @ThisSeedBlock = @ThisSeedBlock + N'    INSERT ' + @bpCurFull + N' DEFAULT VALUES;' + @CRLF;
                    END;

                    CLOSE seedcur2;
                    DEALLOCATE seedcur2;

                    -- Test name
                    IF @GenPathType = 'EXISTS_TRUE'
                        -- v9.2.1 (GAP E2): append @GenPathID so multiple
                        -- EXISTS predicates in one branch get DISTINCT test
                        -- names.  Without it every EXISTS_TRUE PathID emitted
                        -- a CREATE PROCEDURE with the same name and the
                        -- IF OBJECT_ID DROP/CREATE pattern kept only the last.
                        SET @GenTestSuffix = @BranchParam + N' = ' + @BranchVal
                                           + N' EXISTS path #' + CAST(@GenPathID AS NVARCHAR(10));
                    ELSE IF @GenPathType = 'EXISTS_FALSE'
                        SET @GenTestSuffix = @BranchParam + N' = ' + @BranchVal + N' ELSE path';
                    ELSE IF @GenPathType = 'CASE_WHEN'
                    BEGIN
                        -- Use the CASE column and WHEN value for the test name
                        SELECT TOP 1
                            @GenTestSuffix = ISNULL(ColumnName, @BranchParam) + N' = ' + ISNULL(CondValue, 'Unknown') + N' path'
                        FROM #BranchPaths WHERE PathID = @GenPathID AND PathType = 'CASE_WHEN';
                    END
                    ELSE IF @GenPathType = 'CASE_ELSE'
                        SET @GenTestSuffix = @BranchParam + N' = _ELSE_CASE_ path';
                    ELSE IF @GenPathType = 'IF_ELSE'
                        -- v9.2.1: the ELSE side of a plain nested IF.  Name
                        -- carries the IF's param, value and PathID so it is
                        -- unique within the branch.
                        SELECT TOP 1 @GenTestSuffix =
                               ISNULL(ColumnName, @BranchParam) + N' <> '
                             + ISNULL(CondValue, N'?') + N' path #' + CAST(@GenPathID AS NVARCHAR(10))
                        FROM #BranchPaths WHERE PathID = @GenPathID AND PathType = 'IF_ELSE';
                    ELSE
                        SET @GenTestSuffix = @BranchParam + N' = ' + @BranchVal + N' path';

                    -- Emit test procedure (drop first if exists for re-runs)
                    SET @S = @S + N'IF OBJECT_ID(''' + @TC + N'.[test ' + @ProcName + N' executes ' + @GenTestSuffix + N']'', ''P'') IS NOT NULL' + @CRLF;
                    SET @S = @S + N'    DROP PROCEDURE ' + QUOTENAME(@TC) + N'.[test ' + @ProcName + N' executes ' + @GenTestSuffix + N'];' + @CRLF;
                    SET @S = @S + N'GO' + @CRLF;
                    SET @v94CpPos      = DATALENGTH(@S)/2 + 1;  -- v9.4.2+: SkipTest annotation insert point
                    SET @v94SkipReason = NULL;
                    SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC) + N'.[test ' + @ProcName + N' executes ' + @GenTestSuffix + N']' + @CRLF;
                    SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF;
                    SET @S = @S + @MockBlock + ISNULL(@OutputDecls, N'');

                    -- Seed block  (v9.2.1: IF_ELSE seeds its ancestor EXISTS
                    -- conditions through the same EXISTS_TRUE-style emission)
                    IF @GenPathType IN ('EXISTS_TRUE','IF_ELSE') AND LEN(@ThisSeedBlock) > 0
                    BEGIN
                        SET @S = @S + @CRLF;
                        SET @S = @S + N'    -- Seed exact data so EXISTS = TRUE' + @CRLF;
                        SET @S = @S + @ThisSeedBlock;
                    END
                    ELSE IF @GenPathType = 'EXISTS_FALSE'
                    BEGIN
                        SET @S = @S + @CRLF;
                        SET @S = @S + N'    -- No seed: EXISTS = FALSE, ELSE branch executes.' + @CRLF;
                        -- v9.2: the FK-seeding block above this point may have
                        -- populated the predicate's primary table with rows
                        -- that accidentally satisfy the predicate (especially
                        -- with OR/equality conditions on common keys like
                        -- CustomerID = 1).  Clear the predicate's PRIMARY
                        -- table here so EXISTS truly evaluates to FALSE.
                        -- @AssertFullName at this point = the EXISTS source
                        -- (per analyzer v3.2 setting TableName = @PrimaryTbl
                        -- for EXISTS_FALSE rows).
                        IF @AssertFullName IS NOT NULL AND @AssertFullName <> N''
                            SET @S = @S + N'    DELETE FROM ' + @AssertFullName + N';' + @CRLF;
                    END;

                    -- Build the EXEC arglist - for CASE_WHEN substitute the WHEN value
                    SET @ExecArgList = @BranchArgList;
                    IF @GenPathType IN ('CASE_WHEN', 'CASE_ELSE', 'IF_ELSE')
                    BEGIN
                        SET @CWCol = NULL; SET @CWVal = NULL;
                        SELECT TOP 1 @CWCol = ColumnName, @CWVal = CondValue
                        FROM #BranchPaths WHERE PathID = @GenPathID;

                        IF @CWCol IS NOT NULL AND @CWVal IS NOT NULL
                        BEGIN
                            SET @CWSearch = @CWCol + N' = ';
                            SET @CWPos    = CHARINDEX(@CWSearch, @ExecArgList);
                            IF @CWPos > 0
                            BEGIN
                                SET @CWAfter  = @CWPos + LEN(@CWSearch);
                                SET @CWOldVal = SUBSTRING(@ExecArgList, @CWAfter, 200);
                                SET @CWComma  = CHARINDEX(',', @CWOldVal);
                                IF @CWComma > 0
                                    SET @CWOldVal = LTRIM(RTRIM(SUBSTRING(@CWOldVal, 1, @CWComma-1)));
                                ELSE
                                    SET @CWOldVal = LTRIM(RTRIM(@CWOldVal));
                                -- v9.2.1 (IF_ELSE): the ELSE side needs the
                                -- IF's parameter set to a value that does NOT
                                -- match the IF literal.  Substitute a sentinel,
                                -- keeping the current quoted/numeric shape so
                                -- the EXEC stays valid.
                                IF @GenPathType = 'IF_ELSE'
                                BEGIN
                                    IF LEFT(@CWOldVal, 1) = N''''
                                        SET @CWVal = N'''_ELSEPATH_''';
                                    ELSE
                                        SET @CWVal = N'-2147483647';
                                END;
                                SET @ExecArgList = REPLACE(@ExecArgList, @CWSearch + @CWOldVal, @CWSearch + @CWVal);
                            END;
                        END;
                    END;

                    -- ===========================================================
                    -- v9.4: decide whether this path's branch body can be
                    -- characterised by snapshot-and-replay, and if so emit the
                    -- snapshot + replayed DML just before the Act.  See
                    -- DESIGN_v9_4_Strong_Assertions.md sections 3, 7, 8.
                    -- ===========================================================
                    IF @BodyDmlText IS NOT NULL
                    BEGIN
                        -- resolve the body-DML target table to a full name
                        SET @v94Sch = NULL;
                        SELECT TOP 1 @v94Sch = SchemaName FROM @Deps
                        WHERE ObjectName = @BodyDmlTable AND DepKind IN ('TABLE','VIEW');
                        IF @v94Sch IS NULL
                            SELECT TOP 1 @v94Sch = SchemaName FROM @Deps
                            WHERE LOWER(ObjectName) = LOWER(ISNULL(@BodyDmlTable,'')) AND DepKind IN ('TABLE','VIEW');
                        IF @v94Sch IS NOT NULL
                            SET @v94TargetFull = QUOTENAME(@v94Sch) + N'.' + QUOTENAME(@BodyDmlTable);

                        IF @v94TargetFull IS NOT NULL
                        BEGIN
                            -- v9.4.2: a resolved body-DML target means this
                            -- path can carry the before/after delta assertion.
                            IF @BodyDmlKind IN ('INSERT','UPDATE')
                                SET @v94HasBodyDml = 1;
                            -- substitute proc parameters with the literal values
                            -- this test passes (longest names first so e.g.
                            -- @CustomerID is resolved before @Customer).
                            SET @v94ReplaySql = REPLACE(@BodyDmlText, N'{{TARGET}}', N'#v94_Expected');
                            DECLARE v94pcur CURSOR LOCAL FAST_FORWARD FOR
                                SELECT ParamName FROM @Params ORDER BY LEN(ParamName) DESC;
                            OPEN v94pcur;
                            FETCH NEXT FROM v94pcur INTO @v94pName;
                            WHILE @@FETCH_STATUS = 0
                            BEGIN
                                SET @v94avPos = CHARINDEX(@v94pName + N' =', @ExecArgList);
                                IF @v94avPos > 0
                                BEGIN
                                    SET @v94avStart = @v94avPos + LEN(@v94pName) + 2;
                                    WHILE @v94avStart <= LEN(@ExecArgList)
                                      AND SUBSTRING(@ExecArgList,@v94avStart,1) = N' '
                                        SET @v94avStart = @v94avStart + 1;
                                    SET @v94avEnd = CHARINDEX(N', @', @ExecArgList, @v94avStart);
                                    IF @v94avEnd = 0 SET @v94avEnd = LEN(@ExecArgList) + 1;
                                    SET @v94avVal = LTRIM(RTRIM(SUBSTRING(@ExecArgList,@v94avStart,@v94avEnd-@v94avStart)));
                                    SET @v94ReplaySql = REPLACE(@v94ReplaySql, @v94pName, @v94avVal);
                                END;
                                FETCH NEXT FROM v94pcur INTO @v94pName;
                            END;
                            CLOSE v94pcur; DEALLOCATE v94pcur;

                            -- A leftover @ means a procedure-local variable
                            -- the generator cannot resolve - the branch
                            -- genuinely cannot be replayed.
                            SET @v94Replayable = 1;
                            IF CHARINDEX(N'@', @v94ReplaySql) > 0
                                SET @v94Replayable = 0;

                            -- v9.4.1: a non-deterministic function (GETDATE,
                            -- NEWID, RAND, ...) does NOT block replay when it
                            -- sits in an ASSIGNMENT (an UPDATE SET clause or an
                            -- INSERT VALUES list): the columns it feeds are
                            -- simply projected OUT of the whole-table compare
                            -- below, so the comparison stays on deterministic
                            -- data.  It blocks replay ONLY when it sits in an
                            -- UPDATE's WHERE clause - there the replay and the
                            -- proc would target different rows.
                            -- (@v94RU is whitespace-flattened so a WHERE on its
                            --  own line is still found.)
                            SET @v94RU = UPPER(REPLACE(REPLACE(REPLACE(
                                         @v94ReplaySql,CHAR(13),N' '),CHAR(10),N' '),CHAR(9),N' '));
                            SET @v94HasClock = 0;
                            SET @v94HasNewid = 0;
                            SET @v94HasRand  = 0;
                            IF @v94RU LIKE N'%GETDATE%'        OR @v94RU LIKE N'%SYSDATETIME%'
                            OR @v94RU LIKE N'%SYSUTCDATETIME%' OR @v94RU LIKE N'%CURRENT_TIMESTAMP%'
                            OR @v94RU LIKE N'%SYSDATETIMEOFFSET%'
                                SET @v94HasClock = 1;
                            IF @v94RU LIKE N'%NEWID%'  SET @v94HasNewid = 1;
                            IF @v94RU LIKE N'%RAND(%'  SET @v94HasRand  = 1;

                            SET @v94WherePos = 0;
                            IF @BodyDmlKind = 'UPDATE'
                                SET @v94WherePos = CHARINDEX(N' WHERE ', @v94RU);
                            SET @v94NdInWhere = 0;
                            IF @v94WherePos > 0
                               AND (@v94HasClock = 1 OR @v94HasNewid = 1 OR @v94HasRand = 1)
                               AND (
                                    SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%GETDATE%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%SYSDATETIME%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%SYSUTCDATETIME%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%CURRENT_TIMESTAMP%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%SYSDATETIMEOFFSET%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%NEWID%'
                                 OR SUBSTRING(@v94RU,@v94WherePos,8000) LIKE N'%RAND(%'
                               )
                                SET @v94NdInWhere = 1;
                            IF @v94NdInWhere = 1
                                SET @v94Replayable = 0;

                            -- deterministic projection columns: exclude
                            -- identity / computed / rowversion (the replay
                            -- cannot reproduce those), AND - when the branch
                            -- DML assigns a clock / newid / rand value - the
                            -- column TYPE families those functions feed, so the
                            -- whole-table compare stays on deterministic data
                            -- (section 8).
                            IF @v94Replayable = 1
                            BEGIN
                                -- v9.4.2: an INSERT branch can only reproduce the
                                -- columns the INSERT explicitly names.  A column it
                                -- omits gets the table's DEFAULT in the real (faked)
                                -- table but NULL in the SELECT * INTO snapshot, so
                                -- such columns must be left out of the compare.
                                -- Capture the INSERT column list (names between the
                                -- first '(' and its ')', that '(' preceding VALUES)
                                -- as a ,delimited, lookup string.
                                SET @v94InsNorm = NULL;
                                IF @BodyDmlKind = 'INSERT'
                                BEGIN
                                    SET @v94InsOp = CHARINDEX(N'(', @BodyDmlText);
                                    SET @v94InsCp = CHARINDEX(N')', @BodyDmlText, @v94InsOp + 1);
                                    IF @v94InsOp > 0 AND @v94InsCp > @v94InsOp + 1
                                       AND @v94InsOp < CHARINDEX(N'VALUES', UPPER(@BodyDmlText))
                                    BEGIN
                                        SET @v94InsNorm = SUBSTRING(@BodyDmlText, @v94InsOp + 1, @v94InsCp - @v94InsOp - 1);
                                        SET @v94InsNorm = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                                            @v94InsNorm, N'[', N''), N']', N''), CHAR(13), N''), CHAR(10), N''), CHAR(9), N''), N' ', N'');
                                        SET @v94InsNorm = N',' + @v94InsNorm + N',';
                                    END;
                                END;
                                SET @v94DetCols = N'';
                                SELECT @v94DetCols = @v94DetCols + N', ' + QUOTENAME(c.name)
                                FROM sys.columns c
                                JOIN sys.types t ON c.user_type_id = t.user_type_id
                                WHERE c.object_id = OBJECT_ID(@v94TargetFull)
                                  AND c.is_identity = 0
                                  AND c.is_computed  = 0
                                  AND t.name NOT IN ('timestamp','rowversion')
                                  AND NOT (@v94HasClock = 1 AND t.name IN
                                       ('datetime','datetime2','smalldatetime','date','time','datetimeoffset'))
                                  AND NOT (@v94HasNewid = 1 AND t.name = 'uniqueidentifier')
                                  AND NOT (@v94HasRand  = 1 AND t.name IN ('float','real'))
                                  AND (@v94InsNorm IS NULL
                                       OR CHARINDEX(N',' + REPLACE(c.name,N' ',N'') + N',', @v94InsNorm) > 0)
                                ORDER BY c.column_id;
                                IF LEN(ISNULL(@v94DetCols,N'')) > 0
                                    SET @v94DetCols = STUFF(@v94DetCols,1,2,N'');
                                ELSE
                                    SET @v94Replayable = 0;
                            END;
                        END;
                    END;

                    -- v9.4: emit the snapshot + replayed branch DML (this forms
                    -- the expected post-state) immediately before the Act.
                    IF @v94Replayable = 1
                    BEGIN
                        SET @S = @S + @CRLF;
                        SET @S = @S + N'    -- v9.4 strong assertion: snapshot the branch-DML target,' + @CRLF;
                        SET @S = @S + N'    -- then replay the branch''s own ' + @BodyDmlKind + N' onto the snapshot.' + @CRLF;
                        SET @S = @S + N'    BEGIN TRY' + @CRLF;
                        SET @S = @S + N'        SELECT * INTO #v94_Expected FROM ' + @v94TargetFull + N';' + @CRLF;
                        SET @S = @S + N'        ' + @v94ReplaySql + N';' + @CRLF;
                        SET @S = @S + N'    END TRY' + @CRLF;
                        SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                        SET @S = @S + N'        DECLARE @v94SetupErr NVARCHAR(MAX) =' + @CRLF;
                        SET @S = @S + N'            N''v9.4 snapshot/replay setup failed: '' + ERROR_MESSAGE();' + @CRLF;
                        SET @S = @S + N'        EXEC tSQLt.Fail @v94SetupErr;' + @CRLF;
                        SET @S = @S + N'    END CATCH;' + @CRLF;
                    END;

                    -- v9.4.2: delta assertion - capture the body-DML target's
                    -- pre-EXEC state so the branch's real table effect can be
                    -- verified independently of the replay.  An UPDATE that only
                    -- writes a non-deterministic column (e.g. ModifiedDate =
                    -- GETDATE()) is projected out of the AssertEqualsTable and
                    -- would otherwise go completely unchecked.
                    IF @v94HasBodyDml = 1
                    BEGIN
                        IF @BodyDmlKind = 'UPDATE'
                        BEGIN
                            -- compare on every column except types EXCEPT cannot handle
                            SET @v94d_Cols = N'';
                            SELECT @v94d_Cols = @v94d_Cols + N', ' + QUOTENAME(c.name)
                            FROM sys.columns c
                            JOIN sys.types t ON c.user_type_id = t.user_type_id
                            WHERE c.object_id = OBJECT_ID(@v94TargetFull)
                              AND t.name NOT IN ('xml','text','ntext','image','geography','geometry')
                            ORDER BY c.column_id;
                            IF LEN(ISNULL(@v94d_Cols,N'')) > 0
                                SET @v94d_Cols = STUFF(@v94d_Cols,1,2,N'');
                            ELSE
                                SET @v94HasBodyDml = 0;   -- nothing comparable: skip the delta check
                        END;
                        IF @v94HasBodyDml = 1
                        BEGIN
                            SET @S = @S + @CRLF;
                            SET @S = @S + N'    -- v9.4.2 delta assertion: capture the branch-DML target before EXEC' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94d_CntBefore INT = (SELECT COUNT(*) FROM ' + @v94TargetFull + N');' + @CRLF;
                            IF @BodyDmlKind = 'UPDATE'
                                SET @S = @S + N'    SELECT ' + @v94d_Cols + N' INTO #v94d_PreImg FROM ' + @v94TargetFull + N';' + @CRLF;
                        END;
                    END;

                    -- Execute  (v9.4 Phase B: capture the result set via
                    -- INSERT ... EXEC when a CASE-derived result column is
                    -- being asserted)
                    SET @S = @S + @CRLF;
                    IF @v94RsActive = 1
                        SET @S = @S + N'    CREATE TABLE #v94rs (' + @v94RsColDDL + N');' + @CRLF;
                    SET @S = @S + N'    BEGIN TRY' + @CRLF;
                    IF @v94RsActive = 1
                        SET @S = @S + N'        INSERT #v94rs EXEC ' + @FullProc + N' ' + @ExecArgList + N';' + @CRLF;
                    ELSE
                        SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @ExecArgList + N';' + @CRLF;
                    SET @S = @S + N'    END TRY' + @CRLF;
                    SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                    SET @S = @S + N'        DECLARE @BranchErrMsg NVARCHAR(MAX);' + @CRLF;
                    SET @S = @S + N'        SET @BranchErrMsg = ''Branch (' + @BranchParam + N'=' + @BranchVal + N' ' + @GenPathType + N') failed: '' + ERROR_MESSAGE();' + @CRLF;
                    SET @S = @S + N'        EXEC tSQLt.Fail @BranchErrMsg;' + @CRLF;
                    SET @S = @S + N'    END CATCH;' + @CRLF;
                    SET @S = @S + @CRLF;

                    -- v9.4.2: delta assertion - the branch's table effect must
                    -- actually have happened (INSERT grew the table; UPDATE
                    -- changed rows without changing the count).  Emitted before
                    -- the v9.4 AssertEqualsTable so its clearer message shows
                    -- first; it complements AssertEqualsTable and is the real
                    -- assertion when the body is not replayable.
                    IF @v94HasBodyDml = 1
                    BEGIN
                        IF @BodyDmlKind = 'INSERT'
                        BEGIN
                            SET @S = @S + N'    -- v9.4.2: the procedure (not the test) must INSERT into ' + @v94TargetFull + @CRLF;
                            SET @S = @S + N'    DECLARE @v94d_CntAfter INT = (SELECT COUNT(*) FROM ' + @v94TargetFull + N');' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94d_Grew INT = CASE WHEN @v94d_CntAfter > @v94d_CntBefore THEN 1 ELSE 0 END;' + @CRLF;
                            SET @S = @S + N'    EXEC tSQLt.AssertEquals' + @CRLF;
                            SET @S = @S + N'         @Expected = 1,' + @CRLF;
                            SET @S = @S + N'         @Actual   = @v94d_Grew,' + @CRLF;
                            SET @S = @S + N'         @Message  = ''INSERT branch: ' + @v94TargetFull + N' must gain a row from the procedure'';' + @CRLF;
                        END
                        ELSE
                        BEGIN
                            SET @S = @S + N'    -- v9.4.2: an UPDATE branch must keep the row count stable AND modify rows' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94d_CntAfter INT = (SELECT COUNT(*) FROM ' + @v94TargetFull + N');' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94d_Changed INT;' + @CRLF;
                            SET @S = @S + N'    SET @v94d_Changed = CASE WHEN EXISTS (' + @CRLF;
                            SET @S = @S + N'        SELECT * FROM #v94d_PreImg' + @CRLF;
                            SET @S = @S + N'        EXCEPT' + @CRLF;
                            SET @S = @S + N'        SELECT ' + @v94d_Cols + N' FROM ' + @v94TargetFull + N') THEN 1 ELSE 0 END;' + @CRLF;
                            SET @S = @S + N'    EXEC tSQLt.AssertEquals' + @CRLF;
                            SET @S = @S + N'         @Expected = @v94d_CntBefore,' + @CRLF;
                            SET @S = @S + N'         @Actual   = @v94d_CntAfter,' + @CRLF;
                            SET @S = @S + N'         @Message  = ''UPDATE branch: ' + @v94TargetFull + N' row count must not change'';' + @CRLF;
                            SET @S = @S + N'    EXEC tSQLt.AssertEquals' + @CRLF;
                            SET @S = @S + N'         @Expected = 1,' + @CRLF;
                            SET @S = @S + N'         @Actual   = @v94d_Changed,' + @CRLF;
                            SET @S = @S + N'         @Message  = ''UPDATE branch: ' + @v94TargetFull + N' must actually be modified by the procedure'';' + @CRLF;
                        END;
                    END;

                    -- Assertion
                    -- v9.4: a replayable leaf branch body gets the strong
                    -- whole-table characterization assertion; everything else
                    -- keeps the prior (weaker) row-count / smoke assertion,
                    -- now labelled so the reader knows the branch effect is
                    -- NOT asserted for that test.
                    IF @v94Replayable = 1
                    BEGIN
                        SET @S = @S + N'    -- v9.4 strong assertion: whole-table characterization' + @CRLF;
                        SET @S = @S + N'    -- (the replayed branch DML must match the proc''s actual table effect)' + @CRLF;
                        IF @v94HasClock = 1 OR @v94HasNewid = 1 OR @v94HasRand = 1
                            SET @S = @S + N'    -- clock/newid/random-typed columns are projected out (branch writes a non-deterministic value there)' + @CRLF;
                        SET @S = @S + N'    SELECT ' + @v94DetCols + N' INTO #v94_ExpProj FROM #v94_Expected;' + @CRLF;
                        SET @S = @S + N'    SELECT ' + @v94DetCols + N' INTO #v94_ActProj FROM ' + @v94TargetFull + N';' + @CRLF;
                        SET @S = @S + N'    EXEC tSQLt.AssertEqualsTable ''#v94_ExpProj'', ''#v94_ActProj'';' + @CRLF;
                    END
                    ELSE IF @AssertFullName IS NOT NULL AND @v94RsActive = 0 AND @v94HasBodyDml = 0
                    BEGIN
                        IF @GenPathType IN ('EXISTS_TRUE','IF_ELSE')
                        BEGIN
                            SET @S = @S + N'    -- v9.4.2: no assertable single-DML effect for this branch (compound /' + @CRLF;
                            SET @S = @S + N'    --         nested body) - skip honestly rather than fake a passing test.' + @CRLF;
                            SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF; SET @v94SkipReason = N'MANUAL TEST REQUIRED: compound branch body - the generator has no single leaf INSERT/UPDATE to characterise here. Assert this branch by hand.';
                        END
                        ELSE
                        BEGIN
                            -- ELSE path: verify procedure executed without error.
                            -- @AssertReadFullName is the ELSE block's INSERT/UPDATE
                            -- target (where we'd expect rows to appear if the ELSE
                            -- ran).  Falls back to @AssertFullName if read target
                            -- couldn't be resolved.
                            -- (DECLARE + SET split: a DECLARE-with-initializer is
                            -- evaluated only once per batch parse, so in this loop
                            -- it would stick at iteration 1's value.)
                            DECLARE @ElseReadName NVARCHAR(500);
                            SET @ElseReadName =
                                COALESCE(NULLIF(@AssertReadFullName, N''), @AssertFullName);
                            IF @ElseReadName IS NOT NULL AND @ElseReadName <> N''
                            BEGIN
                                SET @S = @S + N'    -- v9.4.2: no assertable single-DML effect for this ELSE branch' + @CRLF;
                                SET @S = @S + N'    --         - skip honestly rather than fake a passing test.' + @CRLF;
                                SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF; SET @v94SkipReason = N'MANUAL TEST REQUIRED: ELSE branch body is compound or writes no analysable single DML. Assert this branch by hand.';
                            END
                            ELSE
                            BEGIN
                                SET @S = @S + N'    -- v9.4.2: no assertable effect for this ELSE branch - skip honestly.' + @CRLF;
                                SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF; SET @v94SkipReason = N'MANUAL TEST REQUIRED: ELSE branch has no analysable table effect. Assert this branch by hand.';
                            END;
                        END;
                    END
                    ELSE IF @v94RsActive = 0 AND @v94HasBodyDml = 0
                    BEGIN
                        SET @S = @S + N'    -- v9.4.2: no table effect and no result column for this branch' + @CRLF;
                        SET @S = @S + N'    --         - skip honestly rather than fake a passing test.' + @CRLF;
                        SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF; SET @v94SkipReason = N'MANUAL TEST REQUIRED: this branch writes no table and surfaces no result column - nothing for the generator to assert. Assert it by hand.';
                    END;

                    -- v9.4 (Phase B): result-set value assertion - assert the
                    -- CASE-derived output column.  When this fires it is the
                    -- real assertion for the test, so the weak row-count / 1=1
                    -- fallbacks above are suppressed (@v94RsActive = 0 guards).
                    IF @v94RsActive = 1
                    BEGIN
                        SET @v94RsExp = NULL;
                        SET @v94RsAPos = CHARINDEX(@v94RsParam + N' =', @ExecArgList);
                        IF @v94RsAPos > 0
                        BEGIN
                            SET @v94RsAStart = @v94RsAPos + LEN(@v94RsParam) + 2;
                            WHILE @v94RsAStart <= LEN(@ExecArgList)
                              AND SUBSTRING(@ExecArgList,@v94RsAStart,1) = N' '
                                SET @v94RsAStart = @v94RsAStart + 1;
                            SET @v94RsAEnd = CHARINDEX(N', @', @ExecArgList, @v94RsAStart);
                            IF @v94RsAEnd = 0 SET @v94RsAEnd = LEN(@ExecArgList) + 1;
                            SET @v94RsAVal = LTRIM(RTRIM(SUBSTRING(@ExecArgList,@v94RsAStart,@v94RsAEnd-@v94RsAStart)));
                            IF LEN(@v94RsAVal) >= 2 AND LEFT(@v94RsAVal,1) = N'''' AND RIGHT(@v94RsAVal,1) = N''''
                                SET @v94RsAVal = SUBSTRING(@v94RsAVal,2,LEN(@v94RsAVal)-2);
                            SELECT TOP 1 @v94RsExp = ResultValue FROM #CaseLocalAssigns
                            WHERE LocalVar = @v94RsLocal AND SourceParam = @v94RsParam
                              AND WhenValue = @v94RsAVal;
                            IF @v94RsExp IS NULL
                                SELECT TOP 1 @v94RsExp = ResultValue FROM #CaseLocalAssigns
                                WHERE LocalVar = @v94RsLocal AND SourceParam = @v94RsParam
                                  AND WhenValue = '_ELSE_CASE_';
                        END;
                        IF @v94RsExp IS NOT NULL
                        BEGIN
                            SET @S = @S + N'    -- v9.4 result-set assertion: CASE-derived output column' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94act NVARCHAR(4000) = (SELECT TOP 1 ' + QUOTENAME(@v94RsCol) + N' FROM #v94rs);' + @CRLF;
                            SET @S = @S + N'    EXEC tSQLt.AssertEqualsString @Expected = N''' + REPLACE(@v94RsExp,N'''',N'''''') + N''', @Actual = @v94act, @Message = N''result column ' + @v94RsCol + N' must reflect the CASE on ' + @v94RsParam + N''';' + @CRLF;
                        END
                        ELSE
                        BEGIN
                            SET @S = @S + N'    -- v9.4.2: result column expected value not statically determinable' + @CRLF;
                            SET @S = @S + N'    --         - skip honestly rather than fake a passing test.' + @CRLF;
                            SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF; SET @v94SkipReason = N'MANUAL TEST REQUIRED: the result column expected value could not be derived statically. Assert it by hand.';
                        END;
                    END;

                    -- v9.4.2+: a branch with no auto-assertion is reported Skipped via the tSQLt
                    -- SkipTest annotation, inserted just before its CREATE PROCEDURE.
                    IF @v94SkipReason IS NOT NULL AND @v94CpPos > 0 AND @v94CpPos <= DATALENGTH(@S)/2
                        SET @S = STUFF(@S, @v94CpPos, 0, N'--[@tSQLt:SkipTest](''' + @v94SkipReason + N''')' + @CRLF);
                    SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
                    SET @GenTestCount = @GenTestCount + 1;

                    FETCH NEXT FROM pathidcur INTO @GenPathID, @GenPathType;
                END; -- pathidcur

                CLOSE pathidcur;
                DEALLOCATE pathidcur;
                DROP TABLE #BranchPaths;

                -- If no paths detected (no IF EXISTS in branch), emit basic execution test
                IF @GenTestCount = 0
                BEGIN
                    SET @FallbackName = N'test ' + @ProcName + N' executes ' + @BranchParam + N' = ' + @BranchVal + N' path';
                    SET @S = @S + N'IF OBJECT_ID(''' + @TC + N'.[' + @FallbackName + N']'', ''P'') IS NOT NULL' + @CRLF;
                    SET @S = @S + N'    DROP PROCEDURE ' + QUOTENAME(@TC) + N'.[' + @FallbackName + N'];' + @CRLF;
                    SET @S = @S + N'GO' + @CRLF;
                    SET @v94CpPos      = DATALENGTH(@S)/2 + 1;  -- v9.4.2+: SkipTest annotation insert point
                    SET @v94SkipReason = NULL;
                    SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC) + N'.[' + @FallbackName + N']' + @CRLF;
                    SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF;
                    SET @S = @S + @MockBlock + ISNULL(@OutputDecls, N'');
                    SET @S = @S + @CRLF;
                    IF @v94RsActive = 1
                        SET @S = @S + N'    CREATE TABLE #v94rs (' + @v94RsColDDL + N');' + @CRLF;
                    ELSE
                        SET @S = @S + N'    -- coverage/smoke only - branch effect not asserted (no analyzable paths)' + @CRLF;
                    SET @S = @S + N'    BEGIN TRY' + @CRLF;
                    IF @v94RsActive = 1
                        SET @S = @S + N'        INSERT #v94rs EXEC ' + @FullProc + N' ' + @BranchArgList + N';' + @CRLF;
                    ELSE
                        SET @S = @S + N'        EXEC ' + @FullProc + N' ' + @BranchArgList + N';' + @CRLF;
                    SET @S = @S + N'    END TRY' + @CRLF;
                    SET @S = @S + N'    BEGIN CATCH' + @CRLF;
                    SET @S = @S + N'        DECLARE @FallbackErr NVARCHAR(MAX) = ''Branch (' + @BranchParam + N'=' + @BranchVal + N') failed: '' + ERROR_MESSAGE();' + @CRLF;
                    SET @S = @S + N'        EXEC tSQLt.Fail @FallbackErr;' + @CRLF;
                    SET @S = @S + N'    END CATCH;' + @CRLF;
                    -- v9.4 (Phase B): result-set value assertion for the fallback
                    -- test (e.g. a CASE branch that only assigns a local var).
                    IF @v94RsActive = 1
                    BEGIN
                        SET @v94RsExp = NULL;
                        SET @v94RsAPos = CHARINDEX(@v94RsParam + N' =', @BranchArgList);
                        IF @v94RsAPos > 0
                        BEGIN
                            SET @v94RsAStart = @v94RsAPos + LEN(@v94RsParam) + 2;
                            WHILE @v94RsAStart <= LEN(@BranchArgList)
                              AND SUBSTRING(@BranchArgList,@v94RsAStart,1) = N' '
                                SET @v94RsAStart = @v94RsAStart + 1;
                            SET @v94RsAEnd = CHARINDEX(N', @', @BranchArgList, @v94RsAStart);
                            IF @v94RsAEnd = 0 SET @v94RsAEnd = LEN(@BranchArgList) + 1;
                            SET @v94RsAVal = LTRIM(RTRIM(SUBSTRING(@BranchArgList,@v94RsAStart,@v94RsAEnd-@v94RsAStart)));
                            IF LEN(@v94RsAVal) >= 2 AND LEFT(@v94RsAVal,1) = N'''' AND RIGHT(@v94RsAVal,1) = N''''
                                SET @v94RsAVal = SUBSTRING(@v94RsAVal,2,LEN(@v94RsAVal)-2);
                            SELECT TOP 1 @v94RsExp = ResultValue FROM #CaseLocalAssigns
                            WHERE LocalVar = @v94RsLocal AND SourceParam = @v94RsParam
                              AND WhenValue = @v94RsAVal;
                            IF @v94RsExp IS NULL
                                SELECT TOP 1 @v94RsExp = ResultValue FROM #CaseLocalAssigns
                                WHERE LocalVar = @v94RsLocal AND SourceParam = @v94RsParam
                                  AND WhenValue = '_ELSE_CASE_';
                        END;
                        IF @v94RsExp IS NOT NULL
                        BEGIN
                            SET @S = @S + N'    -- v9.4 result-set assertion: CASE-derived output column' + @CRLF;
                            SET @S = @S + N'    DECLARE @v94act NVARCHAR(4000) = (SELECT TOP 1 ' + QUOTENAME(@v94RsCol) + N' FROM #v94rs);' + @CRLF;
                            SET @S = @S + N'    EXEC tSQLt.AssertEqualsString @Expected = N''' + REPLACE(@v94RsExp,N'''',N'''''') + N''', @Actual = @v94act, @Message = N''result column ' + @v94RsCol + N' must reflect the CASE on ' + @v94RsParam + N''';' + @CRLF;
                        END;
                    END;
                    -- v9.4.2: no analysable branches here - if no real result-set
                    -- assertion was emitted, skip honestly rather than fake a pass.
                    IF NOT (@v94RsActive = 1 AND @v94RsExp IS NOT NULL)
                    BEGIN
                        SET @S = @S + N'    -- (no automated assertion - test carries the [@tSQLt:SkipTest] annotation above)' + @CRLF;
                        SET @v94SkipReason = N'MANUAL TEST REQUIRED: no analysable branches were found in this part of the procedure - only a smoke run was generated. Assert its behaviour by hand.';
                    END;
                    -- v9.4.2+: a smoke-only fallback with no real assertion is reported
                    -- Skipped via the tSQLt SkipTest annotation before CREATE PROCEDURE.
                    IF @v94SkipReason IS NOT NULL AND @v94CpPos > 0 AND @v94CpPos <= DATALENGTH(@S)/2
                        SET @S = STUFF(@S, @v94CpPos, 0, N'--[@tSQLt:SkipTest](''' + @v94SkipReason + N''')' + @CRLF);
                    SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;
                END;
                
                FETCH NEXT FROM brcur INTO @BranchParam, @BranchVal;
            END;
            
            CLOSE brcur;
            DEALLOCATE brcur;
        END;

        SET @GeneratedScript = @S;

        /* ------------------------------------------------------------------
         * 7. Log + optionally execute
         * -----------------------------------------------------------------*/
        DECLARE @TestCount INT =
            (LEN(@S) - LEN(REPLACE(@S, N'CREATE PROCEDURE ' + QUOTENAME(@TC), N'')))
            / LEN(N'CREATE PROCEDURE ' + QUOTENAME(@TC));

        UPDATE TestGenLog.GenerationRun
        SET Status              = 'Generated',
            GeneratedTestCount  = @TestCount,
            GeneratedScript     = @S,
            CompletedAt         = SYSUTCDATETIME()
        WHERE RunId = @RunId;

        IF @ExecuteScript = 1
        BEGIN
            /* v9.4.4 Phase 2: SNAPSHOT preserved tests in this class BEFORE
               the destructive DropClass + NewTestClass + CREATE flow. */
            IF OBJECT_ID('TestGenLog.GeneratedTest','U') IS NOT NULL
               AND SCHEMA_ID(@TC) IS NOT NULL
            BEGIN
                ;WITH latest AS (
                    SELECT gt.TestClassName, gt.TestProcName,
                           gt.OriginalBodyHash,
                           ROW_NUMBER() OVER (PARTITION BY gt.TestClassName, gt.TestProcName
                                              ORDER BY gt.RunId DESC) AS rn
                    FROM   TestGenLog.GeneratedTest gt
                    WHERE  gt.TestClassName = @TC
                )
                INSERT INTO @Preserved (TestProcName, PreservedBody)
                SELECT p.name, m.definition
                FROM   sys.procedures p
                JOIN   sys.sql_modules m ON m.object_id = p.object_id
                JOIN   latest l ON l.TestClassName = @TC
                              AND l.TestProcName  = p.name
                              AND l.rn = 1
                WHERE  p.schema_id = SCHEMA_ID(@TC)
                  AND  l.OriginalBodyHash <> HASHBYTES('SHA2_256', m.definition);
            END;
            SET @TestsPreservedCount = (SELECT COUNT(*) FROM @Preserved);

            -- The generated script contains GO batch separators; use sp_executesql
            -- per-batch by splitting on GO.
            EXEC TestGen.ExecuteBatchedScript @Script = @S;

            /* v9.4.4 Phase 2: RESTORE preserved tests.  Drop the framework's
               same-named proc and replay the developer's saved body verbatim. */
            IF EXISTS (SELECT 1 FROM @Preserved)
            BEGIN
                DECLARE @prName SYSNAME, @prBody NVARCHAR(MAX), @prDrop NVARCHAR(MAX);
                DECLARE prcur CURSOR LOCAL FAST_FORWARD FOR
                    SELECT TestProcName, PreservedBody FROM @Preserved;
                OPEN prcur;
                FETCH NEXT FROM prcur INTO @prName, @prBody;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    IF OBJECT_ID(QUOTENAME(@TC) + N'.' + QUOTENAME(@prName), 'P') IS NOT NULL
                    BEGIN
                        SET @prDrop = N'DROP PROCEDURE ' + QUOTENAME(@TC) + N'.' + QUOTENAME(@prName) + N';';
                        EXEC sys.sp_executesql @prDrop;
                    END;
                    EXEC sys.sp_executesql @prBody;
                    PRINT '  preserved developer-modified test: [' + @TC + '].[' + @prName + ']';
                    FETCH NEXT FROM prcur INTO @prName, @prBody;
                END;
                CLOSE prcur; DEALLOCATE prcur;
            END;

            -- v9.4.2+: "separate developer class" support.  The framework never
            -- creates, drops or edits any test_<proc>_custom... class; those are
            -- owned by the developer.  A test adopted into ANY of them takes
            -- precedence, so drop the framework's same-named copy from [<class>].
            DECLARE @v94DupName SYSNAME, @v94DupSql NVARCHAR(MAX);
            DECLARE v94dup CURSOR LOCAL FAST_FORWARD FOR
                SELECT p.name
                FROM   sys.procedures p
                WHERE  p.schema_id = SCHEMA_ID(@TC)
                  AND  EXISTS (SELECT 1
                               FROM   sys.procedures c
                               JOIN   sys.schemas    cs ON cs.schema_id = c.schema_id
                               WHERE  cs.name LIKE REPLACE(@TC,'_','[_]') + N'[_]custom%'
                                 AND  c.name = p.name);
            OPEN v94dup;
            FETCH NEXT FROM v94dup INTO @v94DupName;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @v94DupSql = N'DROP PROCEDURE ' + QUOTENAME(@TC) + N'.' + QUOTENAME(@v94DupName) + N';';
                EXEC sys.sp_executesql @v94DupSql;
                PRINT '  adopted into a developer class - removed framework copy ' + @TC + '.' + @v94DupName;
                FETCH NEXT FROM v94dup INTO @v94DupName;
            END;
            CLOSE v94dup; DEALLOCATE v94dup;

            /* v9.4.4: capture each emitted test proc's body + hash for the
               preservation mechanism.  We read back from
               sys.sql_modules.definition so the stored body matches what
               the catalog will return at regen-time hash compare - no
               normalization-quirk false positives.  Captured AFTER the
               developer-class dup-removal so we only log the framework's
               canonical copies of tests. */
            IF OBJECT_ID('TestGenLog.GeneratedTest','U') IS NOT NULL
            BEGIN
                INSERT TestGenLog.GeneratedTest
                    (RunId, SchemaName, ProcName, TestClassName, TestProcName, OriginalBody)
                SELECT @RunId, @SchemaName, @ProcName, @TC, p.name, m.definition
                FROM   sys.procedures p
                JOIN   sys.sql_modules m ON m.object_id = p.object_id
                WHERE  p.schema_id = SCHEMA_ID(@TC)
                  AND  p.is_ms_shipped = 0;

                /* v9.4.4 Phase 2: PRUNE log rows just inserted for preserved
                   tests so the OLD log row remains the latest - future hash
                   comparisons still detect the developer's divergence. */
                IF EXISTS (SELECT 1 FROM @Preserved)
                BEGIN
                    DELETE gt
                    FROM   TestGenLog.GeneratedTest gt
                    JOIN   @Preserved pr ON pr.TestProcName = gt.TestProcName
                    WHERE  gt.RunId = @RunId AND gt.TestClassName = @TC;
                END;
            END;

            UPDATE TestGenLog.GenerationRun
            SET Status = 'Installed', CompletedAt = SYSUTCDATETIME()
            WHERE RunId = @RunId;
        END;

        PRINT 'Generated ' + CAST(@TestCount AS VARCHAR(10)) + ' test(s) for ' + @FullProc + ' as class [' + @TC + '].';
    END TRY
    BEGIN CATCH
        UPDATE TestGenLog.GenerationRun
        SET Status       = 'Failed',
            CompletedAt  = SYSUTCDATETIME(),
            ErrorMessage = ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH;
END;
GO

PRINT 'TestGen.GenerateTestsForProcedure created (v9.4.2 - before/after delta assertions).';
GO

/*============================================================================
  TestGen.EnsureCustomTestClass
  ----------------------------------------------------------------------------
  One-call wrapper that creates the developer-owned companion test class for a
  procedure - test_<proc>_custom - so callers need not know the tSQLt naming
  convention, nor that tSQLt.NewTestClass DROPS an existing class.

  SAFE + idempotent: if the custom class already exists it is left completely
  intact (your tests are NOT touched).  The framework never drops or edits this
  class; RunCoverage runs it alongside test_<proc>.

  EXEC TestGen.EnsureCustomTestClass @SchemaName='dbo', @ProcName='YourProc';
============================================================================*/

/*===========================================================================
  TestGen.AssessTestability                                     (v9.4.3 - NEW)
  ---------------------------------------------------------------------------
  Decides, BEFORE any test generation, whether a stored procedure can be
  meaningfully auto-tested by the framework.

  A procedure is classified NOT_TESTABLE when BOTH of these hold:
    (1) it has zero fakeable user table/view dependencies
        (TestGen.GetProcedureDependencies returns no TABLE/VIEW rows), and
    (2) it references the system catalog - the 'sys' schema or
        INFORMATION_SCHEMA - objects that tSQLt.FakeTable cannot fake.
  Such a procedure cannot be isolated: there is nothing to fake and nothing
  to seed, so generated tests would only run against live server state.

  Every other procedure is TESTABLE and generation proceeds unchanged.  The
  rule is deliberately conservative - one fakeable dependency is enough to
  keep a procedure on the normal path.

  Parameters:
    @SchemaName  schema of the target procedure
    @ProcName    name of the target procedure
    @Verdict     OUTPUT - 'TESTABLE' or 'NOT_TESTABLE'
    @Reason      OUTPUT - human-readable reason (NULL when TESTABLE)

  Ad-hoc use:
    DECLARE @v VARCHAR(20), @r NVARCHAR(400);
    EXEC TestGen.AssessTestability 'dbo','MyProc', @v OUTPUT, @r OUTPUT;
    SELECT @v AS Verdict, @r AS Reason;
===========================================================================*/
IF OBJECT_ID('TestGen.AssessTestability', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.AssessTestability;
GO

CREATE PROCEDURE TestGen.AssessTestability
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @Verdict    VARCHAR(20)   = NULL OUTPUT,
    @Reason     NVARCHAR(400) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Verdict = 'TESTABLE';
    SET @Reason  = NULL;

    DECLARE @QFull NVARCHAR(520) =
        QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ProcName);
    DECLARE @ObjId INT = OBJECT_ID(@QFull);

    IF @ObjId IS NULL
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'Procedure ' + @SchemaName + N'.' + @ProcName
                     + N' was not found.';
        RETURN;
    END;

    /* v9.4.3 (parser limitation): the coverage instrumenter locates the
       executable body by finding the AS / BEGIN boundary line.  If no such
       line exists, TestGen.InstrumentProcedure cannot instrument the
       procedure and would otherwise emit an empty-bodied copy - silently
       dropping the procedure's code and producing phantom coverage results.
       Detect it here and classify NOT_TESTABLE with an explicit reason so it
       is reported, not silently mis-measured.  These patterns MUST be kept in
       sync with the body-start detector in TestGen.InstrumentProcedure. */
    IF NOT EXISTS
    (
        SELECT 1
        FROM STRING_SPLIT(
                 REPLACE(ISNULL(OBJECT_DEFINITION(@ObjId), N''), CHAR(13), N''),
                 CHAR(10))
        WHERE UPPER(LTRIM(RTRIM(value))) = N'AS'
           OR UPPER(LTRIM(RTRIM(value))) LIKE N'% AS'
           OR UPPER(LTRIM(RTRIM(value))) = N'AS BEGIN'
           OR UPPER(LTRIM(RTRIM(value))) LIKE N'AS BEGIN[ ;]%'
           OR UPPER(LTRIM(RTRIM(value))) = N'BEGIN'
    )
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'FRAMEWORK PARSER LIMITATION (not a defect in this '
                     + N'procedure): the coverage instrumenter could not locate '
                     + N'the AS / BEGIN boundary that marks where the body of '
                     + @SchemaName + N'.' + @ProcName + N' begins, so the '
                     + N'procedure cannot be instrumented.  Please report this '
                     + N'procedure''s header style to the tSQLtAutoGen '
                     + N'maintainers as a bug.';
        RETURN;
    END;

    /* (1) Count fakeable user table/view dependencies. */
    DECLARE @Deps TABLE
    (
        DepKind     VARCHAR(20),
        SchemaName  SYSNAME,
        ObjectName  SYSNAME,
        IsAmbiguous BIT
    );

    BEGIN TRY
        INSERT @Deps
        EXEC TestGen.GetProcedureDependencies @SchemaName, @ProcName;
    END TRY
    BEGIN CATCH
        /* leave @Deps empty - treated as zero fakeable dependencies */
    END CATCH;

    /* v9.4.3 (temporal): a procedure that uses a FOR SYSTEM_TIME time-travel
       query can never run against a faked or de-versioned table - that clause
       is valid only on a LIVE system-versioned table.  This is permanent: the
       procedure stays NOT_TESTABLE even after SYSTEM_VERSIONING is turned off. */
    IF UPPER(ISNULL(OBJECT_DEFINITION(@ObjId), N'')) LIKE N'%FOR SYSTEM[_]TIME%'
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure uses FOR SYSTEM_TIME time-travel '
                     + N'queries, which require a live system-versioned '
                     + N'temporal table - tSQLt.FakeTable cannot provide one, '
                     + N'so the procedure cannot be isolated for testing.';
        RETURN;
    END;

    /* v9.4.3 (full-text): a procedure that uses CONTAINSTABLE / FREETEXTTABLE
       / CONTAINS / FREETEXT depends on a full-text index.  tSQLt.FakeTable
       strips full-text indexes from its faked copy, so the predicate cannot
       run - the procedure cannot be isolated for testing. */
    DECLARE @FtDef NVARCHAR(MAX) = UPPER(ISNULL(OBJECT_DEFINITION(@ObjId), N''));
    IF @FtDef LIKE N'%CONTAINSTABLE%'
       OR @FtDef LIKE N'%FREETEXTTABLE%'
       OR @FtDef LIKE N'%CONTAINS(%'
       OR @FtDef LIKE N'%FREETEXT(%'
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure uses full-text search (CONTAINSTABLE, '
                     + N'FREETEXTTABLE, CONTAINS or FREETEXT).  tSQLt.FakeTable '
                     + N'strips full-text indexes from the faked table, so the '
                     + N'full-text predicate cannot run and the procedure '
                     + N'cannot be isolated for testing.';
        RETURN;
    END;

    /* v9.4.3 (CATCH-context helper): a procedure whose body is gated on
       ERROR_NUMBER() IS NULL is a CATCH-context helper - it does nothing
       useful unless called from inside another procedure's CATCH block,
       where ERROR_NUMBER() is non-NULL.  The framework cannot manufacture
       an outer error context, so the procedure's body is unreachable on a
       direct call and coverage is always 0.  Example: dbo.uspLogError. */
    IF UPPER(ISNULL(OBJECT_DEFINITION(@ObjId), N'')) LIKE N'%ERROR_NUMBER() IS NULL%'
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure is gated on ERROR_NUMBER() IS NULL - '
                     + N'it is a CATCH-context helper that returns '
                     + N'immediately unless called from inside another '
                     + N'procedure''s CATCH block.  The framework cannot '
                     + N'manufacture an outer error context, so the body is '
                     + N'unreachable on a direct call.  Hand-write a custom '
                     + N'test, or test it indirectly via the call site.';
        RETURN;
    END;

    /* v9.4.3 (temporal): if a dependency is still system-versioned,
       tSQLt.FakeTable cannot rename or seed it.  The operator must turn
       SYSTEM_VERSIONING OFF on the temporal tables first - see the README
       prerequisite.  Once they do, sys.tables.temporal_type becomes 0, this
       check stops firing, and the procedure flows into normal generation. */
    IF EXISTS
    (
        SELECT 1
        FROM @Deps d
        JOIN sys.tables t
          ON t.object_id =
             OBJECT_ID(QUOTENAME(d.SchemaName) + N'.' + QUOTENAME(d.ObjectName))
        WHERE d.DepKind IN ('TABLE','VIEW')
          AND t.temporal_type <> 0
    )
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure depends on a system-versioned temporal '
                     + N'table or history table.  Turn SYSTEM_VERSIONING OFF '
                     + N'on the temporal tables - see the README prerequisite '
                     + N'- then regenerate; tSQLt.FakeTable cannot fake a '
                     + N'system-versioned table.';
        RETURN;
    END;

    /* v9.4.3 (in-memory): tSQLt.FakeTable cannot fake a memory-optimized
       (In-Memory OLTP) table - the fake attempt dooms tSQLt's test
       transaction (error 3931).  Unlike SYSTEM_VERSIONING, memory-optimization
       is intrinsic to the table and cannot be turned off, so this is
       permanent. */
    IF EXISTS
    (
        SELECT 1
        FROM @Deps d
        JOIN sys.tables t
          ON t.object_id =
             OBJECT_ID(QUOTENAME(d.SchemaName) + N'.' + QUOTENAME(d.ObjectName))
        WHERE d.DepKind IN ('TABLE','VIEW')
          AND t.is_memory_optimized = 1
    )
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure depends on a memory-optimized '
                     + N'(In-Memory OLTP) table.  tSQLt.FakeTable cannot fake '
                     + N'a memory-optimized table - the fake attempt dooms the '
                     + N'test transaction - and memory-optimization cannot be '
                     + N'turned off the way SYSTEM_VERSIONING can.';
        RETURN;
    END;

    /* v9.4.3 (missing object): the procedure names a schema-qualified object
       that does not exist in this database - sys.sql_expression_dependencies
       recorded the reference unresolved (referenced_id IS NULL) and OBJECT_ID
       still cannot bind it.  Deferred name resolution lets such a procedure be
       created, but the generator can neither fake nor spy an object that is
       not there.  Cross-database / cross-server / temp-table / caller-
       dependent and unqualified references are deliberately excluded so this
       never mis-fires. */
    DECLARE @MissingObj NVARCHAR(260) = NULL;
    BEGIN TRY
        SELECT TOP 1 @MissingObj =
               sed.referenced_schema_name + N'.' + sed.referenced_entity_name
        FROM sys.sql_expression_dependencies sed
        WHERE sed.referencing_id           = @ObjId
          AND sed.referenced_class         = 1
          AND sed.referenced_minor_id      = 0
          AND sed.referenced_server_name   IS NULL
          AND sed.referenced_database_name IS NULL
          AND sed.referenced_schema_name   IS NOT NULL
          AND sed.referenced_entity_name   IS NOT NULL
          AND sed.referenced_entity_name NOT LIKE N'#%'
          AND sed.is_caller_dependent      = 0
          AND sed.referenced_id            IS NULL
          AND OBJECT_ID(QUOTENAME(sed.referenced_schema_name)
                        + N'.' + QUOTENAME(sed.referenced_entity_name)) IS NULL;
    END TRY
    BEGIN CATCH
        SET @MissingObj = NULL;   /* DMV unreadable - skip this check */
    END CATCH;

    IF @MissingObj IS NOT NULL
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'The procedure references ' + @MissingObj
                     + N', which does not exist as a persistent object in '
                     + N'this database - tSQLt cannot fake or spy a missing '
                     + N'object.  If the procedure creates it at run time via '
                     + N'a setup procedure, that setup procedure is itself '
                     + N'spied out during the test.  Create the object '
                     + N'permanently, or hand-write a custom test.';
        RETURN;
    END;

    DECLARE @FakeableDeps INT =
        (SELECT COUNT(*) FROM @Deps WHERE DepKind IN ('TABLE','VIEW'));

    /* One fakeable dependency is enough to isolate the procedure - it stays
       on the normal generation path. */
    IF @FakeableDeps > 0
        RETURN;

    /* (2) Does the procedure reference the system catalog?  sys.* catalog
       views/tables cannot be faked by tSQLt.FakeTable. */
    DECLARE @RefsSystem BIT = 0;

    /* 2a - resolved references (comment / string immune). */
    BEGIN TRY
        IF EXISTS
        (
            SELECT 1
            FROM sys.dm_sql_referenced_entities(@QFull, N'OBJECT')
            WHERE referenced_schema_name IN (N'sys', N'INFORMATION_SCHEMA')
        )
            SET @RefsSystem = 1;
    END TRY
    BEGIN CATCH
        /* the DMV could not resolve every reference - the scan below covers it */
    END CATCH;

    /* 2b - source-text scan (fallback / corroboration). */
    IF @RefsSystem = 0
    BEGIN
        DECLARE @U NVARCHAR(MAX) =
            N' ' + UPPER(ISNULL(OBJECT_DEFINITION(@ObjId), N''));
        IF @U LIKE N'%[^A-Z0-9_@#$]SYS.%'
           OR @U LIKE N'%[^A-Z0-9_@#$][[]SYS].%'
           OR @U LIKE N'%[^A-Z0-9_@#$]INFORMATION[_]SCHEMA.%'
            SET @RefsSystem = 1;
    END;

    IF @FakeableDeps = 0 AND @RefsSystem = 1
    BEGIN
        SET @Verdict = 'NOT_TESTABLE';
        SET @Reason  = N'No fakeable table or view dependencies, and the '
                     + N'procedure reads system catalog objects in the sys '
                     + N'schema that tSQLt.FakeTable cannot fake - no test '
                     + N'isolation is possible.';
    END;
END;
GO
PRINT 'TestGen.AssessTestability created.';
GO

IF OBJECT_ID('TestGen.EnsureCustomTestClass','P') IS NOT NULL
    DROP PROCEDURE TestGen.EnsureCustomTestClass;
GO
CREATE PROCEDURE TestGen.EnsureCustomTestClass
    @SchemaName      SYSNAME,                   -- accepted for symmetry with GenerateTestsForProcedure
    @ProcName        SYSNAME,
    @TestClassName   SYSNAME = NULL,             -- defaults to 'test_' + @ProcName
    @Variant         SYSNAME = NULL,             -- optional suffix for a 2nd, 3rd... custom class
    @CustomClassName SYSNAME = NULL OUTPUT       -- returns the custom class name
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tSQLt.NewTestClass','P') IS NULL
    BEGIN
        RAISERROR('tSQLt is not installed in this database - cannot create a test class.',16,1);
        RETURN;
    END;

    IF @TestClassName IS NULL
        SET @TestClassName = N'test_' + @ProcName;

    -- base custom class is test_<proc>_custom; @Variant appends a suffix so a
    -- procedure can have several developer-owned classes - all are recognised
    -- by RunCoverage and the regeneration dedup (they match test_<proc>_custom%).
    SET @CustomClassName = @TestClassName + N'_custom'
                         + CASE WHEN @Variant IS NULL OR @Variant = N'' THEN N''
                                ELSE N'_' + @Variant END;

    -- soft sanity check: warn (do not fail) if the named procedure is not found
    IF OBJECT_ID(QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ProcName), 'P') IS NULL
        PRINT 'Note: ' + @SchemaName + '.' + @ProcName
            + ' is not a procedure in this database - check the name.';

    IF SCHEMA_ID(@CustomClassName) IS NULL
    BEGIN
        EXEC tSQLt.NewTestClass @CustomClassName;
        PRINT 'Created developer-owned test class [' + @CustomClassName + '].';
        PRINT '  - The framework never drops or edits this class.';
        PRINT '  - Put tests you want to keep here: CREATE PROCEDURE in this schema,';
        PRINT '    with a test-procedure name starting with ''test''.';
        PRINT '  - RunCoverage runs it alongside [' + @TestClassName + '].';
    END
    ELSE
    BEGIN
        PRINT 'Test class [' + @CustomClassName + '] already exists - left intact.';
        PRINT '  Nothing was changed; your tests in it are safe.';
    END;
END;
GO
PRINT 'TestGen.EnsureCustomTestClass created.';
GO

/*============================================================================
  TestGen.GenerateAndRunCoverage
  ----------------------------------------------------------------------------
  One call that does the whole loop: generate + install the test class for a
  procedure, then instrument it and report coverage.  The signature mirrors
  GenerateTestsForProcedure (same generation switches), plus @OutputMode for
  the coverage report.

  It always executes the generated script (there is nothing to measure
  otherwise) and uses the default test class name test_<proc>; for a
  non-default @TestClassName, call GenerateTestsForProcedure and RunCoverage
  separately.  If generation fails the error propagates and coverage is not
  attempted.

  EXEC TestGen.GenerateAndRunCoverage @SchemaName='dbo', @ProcName='YourProc';
============================================================================*/
IF OBJECT_ID('TestGen.GenerateAndRunCoverage','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateAndRunCoverage;
GO
CREATE PROCEDURE TestGen.GenerateAndRunCoverage
    @SchemaName                    SYSNAME,
    @ProcName                      SYSNAME,
    @CaptureRows                   BIT           = 1,
    @EmitNegativeTests             BIT           = 1,
    @AssertExceptionOnInvalidInputs BIT          = 1,
    @EmitNullChecks                BIT           = 1,
    @EmitScaffold                  BIT           = 1,
    @OutputMode                    VARCHAR(10)   = 'TEXT',   -- coverage report mode
    @RunId                         INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    PRINT '=== TestGen.GenerateAndRunCoverage: ' + @SchemaName + '.' + @ProcName + ' ===';

    PRINT '--- Step 1 of 2: generate + install the test class ---';
    EXEC TestGen.GenerateTestsForProcedure
         @SchemaName                     = @SchemaName,
         @ProcName                       = @ProcName,
         @ExecuteScript                  = 1,
         @CaptureRows                    = @CaptureRows,
         @EmitNegativeTests              = @EmitNegativeTests,
         @AssertExceptionOnInvalidInputs = @AssertExceptionOnInvalidInputs,
         @EmitNullChecks                 = @EmitNullChecks,
         @EmitScaffold                   = @EmitScaffold,
         @RunId                          = @RunId OUTPUT;

    PRINT '';
    PRINT '--- Step 2 of 2: instrument + run coverage ---';
    EXEC TestGen.RunCoverage
         @SchemaName = @SchemaName,
         @ProcName   = @ProcName,
         @OutputMode = @OutputMode;
END;
GO
PRINT 'TestGen.GenerateAndRunCoverage created.';
GO

/*============================================================================
  TestGen.CoverageResult  +  TestGen.GenerateAndCoverDatabase            v9.4.2
  ----------------------------------------------------------------------------
  Database-wide CI/CD coverage report.  For every user procedure it generates
  the tests, runs them, measures coverage, and records one row per procedure
  in TestGen.CoverageResult (kept across runs, keyed by BatchId, for trending).
  It then emits ONE report - HTML table or TEXT - with a per-procedure row, a
  TOTAL row, and aggregate test outcomes (passed / failed / errored / skipped)
  with percentages.

    EXEC TestGen.GenerateAndCoverDatabase;                       -- HTML, all schemas
    EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'TEXT';
    EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = 'dbo';

  Notes: each procedure's tests run ONCE - RunCoverage instruments the proc,
  runs the tests, measures coverage, and returns the pass/fail/skip/error
  counts via OUTPUT parameters.  It is driven with @OutputMode='NONE' so no
  per-procedure report is printed.  RunCoverage needs server-level XEvent
  permission.
============================================================================*/
IF OBJECT_ID('TestGen.CoverageResult','U') IS NULL
    CREATE TABLE TestGen.CoverageResult (
        ResultId        INT IDENTITY(1,1) CONSTRAINT PK_TestGen_CoverageResult PRIMARY KEY,
        BatchId         DATETIME2(3)   NOT NULL,
        SchemaName      SYSNAME        NOT NULL,
        ProcName        SYSNAME        NOT NULL,
        GenSucceeded    BIT            NOT NULL,
        TotalLines      INT            NOT NULL,
        CoveredLines    INT            NOT NULL,
        LinePct         DECIMAL(5,1)   NOT NULL,
        TotalBranches   INT            NOT NULL,
        CoveredBranches INT            NOT NULL,
        BranchPct       DECIMAL(5,1)   NOT NULL,
        TestsRun        INT            NOT NULL,
        TestsPassed     INT            NOT NULL,
        TestsFailed     INT            NOT NULL,
        TestsErrored    INT            NOT NULL,
        TestsSkipped    INT            NOT NULL,
        ErrorText       NVARCHAR(2000) NULL,
        RunAt           DATETIME2(3)   NOT NULL
    );
GO

/* v9.4.3: TestGen.CoverageResult gains a Testability classification, and its
   six coverage columns become NULLable, so a NOT_TESTABLE procedure records
   NULL coverage (never 0%).  Applied to a freshly created table and to one
   left by a pre-v9.4.3 install alike; idempotent. */
IF OBJECT_ID('TestGen.CoverageResult','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('TestGen.CoverageResult','Testability') IS NULL
        ALTER TABLE TestGen.CoverageResult
            ADD Testability VARCHAR(20) NOT NULL
                CONSTRAINT DF_CoverageResult_Testability DEFAULT 'TESTED';
    IF COL_LENGTH('TestGen.CoverageResult','NotTestableReason') IS NULL
        ALTER TABLE TestGen.CoverageResult
            ADD NotTestableReason NVARCHAR(400) NULL;
    /* v9.4.4: TestsPreserved - count of tests preserved (developer-modified)
       across this regen.  Default 0 so existing rows have a meaningful value
       and the autonomy metric can sum across the batch. */
    IF COL_LENGTH('TestGen.CoverageResult','TestsPreserved') IS NULL
        ALTER TABLE TestGen.CoverageResult
            ADD TestsPreserved INT NOT NULL
                CONSTRAINT DF_CoverageResult_TestsPreserved DEFAULT 0;
    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('TestGen.CoverageResult')
                 AND name = 'TotalLines' AND is_nullable = 0)
    BEGIN
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN TotalLines      INT          NULL;
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN CoveredLines    INT          NULL;
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN LinePct         DECIMAL(5,1) NULL;
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN TotalBranches   INT          NULL;
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN CoveredBranches INT          NULL;
        ALTER TABLE TestGen.CoverageResult ALTER COLUMN BranchPct       DECIMAL(5,1) NULL;
    END;
END;
GO

IF OBJECT_ID('TestGen.GenerateAndCoverDatabase','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateAndCoverDatabase;
GO
CREATE PROCEDURE TestGen.GenerateAndCoverDatabase
    @SchemaFilter   SYSNAME       = NULL,   -- NULL = every user schema
    @ExcludePattern NVARCHAR(200) = NULL,   -- LIKE pattern of proc names to skip
    @OutputMode     VARCHAR(10)   = 'HTML'  -- HTML, TEXT, or COBERTURA
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('TestGen.GenerateTestsForProcedure','P') IS NULL
       OR OBJECT_ID('TestGen.RunCoverage','P') IS NULL
    BEGIN
        RAISERROR('The tSQLt Auto-Gen framework is not fully installed in this database.',16,1);
        RETURN;
    END;

    DECLARE @BatchId DATETIME2(3) = SYSUTCDATETIME();

    -- loop variables (declared once; SET per iteration - never DECLARE = expr in a loop)
    DECLARE @Seq INT, @s SYSNAME, @p SYSNAME, @cls SYSNAME;
    DECLARE @genOK BIT, @err NVARCHAR(2000), @Total INT;
    DECLARE @run INT,@pass INT,@fail INT,@errc INT,@skip INT;
    DECLARE @tot INT,@cov INT,@tb INT,@cb INT;
    DECLARE @lp DECIMAL(5,1), @bp DECIMAL(5,1);
    DECLARE @testability VARCHAR(20), @reason NVARCHAR(400);   -- v9.4.3 testability gate
    DECLARE @pres INT;                                          -- v9.4.4 preservation count from GenerateTestsForProcedure

    DECLARE @work TABLE (Seq INT IDENTITY(1,1), s SYSNAME, p SYSNAME);
    INSERT @work (s,p)
    SELECT SCHEMA_NAME(o.schema_id), o.name
    FROM   sys.procedures o
    WHERE  SCHEMA_NAME(o.schema_id) NOT IN ('tSQLt','TestGen','TestGenLog')
      AND  SCHEMA_NAME(o.schema_id) NOT LIKE 'test[_]%'      -- exclude generated test classes
      AND  (@SchemaFilter   IS NULL OR SCHEMA_NAME(o.schema_id) = @SchemaFilter)
      AND  (@ExcludePattern IS NULL OR o.name NOT LIKE @ExcludePattern)
      AND  o.name NOT LIKE '%[_]cov'   -- v9.4.3: skip the framework's own _cov instrumentation copies
      AND  o.name NOT LIKE '%[_]orig'  -- v9.4.3: and stranded _orig originals
    ORDER  BY 1,2;

    SET @Total = (SELECT COUNT(*) FROM @work);
    PRINT 'GenerateAndCoverDatabase: ' + CAST(@Total AS VARCHAR) + ' procedure(s) to process.';
    PRINT '';
    PRINT 'NOTE: turn SYSTEM_VERSIONING OFF on any system-versioned temporal';
    PRINT '      tables before this run, and back ON afterwards - see the';
    PRINT '      README_v9_4 temporal prerequisite.  A procedure still';
    PRINT '      system-versioned, or using FOR SYSTEM_TIME, is reported';
    PRINT '      NOT TESTABLE.';

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Seq,s,p FROM @work ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @Seq,@s,@p;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @genOK=0; SET @err=NULL; SET @cls=N'test_'+@p;
        SET @run=0; SET @pass=0; SET @fail=0; SET @errc=0; SET @skip=0;
        SET @tot=0; SET @cov=0; SET @tb=0; SET @cb=0;
        SET @pres=0;   -- v9.4.4: preservation count reset per iteration

        PRINT '  [' + CAST(@Seq AS VARCHAR) + '/' + CAST(@Total AS VARCHAR) + '] ' + @s + '.' + @p;

        -- v9.4.3: testability gate - classify the procedure BEFORE generation.
        -- A NOT_TESTABLE procedure (no fakeable dependencies + system-catalog
        -- usage) gets the Phase 1 SkipTest marker class and a CoverageResult
        -- row with NULL coverage - it is never measured, never shown as 0%.
        SET @testability = N'TESTABLE'; SET @reason = NULL;
        BEGIN TRY
            EXEC TestGen.AssessTestability @SchemaName=@s, @ProcName=@p,
                 @Verdict=@testability OUTPUT, @Reason=@reason OUTPUT;
        END TRY
        BEGIN CATCH SET @testability = N'TESTABLE'; END CATCH

        IF @testability = N'NOT_TESTABLE'
        BEGIN
            BEGIN TRY
                EXEC TestGen.GenerateTestsForProcedure
                     @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                     @TestsPreservedCount=@pres OUTPUT;
            END TRY
            BEGIN CATCH SET @err = N'GEN: ' + ERROR_MESSAGE(); END CATCH

            INSERT TestGen.CoverageResult
                (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
                 TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
                 TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
            VALUES
                (@BatchId,@s,@p,1,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,1,@pres,@err,
                 N'NOT_TESTABLE',@reason,SYSUTCDATETIME());

            PRINT '      -> NOT TESTABLE - recorded, not measured';
            FETCH NEXT FROM cur INTO @Seq,@s,@p;
            CONTINUE;
        END;


        -- 1. generate + install the test class
        BEGIN TRY
            EXEC TestGen.GenerateTestsForProcedure @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                 @TestsPreservedCount=@pres OUTPUT;
            SET @genOK=1;
        END TRY
        BEGIN CATCH SET @err=N'GEN: '+ERROR_MESSAGE(); END CATCH

        IF @genOK = 1
        BEGIN
            -- RunCoverage runs the tests ONCE (instrumented), measures coverage,
            -- AND returns the outcomes via OUTPUT params - no separate test run.
            -- Silent: 'NONE' -> GetCoverageReport emits no per-procedure report.
            BEGIN TRY
                EXEC TestGen.RunCoverage
                     @SchemaName=@s, @ProcName=@p, @OutputMode='NONE',
                     @TestsRun=@run OUTPUT, @TestsPassed=@pass OUTPUT,
                     @TestsFailed=@fail OUTPUT, @TestsErrored=@errc OUTPUT,
                     @TestsSkipped=@skip OUTPUT;
            END TRY
            BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'COV: '+ERROR_MESSAGE(); END CATCH

            -- 4. compute coverage from the line catalogue + hits (same rule as GetCoverageReport)
            ;WITH ln AS (
                SELECT cl.LineNum, cl.IsExec, cl.IsBranch,
                       CASE WHEN EXISTS (SELECT 1 FROM TestGen.CoverageHits ch
                                         WHERE ch.SchemaName=cl.SchemaName
                                           AND ch.ProcName=cl.ProcName
                                           AND ch.LineNum=cl.LineNum) THEN 1 ELSE 0 END AS DirectHit
                FROM TestGen.CoverageLines cl
                WHERE cl.SchemaName=@s AND cl.ProcName=@p
            ),
            nx AS (
                SELECT l.LineNum,
                       (SELECT TOP 1 e.LineNum FROM ln e
                        WHERE e.IsExec=1 AND e.LineNum>l.LineNum ORDER BY e.LineNum) AS NextExecLine
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
        END

        SET @lp = CASE WHEN @tot>0 THEN CAST(@cov AS DECIMAL(9,2))/@tot*100 ELSE 0 END;
        SET @bp = CASE WHEN @tb >0 THEN CAST(@cb  AS DECIMAL(9,2))/@tb *100 ELSE 0 END;

        INSERT TestGen.CoverageResult
            (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
             TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
             TestsErrored,TestsSkipped,TestsPreserved,ErrorText,RunAt)
        VALUES
            (@BatchId,@s,@p,@genOK,@tot,@cov,@lp,@tb,@cb,@bp,@run,@pass,@fail,
             @errc,@skip,@pres,@err,SYSUTCDATETIME());

        FETCH NEXT FROM cur INTO @Seq,@s,@p;
    END
    CLOSE cur; DEALLOCATE cur;

    /*------------------------------ aggregates ------------------------------*/
    DECLARE @gProcs INT,@gGenFail INT,@gTot INT,@gCov INT,@gTB INT,@gCB INT,
            @gRun INT,@gPass INT,@gFail INT,@gErr INT,@gSkip INT;
    DECLARE @gNotTestable INT;
    DECLARE @gPres INT;   -- v9.4.4: total preserved (developer-modified) tests across the batch
    SELECT @gProcs=COUNT(*),
           @gNotTestable=ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 1 ELSE 0 END),0),
           @gGenFail=ISNULL(SUM(CASE WHEN GenSucceeded=0 THEN 1 ELSE 0 END),0),
           @gTot=ISNULL(SUM(TotalLines),0),     @gCov=ISNULL(SUM(CoveredLines),0),
           @gTB =ISNULL(SUM(TotalBranches),0),  @gCB =ISNULL(SUM(CoveredBranches),0),
           @gRun=ISNULL(SUM(TestsRun),0),       @gPass=ISNULL(SUM(TestsPassed),0),
           @gFail=ISNULL(SUM(TestsFailed),0),   @gErr=ISNULL(SUM(TestsErrored),0),
           @gSkip=ISNULL(SUM(CASE WHEN Testability=N'NOT_TESTABLE' THEN 0 ELSE TestsSkipped END),0),
           @gPres=ISNULL(SUM(TestsPreserved),0)
    FROM TestGen.CoverageResult WHERE BatchId=@BatchId;

    DECLARE @gLinePct DECIMAL(5,1) = CASE WHEN @gTot>0 THEN CAST(@gCov AS DECIMAL(9,2))/@gTot*100 ELSE 0 END;
    DECLARE @gBrPct   DECIMAL(5,1) = CASE WHEN @gTB >0 THEN CAST(@gCB  AS DECIMAL(9,2))/@gTB *100 ELSE 0 END;
    DECLARE @pPass DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gPass AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pFail DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gFail AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pErr  DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gErr  AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    DECLARE @pSkip DECIMAL(5,1) = CASE WHEN @gRun>0 THEN CAST(@gSkip AS DECIMAL(9,2))/@gRun*100 ELSE 0 END;
    /* v9.4.4: Autonomy % = fraction of tests the framework still owns.
       Preserved tests are developer-modified tests that survive regeneration;
       they are still procs in the test class and tSQLt runs them as part of
       @gRun, so the denominator is just @gRun.  Autonomy = (run - preserved)/run. */
    DECLARE @gAutonomy DECIMAL(5,1) =
        CASE WHEN @gRun > 0
             THEN CAST(@gRun - @gPres AS DECIMAL(9,2)) / @gRun * 100
             ELSE 100 END;

    IF @OutputMode = 'TEXT'
    BEGIN
        PRINT '';
        PRINT '============== DATABASE COVERAGE SUMMARY ('+ DB_NAME() +') ==============';
        PRINT 'Procedures      : ' + CAST(@gProcs AS VARCHAR) + '   (generation failed: ' + CAST(@gGenFail AS VARCHAR) + ')';
        PRINT 'Not testable    : ' + CAST(@gNotTestable AS VARCHAR) + '   (recorded; excluded from coverage %)';
        PRINT 'Line coverage   : ' + CAST(@gCov AS VARCHAR)+'/'+CAST(@gTot AS VARCHAR)+'  -> '+CAST(@gLinePct AS VARCHAR)+'%';
        PRINT 'Branch coverage : ' + CAST(@gCB AS VARCHAR)+'/'+CAST(@gTB AS VARCHAR)+'  -> '+CAST(@gBrPct AS VARCHAR)+'%';
        PRINT 'Tests           : ' + CAST(@gRun AS VARCHAR) + ' total';
        PRINT '   passed  : ' + CAST(@gPass AS VARCHAR) + '  (' + CAST(@pPass AS VARCHAR) + '%)';
        PRINT '   failed  : ' + CAST(@gFail AS VARCHAR) + '  (' + CAST(@pFail AS VARCHAR) + '%)';
        PRINT '   errored : ' + CAST(@gErr  AS VARCHAR) + '  (' + CAST(@pErr  AS VARCHAR) + '%)';
        PRINT '   skipped : ' + CAST(@gSkip AS VARCHAR) + '  (' + CAST(@pSkip AS VARCHAR) + '%)';
        PRINT 'Autonomy        : ' + CAST(@gAutonomy AS VARCHAR) + '%   ('
            + CAST(@gRun - @gPres AS VARCHAR) + '/' + CAST(@gRun AS VARCHAR)
            + ' framework-owned, ' + CAST(@gPres AS VARCHAR) + ' user-modified)';
        PRINT '=====================================================================';
        SELECT SchemaName, ProcName, Testability, GenSucceeded, TestsRun, TestsPassed, TestsFailed,
               TestsErrored, TestsSkipped, TotalLines, CoveredLines, LinePct, BranchPct, NotTestableReason, ErrorText
        FROM   TestGen.CoverageResult
        WHERE  BatchId = @BatchId
        ORDER  BY SchemaName, ProcName;
        RETURN;
    END;

    /*------------------------------ COBERTURA ------------------------------*/
    /* Delegates to TestGen.GetCoverageCoberturaXml (module 23).                      */
    /* All existing TEXT / HTML code above is untouched.                     */
    IF @OutputMode = 'COBERTURA'
    BEGIN
        EXEC TestGen.GetCoverageCoberturaXml @BatchId = @BatchId, @SchemaFilter = @SchemaFilter;
        RETURN;
    END;

    /*-------------------------------- HTML ---------------------------------*/
    DECLARE @H NVARCHAR(MAX) = N'';
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

    SET @H = @H + N'<div class="cards">';
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gLinePct>=80 THEN 'g' WHEN @gLinePct>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gLinePct AS VARCHAR) + N'%</div><div class="lbl">Line coverage<br>'
        + CAST(@gCov AS VARCHAR) + N'/' + CAST(@gTot AS VARCHAR) + N' lines</div></div>';
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gBrPct>=80 THEN 'g' WHEN @gBrPct>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gBrPct AS VARCHAR) + N'%</div><div class="lbl">Branch coverage<br>'
        + CAST(@gCB AS VARCHAR) + N'/' + CAST(@gTB AS VARCHAR) + N' branches</div></div>';
    SET @H = @H + N'<div class="card"><div class="big">' + CAST(@gRun AS VARCHAR)
        + N'</div><div class="lbl">Tests &middot; '
        + N'<span class="g">' + CAST(@gPass AS VARCHAR) + N' pass ' + CAST(@pPass AS VARCHAR) + N'%</span>, '
        + N'<span class="r">' + CAST(@gFail AS VARCHAR) + N' fail ' + CAST(@pFail AS VARCHAR) + N'%</span>, '
        + CAST(@gErr AS VARCHAR) + N' err ' + CAST(@pErr AS VARCHAR) + N'%, '
        + CAST(@gSkip AS VARCHAR) + N' skip ' + CAST(@pSkip AS VARCHAR) + N'%</div></div>';
    /* v9.4.4: Autonomy headline card.  Shows what fraction of executed tests
       the framework still owns (the complement of user-modified preserved tests). */
    SET @H = @H + N'<div class="card"><div class="big ' +
        CASE WHEN @gAutonomy>=80 THEN 'g' WHEN @gAutonomy>=50 THEN 'a' ELSE 'r' END +
        N'">' + CAST(@gAutonomy AS VARCHAR) + N'%</div><div class="lbl">Autonomy<br>'
        + CAST(@gRun - @gPres AS VARCHAR) + N' of ' + CAST(@gRun AS VARCHAR)
        + N' tests framework-owned<br><span style="color:#999">'
        + CAST(@gPres AS VARCHAR) + N' user-modified</span></div></div>';
    SET @H = @H + N'</div>';

    SET @H = @H + N'<table><tr>'
        + N'<th class="l">Schema</th><th class="l">Object</th>'
        + N'<th>Testable</th><th>Gen</th>'
        + N'<th>Tests</th><th>Pass</th><th>Fail</th><th>Err</th><th>Skip</th>'
        + N'<th>Lines</th><th>Covered</th><th>Line %</th><th>Branch %</th></tr>';

    DECLARE @rS SYSNAME,@rP SYSNAME,@rGen BIT,@rRun INT,@rPass INT,@rFail INT,
            @rErr INT,@rSkip INT,@rTot INT,@rCov INT,@rLP DECIMAL(5,1),@rBP DECIMAL(5,1);
    DECLARE @rTestability VARCHAR(20), @rReason NVARCHAR(400), @rTB INT;
    DECLARE @rPres INT;   -- v9.4.4: per-proc count of preserved (developer-modified) tests
    DECLARE rc CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName,ProcName,GenSucceeded,TestsRun,TestsPassed,TestsFailed,
               TestsErrored,TestsSkipped,TotalLines,CoveredLines,LinePct,BranchPct,TotalBranches,Testability,NotTestableReason,
               TestsPreserved
        FROM TestGen.CoverageResult WHERE BatchId=@BatchId
        ORDER BY SchemaName,ProcName;
    OPEN rc;
    FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,@rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @rTestability = N'NOT_TESTABLE'
            SET @H = @H + N'<tr style="background:#f6f6f6;color:#999">'
                + N'<td class="l">' + @rS + N'</td>'
                + N'<td class="l">' + @rP
                + N'<details style="margin-top:2px"><summary style="font-size:11px;color:#888;cursor:pointer;font-weight:normal">why not testable?</summary>'
                + N'<div style="font-size:12px;font-weight:normal;color:#555;margin-top:4px;white-space:normal">'
                + ISNULL(@rReason, N'no fakeable dependencies; system-catalog usage')
                + N'</div></details>'
                + N'</td>'
                + N'<td><span class="r">N</span></td>'
                + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'N' END + N'</td>'
                + N'<td>' + CAST(ISNULL(@rRun ,0) AS VARCHAR)
                    + CASE WHEN ISNULL(@rPres,0) > 0
                           THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                           ELSE N'' END
                    + N'</td>'
                + N'<td>' + CAST(ISNULL(@rPass,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rFail,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rErr ,0) AS VARCHAR) + N'</td>'
                + N'<td>' + CAST(ISNULL(@rSkip,0) AS VARCHAR) + N'</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'<td style="color:#999">n/a</td>'
                + N'</tr>';
        ELSE
        SET @H = @H + N'<tr><td class="l">' + @rS + N'</td><td class="l">' + @rP + N'</td>'
            + N'<td><span class="g">Y</span></td>'
            + N'<td>' + CASE WHEN @rGen=1 THEN N'Y' ELSE N'<span class="r">N</span>' END + N'</td>'
            + N'<td>' + CAST(@rRun AS VARCHAR)
                + CASE WHEN ISNULL(@rPres,0) > 0
                       THEN N' <span style="color:#9a6700" title="user-modified tests preserved this regen">(' + CAST(@rPres AS VARCHAR) + N' preserved)</span>'
                       ELSE N'' END
                + N'</td>'
            + N'<td>' + CAST(@rPass AS VARCHAR) + N'</td>'
            + N'<td>' + CASE WHEN @rFail>0 THEN N'<span class="r">'+CAST(@rFail AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
            + N'<td>' + CASE WHEN @rErr >0 THEN N'<span class="r">'+CAST(@rErr  AS VARCHAR)+N'</span>' ELSE N'0' END + N'</td>'
            + N'<td>' + CAST(@rSkip AS VARCHAR) + N'</td>'
            + N'<td>' + CAST(@rTot AS VARCHAR) + N'</td>'
            + N'<td>' + CAST(@rCov AS VARCHAR) + N'</td>'
            + CASE WHEN ISNULL(@rTot,0) = 0
                   THEN N'<td style="color:#999">n/a</td>'
                   ELSE N'<td class="' + CASE WHEN @rLP>=80 THEN 'g' WHEN @rLP>=50 THEN 'a' ELSE 'r' END
                        + N'">' + CAST(@rLP AS VARCHAR) + N'%</td>' END
            + CASE WHEN ISNULL(@rTB,0) = 0
                   THEN N'<td style="color:#999">n/a</td>'
                   ELSE N'<td class="' + CASE WHEN @rBP>=80 THEN 'g' WHEN @rBP>=50 THEN 'a' ELSE 'r' END
                        + N'">' + CAST(@rBP AS VARCHAR) + N'%</td>' END
            + N'</tr>';
        FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,@rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    END;
    CLOSE rc; DEALLOCATE rc;

    SET @H = @H + N'<tr class="total"><td class="l" colspan="4">TOTAL &mdash; '
        + CAST(@gProcs AS VARCHAR) + N' objects ('
        + CAST(@gProcs - @gNotTestable AS VARCHAR) + N' testable, '
        + CAST(@gNotTestable AS VARCHAR) + N' not)</td>'
        + N'<td>' + CAST(@gRun AS VARCHAR)
            + CASE WHEN @gPres > 0
                   THEN N' <span style="color:#9a6700">(' + CAST(@gPres AS VARCHAR) + N' preserved)</span>'
                   ELSE N'' END
            + N'</td>'
        + N'<td>' + CAST(@gPass AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gFail AS VARCHAR) + N'</td><td>' + CAST(@gErr AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gSkip AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gTot AS VARCHAR) + N'</td><td>' + CAST(@gCov AS VARCHAR) + N'</td>'
        + N'<td>' + CAST(@gLinePct AS VARCHAR) + N'%</td><td>' + CAST(@gBrPct AS VARCHAR) + N'%</td></tr>';
    SET @H = @H + N'</table></body></html>';

    SELECT @H AS CoverageReportHTML;

    PRINT '/* =============== DATABASE COVERAGE REPORT HTML =============== */';
    DECLARE @Chunk INT = 1, @ChunkSize INT = 4000;
    WHILE @Chunk <= LEN(@H)
    BEGIN
        PRINT SUBSTRING(@H, @Chunk, @ChunkSize);
        SET @Chunk = @Chunk + @ChunkSize;
    END;
    PRINT '/* =================== END HTML =================== */';
END;
GO
PRINT 'TestGen.CoverageResult table + TestGen.GenerateAndCoverDatabase created.';
GO

/*============================================================================
  TestGen.DropGeneratedTestClasses
  ----------------------------------------------------------------------------
  Tear-down: removes the test classes the framework generated, so a database
  can be returned to just its business procedures.

  It reads TestGenLog.GenerationRun - the framework's own log of every class it
  has generated - so it ONLY drops framework-generated test_<proc> classes.
  Developer-owned test_<proc>_custom... classes are preserved unless
  @IncludeCustom = 1 is passed explicitly.

     @SchemaFilter   NULL = every schema; else only procedures of that schema
     @IncludeCustom  1 = also drop developer-owned test_<proc>_custom... classes
     @WhatIf         1 = list what WOULD be dropped and drop nothing (dry run)

     EXEC TestGen.DropGeneratedTestClasses @WhatIf = 1;         -- preview first
     EXEC TestGen.DropGeneratedTestClasses;                     -- drop generated
     EXEC TestGen.DropGeneratedTestClasses @IncludeCustom = 1;  -- full wipe
============================================================================*/
IF OBJECT_ID('TestGen.DropGeneratedTestClasses','P') IS NOT NULL
    DROP PROCEDURE TestGen.DropGeneratedTestClasses;
GO
CREATE PROCEDURE TestGen.DropGeneratedTestClasses
    @SchemaFilter  SYSNAME = NULL,
    @IncludeCustom BIT     = 0,
    @WhatIf        BIT     = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tSQLt.DropClass','P') IS NULL
    BEGIN
        RAISERROR('tSQLt is not installed in this database.',16,1);
        RETURN;
    END;
    IF OBJECT_ID('TestGenLog.GenerationRun','U') IS NULL
    BEGIN
        RAISERROR('TestGenLog.GenerationRun not found - no generation log to read.',16,1);
        RETURN;
    END;

    DECLARE @drop TABLE (ClassName SYSNAME PRIMARY KEY, Kind VARCHAR(10));

    -- framework-generated classes: exactly what the log records, still present
    INSERT @drop (ClassName, Kind)
    SELECT DISTINCT gr.TestClassName, 'framework'
    FROM   TestGenLog.GenerationRun gr
    WHERE  gr.TestClassName IS NOT NULL
      AND  SCHEMA_ID(gr.TestClassName) IS NOT NULL
      AND  (@SchemaFilter IS NULL OR gr.TargetSchema = @SchemaFilter);

    -- developer-owned custom classes: only when explicitly requested
    IF @IncludeCustom = 1
        INSERT @drop (ClassName, Kind)
        SELECT DISTINCT s.name, 'custom'
        FROM   sys.schemas s
        WHERE  s.name NOT IN (SELECT ClassName FROM @drop)
          AND  EXISTS (SELECT 1 FROM TestGenLog.GenerationRun gr
                       WHERE gr.TestClassName IS NOT NULL
                         AND (@SchemaFilter IS NULL OR gr.TargetSchema = @SchemaFilter)
                         AND s.name LIKE REPLACE(gr.TestClassName,'_','[_]') + '[_]custom%');

    DECLARE @n INT = (SELECT COUNT(*) FROM @drop);

    IF @WhatIf = 1
    BEGIN
        PRINT 'DropGeneratedTestClasses (WhatIf): ' + CAST(@n AS VARCHAR) + ' class(es) WOULD be dropped.';
        SELECT ClassName, Kind FROM @drop ORDER BY Kind, ClassName;
        RETURN;
    END;

    IF @IncludeCustom = 1
        PRINT 'WARNING: @IncludeCustom = 1 - developer-owned test_<proc>_custom... classes WILL be dropped.';

    DECLARE @cls SYSNAME, @kind VARCHAR(10), @dropped INT = 0, @failed INT = 0;
    DECLARE dc CURSOR LOCAL FAST_FORWARD FOR
        SELECT ClassName, Kind FROM @drop ORDER BY Kind, ClassName;
    OPEN dc;
    FETCH NEXT FROM dc INTO @cls, @kind;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC tSQLt.DropClass @cls;
            SET @dropped = @dropped + 1;
            PRINT '  dropped (' + @kind + ') : ' + @cls;
        END TRY
        BEGIN CATCH
            SET @failed = @failed + 1;
            PRINT '  FAILED  (' + @kind + ') : ' + @cls + ' - ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM dc INTO @cls, @kind;
    END;
    CLOSE dc; DEALLOCATE dc;

    PRINT 'DropGeneratedTestClasses: ' + CAST(@dropped AS VARCHAR) + ' dropped, '
        + CAST(@failed AS VARCHAR) + ' failed.';
END;
GO
PRINT 'TestGen.DropGeneratedTestClasses created.';
GO
