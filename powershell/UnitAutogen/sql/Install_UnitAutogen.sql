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
 * tSQLt Auto-Generation Framework  --  v9.4.2   (single-file installer)
 *
 * Self-contained.  Run this entire file ONCE, in the target database, in SSMS
 * or sqlcmd.  It is idempotent - safe to re-run.  Expect the message
 * "TestGen.GetCoverageReport v2 created." as the final line of output.
 *
 * Prerequisites: SQL Server 2017+ and tSQLt installed in the target database.
 *
 * v9.4.2 - strong branch-test assertions + before/after delta assertions:
 *   - Branch/path tests carry real assertions (snapshot-and-replay via
 *     tSQLt.AssertEqualsTable) instead of tautologies.
 *   - INSERT-branch tests assert the target table GAINED a row from the
 *     procedure; UPDATE-branch tests assert the row count held but rows
 *     actually changed.
 *   - Non-replayable bodies emit tSQLt.SkipTest ("MANUAL TEST REQUIRED")
 *     rather than a silent smoke pass - no phantom passes.
 *   See README_v9_4.md ("What's new in v9.4.2"), DESIGN_v9_4_Strong_Assertions.md
 *   and CHANGES.md for the full history.
 *
 * NOTE: this installer carries v9.4.2 code in modules 04 (Test_Generator) and
 * 17 (Branch_Path_Analyzer); all other sections are the verified v9.3 build.
 * Earlier copies of this file were truncated mid-InstrumentProcedure - this
 * copy is complete (all five coverage procs included).
 *******************************************************************************/

/* === 01_Install_Framework.sql === */
/*****************************************************************************
 * tSQLt Auto-Generation Framework - Installer
 * -----------------------------------------------------------------------------
 * Prerequisites:
 *   - tSQLt v1.0.5873.27393 or later installed in the target database.
 *     (https://tsqlt.org/downloads)
 *   - User running this script needs CREATE SCHEMA + CREATE PROCEDURE rights.
 *
 * What this installs:
 *   - Schema [TestGen]              - houses all framework objects
 *   - Schema [TestGenLog]           - audit log for generation runs
 *   - Tables for metadata caching & generation history
 *   - Procedures that introspect a stored procedure and emit a tSQLt test class
 *
 * Idempotent: safe to re-run; it drops & recreates framework objects but
 * leaves tSQLt itself and your application objects untouched.
 *****************************************************************************/
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*---------------------------------------------------------------------------
 * Pre-flight check: tSQLt must be present. If it's missing, raise a clear
 * error and short-circuit the rest of the script with SET NOEXEC ON so the
 * user sees one clean message instead of a cascade of follow-on errors.
 * The matching SET NOEXEC OFF is at the very bottom of this file.
 *--------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'tSQLt')
BEGIN
    RAISERROR('UnitAutogen install aborted: tSQLt is not installed in this database. Install tSQLt from https://tsqlt.org first, then re-run this script.', 16, 1);
    SET NOEXEC ON;
END
GO

/*---------------------------------------------------------------------------
 * Pre-flight check: database compatibility level must be 130 or higher.
 * UnitAutogen uses STRING_SPLIT, which requires compatibility_level >= 130
 * (SQL Server 2016 syntax). The SQL Server instance can be newer; this is
 * about the DATABASE compat setting specifically. Databases upgraded
 * across SQL Server versions without an explicit ALTER DATABASE often sit
 * at compat 110 (SQL 2012) or 120 (SQL 2014).
 *
 * Same short-circuit pattern as the tSQLt check: SET NOEXEC ON, with the
 * matching SET NOEXEC OFF at the very bottom of this file.
 *--------------------------------------------------------------------------*/
DECLARE @CompatLevel TINYINT;
SELECT @CompatLevel = compatibility_level
FROM sys.databases
WHERE database_id = DB_ID();

IF @CompatLevel < 130
BEGIN
    DECLARE @msg NVARCHAR(MAX) =
        'UnitAutogen install aborted: this database compatibility_level is ' +
        CAST(@CompatLevel AS VARCHAR(10)) +
        '. UnitAutogen requires compatibility_level >= 130 (SQL Server 2016) ' +
        'because the framework uses STRING_SPLIT. To bump the level: ' +
        'ALTER DATABASE [' + DB_NAME() + '] SET COMPATIBILITY_LEVEL = 130; ' +
        'then re-run this installer.';
    RAISERROR(@msg, 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'TestGen')
    EXEC('CREATE SCHEMA TestGen AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'TestGenLog')
    EXEC('CREATE SCHEMA TestGenLog AUTHORIZATION dbo;');
GO

/*---------------------------------------------------------------------------
 * Drop existing log tables in child-then-parent order so the FKs to
 * GenerationRun (ProcedureSnapshot.RunId, GeneratedTest.RunId) don't block.
 *--------------------------------------------------------------------------*/
IF OBJECT_ID('TestGenLog.GeneratedTest', 'U') IS NOT NULL
    DROP TABLE TestGenLog.GeneratedTest;
GO

IF OBJECT_ID('TestGenLog.ProcedureSnapshot', 'U') IS NOT NULL
    DROP TABLE TestGenLog.ProcedureSnapshot;
GO

IF OBJECT_ID('TestGenLog.GenerationRun', 'U') IS NOT NULL
    DROP TABLE TestGenLog.GenerationRun;
GO

/*---------------------------------------------------------------------------
 * Generation runs - one row per "generate tests for proc X" invocation.
 *--------------------------------------------------------------------------*/
CREATE TABLE TestGenLog.GenerationRun
(
    RunId             INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GenerationRun PRIMARY KEY,
    TargetSchema      SYSNAME           NOT NULL,
    TargetProcedure   SYSNAME           NOT NULL,
    TestClassName     SYSNAME           NOT NULL,
    StartedAt         DATETIME2(3)      NOT NULL CONSTRAINT DF_GenerationRun_StartedAt DEFAULT SYSUTCDATETIME(),
    CompletedAt       DATETIME2(3)      NULL,
    Status            VARCHAR(20)       NOT NULL CONSTRAINT DF_GenerationRun_Status DEFAULT 'Running',
    GeneratedTestCount INT              NULL,
    GeneratedScript   NVARCHAR(MAX)     NULL,
    ErrorMessage      NVARCHAR(4000)    NULL,
    InvokedBy         SYSNAME           NOT NULL CONSTRAINT DF_GenerationRun_InvokedBy DEFAULT SUSER_SNAME()
);
GO

/*---------------------------------------------------------------------------
 * Snapshot of analysed procedure metadata - useful for replay & debugging.
 *--------------------------------------------------------------------------*/
CREATE TABLE TestGenLog.ProcedureSnapshot
(
    SnapshotId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProcedureSnapshot PRIMARY KEY,
    RunId           INT               NOT NULL CONSTRAINT FK_ProcSnap_Run REFERENCES TestGenLog.GenerationRun(RunId),
    Kind            VARCHAR(20)       NOT NULL,  -- 'Parameter' | 'TableDep' | 'ProcDep' | 'Source'
    ItemName        NVARCHAR(512)     NULL,
    ItemDetail      NVARCHAR(MAX)     NULL
);
GO

/*---------------------------------------------------------------------------
 * v9.4.4: Per-test capture for the preservation mechanism.  After each
 * emitted test proc is created, we record its body (read back from
 * sys.sql_modules.definition) and a SHA2_256 hash.  At regen / drop time
 * the framework compares the current body's hash to OriginalBodyHash; a
 * mismatch means the developer modified the test, so the framework
 * preserves it instead of dropping & regenerating.
 *--------------------------------------------------------------------------*/
CREATE TABLE TestGenLog.GeneratedTest
(
    GeneratedTestId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GeneratedTest PRIMARY KEY,
    RunId             INT               NOT NULL CONSTRAINT FK_GenTest_Run REFERENCES TestGenLog.GenerationRun(RunId),
    SchemaName        SYSNAME           NOT NULL,
    ProcName          SYSNAME           NOT NULL,
    TestClassName     SYSNAME           NOT NULL,
    TestProcName      SYSNAME           NOT NULL,
    OriginalBody      NVARCHAR(MAX)     NOT NULL,
    OriginalBodyHash  AS HASHBYTES('SHA2_256', OriginalBody) PERSISTED,
    EmittedAt         DATETIME2(3)      NOT NULL CONSTRAINT DF_GenTest_EmittedAt DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_GenTest_ProcAndClass
    ON TestGenLog.GeneratedTest (SchemaName, ProcName, TestClassName, TestProcName, RunId DESC);
GO

PRINT 'Framework schemas and log tables created.';
GO


/* === 02_Metadata_Procedures.sql === */
/*****************************************************************************
 * TestGen.GetProcedureParameters
 * -----------------------------------------------------------------------------
 * Returns a result set describing every parameter of a stored procedure:
 *   ParamId, ParamName, SqlTypeName, MaxLength, Precision, Scale, IsOutput,
 *   IsNullable, HasDefault, DefaultValueSql, IsTableType, TypeSchema
 *
 * The output is ordered by parameter position so callers can emit EXEC calls
 * in the correct order.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetProcedureParameters', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GetProcedureParameters;
GO

CREATE PROCEDURE TestGen.GetProcedureParameters
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName));

    IF @ObjId IS NULL
    BEGIN
        RAISERROR('Procedure %s.%s not found.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    SELECT
        p.parameter_id                                              AS ParamId,
        p.name                                                      AS ParamName,
        TYPE_NAME(p.user_type_id)                                   AS SqlTypeName,
        p.max_length                                                AS MaxLength,
        p.precision                                                 AS [Precision],
        p.scale                                                     AS Scale,
        p.is_output                                                 AS IsOutput,
        CAST(CASE WHEN p.is_nullable = 1 THEN 1 ELSE 0 END AS BIT)  AS IsNullable,
        CAST(p.has_default_value AS BIT)                            AS HasDefault,
        CONVERT(NVARCHAR(MAX), p.default_value)                     AS DefaultValueSql,
        CAST(t.is_table_type AS BIT)                                AS IsTableType,
        SCHEMA_NAME(t.schema_id)                                    AS TypeSchema
    FROM sys.parameters p
    INNER JOIN sys.types t ON t.user_type_id = p.user_type_id
    WHERE p.object_id = @ObjId
      AND p.parameter_id > 0
    ORDER BY p.parameter_id;
END;
GO

/*****************************************************************************
 * TestGen.GetProcedureDependencies
 * -----------------------------------------------------------------------------
 * Returns all referenced tables, views, and procedures so the generator knows
 * what to FakeTable / SpyProcedure. Uses sys.sql_expression_dependencies plus
 * a regex-light fallback over the source text for dynamic SQL hints.
 *
 * Columns: DepKind ('TABLE'|'VIEW'|'PROCEDURE'|'FUNCTION'), SchemaName, ObjectName, IsAmbiguous
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetProcedureDependencies', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GetProcedureDependencies;
GO

CREATE PROCEDURE TestGen.GetProcedureDependencies
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName));

    IF @ObjId IS NULL
    BEGIN
        RAISERROR('Procedure %s.%s not found.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    ;WITH RawDeps AS
    (
        SELECT
            d.referenced_schema_name                AS SchemaName,
            d.referenced_entity_name                AS ObjectName,
            d.is_ambiguous                          AS IsAmbiguous,
            OBJECT_ID(
                QUOTENAME(ISNULL(d.referenced_schema_name, SCHEMA_NAME(SCHEMA_ID())))
              + '.' + QUOTENAME(d.referenced_entity_name)
            )                                       AS RefObjectId
        FROM sys.sql_expression_dependencies d
        WHERE d.referencing_id = @ObjId
          AND d.referenced_entity_name IS NOT NULL
    )
    SELECT DISTINCT
        CASE o.type
            WHEN 'U'  THEN 'TABLE'
            WHEN 'V'  THEN 'VIEW'
            WHEN 'P'  THEN 'PROCEDURE'
            WHEN 'FN' THEN 'FUNCTION'
            WHEN 'IF' THEN 'FUNCTION'
            WHEN 'TF' THEN 'FUNCTION'
            ELSE 'OTHER'
        END                                         AS DepKind,
        ISNULL(r.SchemaName, SCHEMA_NAME(o.schema_id)) AS SchemaName,
        r.ObjectName                                AS ObjectName,
        r.IsAmbiguous                               AS IsAmbiguous
    FROM RawDeps r
    LEFT JOIN sys.objects o ON o.object_id = r.RefObjectId
    WHERE o.type IN ('U','V','P','FN','IF','TF')
    ORDER BY DepKind, SchemaName, ObjectName;
END;
GO

/*****************************************************************************
 * TestGen.GetProcedureSource
 * -----------------------------------------------------------------------------
 * Returns the CREATE PROCEDURE text - used by the generator to detect a few
 * patterns (RAISERROR, RETURN <int>, OUTPUT params actually assigned, etc.)
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetProcedureSource', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GetProcedureSource;
GO

CREATE PROCEDURE TestGen.GetProcedureSource
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName));

    IF @ObjId IS NULL
    BEGIN
        RAISERROR('Procedure %s.%s not found.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    SELECT OBJECT_DEFINITION(@ObjId) AS SourceText;
END;
GO

PRINT 'Metadata-extraction procedures installed.';
GO


/* === 03_Value_Helpers.sql === */
/* === 03_Value_Helpers.sql === v9.2 === */
/*****************************************************************************
 * TestGen.GetSampleValueLiteral
 * -----------------------------------------------------------------------------
 * Returns a T-SQL literal suitable for a given type name. The @Variant argument
 * selects which sample to return:
 *   0 = a "typical valid" value
 *   1 = a "boundary low" value  (zero, empty string, 1900-01-01, ...)
 *   2 = a "boundary high" value (MAX-like, long string, future date, ...)
 *   3 = NULL literal
 *
 * Used by the test-class generator to build _Happy / _Boundary / _Null tests.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetSampleValueLiteral', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.GetSampleValueLiteral;
GO

CREATE FUNCTION TestGen.GetSampleValueLiteral
(
    @SqlTypeName SYSNAME,
    @MaxLength   SMALLINT,
    @Precision   TINYINT,
    @Scale       TINYINT,
    @Variant     TINYINT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @Variant = 3 RETURN N'NULL';

    DECLARE @t SYSNAME = LOWER(@SqlTypeName);

    -- Integers
    IF @t IN ('bit')
        RETURN CASE @Variant WHEN 0 THEN N'1' WHEN 1 THEN N'0' ELSE N'1' END;
    IF @t IN ('tinyint')
        RETURN CASE @Variant WHEN 0 THEN N'42' WHEN 1 THEN N'0' ELSE N'255' END;
    IF @t IN ('smallint')
        RETURN CASE @Variant WHEN 0 THEN N'1234' WHEN 1 THEN N'-32768' ELSE N'32767' END;
    IF @t IN ('int')
        RETURN CASE @Variant WHEN 0 THEN N'42' WHEN 1 THEN N'-2147483648' ELSE N'2147483647' END;
    IF @t IN ('bigint')
        RETURN CASE @Variant WHEN 0 THEN N'1000000' WHEN 1 THEN N'-9223372036854775808' ELSE N'9223372036854775807' END;

    -- Money / decimal / numeric
    IF @t IN ('money','smallmoney')
        RETURN CASE @Variant WHEN 0 THEN N'$123.45' WHEN 1 THEN N'$0.00' ELSE N'$999999.99' END;
    IF @t IN ('decimal','numeric')
        RETURN CASE @Variant WHEN 0 THEN N'123.45' WHEN 1 THEN N'0' ELSE N'99999.99' END;
    IF @t IN ('float','real')
        RETURN CASE @Variant WHEN 0 THEN N'1.5' WHEN 1 THEN N'0' ELSE N'1.7976931348623157E+308' END;

    -- Strings
    IF @t IN ('char','varchar','nchar','nvarchar','sysname','text','ntext')
    BEGIN
        -- Compute the column's effective character length up front so all
        -- variants can respect it.
        DECLARE @len INT =
            CASE
                WHEN @MaxLength = -1 THEN 200          -- MAX types
                WHEN @t IN ('nchar','nvarchar')
                                     THEN @MaxLength/2
                ELSE @MaxLength
            END;
        IF @len IS NULL OR @len < 1 SET @len = 10;
        IF @len > 200 SET @len = 200;

        IF @Variant = 0
        BEGIN
            -- v9.2 (revision 2): always return a SHORT sample value (3 chars
            -- or shorter, capped by @len) for strings.  Reason: parameters
            -- are often used in WHERE clauses against columns of varying
            -- max-length.  If the EXEC arg uses 'SampleText' (10 chars) and
            -- the seed truncates to 'Sam' to fit a NCHAR(3) column, the
            -- predicate `col = @param` evaluates 'Sam' = 'SampleText' = false.
            -- A 3-char default fits in any column with max-length >= 3 (which
            -- is most realistic columns).  Sub-3-char columns are rare.
            IF @len >= 3 RETURN N'''Sam''';
            RETURN N'''' + LEFT(N'Sam', @len) + N'''';
        END;
        IF @Variant = 1 RETURN N'''''';   -- empty string
        -- boundary high: build a longish string respecting max_length
        RETURN N'''' + REPLICATE(N'X', @len) + N'''';
    END;

    -- Dates / times
    IF @t = 'date'
        RETURN CASE @Variant WHEN 0 THEN N'''2024-06-15''' WHEN 1 THEN N'''1900-01-01''' ELSE N'''9999-12-31''' END;
    IF @t IN ('datetime','datetime2','smalldatetime','datetimeoffset')
        RETURN CASE @Variant
                 WHEN 0 THEN N'''2024-06-15T12:34:56'''
                 WHEN 1 THEN N'''1900-01-01T00:00:00'''
                 ELSE        N'''9999-12-31T23:59:59'''
               END;
    IF @t = 'time'
        RETURN CASE @Variant WHEN 0 THEN N'''12:34:56''' WHEN 1 THEN N'''00:00:00''' ELSE N'''23:59:59''' END;

    -- Binary
    IF @t IN ('binary','varbinary','image')
        RETURN CASE @Variant WHEN 0 THEN N'0x0102' WHEN 1 THEN N'0x00' ELSE N'0xFFFFFFFF' END;

    -- Uniqueidentifier
    IF @t = 'uniqueidentifier'
        RETURN CASE @Variant
                 WHEN 0 THEN N'''11111111-1111-1111-1111-111111111111'''
                 WHEN 1 THEN N'''00000000-0000-0000-0000-000000000000'''
                 ELSE        N'''FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'''
               END;

    IF @t = 'xml'
        RETURN N'''<sample/>''';

    -- Fallback
    RETURN N'NULL /* unknown type ' + @SqlTypeName + N' */';
END;
GO

/*****************************************************************************
 * TestGen.GetDeclareLiteralForType
 * -----------------------------------------------------------------------------
 * Returns the type portion of a DECLARE statement, e.g. NVARCHAR(50),
 * DECIMAL(10,2), DATETIME2(3). Used when we need to declare local variables
 * for OUTPUT parameters inside generated tests.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GetDeclareLiteralForType', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.GetDeclareLiteralForType;
GO

CREATE FUNCTION TestGen.GetDeclareLiteralForType
(
    @SqlTypeName SYSNAME,
    @MaxLength   SMALLINT,
    @Precision   TINYINT,
    @Scale       TINYINT
)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @t SYSNAME = LOWER(@SqlTypeName);

    IF @t IN ('char','varchar','binary','varbinary')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength AS NVARCHAR(10)) END + N')';

    IF @t IN ('nchar','nvarchar')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength/2 AS NVARCHAR(10)) END + N')';

    IF @t IN ('decimal','numeric')
        RETURN UPPER(@t) + N'(' + CAST(@Precision AS NVARCHAR(10)) + N',' + CAST(@Scale AS NVARCHAR(10)) + N')';

    IF @t IN ('datetime2','datetimeoffset','time')
        RETURN UPPER(@t) + N'(' + CAST(@Scale AS NVARCHAR(10)) + N')';

    RETURN UPPER(@t);
END;
GO

PRINT 'Sample-value helpers installed.';
GO


/* === 05_Batch_Executor.sql === */
/*****************************************************************************
 * TestGen.ExecuteBatchedScript
 * -----------------------------------------------------------------------------
 * sp_executesql cannot consume the GO batch separator (it is a client-side
 * directive, not T-SQL). This procedure does what SQLCMD does: split the
 * script on lines containing only "GO" (optionally followed by a count) and
 * run each batch via sp_executesql.
 *
 * It deliberately runs every batch inside the SAME session so that
 * tSQLt.NewTestClass and the subsequent CREATE PROCEDUREs see each other.
 *****************************************************************************/
IF OBJECT_ID('TestGen.ExecuteBatchedScript', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ExecuteBatchedScript;
GO

CREATE PROCEDURE TestGen.ExecuteBatchedScript
    @Script NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);

    -- Normalise line endings so the split below is simpler.
    SET @Script = REPLACE(REPLACE(@Script, CHAR(13) + CHAR(10), CHAR(10)), CHAR(13), CHAR(10));

    DECLARE @pos INT = 1, @nl INT, @line NVARCHAR(MAX), @batch NVARCHAR(MAX) = N'';

    WHILE @pos <= LEN(@Script) + 1
    BEGIN
        SET @nl = CHARINDEX(CHAR(10), @Script, @pos);
        IF @nl = 0 SET @nl = LEN(@Script) + 1;

        SET @line = SUBSTRING(@Script, @pos, @nl - @pos);

        IF LTRIM(RTRIM(UPPER(@line))) = N'GO'
           OR LTRIM(RTRIM(UPPER(@line))) LIKE N'GO[0-9]%'
        BEGIN
            IF LEN(LTRIM(RTRIM(@batch))) > 0
                EXEC sp_executesql @batch;
            SET @batch = N'';
        END
        ELSE
        BEGIN
            SET @batch = @batch + @line + CHAR(10);
        END;

        SET @pos = @nl + 1;
    END;

    IF LEN(LTRIM(RTRIM(@batch))) > 0
        EXEC sp_executesql @batch;
END;
GO

PRINT 'TestGen.ExecuteBatchedScript installed.';
GO


/* === 08_Build_Seed_Insert.sql === */
/******************************************************************************
 * TestGen.BuildSeedInsertForTable
 * ----------------------------------------------------------------------------
 * Builds an INSERT ... SELECT statement that seeds @RowCount rows into the
 * given (already faked) table.
 *
 * Output strategy:
 *   The generated SQL uses a UNION ALL of @RowCount one-row SELECTs (rather
 *   than VALUES) so we can portably embed sub-selects against parent tables
 *   for FK columns:
 *
 *      INSERT [schema].[table] ([c1],[c2],[fkCol])
 *      SELECT 1, 'SampleText_1',
 *             (SELECT TOP 1 pkCol FROM [schema].[parent] ORDER BY pkCol
 *              OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY)
 *      UNION ALL
 *      SELECT 2, 'SampleText_2',
 *             (SELECT TOP 1 pkCol FROM [schema].[parent] ORDER BY pkCol
 *              OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY)
 *      ...
 *
 * The OFFSET trick is what gives us round-robin FK reuse: row 1 takes parent
 * row 1, row 2 takes parent row 2, etc., wrapping with modulo if @RowCount
 * exceeds the parent count.
 ******************************************************************************/
IF OBJECT_ID('TestGen.BuildSeedInsertForTable', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.BuildSeedInsertForTable;
GO

CREATE PROCEDURE TestGen.BuildSeedInsertForTable
    @ObjectId         INT,
    @TableSet         NVARCHAR(MAX),       -- comma-separated list of tables in this seed run
    @RowCount         INT,
    @InsertSql        NVARCHAR(MAX) OUTPUT,
    @SkipSafetyCheck  BIT = 0              -- generator uses 1 when building static templates
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);

    DECLARE @schema SYSNAME = OBJECT_SCHEMA_NAME(@ObjectId);
    DECLARE @table  SYSNAME = OBJECT_NAME(@ObjectId);
    DECLARE @full   NVARCHAR(300) = QUOTENAME(@schema) + N'.' + QUOTENAME(@table);

    /* ----------------------------------------------------------------
     * SAFETY: refuse to seed if the table doesn't appear to be faked.
     * tSQLt.FakeTable drops PK/UQ/FK/CHECK constraints from the fake
     * (it preserves defaults only when @Defaults = 1, which is our
     * generator's default). So if we still see PK/UQ/FK/CHECK on this
     * object, the caller either forgot to FakeTable it or we are
     * pointing at the real production table. Either way -> abort.
     *
     * The generator passes @SkipSafetyCheck = 1 because at generation
     * time the table is naturally NOT faked - the test that will EXECUTE
     * the resulting INSERT statement will fake it first. The check is
     * deferred to the test's own arrange block where it belongs.
     * ---------------------------------------------------------------*/
    IF @SkipSafetyCheck = 0
       AND EXISTS
       (
           SELECT 1 FROM sys.objects
           WHERE parent_object_id = @ObjectId
             AND type IN ('PK','UQ','F','C')
       )
    BEGIN
        DECLARE @errMsg NVARCHAR(400) =
            N'TestGen.BuildSeedInsertForTable: %s still has PK/UQ/FK/CHECK constraints attached. '
          + N'It does not appear to have been faked. Refusing to seed.';
        RAISERROR(@errMsg, 16, 1, @full);
        RETURN;
    END;

    /* ----------------------------------------------------------------
     * 1. Gather column metadata.
     *
     * Excluded:
     *   - Computed columns (cannot INSERT even if FakeTable tried to materialize them)
     *   - timestamp/rowversion (cannot be INSERTed)
     *   - IDENTITY columns (defensive - FakeTable strips but user could override)
     * ---------------------------------------------------------------*/
    DECLARE @Cols TABLE
    (
        ColOrdinal     INT,
        ColName        SYSNAME,
        SqlTypeName    SYSNAME,
        MaxLength      SMALLINT,
        [Precision]    TINYINT,
        Scale          TINYINT,
        IsNullable     BIT,
        IsIdentity     BIT,
        IsComputed     BIT,
        IsRowVersion   BIT,
        IsGeneratedAlways BIT,
        HasDefault     BIT,
        FkParentObjId  INT          NULL,
        FkParentCol    SYSNAME      NULL
    );

    INSERT @Cols
    SELECT
        c.column_id,
        c.name,
        TYPE_NAME(c.user_type_id),
        c.max_length,
        c.precision,
        c.scale,
        c.is_nullable,
        c.is_identity,
        c.is_computed,
        CASE WHEN TYPE_NAME(c.user_type_id) IN ('timestamp','rowversion') THEN 1 ELSE 0 END,
        CASE WHEN c.generated_always_type <> 0 THEN 1 ELSE 0 END,
        CASE WHEN c.default_object_id <> 0 THEN 1 ELSE 0 END,
        NULL, NULL
    FROM sys.columns c
    WHERE c.object_id = @ObjectId;

    -- Annotate FK columns. Only consider FKs pointing into the seed set.
    DECLARE @ParentObjIds TABLE (ObjId INT);
    ;WITH split AS
    (
        SELECT LTRIM(RTRIM(value)) AS FullName
        FROM STRING_SPLIT(@TableSet, ',')
        WHERE LTRIM(RTRIM(value)) <> ''
    )
    INSERT @ParentObjIds (ObjId)
    SELECT OBJECT_ID(FullName) FROM split;

    UPDATE c
    SET FkParentObjId = e.referenced_object_id,
        FkParentCol   = pc.name
    FROM @Cols c
    JOIN sys.foreign_key_columns e
      ON e.parent_object_id = @ObjectId
     AND e.parent_column_id = c.ColOrdinal
    JOIN sys.columns pc
      ON pc.object_id = e.referenced_object_id
     AND pc.column_id = e.referenced_column_id
    WHERE e.referenced_object_id IN (SELECT ObjId FROM @ParentObjIds);

    /* ----------------------------------------------------------------
     * 2. Build the column list and one SELECT per row.
     *
     * Columns with a DEFAULT constraint are intentionally LEFT OUT of the
     * insert column list. FakeTable preserves defaults (@Defaults = 1),
     * so the default value is what lands in the row - which matches what
     * the application actually does at runtime and avoids the seeder
     * overriding meaningful values like Status = 'Active'.
     *
     * FK columns take precedence over the "has default" rule because we
     * want our round-robin FK consistency to win; otherwise child rows
     * could end up pointing at non-existent parents.
     *
     * IDENTITY columns are INCLUDED in the seed. At generation time we
     * read sys.columns from the REAL table where Identity is set, but at
     * test time FakeTable strips the identity property (with the default
     * @Identity = 0 we emit). The fake column is then a plain INT that
     * accepts and requires our explicit values - so we treat it like any
     * other int column and populate it with the row index. Without this,
     * the formerly-identity column ends up NULL on every seeded row, and
     * procs that do "WHERE CustomerId = @CustomerId" find nothing.
     * ---------------------------------------------------------------*/
    DECLARE @colList NVARCHAR(MAX) = N'';
    SELECT @colList = @colList + N',' + QUOTENAME(ColName)
    FROM @Cols
    WHERE IsRowVersion = 0
      AND IsComputed = 0
      AND IsGeneratedAlways = 0
      AND (HasDefault  = 0 OR FkParentObjId IS NOT NULL)
    ORDER BY ColOrdinal;
    SET @colList = STUFF(@colList, 1, 1, N'');

    IF @colList IS NULL OR @colList = N''
    BEGIN
        SET @InsertSql = N'-- ' + @full + N': no insertable columns; skipped.' + @CRLF;
        RETURN;
    END;

    DECLARE @body NVARCHAR(MAX) = N'';
    DECLARE @row INT = 1;
    WHILE @row <= @RowCount
    BEGIN
        DECLARE @rowSelect NVARCHAR(MAX) = N'SELECT ';
        DECLARE @first BIT = 1;

        DECLARE @cName SYSNAME, @cType SYSNAME, @cMax SMALLINT,
                @cPrec TINYINT, @cScale TINYINT, @cNull BIT,
                @cFkObj INT, @cFkCol SYSNAME;

        DECLARE ccur CURSOR LOCAL FAST_FORWARD FOR
            SELECT ColName, SqlTypeName, MaxLength, [Precision], Scale,
                   IsNullable, FkParentObjId, FkParentCol
            FROM @Cols
            WHERE IsRowVersion = 0
              AND IsComputed = 0
              AND IsGeneratedAlways = 0
              AND (HasDefault  = 0 OR FkParentObjId IS NOT NULL)
            ORDER BY ColOrdinal;
        OPEN ccur;
        FETCH NEXT FROM ccur INTO @cName, @cType, @cMax, @cPrec, @cScale, @cNull, @cFkObj, @cFkCol;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @first = 0 SET @rowSelect = @rowSelect + N', ';
            SET @first = 0;

            IF @cFkObj IS NOT NULL
            BEGIN
                -- Round-robin FK value: row N picks parent row ((N-1) mod parentRows).
                -- We don't know the live parent row count, so we use modulo @RowCount
                -- (since both child and parent get the same row count from this seeder).
                DECLARE @offset INT = (@row - 1) % @RowCount;
                SET @rowSelect = @rowSelect
                    + N'(SELECT ' + QUOTENAME(@cFkCol)
                    + N' FROM '
                    + QUOTENAME(OBJECT_SCHEMA_NAME(@cFkObj)) + N'.' + QUOTENAME(OBJECT_NAME(@cFkObj))
                    + N' ORDER BY ' + QUOTENAME(@cFkCol)
                    + N' OFFSET ' + CAST(@offset AS NVARCHAR(10)) + N' ROWS FETCH NEXT 1 ROWS ONLY)';
            END
            ELSE
            BEGIN
                -- Non-FK column: use the type-based generator.
                -- For non-nullable string types, suffix the row number so we
                -- don't violate any UNIQUE constraints the proc might rely on.
                DECLARE @baseVal NVARCHAR(400) =
                    TestGen.GetSampleValueLiteral(@cType, @cMax, @cPrec, @cScale, 0);

                IF LOWER(@cType) IN ('char','varchar','nchar','nvarchar')
                BEGIN
                    /*
                     * Build a string value that respects the column's max
                     * character length. sys.columns.max_length is in BYTES,
                     * so unicode types need a /2. -1 means MAX.
                     *
                     * Strategy:
                     *   - if room for 'X_NN' or more, use 'X_<row>' style
                     *     padded to the available width (helps uniqueness);
                     *   - if column is 1..3 chars, use just '<row>' digits;
                     *   - never produce a string longer than the column.
                     */
                    DECLARE @charLen INT =
                        CASE
                            WHEN @cMax = -1 THEN 200
                            WHEN LOWER(@cType) IN ('nchar','nvarchar') THEN @cMax / 2
                            ELSE @cMax
                        END;
                    IF @charLen IS NULL OR @charLen < 1 SET @charLen = 1;

                    DECLARE @nPrefix2 NVARCHAR(2) = N'';
                    IF LOWER(@cType) IN ('nchar','nvarchar') SET @nPrefix2 = N'N';

                    DECLARE @rowStr NVARCHAR(20) = CAST(@row AS NVARCHAR(20));
                    DECLARE @raw    NVARCHAR(220);

                    IF @charLen >= LEN(N'X_' + @rowStr)
                    BEGIN
                        -- pad up to 12 chars or column length, whichever smaller
                        DECLARE @target INT = CASE WHEN @charLen > 12 THEN 12 ELSE @charLen END;
                        SET @raw = LEFT(N'SampleText_' + @rowStr + REPLICATE(N'X', @target), @target);
                        -- ensure the row digits are preserved at the end so values
                        -- stay distinct: replace last LEN(@rowStr) chars with @rowStr
                        IF LEN(@raw) >= LEN(@rowStr)
                            SET @raw = LEFT(@raw, LEN(@raw) - LEN(@rowStr)) + @rowStr;
                    END
                    ELSE IF @charLen >= LEN(@rowStr)
                    BEGIN
                        SET @raw = RIGHT(REPLICATE(N'0', @charLen) + @rowStr, @charLen);
                    END
                    ELSE
                    BEGIN
                        -- Column is 1..(LEN(rowStr)-1) chars: just take the
                        -- last @charLen digits of @row. With @RowCount <= 100,
                        -- and @charLen >= 1, this still produces distinct values
                        -- for rows 1..9 if @charLen = 1, etc.
                        SET @raw = RIGHT(@rowStr, @charLen);
                    END;

                    -- escape any single quotes (none in our generated values, but
                    -- safer for any future template change)
                    SET @raw = REPLACE(@raw, N'''', N'''''');
                    SET @baseVal = @nPrefix2 + N'''' + @raw + N'''';
                END
                ELSE IF LOWER(@cType) IN ('int','bigint','smallint','tinyint')
                BEGIN
                    SET @baseVal = CAST(@row AS NVARCHAR(10));
                END
                ELSE IF LOWER(@cType) IN ('decimal','numeric','money','smallmoney','float','real')
                BEGIN
                    SET @baseVal = CAST(@row AS NVARCHAR(10)) + N'.50';
                END;

                SET @rowSelect = @rowSelect + @baseVal;
            END;

            FETCH NEXT FROM ccur INTO @cName, @cType, @cMax, @cPrec, @cScale, @cNull, @cFkObj, @cFkCol;
        END;
        CLOSE ccur; DEALLOCATE ccur;

        IF @row > 1 SET @body = @body + @CRLF + N'UNION ALL ';
        SET @body = @body + @rowSelect;

        SET @row = @row + 1;
    END;

    SET @InsertSql =
        N'INSERT ' + @full + N' (' + @colList + N')' + @CRLF + @body + N';' + @CRLF;
END;
GO

PRINT 'TestGen.BuildSeedInsertForTable installed.';
GO


/* === 07_Seed_FakedTables.sql === */
/******************************************************************************
 * TestGen.SeedFakedTables
 * ----------------------------------------------------------------------------
 * Populates a set of tSQLt-faked tables with deterministic sample data.
 *
 * Behaviour:
 *   - 5 rows per table (configurable via @RowCount).
 *   - For each table, columns are filled as follows:
 *       * Identity column        -> explicit values 1..N (FakeTable drops identity
 *                                   property by default, so this is just an INT).
 *       * Foreign-key column     -> a value taken from the parent table that is
 *                                   ALSO in the faked set. Round-robins across
 *                                   parent rows so every parent row is referenced.
 *                                   FKs to non-faked tables are ignored because
 *                                   FakeTable already dropped the constraint.
 *       * Other NOT NULL column  -> deterministic value derived from the column's
 *                                   data type (see TestGen.GetSampleValueLiteral
 *                                   variant 0, with row-index suffixing for
 *                                   string types so we don't violate uniqueness).
 *       * Nullable column        -> NULL.
 *   - Tables are topologically sorted by intra-set FK dependencies so parents
 *     are always seeded before children. Cycles are broken arbitrarily; the
 *     seeder logs a warning and seeds the cycle members with NULL FK values
 *     (only possible when the FK column is nullable).
 *
 * Usage in a generated test:
 *
 *     EXEC tSQLt.FakeTable @TableName = N'dbo.Orders';
 *     EXEC tSQLt.FakeTable @TableName = N'dbo.Customers';
 *     EXEC TestGen.SeedFakedTables
 *          @TableList = N'dbo.Customers,dbo.Orders';
 *     EXEC dbo.PlaceOrder @CustomerId = 1, @Total = 99.95, @NewOrderId = @id OUTPUT;
 *
 * Parameters:
 *   @TableList   Comma-separated list of schema.table names. Must match
 *                the tables passed to FakeTable in the same test.
 *   @RowCount    Rows to insert per table. Default 5.
 *   @Verbose     1 = PRINT progress and the generated INSERT statements.
 ******************************************************************************/
IF OBJECT_ID('TestGen.SeedFakedTables', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.SeedFakedTables;
GO

CREATE PROCEDURE TestGen.SeedFakedTables
    @TableList NVARCHAR(MAX),
    @RowCount  INT = 5,
    @Verbose   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @RowCount < 1 OR @RowCount > 100
    BEGIN
        RAISERROR('SeedFakedTables: @RowCount must be between 1 and 100.', 16, 1);
        RETURN;
    END;

    /* ----------------------------------------------------------------
     * 1. Parse the comma-separated table list into (schema, name) rows.
     *    Resolves to original-table object_id (FakeTable preserves the
     *    object name, so OBJECT_ID still works after faking).
     * ---------------------------------------------------------------*/
    DECLARE @Tables TABLE
    (
        Ord         INT IDENTITY(1,1) PRIMARY KEY,
        SchemaName  SYSNAME,
        TableName   SYSNAME,
        FullName    NVARCHAR(300),
        ObjectId    INT  NULL,
        SeedOrder   INT  NULL    -- filled in by topological sort
    );

    ;WITH split AS
    (
        SELECT LTRIM(RTRIM(value)) AS FullName
        FROM STRING_SPLIT(@TableList, ',')
        WHERE LTRIM(RTRIM(value)) <> ''
    )
    INSERT @Tables (SchemaName, TableName, FullName, ObjectId)
    SELECT
        PARSENAME(FullName, 2),
        PARSENAME(FullName, 1),
        FullName,
        OBJECT_ID(FullName)
    FROM split;

    IF EXISTS (SELECT 1 FROM @Tables WHERE ObjectId IS NULL)
    BEGIN
        DECLARE @missing NVARCHAR(MAX) =
            (SELECT STRING_AGG(FullName, ', ') FROM @Tables WHERE ObjectId IS NULL);
        RAISERROR('SeedFakedTables: cannot resolve table(s): %s', 16, 1, @missing);
        RETURN;
    END;

    /* ----------------------------------------------------------------
     * 2. Discover FK relationships *between tables in our set*.
     *    A relationship is a single (childCol -> parentTable.parentCol)
     *    edge; composite FKs become multiple rows sharing FkId.
     * ---------------------------------------------------------------*/
    DECLARE @Edges TABLE
    (
        FkId         INT,
        ChildObjId   INT,
        ChildCol     SYSNAME,
        ParentObjId  INT,
        ParentCol    SYSNAME
    );

    INSERT @Edges
    SELECT
        fk.object_id                                AS FkId,
        fkc.parent_object_id                        AS ChildObjId,
        cc.name                                     AS ChildCol,
        fkc.referenced_object_id                    AS ParentObjId,
        pc.name                                     AS ParentCol
    FROM sys.foreign_keys fk
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
    JOIN sys.columns cc ON cc.object_id = fkc.parent_object_id     AND cc.column_id = fkc.parent_column_id
    JOIN sys.columns pc ON pc.object_id = fkc.referenced_object_id AND pc.column_id = fkc.referenced_column_id
    WHERE fkc.parent_object_id     IN (SELECT ObjectId FROM @Tables)
      AND fkc.referenced_object_id IN (SELECT ObjectId FROM @Tables)
      AND fkc.parent_object_id <> fkc.referenced_object_id;   -- ignore self-FKs

    /* ----------------------------------------------------------------
     * 3. Topological sort: Kahn's algorithm.
     *    "Parents first" => start with tables that have no parent in
     *    the set and remove edges as we go.
     * ---------------------------------------------------------------*/
    DECLARE @order INT = 0;
    WHILE EXISTS (SELECT 1 FROM @Tables WHERE SeedOrder IS NULL)
    BEGIN
        DECLARE @nextId INT =
        (
            SELECT TOP 1 t.ObjectId
            FROM @Tables t
            WHERE t.SeedOrder IS NULL
              AND NOT EXISTS
              (
                  SELECT 1 FROM @Edges e
                  JOIN @Tables tp ON tp.ObjectId = e.ParentObjId
                  WHERE e.ChildObjId = t.ObjectId
                    AND tp.SeedOrder IS NULL          -- parent not yet seeded
              )
            ORDER BY t.Ord
        );

        IF @nextId IS NULL
        BEGIN
            -- Cycle: pick the lowest-ord remaining and break the cycle.
            SET @nextId = (SELECT TOP 1 ObjectId FROM @Tables WHERE SeedOrder IS NULL ORDER BY Ord);
            IF @Verbose = 1
                PRINT 'SeedFakedTables: FK cycle detected, breaking arbitrarily at object_id ' + CAST(@nextId AS VARCHAR(20));
        END;

        SET @order = @order + 1;
        UPDATE @Tables SET SeedOrder = @order WHERE ObjectId = @nextId;
    END;

    /* ----------------------------------------------------------------
     * 4. For each table in seed order, build and execute an INSERT.
     * ---------------------------------------------------------------*/
    DECLARE @curObjId INT, @curSchema SYSNAME, @curTable SYSNAME, @curFull NVARCHAR(300);

    DECLARE seedcur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ObjectId, SchemaName, TableName, FullName
        FROM @Tables
        ORDER BY SeedOrder;
    OPEN seedcur;
    FETCH NEXT FROM seedcur INTO @curObjId, @curSchema, @curTable, @curFull;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @insertSql NVARCHAR(MAX);
        EXEC TestGen.BuildSeedInsertForTable
             @ObjectId  = @curObjId,
             @TableSet  = @TableList,   -- so the builder knows which parents to draw FK values from
             @RowCount  = @RowCount,
             @InsertSql = @insertSql OUTPUT;

        IF @Verbose = 1
        BEGIN
            PRINT '--- SeedFakedTables: ' + @curFull + ' ---';
            PRINT @insertSql;
        END;

        EXEC sp_executesql @insertSql;

        FETCH NEXT FROM seedcur INTO @curObjId, @curSchema, @curTable, @curFull;
    END;
    CLOSE seedcur; DEALLOCATE seedcur;
END;
GO

PRINT 'TestGen.SeedFakedTables installed.';
GO


/* === 09_Clear_SchemaBound_Refs.sql === */
/******************************************************************************
 * TestGen.ClearSchemaBoundReferences
 * ----------------------------------------------------------------------------
 * tSQLt.FakeTable renames the real table out of the way. SQL Server forbids
 * that rename whenever another object schema-binds to it (typical culprits:
 * WITH SCHEMABINDING views, persisted computed columns referencing UDFs).
 *
 * tSQLt has a built-in @SchemaBoundDependencies = 1 switch that tries to drop
 * the schema-binding on referencing objects before the rename. It works for
 * most simple cases but cannot rebuild views that reference multiple faked
 * tables, and it errors out on persisted computed columns.
 *
 * This helper is a more aggressive alternative: it temporarily DROPs every
 * referencing object with a schema-bound dependency on @SchemaName.@TableName.
 * Because tSQLt runs each test inside an outer transaction, the drops are
 * rolled back automatically when the test ends - no permanent damage.
 *
 * Use:
 *   EXEC TestGen.ClearSchemaBoundReferences N'Production.Product';
 *   EXEC tSQLt.FakeTable N'Production.Product', @SchemaBoundDependencies = 1;
 *
 * Pass @WhatIf = 1 to PRINT what would be dropped without actually dropping.
 ******************************************************************************/
IF OBJECT_ID('TestGen.ClearSchemaBoundReferences', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ClearSchemaBoundReferences;
GO

CREATE PROCEDURE TestGen.ClearSchemaBoundReferences
    @TableFullName NVARCHAR(300),
    @WhatIf        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ObjId INT = OBJECT_ID(@TableFullName);
    IF @ObjId IS NULL
    BEGIN
        RAISERROR('ClearSchemaBoundReferences: table %s not found.', 16, 1, @TableFullName);
        RETURN;
    END;

    -- IMPORTANT: rolling back is on the caller's transaction. If we are
    -- invoked OUTSIDE a transaction, we refuse - dropping schema-bound
    -- views permanently would be a disaster on a production database.
    IF @@TRANCOUNT = 0 AND @WhatIf = 0
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'ClearSchemaBoundReferences must be called inside a transaction. '
          + N'tSQLt provides one automatically per test. Refusing to run.';
        RAISERROR(@msg, 16, 1);
        RETURN;
    END;

    DECLARE @drops TABLE (Sql NVARCHAR(MAX), ReferencingName NVARCHAR(300));

    INSERT @drops (Sql, ReferencingName)
    SELECT
        N'DROP ' +
        CASE o.type
            WHEN 'V'  THEN N'VIEW '
            WHEN 'FN' THEN N'FUNCTION '
            WHEN 'IF' THEN N'FUNCTION '
            WHEN 'TF' THEN N'FUNCTION '
            WHEN 'P'  THEN N'PROCEDURE '
            ELSE N'OBJECT '
        END
        + QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id))
        + N'.' + QUOTENAME(o.name) + N';',
        QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id)) + N'.' + QUOTENAME(o.name)
    FROM sys.sql_expression_dependencies d
    JOIN sys.objects o ON o.object_id = d.referencing_id
    WHERE d.referenced_id = @ObjId
      AND d.is_schema_bound_reference = 1
      AND o.type IN ('V','FN','IF','TF','P');

    IF NOT EXISTS (SELECT 1 FROM @drops)
    BEGIN
        IF @WhatIf = 1
            PRINT 'ClearSchemaBoundReferences: nothing to do for ' + @TableFullName + '.';
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX), @name NVARCHAR(300);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Sql, ReferencingName FROM @drops;
    OPEN cur;
    FETCH NEXT FROM cur INTO @sql, @name;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @WhatIf = 1
            PRINT 'WOULD DROP: ' + @name;
        ELSE
        BEGIN
            -- A previous call to this helper (for a sibling faked table)
            -- may already have dropped this referent. Skip silently if so.
            IF OBJECT_ID(@name) IS NULL
            BEGIN
                FETCH NEXT FROM cur INTO @sql, @name;
                CONTINUE;
            END;

            BEGIN TRY
                EXEC sp_executesql @sql;
                PRINT 'Cleared schema-bound dependency: ' + @name + ' (transaction will restore it).';
            END TRY
            BEGIN CATCH
                PRINT 'Could not drop ' + @name + ': ' + ERROR_MESSAGE();
            END CATCH;
        END;
        FETCH NEXT FROM cur INTO @sql, @name;
    END;
    CLOSE cur; DEALLOCATE cur;
END;
GO

PRINT 'TestGen.ClearSchemaBoundReferences installed.';
GO


/* === 10_Safe_FakeTable.sql === */
/******************************************************************************
 * TestGen.SafeFakeTable
 * ----------------------------------------------------------------------------
 * A version-tolerant wrapper around tSQLt.FakeTable. Tries the richest
 * argument list the official tSQLt supports, falling back through
 * progressively smaller signatures if the build is older.
 *
 * Note: @SchemaBoundDependencies is NOT a real official tSQLt parameter.
 *       Some community forks add it; the upstream release does not. We
 *       handle SCHEMABINDING entirely via TestGen.ClearSchemaBoundReferences
 *       and never pass that argument to FakeTable.
 *
 * Attempt order:
 *     1. @TableName + @Identity + @ComputedColumns + @Defaults
 *     2. @TableName + @Identity
 *     3. @TableName
 ******************************************************************************/
IF OBJECT_ID('TestGen.SafeFakeTable', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.SafeFakeTable;
GO

CREATE PROCEDURE TestGen.SafeFakeTable
    @TableName NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @lastErr NVARCHAR(2000) = N'';
    DECLARE @ok BIT = 0;

    /* v0.13.x: a table referenced by a SCHEMA-BOUND object (indexed view, a
       WITH SCHEMABINDING view/function, or a schema-bound computed column) cannot
       be renamed by tSQLt.FakeTable -> Msg 15336 "participates in enforced
       dependencies", which otherwise aborts the whole test/generation run. Drop
       those dependents here, deepest-first. tSQLt wraps every test in a
       transaction that ROLLS BACK, so they are restored automatically when the
       test ends - no permanent change to the database.

       HARDENING: this cleanup must NEVER doom the test transaction. tSQLt runs
       tests with XACT_ABORT ON, under which ANY error here dooms the transaction -
       a TRY/CATCH swallows the message but cannot un-doom it, so every later fake
       then fails with "the current transaction cannot be committed". A persisted
       computed column makes a table reference ITSELF as schema-bound, so the
       recursive walk used to hit MAXRECURSION and doom the transaction. Fixes:
         (1) SET XACT_ABORT OFF for the duration (auto-restored on proc exit), so a
             swallowed error here leaves the transaction usable; and
         (2) a cycle-guarded recursive walk that ignores the table's self-edge, so
             the walk terminates instead of erroring. */
    SET XACT_ABORT OFF;
    BEGIN TRY
        DECLARE @ffObj INT = OBJECT_ID(@TableName);
        IF @ffObj IS NOT NULL
           AND EXISTS (SELECT 1 FROM sys.sql_expression_dependencies
                       WHERE referenced_id = @ffObj AND is_schema_bound_reference = 1
                         AND referencing_id <> @ffObj)
        BEGIN
            IF OBJECT_ID('tempdb..#sbdep') IS NOT NULL DROP TABLE #sbdep;
            ;WITH dep AS (
                SELECT d.referencing_id AS id, 1 AS lvl,
                       CAST('|' + CAST(d.referencing_id AS VARCHAR(20)) + '|' AS VARCHAR(8000)) AS pth
                FROM sys.sql_expression_dependencies d
                WHERE d.referenced_id = @ffObj
                  AND d.is_schema_bound_reference = 1
                  AND d.referencing_id <> @ffObj           -- ignore self-reference (persisted computed column)
                UNION ALL
                SELECT d.referencing_id, dep.lvl + 1,
                       dep.pth + CAST(d.referencing_id AS VARCHAR(20)) + '|'
                FROM sys.sql_expression_dependencies d
                JOIN dep ON d.referenced_id = dep.id
                WHERE d.is_schema_bound_reference = 1
                  AND d.referencing_id <> @ffObj
                  AND dep.pth NOT LIKE '%|' + CAST(d.referencing_id AS VARCHAR(20)) + '|%'   -- cycle guard
            )
            SELECT id, MAX(lvl) AS lvl INTO #sbdep FROM dep GROUP BY id OPTION (MAXRECURSION 256);

            DECLARE @sbName NVARCHAR(400), @sbType CHAR(2), @sbDrop NVARCHAR(700);
            DECLARE sbcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT QUOTENAME(s.name) + N'.' + QUOTENAME(o.name), o.type
                FROM #sbdep x
                JOIN sys.objects o ON o.object_id = x.id
                JOIN sys.schemas s ON s.schema_id = o.schema_id
                WHERE o.type IN ('V','FN','IF','TF','FS','FT')   -- schema-bound view / function
                ORDER BY x.lvl DESC;                              -- deepest dependents first
            OPEN sbcur; FETCH NEXT FROM sbcur INTO @sbName, @sbType;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @sbDrop = CASE WHEN @sbType = 'V' THEN N'DROP VIEW ' ELSE N'DROP FUNCTION ' END + @sbName;
                BEGIN TRY EXEC (@sbDrop); END TRY BEGIN CATCH END CATCH;
                FETCH NEXT FROM sbcur INTO @sbName, @sbType;
            END;
            CLOSE sbcur; DEALLOCATE sbcur;
            DROP TABLE #sbdep;
        END;
    END TRY BEGIN CATCH END CATCH;
    SET XACT_ABORT ON;   -- restore the mode tSQLt runs tests under

    /* Attempt 1: full signature against the official tSQLt release */
    IF @ok = 0
    BEGIN
        BEGIN TRY
            EXEC tSQLt.FakeTable
                 @TableName       = @TableName,
                 @Identity        = 0,
                 @ComputedColumns = 0,
                 @Defaults        = 1;
            SET @ok = 1;
        END TRY
        BEGIN CATCH
            SET @lastErr = ERROR_MESSAGE();
        END CATCH;
    END;

    /* Attempt 2: just kill identity */
    IF @ok = 0
    BEGIN
        BEGIN TRY
            EXEC tSQLt.FakeTable @TableName = @TableName, @Identity = 0;
            SET @ok = 1;
        END TRY
        BEGIN CATCH
            SET @lastErr = ERROR_MESSAGE();
        END CATCH;
    END;

    /* Attempt 3: minimum viable call */
    IF @ok = 0
    BEGIN
        BEGIN TRY
            EXEC tSQLt.FakeTable @TableName = @TableName;
            SET @ok = 1;
        END TRY
        BEGIN CATCH
            SET @lastErr = ERROR_MESSAGE();
        END CATCH;
    END;

    IF @ok = 0
    BEGIN
        DECLARE @msg NVARCHAR(2400) =
            N'SafeFakeTable: all attempts to fake ' + @TableName + N' failed. Last error: ' + @lastErr;
        RAISERROR(@msg, 16, 1);
        RETURN;
    END;
END;
GO

PRINT 'TestGen.SafeFakeTable installed.';
GO


/* === 11_Baseline_Tables.sql === */
/******************************************************************************
 * Baseline storage for assert-on-result-set generation.
 * ----------------------------------------------------------------------------
 * Two tables, both under TestGenLog:
 *
 *   ResultShapeBaseline
 *       One row per (test class, ordinal column) capturing the column name,
 *       data type, max length, precision, scale, and nullability the proc is
 *       expected to return. Created from the first successful run of the
 *       generated shape-assertion test, then used as the source of truth on
 *       subsequent runs.
 *
 *   ResultRowsBaseline
 *       One row per (test class, row ordinal) capturing a JSON-encoded
 *       snapshot of the proc's first-result-set output. Used by the
 *       "golden" test only when @CaptureRows = 1 was passed to the
 *       generator.
 *
 * Both are indexed by ClassName + ordinal so lookups in the assertion
 * helpers are point-reads.
 ******************************************************************************/

IF OBJECT_ID('TestGenLog.ResultShapeBaseline', 'U') IS NOT NULL
    DROP TABLE TestGenLog.ResultShapeBaseline;
GO

CREATE TABLE TestGenLog.ResultShapeBaseline
(
    BaselineId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ResultShapeBaseline PRIMARY KEY,
    TestClass    SYSNAME            NOT NULL,
    ColumnOrdinal INT               NOT NULL,
    ColumnName   SYSNAME            NULL,           -- the proc may return unnamed columns
    SqlTypeName  SYSNAME            NOT NULL,
    MaxLength    SMALLINT           NULL,
    [Precision]  TINYINT            NULL,
    Scale        TINYINT            NULL,
    IsNullable   BIT                NOT NULL,
    CapturedAt   DATETIME2(3)       NOT NULL CONSTRAINT DF_ShapeBaseline_CapturedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ResultShapeBaseline UNIQUE (TestClass, ColumnOrdinal)
);
GO

IF OBJECT_ID('TestGenLog.ResultRowsBaseline', 'U') IS NOT NULL
    DROP TABLE TestGenLog.ResultRowsBaseline;
GO

CREATE TABLE TestGenLog.ResultRowsBaseline
(
    BaselineId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ResultRowsBaseline PRIMARY KEY,
    TestClass    SYSNAME            NOT NULL,
    RowOrdinal   INT                NOT NULL,
    RowJson      NVARCHAR(MAX)      NOT NULL,
    CapturedAt   DATETIME2(3)       NOT NULL CONSTRAINT DF_RowsBaseline_CapturedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ResultRowsBaseline UNIQUE (TestClass, RowOrdinal)
);
GO

PRINT 'Baseline tables installed.';
GO


/* === 12_Result_Shape_Helpers.sql === */
/******************************************************************************
 * TestGen.CaptureResultShape  /  TestGen.AssertResultShape
 * ----------------------------------------------------------------------------
 * These helpers let generated tests assert that a procedure's first-result-set
 * shape is stable across runs.
 *
 *   CaptureResultShape: writes the current shape of @ExecSql's result set
 *                       into TestGenLog.ResultShapeBaseline under @TestClass.
 *                       Idempotent: overwrites previous rows for that class.
 *
 *   AssertResultShape:  runs @ExecSql, compares the resulting shape to the
 *                       baseline, and calls tSQLt.Fail with a diff if they
 *                       don't match. On the very first run (no baseline
 *                       yet), it captures + passes - "auto-bless" mode.
 *
 * Shape detection uses sys.dm_exec_describe_first_result_set which is the
 * supported way to inspect a proc's first result set without executing it.
 ******************************************************************************/

IF OBJECT_ID('TestGen.CaptureResultShape', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.CaptureResultShape;
GO

CREATE PROCEDURE TestGen.CaptureResultShape
    @TestClass SYSNAME,
    @ExecSql   NVARCHAR(MAX)         -- e.g. N'EXEC dbo.MyProc @p = 1'
AS
BEGIN
    SET NOCOUNT ON;

    -- Wipe any previous baseline for this test class.
    DELETE FROM TestGenLog.ResultShapeBaseline WHERE TestClass = @TestClass;

    INSERT TestGenLog.ResultShapeBaseline
           (TestClass, ColumnOrdinal, ColumnName, SqlTypeName, MaxLength,
            [Precision], Scale, IsNullable)
    SELECT
        @TestClass,
        column_ordinal,
        name,
        system_type_name,
        max_length,
        [precision],
        scale,
        is_nullable
    FROM sys.dm_exec_describe_first_result_set(@ExecSql, NULL, 0);
END;
GO

IF OBJECT_ID('TestGen.AssertResultShape', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.AssertResultShape;
GO

CREATE PROCEDURE TestGen.AssertResultShape
    @TestClass SYSNAME,
    @ExecSql   NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BaselineRows INT =
        (SELECT COUNT(*) FROM TestGenLog.ResultShapeBaseline WHERE TestClass = @TestClass);

    -- First-run path: capture and pass.
    IF @BaselineRows = 0
    BEGIN
        EXEC TestGen.CaptureResultShape @TestClass = @TestClass, @ExecSql = @ExecSql;
        PRINT 'AssertResultShape: no baseline for ' + @TestClass
            + ' - captured ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' column(s) as baseline.';
        RETURN;
    END;

    -- Subsequent runs: build #Expected/#Actual shape tables and let
    -- tSQLt.AssertEqualsTable do the diff so the failure output matches
    -- what users get from hand-written tSQLt tests.
    -- v0.9.11: IsNullable is intentionally EXCLUDED from the shape comparison.
    -- SQL Server's nullability inference for literal / computed result columns
    -- (e.g. SELECT 'x' AS Arm) is unstable - it flips True<->False across
    -- recompiles, builds and call contexts - so comparing it produced
    -- false-positive "shape drift" (every pz gate failed on exactly this). The
    -- shape contract that actually matters - column count, order, names, types
    -- and sizes - is still asserted in full. Nullability is still recorded in the
    -- baseline (TestGenLog.ResultShapeBaseline) for information, just not compared.
    CREATE TABLE #ExpectedShape
    (
        ColumnOrdinal INT,
        ColumnName    SYSNAME NULL,
        SqlTypeName   SYSNAME,
        MaxLength     SMALLINT,
        [Precision]   TINYINT,
        Scale         TINYINT
    );
    CREATE TABLE #ActualShape
    (
        ColumnOrdinal INT,
        ColumnName    SYSNAME NULL,
        SqlTypeName   SYSNAME,
        MaxLength     SMALLINT,
        [Precision]   TINYINT,
        Scale         TINYINT
    );

    INSERT #ExpectedShape (ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale)
    SELECT ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale
    FROM TestGenLog.ResultShapeBaseline
    WHERE TestClass = @TestClass;

    INSERT #ActualShape (ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale)
    SELECT column_ordinal, name,
           -- v9.4.3: compare the BARE type name to match the baseline, which
           -- stores TYPE_NAME() with no length/precision suffix.  dm_exec_describe
           -- returns the full form such as nvarchar followed by (40); strip from
           -- the open paren CHAR(40) onward so only the type name is compared.
           -- Size is still asserted via MaxLength/Precision/Scale, nothing lost.
           LEFT(system_type_name,
                ISNULL(NULLIF(CHARINDEX(CHAR(40), system_type_name), 0) - 1, LEN(system_type_name))),
           max_length, [precision], scale
    FROM sys.dm_exec_describe_first_result_set(@ExecSql, NULL, 0);

    DECLARE @msg NVARCHAR(400) =
        N'Result-set shape drift for ' + @TestClass
      + N'. Re-bless with: EXEC TestGen.BlessBaseline ''' + @TestClass + N''', ''Shape''';

    EXEC tSQLt.AssertEqualsTable
         @Expected = '#ExpectedShape',
         @Actual   = '#ActualShape',
         @FailMsg  = @msg;
END;
GO

PRINT 'TestGen.CaptureResultShape / AssertResultShape installed.';
GO


/* === 13_Result_Rows_Helpers.sql === */
/******************************************************************************
 * TestGen.AssertResultRowsMatchBaseline  (v2 - tSQLt.AssertEqualsTable based)
 * ----------------------------------------------------------------------------
 * The "AssertEqualsTable" of the auto-generated framework, delegating to
 * tSQLt.AssertEqualsTable so failures look exactly like hand-written
 * tSQLt tests - including the side-by-side "expected vs actual" diff that
 * CI tools and humans both expect.
 *
 * Caller contract:
 *   - Caller has already created a temp table named #ActualResult (or
 *     whatever name was passed via @ActualTable) and INSERTed the proc's
 *     output into it.
 *   - The shape of #ActualResult must match what the generator used.
 *
 * Flow:
 *   1. If no shape baseline yet -> capture shape (from the actual table)
 *      and rows, then pass (auto-bless).
 *   2. Otherwise:
 *      a. Build a #Expected temp table with the column DDL reconstructed
 *         from ResultShapeBaseline.
 *      b. Hydrate #Expected from ResultRowsBaseline.RowJson via OPENJSON.
 *      c. EXEC tSQLt.AssertEqualsTable '#Expected', '#ActualResult'.
 ******************************************************************************/

IF OBJECT_ID('TestGen.CaptureResultRows', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.CaptureResultRows;
GO

CREATE PROCEDURE TestGen.CaptureResultRows
    @TestClass     SYSNAME,
    @ActualTable   SYSNAME = N'#ActualResult'
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM TestGenLog.ResultRowsBaseline WHERE TestClass = @TestClass;

    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT TestGenLog.ResultRowsBaseline (TestClass, RowOrdinal, RowJson)
        SELECT ' + QUOTENAME(@TestClass, '''') + N',
               ROW_NUMBER() OVER (ORDER BY (SELECT 1)),
               (SELECT t.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
        FROM ' + @ActualTable + N' AS t;';

    EXEC (@sql);
END;
GO

/*---------------------------------------------------------------------------
 * Helper function used by the dynamic SQL inside the assertion helper.
 * Reconstructs a usable T-SQL type literal from the components stored in
 * the shape baseline.
 *
 * Living in dbo so the dynamic SQL can reference it without schema
 * permission surprises. If you'd rather keep it under TestGen, rename
 * here and in the dynamic SQL block below.
 *--------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.TestGen_RebuildTypeName', 'FN') IS NOT NULL
    DROP FUNCTION dbo.TestGen_RebuildTypeName;
GO

CREATE FUNCTION dbo.TestGen_RebuildTypeName
(
    @SqlTypeName SYSNAME,
    @MaxLength   SMALLINT,
    @Precision   TINYINT,
    @Scale       TINYINT
)
RETURNS NVARCHAR(200)
AS
BEGIN
    DECLARE @t SYSNAME = LOWER(@SqlTypeName);

    -- DMV-sourced type names sometimes already include length (e.g. "nvarchar(50)").
    -- If so, return as-is to avoid double-encoding.
    IF CHARINDEX('(', @SqlTypeName) > 0
        RETURN UPPER(@SqlTypeName);

    IF @t IN ('char','varchar','binary','varbinary')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength AS NVARCHAR(10)) END + N')';

    IF @t IN ('nchar','nvarchar')
        RETURN UPPER(@t) + N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CAST(@MaxLength/2 AS NVARCHAR(10)) END + N')';

    IF @t IN ('decimal','numeric')
        RETURN UPPER(@t) + N'(' + CAST(@Precision AS NVARCHAR(10)) + N',' + CAST(@Scale AS NVARCHAR(10)) + N')';

    IF @t IN ('datetime2','datetimeoffset','time')
        RETURN UPPER(@t) + N'(' + CAST(@Scale AS NVARCHAR(10)) + N')';

    RETURN UPPER(@t);
END;
GO

IF OBJECT_ID('TestGen.AssertResultRowsMatchBaseline', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.AssertResultRowsMatchBaseline;
GO

CREATE PROCEDURE TestGen.AssertResultRowsMatchBaseline
    @TestClass    SYSNAME,
    @ActualTable  SYSNAME = N'#ActualResult'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ShapeRows INT =
        (SELECT COUNT(*) FROM TestGenLog.ResultShapeBaseline WHERE TestClass = @TestClass);

    /* ----------------------------------------------------------------
     * First-run path: capture shape AND rows, then pass.
     * We pull shape from tempdb.sys.columns of the caller's #Actual
     * because that is the most reliable source for tempdb column names
     * and types.
     * --------------------------------------------------------------*/
    IF @ShapeRows = 0
    BEGIN
        DECLARE @captureShapeSql NVARCHAR(MAX) = N'
            INSERT TestGenLog.ResultShapeBaseline
                   (TestClass, ColumnOrdinal, ColumnName, SqlTypeName,
                    MaxLength, [Precision], Scale, IsNullable)
            SELECT
                ' + QUOTENAME(@TestClass, '''') + N',
                c.column_id,
                c.name,
                TYPE_NAME(c.user_type_id),
                c.max_length,
                c.precision,
                c.scale,
                c.is_nullable
            FROM tempdb.sys.columns c
            WHERE c.object_id = OBJECT_ID(''tempdb..' + @ActualTable + N''')
            ORDER BY c.column_id;';
        EXEC (@captureShapeSql);

        EXEC TestGen.CaptureResultRows @TestClass = @TestClass, @ActualTable = @ActualTable;

        DECLARE @cShape INT =
            (SELECT COUNT(*) FROM TestGenLog.ResultShapeBaseline WHERE TestClass = @TestClass);
        DECLARE @cRows INT =
            (SELECT COUNT(*) FROM TestGenLog.ResultRowsBaseline WHERE TestClass = @TestClass);

        PRINT 'AssertResultRowsMatchBaseline: no baseline for ' + @TestClass
            + ' - captured shape (' + CAST(@cShape AS VARCHAR(10))
            + ' cols) and rows ('   + CAST(@cRows  AS VARCHAR(10))
            + ').';
        RETURN;
    END;

    /* ----------------------------------------------------------------
     * Reconstruction path:
     *   - column DDL for #Expected
     *   - OPENJSON WITH (...) typed column list to extract from baseline rows
     *   - INSERT column list (same names, used twice)
     * --------------------------------------------------------------*/
    DECLARE @columnDdl    NVARCHAR(MAX) = N'';
    DECLARE @openJsonCols NVARCHAR(MAX) = N'';
    DECLARE @insertCols   NVARCHAR(MAX) = N'';

    SELECT
        @columnDdl    = @columnDdl    + N',' + QUOTENAME(ColumnName) + N' '
                                      + dbo.TestGen_RebuildTypeName(SqlTypeName, MaxLength, [Precision], Scale)
                                      + CASE WHEN IsNullable = 1 THEN N' NULL' ELSE N' NOT NULL' END,
        @openJsonCols = @openJsonCols + N',' + QUOTENAME(ColumnName) + N' '
                                      + dbo.TestGen_RebuildTypeName(SqlTypeName, MaxLength, [Precision], Scale)
                                      + N' ''$.' + ColumnName + N'''',
        @insertCols   = @insertCols   + N',' + QUOTENAME(ColumnName)
    FROM TestGenLog.ResultShapeBaseline
    WHERE TestClass = @TestClass
    ORDER BY ColumnOrdinal;

    SET @columnDdl    = STUFF(@columnDdl,    1, 1, N'');
    SET @openJsonCols = STUFF(@openJsonCols, 1, 1, N'');
    SET @insertCols   = STUFF(@insertCols,   1, 1, N'');

    DECLARE @failMsg NVARCHAR(400) =
        N'Result rows do not match baseline. Re-bless with: '
      + N'EXEC TestGen.BlessBaseline ''' + @TestClass + N'''';

    DECLARE @sql NVARCHAR(MAX) = N'
        CREATE TABLE #Expected (' + @columnDdl + N');

        INSERT #Expected (' + @insertCols + N')
        SELECT ' + @insertCols + N'
        FROM TestGenLog.ResultRowsBaseline b
        CROSS APPLY OPENJSON(b.RowJson)
                    WITH (' + @openJsonCols + N') AS j
        WHERE b.TestClass = ' + QUOTENAME(@TestClass, '''') + N'
        ORDER BY b.RowOrdinal;

        EXEC tSQLt.AssertEqualsTable
             @Expected = ''#Expected'',
             @Actual   = ''' + @ActualTable + N''',
             @FailMsg  = ' + QUOTENAME(@failMsg, '''') + N';';

    EXEC (@sql);
END;
GO

PRINT 'TestGen.CaptureResultRows / AssertResultRowsMatchBaseline (v2) installed.';
GO


/* === 14_Bless_Baseline.sql === */
/******************************************************************************
 * TestGen.BlessBaseline
 * ----------------------------------------------------------------------------
 * After an intentional change to a stored procedure, the auto-generated
 * golden tests will fail because the baseline no longer matches the new
 * output. This procedure clears the baseline so the next test run
 * auto-captures fresh values. Run it once, re-run the test, you're back to
 * green.
 *
 * Parameters:
 *   @TestClass      Test class to bless (e.g. 'test_uspGetBillOfMaterials').
 *                   NULL = clear baselines for every test class.
 *   @Kind           'Shape' | 'Rows' | 'Both'  - default 'Both'.
 *
 * Usage:
 *   EXEC TestGen.BlessBaseline 'test_uspGetBillOfMaterials';
 *   EXEC tSQLt.Run 'test_uspGetBillOfMaterials';   -- captures + passes
 ******************************************************************************/
IF OBJECT_ID('TestGen.BlessBaseline', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.BlessBaseline;
GO

CREATE PROCEDURE TestGen.BlessBaseline
    @TestClass SYSNAME      = NULL,
    @Kind      VARCHAR(10)  = 'Both'
AS
BEGIN
    SET NOCOUNT ON;

    IF @Kind NOT IN ('Shape','Rows','Both')
    BEGIN
        RAISERROR('@Kind must be Shape, Rows, or Both.', 16, 1);
        RETURN;
    END;

    IF @Kind IN ('Shape','Both')
        DELETE FROM TestGenLog.ResultShapeBaseline
        WHERE @TestClass IS NULL OR TestClass = @TestClass;

    IF @Kind IN ('Rows','Both')
        DELETE FROM TestGenLog.ResultRowsBaseline
        WHERE @TestClass IS NULL OR TestClass = @TestClass;

    PRINT 'Baseline(s) cleared. Next test run will auto-capture and pass.';
END;
GO

PRINT 'TestGen.BlessBaseline installed.';
GO


/* === Result-baseline persistent capture (v11.x) === */
GO
CREATE OR ALTER PROCEDURE TestGen.CaptureResultBaseline
    @TestClass SYSNAME,
    @MockSql   NVARCHAR(MAX),    -- the FakeTable + seed block (same the test uses)
    @ExecSql   NVARCHAR(MAX)     -- e.g. N'EXEC dbo.MyProc @p = 1'
AS
BEGIN
    -- Persist the EXPECTED result baseline OUTSIDE any tSQLt per-test rollback, so
    -- the generated 'returns rows matching baseline' test ASSERTS instead of
    -- capturing-and-passing.  Fakes + seeds inside a savepoint, runs the proc,
    -- copies the rows into TABLE VARIABLES (which survive the rollback), rolls the
    -- faking back, then persists.  The real tables are never modified.
    SET NOCOUNT ON;
    DECLARE @ddl NVARCHAR(MAX) = N'';
    SELECT @ddl = @ddl + N', ' + QUOTENAME(ISNULL(name, N'Col'+CAST(column_ordinal AS NVARCHAR(5)))) + N' ' + system_type_name
    FROM sys.dm_exec_describe_first_result_set(@ExecSql, NULL, 0)
    WHERE name IS NOT NULL OR system_type_name IS NOT NULL
    ORDER BY column_ordinal;
    IF LEN(ISNULL(@ddl,N'')) = 0 BEGIN PRINT 'CaptureResultBaseline: no result set for ' + @TestClass; RETURN; END;
    SET @ddl = STUFF(@ddl,1,2,N'');

    IF OBJECT_ID('tempdb..##tgbase') IS NOT NULL DROP TABLE ##tgbase;
    IF OBJECT_ID('tempdb..##tgjson') IS NOT NULL DROP TABLE ##tgjson;
    EXEC('CREATE TABLE ##tgbase (' + @ddl + ');');
    CREATE TABLE ##tgjson (RowOrdinal INT, RowJson NVARCHAR(MAX));

    DECLARE @rows  TABLE (RowOrdinal INT, RowJson NVARCHAR(MAX));
    DECLARE @shape TABLE (ColumnOrdinal INT, ColumnName SYSNAME NULL, SqlTypeName SYSNAME, MaxLength SMALLINT, Prec TINYINT, Scal TINYINT, IsNullable BIT);
    DECLARE @started BIT = 0;
    BEGIN TRY
        IF @@TRANCOUNT = 0 BEGIN BEGIN TRANSACTION; SET @started = 1; END;
        SAVE TRANSACTION tgcap;
        EXEC sys.sp_executesql @MockSql;
        EXEC('INSERT ##tgbase ' + @ExecSql);
        EXEC sys.sp_executesql N'INSERT ##tgjson (RowOrdinal, RowJson)
            SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)),
                   (SELECT x.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
            FROM ##tgbase x;';
        INSERT @rows (RowOrdinal, RowJson) SELECT RowOrdinal, RowJson FROM ##tgjson;
        INSERT @shape (ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, Prec, Scal, IsNullable)
            SELECT c.column_id, c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.is_nullable
            FROM tempdb.sys.columns c WHERE c.object_id = OBJECT_ID('tempdb..##tgbase') ORDER BY c.column_id;
        ROLLBACK TRANSACTION tgcap;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION;
        ELSE IF XACT_STATE() = 1 ROLLBACK TRANSACTION tgcap;
        PRINT 'CaptureResultBaseline failed for ' + @TestClass + ': ' + ERROR_MESSAGE();
    END CATCH;
    IF @started = 1 AND @@TRANCOUNT > 0 COMMIT;
    IF OBJECT_ID('tempdb..##tgbase') IS NOT NULL DROP TABLE ##tgbase;
    IF OBJECT_ID('tempdb..##tgjson') IS NOT NULL DROP TABLE ##tgjson;

    DELETE FROM TestGenLog.ResultShapeBaseline WHERE TestClass = @TestClass;
    INSERT TestGenLog.ResultShapeBaseline (TestClass, ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale, IsNullable)
        SELECT @TestClass, ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, Prec, Scal, IsNullable FROM @shape;
    DELETE FROM TestGenLog.ResultRowsBaseline WHERE TestClass = @TestClass;
    INSERT TestGenLog.ResultRowsBaseline (TestClass, RowOrdinal, RowJson)
        SELECT @TestClass, RowOrdinal, RowJson FROM @rows;
    DECLARE @nc INT = (SELECT COUNT(*) FROM @shape);
    DECLARE @nr INT = (SELECT COUNT(*) FROM @rows);
    PRINT 'CaptureResultBaseline: ' + @TestClass + ' captured ' + CAST(@nc AS VARCHAR) + ' col(s), ' + CAST(@nr AS VARCHAR) + ' row(s).';
END;
GO
PRINT 'TestGen.CaptureResultBaseline installed.';
GO


/* === 15_Extract_Error_Paths.sql === */
/******************************************************************************
 * TestGen.ExtractErrorPaths
 * ----------------------------------------------------------------------------
 * Scans a stored procedure's source for RAISERROR(...) and THROW (...) call
 * sites, returning one row per discovered error path with:
 *   - ErrorOrdinal:           1-based call-site index in source order
 *   - MessagePattern:         a LIKE-style pattern usable in
 *                             tSQLt.ExpectException @ExpectedMessagePattern.
 *                             For literal-string RAISERROR ('Customer %d not
 *                             found', 16, 1, @id) the pattern is
 *                             '%Customer % not found%'.
 *                             For dynamic forms (RAISERROR(@msg, ...)) we
 *                             return NULL pattern - test will accept ANY
 *                             error.
 *   - SeverityLiteral:        the integer severity if it's a literal, else NULL.
 *   - SourceFragment:         the matched substring, for diagnostics.
 *
 * Detection strategy: we lower-case the source and use CHARINDEX-based
 * scanning to find each "raiserror" / "throw" token. From the next '(' we
 * extract the argument list up to the matching ')', then parse the FIRST
 * argument:
 *   - if it starts with a quote -> string literal; we extract until the
 *     matching closing quote, accounting for '' (escaped quotes).
 *   - otherwise -> dynamic (likely a variable); MessagePattern = NULL.
 *
 * For RAISERROR we also try to read the SECOND argument (severity) when it
 * is a numeric literal.
 *
 * For THROW (50001, 'foo', 1) the FIRST argument is the error number; the
 * SECOND is the message literal. We adjust accordingly.
 *
 * Known limitations:
 *   - Nested parentheses in arguments break the extraction; rare.
 *   - %d %s %ld etc. printf specifiers are translated to %.
 *   - Single-line comments (--) inside a multi-line RAISERROR call confuse
 *     the parser; flagged as dynamic if encountered.
 ******************************************************************************/
IF OBJECT_ID('TestGen.ExtractErrorPaths', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ExtractErrorPaths;
GO

CREATE PROCEDURE TestGen.ExtractErrorPaths
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @src NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName)));
    IF @src IS NULL
    BEGIN
        RAISERROR('Procedure %s.%s not found.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    -- Strip block comments so they don't confuse the scanner.
    -- (Simple state machine: each /* ... */ becomes a space.)
    DECLARE @clean NVARCHAR(MAX) = @src;
    DECLARE @bcStart INT, @bcEnd INT;
    SET @bcStart = CHARINDEX('/*', @clean);
    WHILE @bcStart > 0
    BEGIN
        SET @bcEnd = CHARINDEX('*/', @clean, @bcStart + 2);
        IF @bcEnd = 0 BREAK;
        SET @clean = STUFF(@clean, @bcStart, @bcEnd - @bcStart + 2, REPLICATE(N' ', @bcEnd - @bcStart + 2));
        SET @bcStart = CHARINDEX('/*', @clean, @bcStart + 1);
    END;

    -- Strip line comments to end of line.
    DECLARE @lcStart INT, @lcEnd INT;
    SET @lcStart = CHARINDEX('--', @clean);
    WHILE @lcStart > 0
    BEGIN
        SET @lcEnd = CHARINDEX(CHAR(10), @clean, @lcStart);
        IF @lcEnd = 0 SET @lcEnd = LEN(@clean) + 1;
        SET @clean = STUFF(@clean, @lcStart, @lcEnd - @lcStart, REPLICATE(N' ', @lcEnd - @lcStart));
        SET @lcStart = CHARINDEX('--', @clean, @lcStart + 1);
    END;

    -- Output table (returned as a result set).
    DECLARE @Result TABLE
    (
        ErrorOrdinal     INT IDENTITY(1,1) PRIMARY KEY,
        Keyword          VARCHAR(10),         -- 'RAISERROR' | 'THROW'
        MessagePattern   NVARCHAR(2000) NULL, -- NULL = dynamic / unknown
        SeverityLiteral  INT NULL,
        SourceFragment   NVARCHAR(2000)
    );

    DECLARE @lower NVARCHAR(MAX) = LOWER(@clean);
    DECLARE @pos INT = 1, @hit INT;
    DECLARE @kw VARCHAR(10), @kwLen INT;
    DECLARE @parenStart INT, @parenEnd INT, @args NVARCHAR(MAX);

    -- Combined scan: find next 'raiserror' or 'throw' starting from @pos.
    WHILE 1 = 1
    BEGIN
        DECLARE @hR INT = CHARINDEX('raiserror', @lower, @pos);
        DECLARE @hT INT = CHARINDEX('throw',     @lower, @pos);

        IF @hR = 0 AND @hT = 0 BREAK;

        IF @hR > 0 AND (@hT = 0 OR @hR < @hT)
        BEGIN
            SET @hit = @hR; SET @kw = 'RAISERROR'; SET @kwLen = 9;
        END
        ELSE
        BEGIN
            SET @hit = @hT; SET @kw = 'THROW';     SET @kwLen = 5;
        END;

        -- Word-boundary check: previous char must not be alnum/underscore.
        IF @hit > 1
        BEGIN
            DECLARE @prev NCHAR(1) = SUBSTRING(@lower, @hit - 1, 1);
            IF @prev LIKE '[A-Za-z0-9_]'
            BEGIN
                SET @pos = @hit + 1;
                CONTINUE;
            END;
        END;

        -- Locate the opening '(' after the keyword.
        SET @parenStart = CHARINDEX('(', @clean, @hit + @kwLen);

        -- THROW has a form without parens (THROW; for rethrow). Skip those.
        IF @parenStart = 0 OR @parenStart > @hit + @kwLen + 80
        BEGIN
            SET @pos = @hit + @kwLen;
            CONTINUE;
        END;

        -- Locate the matching closing ')'. We scan character-by-character
        -- handling string-quote nesting and depth.
        DECLARE @i INT = @parenStart + 1, @depth INT = 1;
        DECLARE @inStr BIT = 0;
        SET @parenEnd = 0;
        WHILE @i <= LEN(@clean)
        BEGIN
            DECLARE @c NCHAR(1) = SUBSTRING(@clean, @i, 1);
            IF @inStr = 1
            BEGIN
                IF @c = N''''
                BEGIN
                    -- Escaped '' or end of string?
                    IF SUBSTRING(@clean, @i + 1, 1) = N''''
                        SET @i = @i + 1;     -- skip the escaped quote
                    ELSE
                        SET @inStr = 0;
                END;
            END
            ELSE
            BEGIN
                IF @c = N'''' SET @inStr = 1;
                ELSE IF @c = N'(' SET @depth = @depth + 1;
                ELSE IF @c = N')'
                BEGIN
                    SET @depth = @depth - 1;
                    IF @depth = 0 BEGIN SET @parenEnd = @i; BREAK; END;
                END;
            END;
            SET @i = @i + 1;
        END;

        IF @parenEnd = 0
        BEGIN
            -- Couldn't find matching paren; skip this hit.
            SET @pos = @hit + @kwLen;
            CONTINUE;
        END;

        SET @args = SUBSTRING(@clean, @parenStart + 1, @parenEnd - @parenStart - 1);

        -- Parse argument 1 (and 2 for severity / message-for-THROW).
        DECLARE @msg NVARCHAR(2000) = NULL, @sev INT = NULL;
        DECLARE @trimmed NVARCHAR(MAX) = LTRIM(@args);

        IF @kw = 'RAISERROR'
        BEGIN
            -- Arg 1 = message (string literal or variable)
            IF LEFT(@trimmed, 1) = N''''
            BEGIN
                -- Pull literal until non-escaped closing quote.
                DECLARE @j INT = 2;
                WHILE @j <= LEN(@trimmed)
                BEGIN
                    IF SUBSTRING(@trimmed, @j, 1) = N''''
                    BEGIN
                        IF SUBSTRING(@trimmed, @j + 1, 1) = N''''
                            SET @j = @j + 2;
                        ELSE
                        BEGIN
                            SET @msg = SUBSTRING(@trimmed, 2, @j - 2);
                            BREAK;
                        END;
                    END
                    ELSE
                        SET @j = @j + 1;
                END;
            END;

            -- Arg 2 = severity literal (best-effort)
            IF @msg IS NOT NULL
            BEGIN
                DECLARE @afterMsg INT = CHARINDEX(N',', @trimmed,
                    CHARINDEX(N'''', @trimmed,
                        CHARINDEX(N'''', @trimmed) + 1) + 1);
                IF @afterMsg > 0
                BEGIN
                    DECLARE @sevStr NVARCHAR(20) = LTRIM(SUBSTRING(@trimmed, @afterMsg + 1, 10));
                    -- Take everything up to the next comma or end.
                    DECLARE @nextC INT = CHARINDEX(N',', @sevStr);
                    IF @nextC > 0 SET @sevStr = LTRIM(RTRIM(LEFT(@sevStr, @nextC - 1)));
                    IF @sevStr LIKE '[0-9]%'
                        SET @sev = TRY_CAST(@sevStr AS INT);
                END;
            END;
        END
        ELSE   -- THROW (errno, 'msg', state)
        BEGIN
            -- Skip first arg (error number), then read second arg as literal.
            DECLARE @c1 INT = CHARINDEX(N',', @trimmed);
            IF @c1 > 0
            BEGIN
                DECLARE @rest NVARCHAR(MAX) = LTRIM(SUBSTRING(@trimmed, @c1 + 1, LEN(@trimmed)));
                IF LEFT(@rest, 1) = N''''
                BEGIN
                    DECLARE @k INT = 2;
                    WHILE @k <= LEN(@rest)
                    BEGIN
                        IF SUBSTRING(@rest, @k, 1) = N''''
                        BEGIN
                            IF SUBSTRING(@rest, @k + 1, 1) = N''''
                                SET @k = @k + 2;
                            ELSE
                            BEGIN
                                SET @msg = SUBSTRING(@rest, 2, @k - 2);
                                BREAK;
                            END;
                        END
                        ELSE
                            SET @k = @k + 1;
                    END;
                END;
            END;
        END;

        -- Translate the literal to a LIKE pattern: every %d, %s, %ld, etc.
        -- becomes %, and a leading/trailing % wraps the whole thing.
        IF @msg IS NOT NULL
        BEGIN
            -- collapse known printf specs -> %
            DECLARE @pat NVARCHAR(2000) = @msg;
            SET @pat = REPLACE(@pat, N'%d',  N'%');
            SET @pat = REPLACE(@pat, N'%ld', N'%');
            SET @pat = REPLACE(@pat, N'%i',  N'%');
            SET @pat = REPLACE(@pat, N'%s',  N'%');
            SET @pat = REPLACE(@pat, N'%I64d', N'%');
            -- escape underscores for LIKE
            SET @pat = REPLACE(@pat, N'_', N'[_]');
            -- collapse runs of %
            WHILE CHARINDEX(N'%%', @pat) > 0
                SET @pat = REPLACE(@pat, N'%%', N'%');
            SET @pat = N'%' + @pat + N'%';
            SET @msg = @pat;
        END;

        INSERT @Result (Keyword, MessagePattern, SeverityLiteral, SourceFragment)
        VALUES
        (
            @kw,
            @msg,
            @sev,
            LEFT(SUBSTRING(@clean, @hit, @parenEnd - @hit + 1), 2000)
        );

        SET @pos = @parenEnd + 1;
    END;

    SELECT ErrorOrdinal, Keyword, MessagePattern, SeverityLiteral, SourceFragment
    FROM @Result
    ORDER BY ErrorOrdinal;
END;
GO

PRINT 'TestGen.ExtractErrorPaths installed.';
GO


/* === 16_Branch_Detector.sql === */
/*******************************************************************************
 * TestGen.ExtractBranchConditions
 * 
 * PURPOSE:
 *   Parses stored procedure source code to extract branch conditions from
 *   IF statements and CASE expressions. Returns parameter values that should
 *   be tested to ensure branch coverage.
 *
 * PATTERNS DETECTED:
 *   - IF @Param = 'literal'
 *   - IF @Param IN ('val1', 'val2', ...)
 *   - IF @Param > numeric
 *   - CASE @Param WHEN 'val' THEN ...
 *
 * RETURNS:
 *   Table with columns: ParamName, BranchValue, BranchDescription
 *
 * LIMITATIONS (v8.0):
 *   - Does not handle complex AND/OR conditions
 *   - Does not handle dynamic SQL
 *   - Does not handle calculated comparisons
 *******************************************************************************/

IF OBJECT_ID('TestGen.ExtractBranchConditions', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ExtractBranchConditions;
GO

CREATE PROCEDURE TestGen.ExtractBranchConditions
    @SchemaName SYSNAME,
    @ProcName SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    -- Get procedure source
    DECLARE @ProcSource NVARCHAR(MAX);
    DECLARE @SourceTable TABLE (SourceText NVARCHAR(MAX));
    INSERT @SourceTable
    EXEC TestGen.GetProcedureSource @SchemaName, @ProcName;
    SELECT @ProcSource = SourceText FROM @SourceTable;

    -- Normalize whitespace for easier parsing
    SET @ProcSource = REPLACE(@ProcSource, CHAR(13) + CHAR(10), CHAR(10)); -- CRLF to LF
    SET @ProcSource = REPLACE(@ProcSource, CHAR(13), CHAR(10));            -- CR to LF
    SET @ProcSource = REPLACE(@ProcSource, CHAR(9), ' ');                  -- TAB to space

    -- Results table
    DECLARE @Branches TABLE (
        ParamName SYSNAME,
        BranchValue NVARCHAR(500),
        BranchDescription NVARCHAR(500),
        LineNumber INT,
        BranchType VARCHAR(20)
    );

    -- Split source into lines for processing
    DECLARE @Lines TABLE (LineNum INT IDENTITY(1,1), LineText NVARCHAR(MAX));
    INSERT @Lines (LineText)
    SELECT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@ProcSource, CHAR(10))
    WHERE LEN(LTRIM(RTRIM(value))) > 0;

    /* =====================================================================
     * Pattern 1: IF @Param = 'StringLiteral'
     * Example: IF @OrderType = 'Standard'
     * ===================================================================== */
    DECLARE @Line NVARCHAR(MAX), @LineNum INT;
    DECLARE @ParamStart INT, @ParamEnd INT, @ValueStart INT, @ValueEnd INT;
    DECLARE @Param SYSNAME, @Value NVARCHAR(500);

    DECLARE line_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LineNum, LineText FROM @Lines
        WHERE LineText LIKE '%IF%@%=%''%''%'
          AND LineText NOT LIKE '--%IF%';  -- Exclude comments

    OPEN line_cursor;
    FETCH NEXT FROM line_cursor INTO @LineNum, @Line;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Find @ParamName
        SET @ParamStart = CHARINDEX('@', @Line);
        IF @ParamStart > 0
        BEGIN
            -- Find end of parameter (space or = or other delimiter)
            SET @ParamEnd = @ParamStart + 1;
            WHILE @ParamEnd <= LEN(@Line) 
              AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', '=', ')', ',', CHAR(10), CHAR(13))
                SET @ParamEnd = @ParamEnd + 1;
            
            SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
            
            -- Find string literal after =
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
                        
                        INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                        VALUES (@Param, @Value, @Param + ' equals ''' + @Value + '''', @LineNum, 'IF_EQUALS');
                    END;
                END;
            END;
        END;

        FETCH NEXT FROM line_cursor INTO @LineNum, @Line;
    END;

    CLOSE line_cursor;
    DEALLOCATE line_cursor;

    /* =====================================================================
     * Pattern 2: IF @Param IN ('Val1', 'Val2', ...)
     * Example: IF @Status IN ('Active', 'Pending')
     * ===================================================================== */
    DECLARE @InClauseStart INT, @InClauseEnd INT, @InClause NVARCHAR(MAX);
    DECLARE @CurrentPos INT, @QuoteStart INT, @QuoteEnd INT;

    DECLARE in_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LineNum, LineText FROM @Lines
        WHERE LineText LIKE '%IF%@%IN%(%''%''%)%'
          AND LineText NOT LIKE '--%IF%';

    OPEN in_cursor;
    FETCH NEXT FROM in_cursor INTO @LineNum, @Line;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Find @ParamName
        SET @ParamStart = CHARINDEX('@', @Line);
        IF @ParamStart > 0
        BEGIN
            SET @ParamEnd = @ParamStart + 1;
            WHILE @ParamEnd <= LEN(@Line) 
              AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', ')', ',', CHAR(10), CHAR(13))
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
                    
                    INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                    VALUES (@Param, @Value, @Param + ' in set (''' + @Value + ''')', @LineNum, 'IF_IN');
                    
                    SET @CurrentPos = @QuoteEnd + 1;
                END;
            END;
        END;

        FETCH NEXT FROM in_cursor INTO @LineNum, @Line;
    END;

    CLOSE in_cursor;
    DEALLOCATE in_cursor;

    /* =====================================================================
     * Pattern 3: CASE @Param WHEN 'Value' THEN (single-line only)
     * DISABLED: Multi-line scanner below handles both single and multi-line CASE
     * ===================================================================== */
    DECLARE @WhenStart INT, @ThenPos INT, @ValStart2 INT, @NumEnd2 INT;
    DECLARE @CaseParam SYSNAME, @InCase BIT, @MLLine NVARCHAR(MAX), @MLLineNum INT;
    
    -- Single-line CASE scanner disabled: multi-line scanner handles all cases
    -- DECLARE case_cursor ...

    /* =====================================================================
     * Pattern 3b: Multi-line CASE @Param ... WHEN value THEN
     * Handles CASE on one line, WHEN on separate lines
     * ===================================================================== */
    -- Initialize multi-line CASE tracking variables
    SET @CaseParam = NULL;
    SET @InCase    = 0;

    DECLARE ml_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LineNum, LineText FROM @Lines
        ORDER BY LineNum;

    OPEN ml_cursor;
    FETCH NEXT FROM ml_cursor INTO @MLLineNum, @MLLine;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Detect CASE @Param line (CASE followed by @ but no WHEN on same line)
        IF @MLLine LIKE '%CASE%@%' AND @MLLine NOT LIKE '%WHEN%' AND @MLLine NOT LIKE '--%'
        BEGIN
            SET @ParamStart = CHARINDEX('@', @MLLine, CHARINDEX('CASE', @MLLine));
            IF @ParamStart > 0
            BEGIN
                SET @ParamEnd = @ParamStart + 1;
                WHILE @ParamEnd <= LEN(@MLLine)
                  AND SUBSTRING(@MLLine, @ParamEnd, 1) NOT IN (' ',CHAR(10),CHAR(13))
                    SET @ParamEnd = @ParamEnd + 1;
                SET @CaseParam = SUBSTRING(@MLLine, @ParamStart, @ParamEnd - @ParamStart);
                SET @InCase = 1;
            END;
        END
        -- Detect END of CASE
        ELSE IF @InCase = 1 AND (@MLLine LIKE '%END%' AND @MLLine NOT LIKE '%BEGIN%')
        BEGIN
            -- Check for ELSE line before END
            IF @MLLine LIKE '%ELSE%' AND @MLLine NOT LIKE '--%'
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM @Branches WHERE ParamName = @CaseParam AND BranchValue = '_ELSE_CASE_')
                    INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                    VALUES (@CaseParam, '_ELSE_CASE_', @CaseParam + ' case else', @MLLineNum, 'CASE_ELSE');
            END;
            SET @InCase = 0;
            SET @CaseParam = NULL;
        END
        -- Detect ELSE inside multi-line CASE
        ELSE IF @InCase = 1 AND @MLLine LIKE '%ELSE%' AND @MLLine NOT LIKE '%WHEN%' AND @MLLine NOT LIKE '--%'
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM @Branches WHERE ParamName = @CaseParam AND BranchValue = '_ELSE_CASE_')
                INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                VALUES (@CaseParam, '_ELSE_CASE_', @CaseParam + ' case else', @MLLineNum, 'CASE_ELSE');
        END
        -- Detect WHEN value line inside multi-line CASE
        ELSE IF @InCase = 1 AND @CaseParam IS NOT NULL AND @MLLine LIKE '%WHEN%' AND @MLLine NOT LIKE '--%'
        BEGIN
            SET @CurrentPos = CHARINDEX('WHEN', @MLLine);
            IF @CurrentPos > 0
            BEGIN
                SET @ValStart2 = @CurrentPos + 4;
                WHILE @ValStart2 <= LEN(@MLLine) AND SUBSTRING(@MLLine, @ValStart2, 1) = ' '
                    SET @ValStart2 = @ValStart2 + 1;

                IF @ValStart2 <= LEN(@MLLine)
                BEGIN
                    IF SUBSTRING(@MLLine, @ValStart2, 1) = ''''
                    BEGIN
                        SET @QuoteStart = @ValStart2;
                        SET @QuoteEnd = CHARINDEX('''', @MLLine, @QuoteStart + 1);
                        IF @QuoteEnd > 0
                        BEGIN
                            SET @Value = SUBSTRING(@MLLine, @QuoteStart + 1, @QuoteEnd - @QuoteStart - 1);
                            IF NOT EXISTS (SELECT 1 FROM @Branches WHERE ParamName = @CaseParam AND BranchValue = @Value)
                                INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                                VALUES (@CaseParam, @Value, @CaseParam + ' case when ''' + @Value + '''', @MLLineNum, 'CASE_WHEN');
                        END;
                    END
                    ELSE IF SUBSTRING(@MLLine, @ValStart2, 1) LIKE '[0-9]'
                    BEGIN
                        SET @NumEnd2 = @ValStart2;
                        WHILE @NumEnd2 <= LEN(@MLLine) AND SUBSTRING(@MLLine, @NumEnd2, 1) LIKE '[0-9.]'
                            SET @NumEnd2 = @NumEnd2 + 1;
                        SET @Value = SUBSTRING(@MLLine, @ValStart2, @NumEnd2 - @ValStart2);
                        IF LEN(LTRIM(RTRIM(@Value))) > 0
                          AND NOT EXISTS (SELECT 1 FROM @Branches WHERE ParamName = @CaseParam AND BranchValue = @Value)
                            INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                            VALUES (@CaseParam, @Value, @CaseParam + ' case when ' + @Value, @MLLineNum, 'CASE_WHEN');
                    END;
                END;
            END;
        END;

        FETCH NEXT FROM ml_cursor INTO @MLLineNum, @MLLine;
    END;

    CLOSE ml_cursor;
    DEALLOCATE ml_cursor;

    /* =====================================================================
     * Pattern 4: Numeric comparisons - IF @Param > 100
     * Example: IF @Amount > 1000, IF @Quantity <= 5
     * ===================================================================== */
    DECLARE @Operator VARCHAR(5), @NumValue NVARCHAR(50);
    
    DECLARE num_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT LineNum, LineText FROM @Lines
        WHERE (LineText LIKE '%IF%@%>%[0-9]%'
            OR LineText LIKE '%IF%@%<%[0-9]%'
            OR LineText LIKE '%IF%@%>=%[0-9]%'
            OR LineText LIKE '%IF%@%<=%[0-9]%')
          AND LineText NOT LIKE '--%IF%';

    OPEN num_cursor;
    FETCH NEXT FROM num_cursor INTO @LineNum, @Line;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Find @ParamName
        SET @ParamStart = CHARINDEX('@', @Line);
        IF @ParamStart > 0
        BEGIN
            SET @ParamEnd = @ParamStart + 1;
            WHILE @ParamEnd <= LEN(@Line) 
              AND SUBSTRING(@Line, @ParamEnd, 1) NOT IN (' ', '>', '<', '=', CHAR(10), CHAR(13))
                SET @ParamEnd = @ParamEnd + 1;
            
            SET @Param = SUBSTRING(@Line, @ParamStart, @ParamEnd - @ParamStart);
            
            -- Find operator
            SET @Operator = NULL;
            IF CHARINDEX('>=', @Line, @ParamEnd) > 0 AND CHARINDEX('>=', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                SET @Operator = '>=';
            ELSE IF CHARINDEX('<=', @Line, @ParamEnd) > 0 AND CHARINDEX('<=', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                SET @Operator = '<=';
            ELSE IF CHARINDEX('>', @Line, @ParamEnd) > 0 AND CHARINDEX('>', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                SET @Operator = '>';
            ELSE IF CHARINDEX('<', @Line, @ParamEnd) > 0 AND CHARINDEX('<', @Line, @ParamEnd) < CHARINDEX(' ', @Line + ' ', @ParamEnd) + 10
                SET @Operator = '<';
            
            IF @Operator IS NOT NULL
            BEGIN
                -- Extract numeric value after operator
                SET @ValueStart = CHARINDEX(@Operator, @Line, @ParamEnd) + LEN(@Operator);
                SET @ValueStart = @ValueStart + PATINDEX('%[0-9]%', SUBSTRING(@Line, @ValueStart, 100)) - 1;
                
                SET @ValueEnd = @ValueStart;
                WHILE @ValueEnd <= LEN(@Line) 
                  AND SUBSTRING(@Line, @ValueEnd, 1) IN ('0','1','2','3','4','5','6','7','8','9','.')
                    SET @ValueEnd = @ValueEnd + 1;
                
                SET @NumValue = SUBSTRING(@Line, @ValueStart, @ValueEnd - @ValueStart);
                
                IF ISNUMERIC(@NumValue) = 1
                BEGIN
                    INSERT @Branches (ParamName, BranchValue, BranchDescription, LineNumber, BranchType)
                    VALUES (@Param, @NumValue, @Param + ' ' + @Operator + ' ' + @NumValue, @LineNum, 'IF_NUMERIC');
                END;
            END;
        END;

        FETCH NEXT FROM num_cursor INTO @LineNum, @Line;
    END;

    CLOSE num_cursor;
    DEALLOCATE num_cursor;

    /* =====================================================================
     * Return Results - Deduplicate
     * ===================================================================== */
    SELECT DISTINCT
        ParamName,
        BranchValue,
        BranchDescription,
        BranchType
    FROM @Branches
    WHERE ParamName IS NOT NULL
      AND ParamName LIKE '@%'
      AND LEN(LTRIM(RTRIM(BranchValue))) > 0
    ORDER BY ParamName, BranchValue;

END;
GO

PRINT '16_Branch_Detector.sql: TestGen.ExtractBranchConditions created (v8.0 Alpha)';
GO


/* === 17_Branch_Path_Analyzer.sql === */
/* === 17_Branch_Path_Analyzer.sql === v3.2 (v9.2) === */
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
/* === 04_Test_Generator.sql === */
/* === 04_Test_Generator.sql === v3 (v9.2) === */
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

            -- v0.13: is the in-database predicate parser active for this proc?
            -- When it is, module 34 emits a per-branch artefact for EVERY gate
            -- (a seeded TRUE/FALSE pair, or a NOT_TESTABLE skip), so the legacy
            -- smoke-ONLY fallback tests below become redundant duplicates and are
            -- rolled back (see the IF @GenTestCount = 0 block). When the parser did
            -- NOT run (no inbox rows), the legacy skip is preserved as the only marker.
            DECLARE @uagPredicateActive BIT =
                CASE WHEN EXISTS (SELECT 1 FROM TestGen.PredicateInbox
                                  WHERE SchemaName = @SchemaName AND ProcName = @ProcName)
                     THEN 1 ELSE 0 END;
            DECLARE @uagFbStart INT;

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
                        ELSE IF ISNUMERIC(@BranchVal) = 1
                            SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + @BranchVal;
                        ELSE
                            -- v0.11.1: a non-numeric branch value paired with a non-string
                            -- parameter (e.g. a scalar-subquery comparand 'OPEN' mis-attributed
                            -- to an INT @OrderId) would emit invalid SQL (EXEC p @OrderId = OPEN);
                            -- use a type-correct sample so generation succeeds. The predicate
                            -- engine (module 34) supplies the real branch coverage for this gate.
                            SET @BranchArgList = @BranchArgList + N', ' + @brName + N' = ' + TestGen.GetSampleValueLiteral(@brType, @brMax, @brPrec, @brScale, 0);
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

                        -- New table â†’ flush previous accumulation
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
                    SET @uagFbStart    = DATALENGTH(@S)/2;       -- v0.13: roll-back point (after the DROP, before CREATE) for the predicate-parser de-dup
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

                    -- v0.13 de-dup: when the in-database predicate parser produced rows
                    -- for this procedure, module 34 already emits a per-branch artefact
                    -- for every gate (seeded TRUE/FALSE, or a NOT_TESTABLE skip). A
                    -- legacy smoke-ONLY fallback (no assertion, carries a SkipTest marker,
                    -- contributes no coverage because skipped tests never run) is then a
                    -- redundant duplicate, so roll it back to @uagFbStart. The DROP emitted
                    -- above is kept, so any stale copy from a prior generation is still
                    -- removed. Real legacy assertions (@v94SkipReason IS NULL) are never
                    -- rolled back; and when the parser did not run (@uagPredicateActive = 0)
                    -- the legacy skip is preserved as the branch's only marker.
                    IF @v94SkipReason IS NOT NULL AND @uagPredicateActive = 1
                        SET @S = SUBSTRING(@S, 1, @uagFbStart);
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

    -- v0.9.5: defensively self-heal any procedures left in a broken state
    -- by a previously-killed coverage run.  Safe no-op if database is clean.
    -- Runs once at the start as a database-wide sweep (more efficient than
    -- per-procedure checks while iterating).
    IF OBJECT_ID('TestGen.CleanupInterruptedRuns','P') IS NOT NULL
        EXEC TestGen.CleanupInterruptedRuns @SchemaFilter = @SchemaFilter;

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
            -- v0.10: add seeded predicate-branch tests BEFORE measuring, so the
            -- single coverage pass also reaches the data-shape arms (~0.6s/proc).
            -- Gated on the proc having been parsed (PredicateInbox rows); unparsed
            -- procs are untouched, so the baseline is unchanged.
            IF OBJECT_ID('TestGen.GeneratePredicateBranchTests','P') IS NOT NULL
               AND EXISTS (SELECT 1 FROM TestGen.PredicateInbox pi WHERE pi.SchemaName=@s AND pi.ProcName=@p)
            BEGIN TRY
                EXEC TestGen.GeneratePredicateBranchTests @SchemaName=@s, @ProcName=@p;
            END TRY BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'V10: '+ERROR_MESSAGE(); END CATCH

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
/* === 06_Schema_Generator.sql === */
/*****************************************************************************
 * TestGen.GenerateTestsForSchema
 * -----------------------------------------------------------------------------
 * Calls TestGen.GenerateTestsForProcedure for every user procedure in a schema.
 * Skips tSQLt itself, the TestGen schema, and anything matching @ExcludePattern.
 *****************************************************************************/
IF OBJECT_ID('TestGen.GenerateTestsForSchema', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForSchema;
GO

CREATE PROCEDURE TestGen.GenerateTestsForSchema
    @SchemaName     SYSNAME,
    @ExcludePattern NVARCHAR(200) = NULL,
    @ExecuteScript  BIT = 1,
    @EmitNullChecks BIT = 1,        -- passed through to GenerateTestsForProcedure
    @EmitScaffold   BIT = 1         -- passed through to GenerateTestsForProcedure
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @procs TABLE (s SYSNAME, p SYSNAME);

    INSERT @procs
    SELECT SCHEMA_NAME(o.schema_id), o.name
    FROM sys.procedures o
    WHERE SCHEMA_NAME(o.schema_id) = @SchemaName
      AND SCHEMA_NAME(o.schema_id) NOT IN ('tSQLt','TestGen','TestGenLog')
      AND (@ExcludePattern IS NULL OR o.name NOT LIKE @ExcludePattern)
      AND o.name NOT LIKE '%[_]cov'   -- v9.4.3: skip framework _cov instrumentation copies
      AND o.name NOT LIKE '%[_]orig'  -- v9.4.3: and stranded _orig originals;

    DECLARE @s SYSNAME, @p SYSNAME, @script NVARCHAR(MAX), @runId INT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT s, p FROM @procs;
    OPEN cur;
    FETCH NEXT FROM cur INTO @s, @p;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC TestGen.GenerateTestsForProcedure
                 @SchemaName      = @s,
                 @ProcName        = @p,
                 @ExecuteScript   = @ExecuteScript,
                 @EmitNullChecks  = @EmitNullChecks,
                 @EmitScaffold    = @EmitScaffold,
                 @GeneratedScript = @script OUTPUT,
                 @RunId           = @runId  OUTPUT;
        END TRY
        BEGIN CATCH
            PRINT 'FAILED for ' + @s + '.' + @p + ' : ' + ERROR_MESSAGE();
        END CATCH;
        FETCH NEXT FROM cur INTO @s, @p;
    END;
    CLOSE cur; DEALLOCATE cur;
END;
GO

PRINT 'TestGen.GenerateTestsForSchema installed.';
GO


/* === 20_Coverage_Instrumenter.sql === */
/* === 20_Coverage_Instrumenter.sql === v5 (v9.2) === */
/*******************************************************************************
 * TestGen.InstrumentProcedure v5.2  (replaces v5.1)
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
PRINT 'TestGen.InstrumentProcedure v5.2 created (TRY/CATCH structural-keyword fix).';
GO
GO


/* === 21_Coverage_TestPatcher.sql === */
/*******************************************************************************
 * TestGen.PatchTestsForCoverage - helper info only
 * TestGen.BootstrapCoverage     - standalone procedure
 ******************************************************************************/

IF OBJECT_ID('TestGen.BootstrapCoverage','P') IS NOT NULL
    DROP PROCEDURE TestGen.BootstrapCoverage;
GO

CREATE PROCEDURE TestGen.BootstrapCoverage
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID('tempdb..##CovHits') IS NOT NULL DROP TABLE ##CovHits;
    CREATE TABLE ##CovHits (
        HitID      INT IDENTITY(1,1),
        SchemaName SYSNAME,
        ProcName   SYSNAME,
        LineNum    INT,
        TestName   NVARCHAR(500) NULL,
        HitAt      DATETIME2 DEFAULT SYSDATETIME()
    );
    PRINT '##CovHits ready for coverage tracking.';
END;
GO
PRINT 'TestGen.BootstrapCoverage created.';
GO

IF OBJECT_ID('TestGen.PatchTestsForCoverage','P') IS NOT NULL
    DROP PROCEDURE TestGen.PatchTestsForCoverage;
GO

CREATE PROCEDURE TestGen.PatchTestsForCoverage
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InstrName SYSNAME = @ProcName + '_cov';
    IF OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@InstrName), 'P') IS NULL
    BEGIN
        RAISERROR('Instrumented procedure %s.%s_cov not found. Run InstrumentProcedure first.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;
    PRINT 'Coverage workflow:';
    PRINT '  1. EXEC TestGen.BootstrapCoverage ''' + @SchemaName + ''', ''' + @ProcName + ''';';
    PRINT '  2. EXEC tSQLt.Run ''test_' + @ProcName + ''';';
    PRINT '  3. EXEC TestGen.FlushCoverageHits ''' + @SchemaName + ''', ''' + @ProcName + ''';';
    PRINT '  4. EXEC TestGen.GetCoverageReport ''' + @SchemaName + ''', ''' + @ProcName + ''', ''HTML'';';
END;
GO
PRINT 'TestGen.PatchTestsForCoverage created.';
GO


/* === 23_Coverage_ServiceBroker.sql === */
/*******************************************************************************
 * Coverage via XEvent event_file target
 * Captures sql_statement_completed INSIDE tSQLt rollbacks - confirmed working
 * Filters by database only (not object_name) to avoid empty results
 ******************************************************************************/

IF OBJECT_ID('TestGen.SetupCoverageBroker','P') IS NOT NULL
    DROP PROCEDURE TestGen.SetupCoverageBroker;
GO

CREATE PROCEDURE TestGen.SetupCoverageBroker
AS
BEGIN
    SET NOCOUNT ON;
    PRINT 'Coverage uses XEvent event_file. No setup required.';
    PRINT 'Run: EXEC TestGen.RunCoverage ''schema'',''proc'',''HTML''';
END;
GO
PRINT 'TestGen.SetupCoverageBroker created.';
GO

IF OBJECT_ID('TestGen.RecordCoverageHit','P') IS NOT NULL
    DROP PROCEDURE TestGen.RecordCoverageHit;
GO

CREATE PROCEDURE TestGen.RecordCoverageHit
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @LineNum    INT
AS
BEGIN
    SET NOCOUNT ON;
    -- No-op stub: actual coverage captured via XEvent event_file in RunCoverage
    -- The _cov proc calls this so instrumentation compiles correctly
    -- XEvent captures the statement text containing the line number
END;
GO
PRINT 'TestGen.RecordCoverageHit (XEvent stub) created.';
GO

--------------------------------------------------------------------
-- TestGen.RunCoverage - XEvent event_file coverage
--------------------------------------------------------------------


/* === Reconstructed from canonical patches on 2026-05-26 === */

/*******************************************************************************
 * Patch_RunCoverage_AlwaysReinstrument.sql
 *
 * Applies the "stale _cov" fix to TestGen.RunCoverage.  Run this ONCE against
 * the database where the tSQLt Auto-Gen framework is installed (the same
 * database you run EXEC TestGen.RunCoverage in).
 *
 * WHAT IT FIXES
 *   RunCoverage used to instrument the target proc ONLY when its _cov copy
 *   was missing:
 *       IF OBJECT_ID(@CovFull,'P') IS NULL
 *           EXEC TestGen.InstrumentProcedure @SchemaName, @ProcName;
 *   So after a framework upgrade - or after the target proc body was edited -
 *   RunCoverage silently REUSED a stale _cov (and stale TestGen.CoverageLines)
 *   and reported coverage for the wrong code.  This produced the misleading
 *   "0/23 lines -> 0.0%" report for dbo.uspGetBillOfMaterials on 2026-05-22:
 *   its _cov was dated 2026-05-20 and had been built by a pre-v5 instrumenter.
 *
 * CHANGES (vs the v9.2 FINAL build of TestGen.RunCoverage)
 *   1. Instrumentation is now UNCONDITIONAL - RunCoverage re-instruments on
 *      every run, so _cov and CoverageLines always reflect the CURRENT proc
 *      body and the CURRENT InstrumentProcedure version.
 *   2. The EXEC TestGen.InstrumentProcedure call was moved to AFTER the
 *      leftover-_orig cleanup, so it always reads a correctly-named proc even
 *      if a previous run died mid-way (proc still renamed to _orig).
 *   3. Cosmetic: the "XEvent rows captured" count is now captured into a
 *      variable BEFORE the PRINT (PRINT resets @@ROWCOUNT to 0), so the
 *      "No RecordCoverageHit statements found" message no longer misfires.
 *
 * SAFE TO RE-RUN: this is a DROP + CREATE of one procedure only.  No data,
 * no other framework objects, and no application objects are touched.
 *
 * AFTER APPLYING: nothing else is needed.  The next EXEC TestGen.RunCoverage
 * on any procedure rebuilds that procedure's _cov automatically, so stale
 * _cov copies left by earlier runs are corrected on their next coverage run.
 ******************************************************************************/

-- USE YourDatabase;   -- <-- make sure you are in the framework's database
GO

IF OBJECT_ID('TestGen.RunCoverage','P') IS NOT NULL
    DROP PROCEDURE TestGen.RunCoverage;
GO

CREATE PROCEDURE TestGen.RunCoverage
    @SchemaName  SYSNAME,
    @ProcName    SYSNAME,
    @OutputMode   VARCHAR(10) = 'HTML',
    @TestsRun     INT = NULL OUTPUT,   -- v9.4.2+: outcomes from this run,
    @TestsPassed  INT = NULL OUTPUT,   -- so a caller need not run the tests
    @TestsFailed  INT = NULL OUTPUT,   -- a second time just to count them
    @TestsErrored INT = NULL OUTPUT,
    @TestsSkipped INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CovFull     NVARCHAR(400);
    DECLARE @CovProcName SYSNAME;
    DECLARE @TestClass   NVARCHAR(400);
    DECLARE @DbName      SYSNAME;
    DECLARE @SQL         NVARCHAR(MAX);
    DECLARE @HitCount    INT;
    DECLARE @OrigDef     NVARCHAR(MAX);
    DECLARE @BackupFull  NVARCHAR(400);
    DECLARE @OrigFull    NVARCHAR(400);
    DECLARE @SynFull     NVARCHAR(400);

    SET @DbName      = DB_NAME();
    SET @CovFull     = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName+'_cov');
    SET @CovProcName = @ProcName + '_cov';
    SET @TestClass   = 'test_' + @ProcName;
    SELECT @TestsRun=0, @TestsPassed=0, @TestsFailed=0, @TestsErrored=0, @TestsSkipped=0;
    SET @BackupFull  = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName+'_orig');
    SET @OrigFull    = QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName);
    DECLARE @covErr  NVARCHAR(MAX) = NULL;  -- v0.13.x: remembered run error so the guaranteed restore can still run

    -- v0.13.x: bulletproof self-heal of any leftover from an interrupted/killed run,
    -- run FIRST (before the testability gate + instrumentation) so a stranded synonym
    -- is restored to its real body rather than mis-judged NOT_TESTABLE and skipped.
    -- It NEVER drops the only copy of the real proc body. Order matters.
    -- (a) a leftover synonym at the base name -> drop it (its _cov target is rebuilt
    --     later); the base name is then free.
    BEGIN TRY
        IF OBJECT_ID(@OrigFull, 'SN') IS NOT NULL
        BEGIN SET @SQL = N'DROP SYNONYM ' + @OrigFull; EXEC(@SQL); END;
    END TRY BEGIN CATCH END CATCH;
    -- (b) base missing but _orig present -> the real body is parked in _orig; restore it.
    BEGIN TRY
        IF OBJECT_ID(@OrigFull,'P') IS NULL AND OBJECT_ID(@BackupFull,'P') IS NOT NULL
        BEGIN
            SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + '_orig'', ''' + @ProcName + '''';
            EXEC(@SQL);
        END;
    END TRY BEGIN CATCH END CATCH;
    -- (c) base IS a live proc AND a stale _orig also exists -> _orig is a redundant
    --     backup (the real body is already at base), so dropping it removes a copy,
    --     never the only one. Clears the way for a clean instrument/rename later.
    BEGIN TRY
        IF OBJECT_ID(@OrigFull,'P') IS NOT NULL AND OBJECT_ID(@BackupFull,'P') IS NOT NULL
        BEGIN SET @SQL = N'DROP PROCEDURE ' + @BackupFull; EXEC(@SQL); END;
    END TRY BEGIN CATCH END CATCH;
    -- (d) safety net: after self-heal the base MUST be a live proc. If it is not
    --     (no base, no recoverable _orig), ABORT instead of instrumenting/renaming a
    --     missing object - that is exactly what cascades into object loss.
    IF OBJECT_ID(@OrigFull,'P') IS NULL
    BEGIN
        RAISERROR('TestGen.RunCoverage: %s.%s has no base procedure and no recoverable _orig backup - aborting to avoid object loss. Investigate an interrupted run.', 16, 1, @SchemaName, @ProcName);
        RETURN;
    END;

    /* v9.4.3: testability gate - a NOT_TESTABLE procedure (no fakeable
       dependencies + system-catalog usage) cannot be meaningfully instrumented
       for coverage; report that honestly instead of a misleading number. */
    DECLARE @v943Verdict VARCHAR(20), @v943Reason NVARCHAR(400);
    BEGIN TRY
        EXEC TestGen.AssessTestability @SchemaName=@SchemaName, @ProcName=@ProcName,
             @Verdict=@v943Verdict OUTPUT, @Reason=@v943Reason OUTPUT;
    END TRY
    BEGIN CATCH SET @v943Verdict = 'TESTABLE'; END CATCH

    IF @v943Verdict = 'NOT_TESTABLE'
    BEGIN
        PRINT '';
        PRINT '=============================================================';
        PRINT ' NOT TESTABLE: ' + @SchemaName + '.' + @ProcName;
        PRINT ' ' + ISNULL(@v943Reason, N'no fakeable dependencies; system-catalog usage');
        PRINT ' This procedure cannot be auto-instrumented for coverage -';
        PRINT ' no coverage measured (the @Tests* outputs are 0).';
        PRINT '=============================================================';
        RETURN;
    END;

    -- NOTE: instrumentation moved further down and made UNCONDITIONAL - see
    -- the "Step 2b: (Re)instrument" block below.

    ---------------------------------------------------------------------------
    -- Step 1: Determine XEL file path (use SQL Server log directory)
    ---------------------------------------------------------------------------
    DECLARE @XelPath NVARCHAR(500);

    SELECT TOP 1 @XelPath =
        REVERSE(SUBSTRING(REVERSE(physical_name),
                CHARINDEX('\', REVERSE(physical_name)), 500)) + 'TestGenCoverage'
    FROM sys.master_files
    WHERE database_id = 1 AND type_desc = 'LOG';

    IF @XelPath IS NULL OR LEN(@XelPath) < 5
        SET @XelPath = 'C:\Windows\Temp\TestGenCoverage';

    SET @XelPath = @XelPath + '_' + REPLACE(REPLACE(REPLACE(
        CONVERT(VARCHAR(20), GETDATE(), 120), '-', ''), ':', ''), ' ', '_');
    PRINT 'XEL path: ' + @XelPath;

    ---------------------------------------------------------------------------
    -- Step 2: Drop existing session if any (always - from failed previous runs)
    ---------------------------------------------------------------------------
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'TestGenCoverage')
            EXEC('ALTER EVENT SESSION TestGenCoverage ON SERVER STATE = STOP');
    END TRY BEGIN CATCH END CATCH;
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'TestGenCoverage')
            EXEC('DROP EVENT SESSION TestGenCoverage ON SERVER');
    END TRY BEGIN CATCH END CATCH;

    -- (v0.13.x: the leftover self-heal now runs at the TOP of the proc, BEFORE the
    --  testability gate - see the self-heal block near the top. A stranded synonym
    --  here would otherwise be mis-judged NOT_TESTABLE and skipped un-healed.)

    -- Delete previous XEL files - skipped (xp_cmdshell may be disabled)
    -- Unique timestamp in filename prevents stale file conflicts

    ---------------------------------------------------------------------------
    -- Step 2b: (Re)instrument the target proc on EVERY run.
    -- Do NOT skip this when _cov already exists.  A _cov left from a previous
    -- run can be stale - built by an older InstrumentProcedure version (the
    -- framework was upgraded since) or before the target proc body was
    -- edited - and reusing it silently reports coverage for the WRONG code.
    -- InstrumentProcedure is cheap and idempotent (DROP+CREATE _cov,
    -- DELETE+INSERT CoverageLines), so always rebuilding is safe.
    -- Placed here deliberately: AFTER the leftover-_orig cleanup above (so the
    -- proc has its real name) and BEFORE Step 4 renames it to _orig.
    ---------------------------------------------------------------------------
    PRINT 'Instrumenting ' + @ProcName + ' (fresh _cov every run)...';
    EXEC TestGen.InstrumentProcedure @SchemaName, @ProcName;

    ---------------------------------------------------------------------------
    -- Step 3: Create XEvent session
    -- No ACTION clause - sql_text captured via statement field by default
    -- Filter by database only, post-filter by statement text
    ---------------------------------------------------------------------------
    SET @SQL = N'
    CREATE EVENT SESSION [TestGenCoverage] ON SERVER
    ADD EVENT sqlserver.sp_statement_completed (
        ACTION (sqlserver.sql_text)
        WHERE sqlserver.database_name = N''' + @DbName + N'''
    )
    ADD TARGET package0.event_file (
        SET filename           = N''' + @XelPath + N''',
            max_file_size      = 50,
            max_rollover_files = 5
    )
    WITH (
        MAX_DISPATCH_LATENCY = 1 SECONDS,
        TRACK_CAUSALITY      = OFF,
        STARTUP_STATE        = OFF
    );';

    -- PERF (v0.10.1): filter the session to the instrumented proc's object_id so only its
    -- statements land in the .xel - far smaller file, far faster read (validated identical
    -- coverage, ~5x faster on busy procs). object_id IS available at predicate-eval time
    -- (the statement-text field is not).
    DECLARE @covid INT = OBJECT_ID(@CovFull);
    IF @covid IS NOT NULL
        SET @SQL = REPLACE(@SQL, N'database_name = N''' + @DbName + N'''', N'database_name = N''' + @DbName + N''' AND [object_id]=(' + CAST(@covid AS NVARCHAR(20)) + N')');

    BEGIN TRY
        EXEC(@SQL);
        EXEC('ALTER EVENT SESSION TestGenCoverage ON SERVER STATE = START');
        PRINT 'XEvent session started.';
    END TRY
    BEGIN CATCH
        PRINT 'XEvent session creation failed: ' + ERROR_MESSAGE();
        -- Don't goto - fall through to run tests anyway (just won't capture coverage)
    END CATCH;

    ---------------------------------------------------------------------------
    -- Step 4: Install synonym so tSQLt transparently calls _cov
    -- Drop original, create synonym original_name -> _cov
    -- tSQLt resolves the name at call time so synonym works
    ---------------------------------------------------------------------------
    DELETE FROM TestGen.CoverageHits
    WHERE SchemaName = @SchemaName AND ProcName = @ProcName;

    SET @SynFull  = @OrigFull;

    -- v0.13.x: GUARANTEED-restore wrapper. Everything from the rename through the
    -- test run is inside this TRY; the restore below the matching CATCH ALWAYS runs,
    -- so a soft error (synonym clash, run abort) can never strand the proc as _orig.
    -- A hard connection drop that bypasses CATCH is healed by the bulletproof
    -- self-heal at the top of the NEXT run (Step 2 above).
    BEGIN TRY
        -- Rename original to _orig. (Step 2 self-heal guarantees the base is the real
        -- proc and no stale _orig remains, so there is no backup to drop here.)
        SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + ''', ''' + @ProcName + '_orig''';
        EXEC(@SQL);
        PRINT 'Original renamed to _orig.';

        -- Create synonym: original name -> _cov
        IF OBJECT_ID(@SynFull, 'SN') IS NOT NULL
        BEGIN SET @SQL = N'DROP SYNONYM ' + @SynFull; EXEC(@SQL); END;
        SET @SQL = N'CREATE SYNONYM ' + @SynFull + N' FOR ' + @CovFull;
        EXEC(@SQL);
        PRINT 'Synonym created: ' + @ProcName + ' -> ' + @CovProcName;

        PRINT 'Running: ' + @TestClass + ' (via synonym to instrumented proc)';
        BEGIN TRY
        -- v9.4.3: tSQLt.Run RAISES an error when any test fails or errors.
        -- Wrap it so that raise does not skip the outcome capture just below
        -- (the custom-class run further down is already wrapped this way).
        BEGIN TRY EXEC tSQLt.Run @TestClass; END TRY
        BEGIN CATCH PRINT 'tSQLt error: ' + ERROR_MESSAGE(); END CATCH;
        -- v9.4.2+: capture this run's outcomes (the instrumented proc behaves
        -- like the real one - instrumentation injects only no-op hit calls),
        -- read here before the next run clears tSQLt.TestResult.
        IF OBJECT_ID('tSQLt.TestResult','U') IS NOT NULL
            SELECT @TestsRun     = @TestsRun     + ISNULL(COUNT(*),0),
                   @TestsPassed  = @TestsPassed  + ISNULL(SUM(CASE WHEN Result = 'Success' THEN 1 ELSE 0 END),0),
                   @TestsFailed  = @TestsFailed  + ISNULL(SUM(CASE WHEN Result = 'Failure' THEN 1 ELSE 0 END),0),
                   @TestsErrored = @TestsErrored + ISNULL(SUM(CASE WHEN Result = 'Error'   THEN 1 ELSE 0 END),0),
                   @TestsSkipped = @TestsSkipped + ISNULL(SUM(CASE WHEN Result IN ('Skipped','Skip','Ignored') THEN 1 ELSE 0 END),0)
            FROM tSQLt.TestResult WHERE Class = @TestClass;
        -- v9.4.2+: run EVERY developer-owned class for this procedure - any
        -- schema named test_<proc>_custom...  The framework never touches
        -- these; their tests count toward coverage too.
        DECLARE @CustomClass SYSNAME;
        DECLARE cc_run CURSOR LOCAL FAST_FORWARD FOR
            SELECT s.name FROM sys.schemas s
            WHERE s.name LIKE REPLACE(@TestClass,'_','[_]') + '[_]custom%'
            ORDER BY s.name;
        OPEN cc_run;
        FETCH NEXT FROM cc_run INTO @CustomClass;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            PRINT 'Running: ' + @CustomClass + ' (developer-owned tests)';
            BEGIN TRY EXEC tSQLt.Run @CustomClass; END TRY
            BEGIN CATCH PRINT 'tSQLt error: ' + ERROR_MESSAGE(); END CATCH
            IF OBJECT_ID('tSQLt.TestResult','U') IS NOT NULL
                SELECT @TestsRun     = @TestsRun     + ISNULL(COUNT(*),0),
                       @TestsPassed  = @TestsPassed  + ISNULL(SUM(CASE WHEN Result = 'Success' THEN 1 ELSE 0 END),0),
                       @TestsFailed  = @TestsFailed  + ISNULL(SUM(CASE WHEN Result = 'Failure' THEN 1 ELSE 0 END),0),
                       @TestsErrored = @TestsErrored + ISNULL(SUM(CASE WHEN Result = 'Error'   THEN 1 ELSE 0 END),0),
                       @TestsSkipped = @TestsSkipped + ISNULL(SUM(CASE WHEN Result IN ('Skipped','Skip','Ignored') THEN 1 ELSE 0 END),0)
                FROM tSQLt.TestResult WHERE Class = @CustomClass;
            FETCH NEXT FROM cc_run INTO @CustomClass;
        END;
        CLOSE cc_run; DEALLOCATE cc_run;
    END TRY
    BEGIN CATCH
        PRINT 'tSQLt error: ' + ERROR_MESSAGE();
    END CATCH;
    END TRY
    BEGIN CATCH
        -- v0.13.x: remember any error from the rename/synonym/run; the guaranteed
        -- restore below still runs so the original is never left stranded as _orig.
        SET @covErr = ERROR_MESSAGE();
    END CATCH;

    ---------------------------------------------------------------------------
    -- Step 5: GUARANTEED, idempotent restore - drop synonym, rename _orig back.
    -- Runs whether or not the wrapper above succeeded; the rename is guarded on the
    -- base name being free, so it can never clobber a live base proc.
    ---------------------------------------------------------------------------
    IF OBJECT_ID(@SynFull, 'SN') IS NOT NULL
    BEGIN SET @SQL = N'DROP SYNONYM ' + @SynFull; EXEC(@SQL); END;
    IF OBJECT_ID(@OrigFull,'P') IS NULL AND OBJECT_ID(@BackupFull, 'P') IS NOT NULL
    BEGIN
        SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + '_orig'', ''' + @ProcName + '''';
        EXEC(@SQL);
    END;
    PRINT 'Original proc restored.';
    IF @covErr IS NOT NULL PRINT 'Coverage run error (original safely restored): ' + @covErr;

    ---------------------------------------------------------------------------
    -- Step 5: Wait for events to flush to disk
    ---------------------------------------------------------------------------
    WAITFOR DELAY '00:00:01';  -- perf: was 3s; STOP flushes, 1s = MAX_DISPATCH_LATENCY margin

    ---------------------------------------------------------------------------
    -- Step 6: Stop session
    ---------------------------------------------------------------------------
    EXEC('ALTER EVENT SESSION TestGenCoverage ON SERVER STATE = STOP');
    PRINT 'XEvent session stopped. Reading events...';

    ---------------------------------------------------------------------------
    -- Step 7: Read XEL file - extract RecordCoverageHit statements
    ---------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..##XEvents') IS NOT NULL DROP TABLE ##XEvents;
    CREATE TABLE ##XEvents (stmt NVARCHAR(MAX));

    -- Read XEL directly - no existence check (unique timestamp filename, no xp_cmdshell needed)
    -- fn_xe_file_target_read_file columns: object_name, event_data, file_name, file_offset
    -- In SS2025 event_data is XML-compatible NVARCHAR
    SET @SQL = N'INSERT ##XEvents (stmt)
    SELECT xdr.value(''(event/data[@name="statement"]/value)[1]'', ''NVARCHAR(MAX)'')
    FROM (
        SELECT TRY_CAST(event_data AS XML) AS xdr
        FROM sys.fn_xe_file_target_read_file(''' + @XelPath + N'*.xel'', NULL, NULL, NULL)
        WHERE object_name = ''sp_statement_completed''
    ) AS raw
    WHERE xdr IS NOT NULL
      AND xdr.value(''(event/data[@name="statement"]/value)[1]'', ''NVARCHAR(MAX)'')
          LIKE ''%RecordCoverageHit%''';

    DECLARE @XeRows INT = 0;
    BEGIN TRY
        EXEC(@SQL);
        -- Capture @@ROWCOUNT IMMEDIATELY.  The PRINT below resets @@ROWCOUNT
        -- to 0, so the old "IF @@ROWCOUNT = 0" tested AFTER the PRINT always
        -- misfired - printing "No RecordCoverageHit statements found" even
        -- when rows WERE captured.
        SET @XeRows = @@ROWCOUNT;
        PRINT 'XEvent rows captured: ' + CAST(@XeRows AS VARCHAR);
        IF @XeRows = 0
        BEGIN
            PRINT 'No RecordCoverageHit statements found. Showing sample of captured events:';
            EXEC('SELECT TOP 5 object_name,
                LEFT(CAST(event_data AS XML).value(
                    ''(event/data[@name="statement"]/value)[1]'',''NVARCHAR(MAX)''),200) AS stmt
                FROM sys.fn_xe_file_target_read_file(''' + @XelPath + '*.xel'', NULL, NULL, NULL)');
        END;
    END TRY
    BEGIN CATCH
        PRINT 'XEvent read error: ' + ERROR_MESSAGE();
        BEGIN TRY
            EXEC('SELECT TOP 1 object_name, LEFT(CAST(event_data AS NVARCHAR(MAX)),200)
                  FROM sys.fn_xe_file_target_read_file(''' + @XelPath + '*.xel'', NULL, NULL, NULL)');
        END TRY BEGIN CATCH END CATCH;
    END CATCH;

    -- Extract line numbers
    INSERT TestGen.CoverageHits (SchemaName, ProcName, LineNum)
    SELECT DISTINCT
        @SchemaName,
        @ProcName,
        CAST(LTRIM(RTRIM(
            SUBSTRING(stmt, LEN(stmt) - CHARINDEX(',', REVERSE(stmt)) + 2, 100)
        )) AS INT)
    FROM ##XEvents
    WHERE stmt LIKE '%RecordCoverageHit%'
      AND ISNUMERIC(LTRIM(RTRIM(
            SUBSTRING(stmt, LEN(stmt) - CHARINDEX(',', REVERSE(stmt)) + 2, 100)
          ))) = 1;

    SELECT @HitCount = COUNT(*)
    FROM TestGen.CoverageHits
    WHERE SchemaName = @SchemaName AND ProcName = @ProcName;
    PRINT 'Coverage hits recorded: ' + CAST(@HitCount AS VARCHAR);

    Cleanup:
    ---------------------------------------------------------------------------
    -- Step 8: Cleanup
    ---------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..##XEvents') IS NOT NULL DROP TABLE ##XEvents;
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'TestGenCoverage')
        EXEC('DROP EVENT SESSION TestGenCoverage ON SERVER');

    -- XEL files remain on disk - cleaned up on next run by unique timestamp naming

    ---------------------------------------------------------------------------
    -- Step 9: Report
    ---------------------------------------------------------------------------
    EXEC TestGen.GetCoverageReport @SchemaName, @ProcName, @OutputMode;
END;
GO
PRINT 'TestGen.RunCoverage created (always-reinstrument stale-_cov fix).';
GO


/* === Reconstructed from canonical patches on 2026-05-26 === */

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


/* === 23_Coverage_Reporter_Xml.sql === */
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
    -- 4. Loop schemas -> packages
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
        -- 5. Loop procs -> classes
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
            -- 6. Per-line detail - same EffectiveHit logic as GetCoverageReport
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


/* === 24_TestResults_Reporter_Xml.sql === */
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
 *   - All variables declared at proc top -- no DECLARE inside loops (T-SQL
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

    IF @BatchId IS NULL
        SELECT TOP 1 @BatchId = BatchId
        FROM   TestGen.CoverageResult
        ORDER  BY BatchId DESC;

    IF @BatchId IS NULL
    BEGIN
        RAISERROR('TestGen.GetTestResultsJunitXml: no results found. Run GenerateAndCoverDatabase first.',16,1);
        RETURN;
    END;

    SELECT
        @gTests = ISNULL(SUM(TestsRun),     0),
        @gFail  = ISNULL(SUM(TestsFailed),  0),
        @gErr   = ISNULL(SUM(TestsErrored), 0),
        @gSkip  = ISNULL(SUM(TestsSkipped), 0)
    FROM   TestGen.CoverageResult
    WHERE  BatchId = @BatchId
      AND  (@SchemaFilter IS NULL OR SchemaName = @SchemaFilter);

    SET @Timestamp = CONVERT(VARCHAR(30), @BatchId, 126);

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
                SET @safeMsg = ISNULL(@clsReason, N'not auto-testable');
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <skipped message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END
            ELSE IF @clsGen = 0
            BEGIN
                SET @safeMsg = ISNULL(@clsErrTxt, N'test generation failed');
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <error message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END
            ELSE IF @clsFail > 0
            BEGIN
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
                SET @safeMsg = CAST(@clsErr AS NVARCHAR) + N' of ' + CAST(@clsRun AS NVARCHAR)
                    + N' tests errored'
                    + CASE WHEN @clsErrTxt IS NOT NULL THEN N'. ' + @clsErrTxt ELSE N'' END;
                SET @safeMsg = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                    @safeMsg, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&apos;');
                SET @XML = @XML + CHAR(10)
                    + N'      <error message="' + @safeMsg + N'"/>' + CHAR(10)
                    + N'    ';
            END;

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


/* === 25_Coverage_Reporter_Html.sql === */
IF OBJECT_ID('TestGen.GetCoverageHtmlReport','P') IS NOT NULL
    DROP PROCEDURE TestGen.GetCoverageHtmlReport;
GO

CREATE PROCEDURE TestGen.GetCoverageHtmlReport
    @BatchId      DATETIME2(3) = NULL,
    @SchemaFilter SYSNAME      = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gProcs INT, @gNotTestable INT, @gGenFail INT;
    DECLARE @gTot INT, @gCov INT, @gTB INT, @gCB INT;
    DECLARE @gRun INT, @gPass INT, @gFail INT, @gErr INT, @gSkip INT, @gPres INT;
    DECLARE @gLinePct DECIMAL(5,1), @gBrPct DECIMAL(5,1);
    DECLARE @pPass DECIMAL(5,1), @pFail DECIMAL(5,1), @pErr DECIMAL(5,1), @pSkip DECIMAL(5,1);
    DECLARE @gAutonomy DECIMAL(5,1);
    DECLARE @H NVARCHAR(MAX);
    DECLARE @rS SYSNAME, @rP SYSNAME;
    DECLARE @rGen BIT, @rRun INT, @rPass INT, @rFail INT;
    DECLARE @rErr INT, @rSkip INT, @rTot INT, @rCov INT;
    DECLARE @rLP DECIMAL(5,1), @rBP DECIMAL(5,1), @rTB INT;
    DECLARE @rTestability VARCHAR(20), @rReason NVARCHAR(400), @rPres INT;

    IF @BatchId IS NULL
        SELECT TOP 1 @BatchId = BatchId FROM TestGen.CoverageResult ORDER BY BatchId DESC;

    IF @BatchId IS NULL
    BEGIN
        RAISERROR('TestGen.GetCoverageHtmlReport: no results found. Run GenerateAndCoverDatabase first.',16,1);
        RETURN;
    END;

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
    SET @gAutonomy = CASE WHEN @gRun>0 THEN CAST(@gRun-@gPres AS DECIMAL(9,2))/@gRun*100 ELSE 100 END;

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
        + CAST(@gRun-@gPres AS VARCHAR) + N' of ' + CAST(@gRun AS VARCHAR)
        + N' tests framework-owned<br><span style="color:#999">'
        + CAST(@gPres AS VARCHAR) + N' user-modified</span></div></div>';
    SET @H = @H + N'</div>';
    SET @H = @H + N'<table><tr>'
        + N'<th class="l">Schema</th><th class="l">Object</th>'
        + N'<th>Testable</th><th>Gen</th>'
        + N'<th>Tests</th><th>Pass</th><th>Fail</th><th>Err</th><th>Skip</th>'
        + N'<th>Lines</th><th>Covered</th><th>Line %</th><th>Branch %</th></tr>';

    DECLARE rc CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName,ProcName,GenSucceeded,TestsRun,TestsPassed,TestsFailed,
               TestsErrored,TestsSkipped,TotalLines,CoveredLines,LinePct,BranchPct,
               TotalBranches,Testability,NotTestableReason,TestsPreserved
        FROM   TestGen.CoverageResult
        WHERE  BatchId=@BatchId AND (@SchemaFilter IS NULL OR SchemaName=@SchemaFilter)
        ORDER  BY SchemaName,ProcName;
    OPEN rc;
    FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,
                             @rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    WHILE @@FETCH_STATUS=0
    BEGIN
        IF @rTestability=N'NOT_TESTABLE'
            SET @H=@H+N'<tr style="background:#f6f6f6;color:#999"><td class="l">'+@rS+N'</td>'
                +N'<td class="l">'+@rP
                +N'<details style="margin-top:2px"><summary style="font-size:11px;color:#888;cursor:pointer;font-weight:normal">why not testable?</summary>'
                +N'<div style="font-size:12px;font-weight:normal;color:#555;margin-top:4px;white-space:normal">'
                +ISNULL(@rReason,N'no fakeable dependencies; system-catalog usage')
                +N'</div></details></td>'
                +N'<td><span class="r">N</span></td>'
                +N'<td>'+CASE WHEN @rGen=1 THEN N'Y' ELSE N'N' END+N'</td>'
                +N'<td>'+CAST(ISNULL(@rRun,0) AS VARCHAR)
                    +CASE WHEN ISNULL(@rPres,0)>0 THEN N' <span style="color:#9a6700">('+CAST(@rPres AS VARCHAR)+N' preserved)</span>' ELSE N'' END+N'</td>'
                +N'<td>'+CAST(ISNULL(@rPass,0) AS VARCHAR)+N'</td>'
                +N'<td>'+CAST(ISNULL(@rFail,0) AS VARCHAR)+N'</td>'
                +N'<td>'+CAST(ISNULL(@rErr,0)  AS VARCHAR)+N'</td>'
                +N'<td>'+CAST(ISNULL(@rSkip,0) AS VARCHAR)+N'</td>'
                +N'<td style="color:#999">n/a</td><td style="color:#999">n/a</td>'
                +N'<td style="color:#999">n/a</td><td style="color:#999">n/a</td></tr>';
        ELSE
            SET @H=@H+N'<tr><td class="l">'+@rS+N'</td><td class="l">'+@rP+N'</td>'
                +N'<td><span class="g">Y</span></td>'
                +N'<td>'+CASE WHEN @rGen=1 THEN N'Y' ELSE N'<span class="r">N</span>' END+N'</td>'
                +N'<td>'+CAST(@rRun AS VARCHAR)
                    +CASE WHEN ISNULL(@rPres,0)>0 THEN N' <span style="color:#9a6700">('+CAST(@rPres AS VARCHAR)+N' preserved)</span>' ELSE N'' END+N'</td>'
                +N'<td>'+CAST(@rPass AS VARCHAR)+N'</td>'
                +N'<td>'+CASE WHEN @rFail>0 THEN N'<span class="r">'+CAST(@rFail AS VARCHAR)+N'</span>' ELSE N'0' END+N'</td>'
                +N'<td>'+CASE WHEN @rErr >0 THEN N'<span class="r">'+CAST(@rErr  AS VARCHAR)+N'</span>' ELSE N'0' END+N'</td>'
                +N'<td>'+CAST(@rSkip AS VARCHAR)+N'</td>'
                +N'<td>'+CAST(@rTot AS VARCHAR)+N'</td>'
                +N'<td>'+CAST(@rCov AS VARCHAR)+N'</td>'
                +CASE WHEN ISNULL(@rTot,0)=0 THEN N'<td style="color:#999">n/a</td>'
                      ELSE N'<td class="'+CASE WHEN @rLP>=80 THEN 'g' WHEN @rLP>=50 THEN 'a' ELSE 'r' END+N'">'+CAST(@rLP AS VARCHAR)+N'%</td>' END
                +CASE WHEN ISNULL(@rTB,0)=0  THEN N'<td style="color:#999">n/a</td>'
                      ELSE N'<td class="'+CASE WHEN @rBP>=80 THEN 'g' WHEN @rBP>=50 THEN 'a' ELSE 'r' END+N'">'+CAST(@rBP AS VARCHAR)+N'%</td>' END
                +N'</tr>';
        FETCH NEXT FROM rc INTO @rS,@rP,@rGen,@rRun,@rPass,@rFail,@rErr,@rSkip,
                                 @rTot,@rCov,@rLP,@rBP,@rTB,@rTestability,@rReason,@rPres;
    END;
    CLOSE rc; DEALLOCATE rc;

    SET @H=@H+N'<tr class="total"><td class="l" colspan="4">TOTAL &mdash; '
        +CAST(@gProcs AS VARCHAR)+N' procedures ('
        +CAST(@gProcs-@gNotTestable AS VARCHAR)+N' testable, '
        +CAST(@gNotTestable AS VARCHAR)+N' not)</td>'
        +N'<td>'+CAST(@gRun AS VARCHAR)
            +CASE WHEN @gPres>0 THEN N' <span style="color:#9a6700">('+CAST(@gPres AS VARCHAR)+N' preserved)</span>' ELSE N'' END+N'</td>'
        +N'<td>'+CAST(@gPass AS VARCHAR)+N'</td>'
        +N'<td>'+CAST(@gFail AS VARCHAR)+N'</td><td>'+CAST(@gErr AS VARCHAR)+N'</td>'
        +N'<td>'+CAST(@gSkip AS VARCHAR)+N'</td>'
        +N'<td>'+CAST(@gTot AS VARCHAR)+N'</td><td>'+CAST(@gCov AS VARCHAR)+N'</td>'
        +N'<td>'+CAST(@gLinePct AS VARCHAR)+N'%</td><td>'+CAST(@gBrPct AS VARCHAR)+N'%</td></tr>';
    SET @H=@H+N'</table></body></html>';

    SELECT @H AS CoverageReportHTML;
END;
GO
PRINT 'TestGen.GetCoverageHtmlReport created.';
GO


/* ===== v11: scalar & table-valued function support (module 30) ===== */
/*****************************************************************************
 * 30_Function_Support_v1.sql  â€”  v11 scalar / table-valued function support
 *---------------------------------------------------------------------------
 * Adds test generation AND line/branch coverage for user-defined functions:
 *   FN  scalar
 *   IF  inline table-valued
 *   TF  multi-statement table-valued
 *
 * Design: design/DESIGN_v11_Functions.md.  Coverage is measured via the
 * SHADOW-PROCEDURE TRANSFORM: a function body cannot host an
 * EXEC TestGen.RecordCoverageHit recorder and is unreliable to capture
 * directly (scalar-UDF statements run inside the calling statement, and
 * SQL 2019+ Froid inlining folds the body into the caller plan).  So we
 * mechanically derive a PROCEDURE whose body is the function body with only
 * the header rewritten, then drive the EXISTING InstrumentProcedure +
 * RunCoverage XEvent pipeline against that procedure â€” a procedure's
 * statements always fire sp_statement_completed and are never inlined.
 *
 * Object map (all in the TestGen schema):
 *   TestGen.GetFunctionKind          - classify FN/IF/TF/CLR/encrypted
 *   TestGen.RewriteScalarReturns     - RETURN <expr> -> SET @__ret=<expr>;RETURN
 *   TestGen.BuildShadowProcForFunction - create <fn>_covfn + line map
 *   TestGen.GenerateTestsForScalarFunction
 *   TestGen.GenerateTestsForTableFunction   (IF + TF)
 *   TestGen.GenerateTestsForObject   - dispatcher (P/FN/IF/TF)
 *   TestGen.RunCoverageForFunction   - shadow + RunCoverage wrapper + relabel
 *   TestGen.ShadowLineMap            - FunctionLine -> ShadowLine attribution
 *
 * IMPORTANT: kept side-by-side with the procedure pipeline; nothing here
 * alters GenerateTestsForProcedure / RunCoverage / InstrumentProcedure.
 * Re-runnable (idempotent DROP+CREATE).  Reuses TestGen helper functions:
 *   TestGen.GetSampleValueLiteral, TestGen.GetDeclareLiteralForType,
 *   dbo.TestGen_RebuildTypeName, TestGen.SafeFakeTable,
 *   TestGen.ExecuteBatchedScript.
 *
 * NOT YET VERIFIED on a live DB - regenerate + run coverage on the three
 * reference databases (AdventureWorks2025 / Northwind / WideWorldImporters)
 * and triage per CHANGES.md convention.
 *****************************************************************************/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/*===========================================================================
 * TestGen.ShadowLineMap - maps a function source line to the line in its
 * shadow procedure, so coverage hits recorded against the shadow attribute
 * back to the original function's source line in the report.
 *==========================================================================*/
IF OBJECT_ID('TestGen.ShadowLineMap','U') IS NULL
    CREATE TABLE TestGen.ShadowLineMap (
        MapId         INT IDENTITY(1,1) PRIMARY KEY,
        SchemaName    SYSNAME NOT NULL,
        FunctionName  SYSNAME NOT NULL,
        FunctionLine  INT     NOT NULL,
        ShadowLine    INT     NOT NULL,
        CreatedAt     DATETIME2 DEFAULT SYSDATETIME(),
        UNIQUE (SchemaName, FunctionName, ShadowLine)
    );
GO

/*===========================================================================
 * TestGen.GetFunctionKind
 *   Returns: 'FN' | 'IF' | 'TF'  (testable shapes)
 *            'FS' | 'FT' | 'AF'  (CLR - not transformable, NOT_TESTABLE)
 *            'ENCRYPTED'         (no body available)
 *            'NA'                (not a function / does not exist)
 *==========================================================================*/
IF OBJECT_ID('TestGen.GetFunctionKind','FN') IS NOT NULL
    DROP FUNCTION TestGen.GetFunctionKind;
GO
CREATE FUNCTION TestGen.GetFunctionKind
(
    @SchemaName SYSNAME,
    @FunctionName SYSNAME
)
RETURNS VARCHAR(10)
AS
BEGIN
    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@FunctionName));
    IF @ObjId IS NULL RETURN 'NA';

    DECLARE @type CHAR(2) = (SELECT type FROM sys.objects WHERE object_id = @ObjId);
    IF @type NOT IN ('FN','IF','TF','FS','FT','AF') RETURN 'NA';

    -- Encrypted bodies expose no definition - cannot transform or test.
    IF OBJECT_DEFINITION(@ObjId) IS NULL AND @type IN ('FN','IF','TF')
        RETURN 'ENCRYPTED';

    RETURN RTRIM(@type);
END;
GO
PRINT 'TestGen.GetFunctionKind installed.';
GO

/*===========================================================================
 * TestGen.RewriteScalarReturns
 *   Rewrites every  RETURN <expr>;  into  BEGIN SET @__ret = (<expr>); RETURN; END
 *   so a scalar-function body becomes legal, control-flow-equivalent
 *   procedure body.  A char walk that respects line/block comments, string
 *   literals, bracketed identifiers and paren depth so it only fires on real
 *   RETURN statements at statement scope.  Early returns keep their
 *   control-transfer semantics (BEGIN ... RETURN; END), so branch structure
 *   is preserved 1:1.
 *==========================================================================*/
IF OBJECT_ID('TestGen.RewriteScalarReturns','FN') IS NOT NULL
    DROP FUNCTION TestGen.RewriteScalarReturns;
GO
CREATE FUNCTION TestGen.RewriteScalarReturns
(
    @Body NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out      NVARCHAR(MAX) = N'';
    DECLARE @len      INT = LEN(@Body);
    DECLARE @i        INT = 1;
    DECLARE @ch       NCHAR(1);
    DECLARE @nx       NCHAR(1);
    DECLARE @inLine   BIT = 0;   -- inside  -- comment
    DECLARE @inBlock  BIT = 0;   -- inside  /* */
    DECLARE @inStr    BIT = 0;   -- inside  '...'
    DECLARE @inBr     BIT = 0;   -- inside  [...]
    DECLARE @paren    INT = 0;

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Body, @i, 1);
        SET @nx = CASE WHEN @i < @len THEN SUBSTRING(@Body, @i + 1, 1) ELSE N'' END;

        -- exit single-line comment at newline
        IF @inLine = 1
        BEGIN
            SET @out += @ch;
            IF @ch = CHAR(10) SET @inLine = 0;
            SET @i += 1; CONTINUE;
        END;
        -- exit block comment
        IF @inBlock = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N'*' AND @nx = N'/' BEGIN SET @out += @nx; SET @i += 2; SET @inBlock = 0; CONTINUE; END;
            SET @i += 1; CONTINUE;
        END;
        -- exit string literal ('' is an escaped quote -> stay in string)
        IF @inStr = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N'''' AND @nx = N'''' BEGIN SET @out += @nx; SET @i += 2; CONTINUE; END;
            IF @ch = N'''' SET @inStr = 0;
            SET @i += 1; CONTINUE;
        END;
        -- exit bracket identifier
        IF @inBr = 1
        BEGIN
            SET @out += @ch;
            IF @ch = N']' SET @inBr = 0;
            SET @i += 1; CONTINUE;
        END;

        -- enter comment / string / bracket
        IF @ch = N'-' AND @nx = N'-' BEGIN SET @out += N'--'; SET @i += 2; SET @inLine = 1; CONTINUE; END;
        IF @ch = N'/' AND @nx = N'*' BEGIN SET @out += N'/*'; SET @i += 2; SET @inBlock = 1; CONTINUE; END;
        IF @ch = N'''' BEGIN SET @out += @ch; SET @inStr = 1; SET @i += 1; CONTINUE; END;
        IF @ch = N'[' BEGIN SET @out += @ch; SET @inBr = 1; SET @i += 1; CONTINUE; END;
        IF @ch = N'(' BEGIN SET @paren += 1; SET @out += @ch; SET @i += 1; CONTINUE; END;
        IF @ch = N')' BEGIN SET @paren = CASE WHEN @paren > 0 THEN @paren - 1 ELSE 0 END; SET @out += @ch; SET @i += 1; CONTINUE; END;

        -- detect a RETURN keyword at statement scope (word-bounded, paren depth 0)
        IF @paren = 0
           AND UPPER(SUBSTRING(@Body, @i, 6)) = N'RETURN'
           AND (@i = 1 OR PATINDEX(N'%[^A-Za-z0-9_@#]%', SUBSTRING(@Body, @i - 1, 1)) = 1)
        BEGIN
            DECLARE @after NCHAR(1) = CASE WHEN @i + 6 <= @len THEN SUBSTRING(@Body, @i + 6, 1) ELSE N' ' END;
            IF @after LIKE N'[ ' + CHAR(9) + CHAR(10) + CHAR(13) + N'(]'  -- RETURN followed by whitespace or (
               OR @i + 6 > @len
            BEGIN
                -- capture the expression up to its terminator.  Track CASE..END
                -- nesting so a CASE arm's END is not mistaken for the body's
                -- closing END; stop at a top-level END, a ';' at paren depth 0,
                -- or an unmatched ')'.  This prevents swallowing the function's
                -- own closing END when "RETURN <expr>" has no trailing semicolon
                -- (e.g. RETURN @ret  <newline>  END).
                DECLARE @j INT = @i + 6;
                DECLARE @ep INT = 0;        -- paren depth within expression
                DECLARE @es BIT = 0;        -- string within expression
                DECLARE @eb BIT = 0;        -- bracket identifier within expression
                DECLARE @ecase INT = 0;     -- CASE..END nesting within expression
                DECLARE @expr NVARCHAR(MAX) = N'';
                DECLARE @ec NCHAR(1), @en NCHAR(1), @epv NCHAR(1);
                WHILE @j <= @len
                BEGIN
                    SET @ec = SUBSTRING(@Body, @j, 1);
                    SET @en = CASE WHEN @j < @len THEN SUBSTRING(@Body, @j + 1, 1) ELSE N'' END;
                    IF @es = 1
                    BEGIN
                        SET @expr += @ec;
                        IF @ec = N'''' AND @en = N'''' BEGIN SET @expr += @en; SET @j += 2; CONTINUE; END;
                        IF @ec = N'''' SET @es = 0;
                        SET @j += 1; CONTINUE;
                    END;
                    IF @eb = 1
                    BEGIN
                        SET @expr += @ec;
                        IF @ec = N']' SET @eb = 0;
                        SET @j += 1; CONTINUE;
                    END;
                    IF @ec = N'''' BEGIN SET @expr += @ec; SET @es = 1; SET @j += 1; CONTINUE; END;
                    IF @ec = N'[' BEGIN SET @expr += @ec; SET @eb = 1; SET @j += 1; CONTINUE; END;
                    IF @ec = N'(' BEGIN SET @ep += 1; SET @expr += @ec; SET @j += 1; CONTINUE; END;
                    IF @ec = N')'
                    BEGIN
                        IF @ep = 0 BREAK;  -- closing paren that ends an enclosing block - stop
                        SET @ep -= 1; SET @expr += @ec; SET @j += 1; CONTINUE;
                    END;
                    SET @epv = CASE WHEN @j = 1 THEN N' ' ELSE SUBSTRING(@Body, @j - 1, 1) END;
                    IF UPPER(SUBSTRING(@Body, @j, 4)) = N'CASE'
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', @epv) = 1
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', SUBSTRING(@Body, @j + 4, 1)) = 1
                    BEGIN SET @ecase += 1; SET @expr += SUBSTRING(@Body, @j, 4); SET @j += 4; CONTINUE; END;
                    IF UPPER(SUBSTRING(@Body, @j, 3)) = N'END'
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', @epv) = 1
                       AND PATINDEX(N'%[^A-Za-z0-9_@#]%', CASE WHEN @j + 3 <= @len THEN SUBSTRING(@Body, @j + 3, 1) ELSE N' ' END) = 1
                    BEGIN
                        IF @ecase = 0 BREAK;   -- block-closing END -> expression ends here
                        SET @ecase -= 1; SET @expr += SUBSTRING(@Body, @j, 3); SET @j += 3; CONTINUE;
                    END;
                    IF @ec = N';' AND @ep = 0 BREAK;             -- statement terminator
                    SET @expr += @ec; SET @j += 1;
                END;

                DECLARE @trim NVARCHAR(MAX) = LTRIM(RTRIM(@expr));
                IF @trim = N''
                    SET @out += N'RETURN';          -- bare RETURN - leave as-is (rare in scalar)
                ELSE
                    -- trailing space + newline so this END never fuses with a
                    -- following token (e.g. the function's own closing END ->
                    -- "ENDEND") when RETURN had no trailing ';'.
                    SET @out += NCHAR(13)+NCHAR(10)+N'BEGIN'+NCHAR(13)+NCHAR(10)+N'SET @__ret = ('+@expr+N');'+NCHAR(13)+NCHAR(10)+N'RETURN;'+NCHAR(13)+NCHAR(10)+N'END'+NCHAR(13)+NCHAR(10);

                -- advance past the consumed ';' if we stopped on one
                IF @j <= @len AND SUBSTRING(@Body, @j, 1) = N';' SET @j += 1;
                SET @i = @j;
                CONTINUE;
            END;
        END;

        SET @out += @ch;
        SET @i += 1;
    END;

    RETURN @out;
END;
GO
PRINT 'TestGen.RewriteScalarReturns installed.';
GO

/*===========================================================================
 * v11 #11: TestGen.ExpandCaseToIf - rewrites a statement-scope SET <t> = CASE
 * ... END;  or  RETURN CASE ... END;  into an IF / ELSE IF / ELSE chain, so each
 * CASE arm becomes an instrumentable + seedable BRANCH (a CASE expression is
 * atomic to the line-based instrumenter, so CASE-in-RETURN scalars otherwise
 * report 0 branches).  Conservative: only a clean top-level SET=CASE / RETURN
 * CASE is expanded; anything else is copied through verbatim, and a malformed
 * expansion simply fails the shadow compile (honest deferral), never a crash.
 * Applied to the shadow body (counting) AND the body the seeder reads (covering).
 *==========================================================================*/
IF OBJECT_ID('TestGen.ExpandCaseToIf','FN') IS NOT NULL
    DROP FUNCTION TestGen.ExpandCaseToIf;
GO
CREATE FUNCTION TestGen.ExpandCaseToIf(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @out NVARCHAR(MAX)=N'', @len INT=LEN(@Body), @i INT=1;
    DECLARE @ch NCHAR(1),@nx NCHAR(1);
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0,@stmt BIT=1;
    DECLARE @k INT,@kc NCHAR(1),@target NVARCHAR(MAX),@isRet BIT,@c0 INT;
    DECLARE @test NVARCHAR(MAX),@searched BIT,@cd INT,@w NVARCHAR(10),@seg NVARCHAR(MAX);
    DECLARE @arms NVARCHAR(MAX),@elseR NVARCHAR(MAX),@whenE NVARCHAR(MAX),@thenE NVARCHAR(MAX);
    DECLARE @armN INT,@es BIT,@eb BIT,@done BIT,@assign NVARCHAR(MAX),@chain NVARCHAR(MAX);

    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Body,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
        IF @inLine=1 BEGIN SET @out+=@ch; IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN SET @out+=@ch; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN SET @out+=@ch; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlk=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @out+=@ch; SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'[' BEGIN SET @out+=@ch; SET @inBr=1; SET @i+=1; CONTINUE; END;

        -- try a trigger only at statement start, paren depth 0, on a non-ws char
        IF @stmt=1 AND @paren=0 AND @ch NOT IN (N' ',CHAR(9),CHAR(10),CHAR(13))
        BEGIN
            SET @isRet=NULL; SET @k=@i;
            IF UPPER(SUBSTRING(@Body,@i,6))=N'RETURN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+6,1))=1
            BEGIN SET @isRet=1; SET @k=@i+6; SET @target=N''; END
            ELSE IF UPPER(SUBSTRING(@Body,@i,3))=N'SET' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+3,1))=1
            BEGIN
                SET @k=@i+3; SET @target=N'';
                WHILE @k<=@len AND SUBSTRING(@Body,@k,1)<>N'=' BEGIN SET @target+=SUBSTRING(@Body,@k,1); SET @k+=1; END;
                IF @k<=@len SET @k+=1;  -- skip '='
                SET @isRet=0;
            END;
            IF @isRet IS NOT NULL
            BEGIN
                WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13)) SET @k+=1;
                IF UPPER(SUBSTRING(@Body,@k,4))=N'CASE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1
                BEGIN
                    SET @c0=@k+4; SET @k=@c0;
                    WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13)) SET @k+=1;
                    -- simple vs searched
                    IF UPPER(SUBSTRING(@Body,@k,4))=N'WHEN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1
                        SET @searched=1;
                    ELSE
                    BEGIN
                        SET @searched=0; SET @test=N''; SET @cd=0; SET @es=0; SET @eb=0;
                        WHILE @k<=@len
                        BEGIN
                            SET @kc=SUBSTRING(@Body,@k,1);
                            IF @es=1 BEGIN SET @test+=@kc; IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @test+=N''''; SET @k+=2; CONTINUE; END; IF @kc=N'''' SET @es=0; SET @k+=1; CONTINUE; END;
                            IF @eb=1 BEGIN SET @test+=@kc; IF @kc=N']' SET @eb=0; SET @k+=1; CONTINUE; END;
                            IF @kc=N'''' BEGIN SET @test+=@kc; SET @es=1; SET @k+=1; CONTINUE; END;
                            IF @kc=N'[' BEGIN SET @test+=@kc; SET @eb=1; SET @k+=1; CONTINUE; END;
                            IF @cd=0 AND UPPER(SUBSTRING(@Body,@k,4))=N'WHEN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k-1,1))=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 BREAK;
                            IF UPPER(SUBSTRING(@Body,@k,4))=N'CASE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 SET @cd+=1;
                            IF UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 AND @cd>0 SET @cd-=1;
                            SET @test+=@kc; SET @k+=1;
                        END;
                        SET @test=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@test,NCHAR(13),N' '),NCHAR(10),N' '),NCHAR(9),N' ')));
                    END;
                    -- read arms
                    SET @chain=N''; SET @armN=0; SET @elseR=NULL; SET @done=0;
                    WHILE @done=0 AND @k<=@len
                    BEGIN
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(10),CHAR(13)) SET @k+=1;
                        IF UPPER(SUBSTRING(@Body,@k,4))=N'WHEN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1
                        BEGIN
                            SET @k+=4; SET @whenE=N''; SET @cd=0; SET @es=0; SET @eb=0;
                            WHILE @k<=@len
                            BEGIN
                                SET @kc=SUBSTRING(@Body,@k,1);
                                IF @es=1 BEGIN SET @whenE+=@kc; IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @whenE+=N''''; SET @k+=2; CONTINUE; END; IF @kc=N'''' SET @es=0; SET @k+=1; CONTINUE; END;
                                IF @eb=1 BEGIN SET @whenE+=@kc; IF @kc=N']' SET @eb=0; SET @k+=1; CONTINUE; END;
                                IF @kc=N'''' BEGIN SET @whenE+=@kc; SET @es=1; SET @k+=1; CONTINUE; END;
                                IF @kc=N'[' BEGIN SET @whenE+=@kc; SET @eb=1; SET @k+=1; CONTINUE; END;
                                IF @cd=0 AND UPPER(SUBSTRING(@Body,@k,4))=N'THEN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k-1,1))=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 BREAK;
                                IF UPPER(SUBSTRING(@Body,@k,4))=N'CASE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 SET @cd+=1;
                                IF UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 AND @cd>0 SET @cd-=1;
                                SET @whenE+=@kc; SET @k+=1;
                            END;
                            SET @k+=4;  -- past THEN
                            SET @thenE=N''; SET @cd=0; SET @es=0; SET @eb=0;
                            WHILE @k<=@len
                            BEGIN
                                SET @kc=SUBSTRING(@Body,@k,1);
                                IF @es=1 BEGIN SET @thenE+=@kc; IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @thenE+=N''''; SET @k+=2; CONTINUE; END; IF @kc=N'''' SET @es=0; SET @k+=1; CONTINUE; END;
                                IF @eb=1 BEGIN SET @thenE+=@kc; IF @kc=N']' SET @eb=0; SET @k+=1; CONTINUE; END;
                                IF @kc=N'''' BEGIN SET @thenE+=@kc; SET @es=1; SET @k+=1; CONTINUE; END;
                                IF @kc=N'[' BEGIN SET @thenE+=@kc; SET @eb=1; SET @k+=1; CONTINUE; END;
                                IF @cd=0 AND ((UPPER(SUBSTRING(@Body,@k,4))=N'WHEN' OR UPPER(SUBSTRING(@Body,@k,4))=N'ELSE') AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k-1,1))=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1) BREAK;
                                IF @cd=0 AND UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k-1,1))=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 BREAK;
                                IF UPPER(SUBSTRING(@Body,@k,4))=N'CASE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 SET @cd+=1;
                                IF UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 AND @cd>0 SET @cd-=1;
                                SET @thenE+=@kc; SET @k+=1;
                            END;
                            SET @whenE=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@whenE,NCHAR(13),N' '),NCHAR(10),N' '),NCHAR(9),N' '))); SET @thenE=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@thenE,NCHAR(13),N' '),NCHAR(10),N' '),NCHAR(9),N' ')));
                            SET @assign=CASE WHEN @isRet=1 THEN N'RETURN '+@thenE ELSE N'SET '+LTRIM(RTRIM(@target))+N' = '+@thenE END;
                            SET @chain += CASE WHEN @armN=0 THEN N'' ELSE N'    ELSE ' END
                              + N'IF ' + CASE WHEN @searched=1 THEN N'('+@whenE+N')' ELSE @test+N' = '+@whenE END
                              + CHAR(13)+CHAR(10) + N'        ' + @assign + N';' + CHAR(13)+CHAR(10);
                            SET @armN+=1;
                        END
                        ELSE IF UPPER(SUBSTRING(@Body,@k,4))=N'ELSE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1
                        BEGIN
                            SET @k+=4; SET @elseR=N''; SET @cd=0; SET @es=0; SET @eb=0;
                            WHILE @k<=@len
                            BEGIN
                                SET @kc=SUBSTRING(@Body,@k,1);
                                IF @es=1 BEGIN SET @elseR+=@kc; IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @elseR+=N''''; SET @k+=2; CONTINUE; END; IF @kc=N'''' SET @es=0; SET @k+=1; CONTINUE; END;
                                IF @eb=1 BEGIN SET @elseR+=@kc; IF @kc=N']' SET @eb=0; SET @k+=1; CONTINUE; END;
                                IF @kc=N'''' BEGIN SET @elseR+=@kc; SET @es=1; SET @k+=1; CONTINUE; END;
                                IF @kc=N'[' BEGIN SET @elseR+=@kc; SET @eb=1; SET @k+=1; CONTINUE; END;
                                IF @cd=0 AND UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k-1,1))=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 BREAK;
                                IF UPPER(SUBSTRING(@Body,@k,4))=N'CASE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+4,1))=1 SET @cd+=1;
                                IF UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1 AND @cd>0 SET @cd-=1;
                                SET @elseR+=@kc; SET @k+=1;
                            END;
                            SET @elseR=LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@elseR,NCHAR(13),N' '),NCHAR(10),N' '),NCHAR(9),N' ')));
                        END
                        ELSE IF UPPER(SUBSTRING(@Body,@k,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@k+3,1))=1
                        BEGIN SET @k+=3; SET @done=1; END
                        ELSE BEGIN SET @done=2; END  -- parse confusion -> abort
                    END;
                    -- skip a trailing ';'
                    IF @done=1
                    BEGIN
                        WHILE @k<=@len AND SUBSTRING(@Body,@k,1) IN (N' ',CHAR(9),CHAR(13),CHAR(10)) SET @k+=1;
                        IF @k<=@len AND SUBSTRING(@Body,@k,1)=N';' SET @k+=1;
                    END;
                    IF @done=1 AND @armN>=1
                    BEGIN
                        SET @assign=CASE WHEN @isRet=1 THEN N'RETURN '+ISNULL(@elseR,N'NULL') ELSE N'SET '+LTRIM(RTRIM(@target))+N' = '+ISNULL(@elseR,N'NULL') END;
                        IF @elseR IS NOT NULL OR @isRet=1
                            SET @chain += N'    ELSE ' + @assign + N';' + CHAR(13)+CHAR(10);
                        SET @out += @chain;
                        SET @i=@k; SET @stmt=1; CONTINUE;
                    END;
                    -- parse failed: fall through to normal copy of the original char
                END;
            END;
        END;

        IF @ch=N'(' SET @paren+=1;
        IF @ch=N')' SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END;
        SET @out+=@ch;
        IF @ch=N';' SET @stmt=1;
        ELSE IF @ch NOT IN (N' ',CHAR(9),CHAR(10),CHAR(13)) SET @stmt=0;
        SET @i+=1;
    END;
    RETURN @out;
END;

GO
PRINT 'TestGen.ExpandCaseToIf installed.';
GO

/*===========================================================================
 * Small text helpers used by the shadow transform.  All do a comment- /
 * string- / bracket-aware char walk so keywords inside literals or comments
 * are never matched.
 *==========================================================================*/
IF OBJECT_ID('TestGen.FindKeyword','FN') IS NOT NULL DROP FUNCTION TestGen.FindKeyword;
GO
CREATE FUNCTION TestGen.FindKeyword
(
    @Text NVARCHAR(MAX),
    @Kw   NVARCHAR(50),
    @Start INT
)
RETURNS INT     -- 1-based position of the first standalone @Kw at/after @Start, else 0
AS
BEGIN
    DECLARE @len INT = LEN(@Text), @i INT = CASE WHEN @Start < 1 THEN 1 ELSE @Start END;
    DECLARE @kl INT = LEN(@Kw);
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@af NCHAR(1);
    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Text,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Text,@i+1,1) ELSE N'' END;
        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1 BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'[' BEGIN SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF UPPER(SUBSTRING(@Text,@i,@kl)) = UPPER(@Kw)
        BEGIN
            SET @pv = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Text,@i-1,1) END;
            SET @af = CASE WHEN @i+@kl<=@len THEN SUBSTRING(@Text,@i+@kl,1) ELSE N' ' END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@af)=1
                RETURN @i;
        END;
        SET @i+=1;
    END;
    RETURN 0;
END;
GO
PRINT 'TestGen.FindKeyword installed.';
GO

IF OBJECT_ID('TestGen.FindTopLevelAs','FN') IS NOT NULL DROP FUNCTION TestGen.FindTopLevelAs;
GO
CREATE FUNCTION TestGen.FindTopLevelAs
(
    @Def NVARCHAR(MAX)
)
RETURNS INT     -- position of the body-introducing AS (paren depth 0), else 0
AS
BEGIN
    DECLARE @len INT = LEN(@Def), @i INT = 1, @paren INT = 0;
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@af NCHAR(1);
    WHILE @i <= @len
    BEGIN
        SET @ch = SUBSTRING(@Def,@i,1);
        SET @nx = CASE WHEN @i<@len THEN SUBSTRING(@Def,@i+1,1) ELSE N'' END;
        IF @inLine=1 BEGIN IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN IF @ch=N'*' AND @nx=N'/' BEGIN SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1 BEGIN IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'[' BEGIN SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'(' BEGIN SET @paren+=1; SET @i+=1; CONTINUE; END;
        IF @ch=N')' BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @i+=1; CONTINUE; END;
        IF @paren=0 AND UPPER(SUBSTRING(@Def,@i,2))=N'AS'
        BEGIN
            SET @pv = CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Def,@i-1,1) END;
            SET @af = CASE WHEN @i+2<=@len THEN SUBSTRING(@Def,@i+2,1) ELSE N' ' END;
            IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1 AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@af)=1
                RETURN @i;
        END;
        SET @i+=1;
    END;
    RETURN 0;
END;
GO
PRINT 'TestGen.FindTopLevelAs installed.';
GO

IF OBJECT_ID('TestGen.StripOuterParens','FN') IS NOT NULL DROP FUNCTION TestGen.StripOuterParens;
GO
CREATE FUNCTION TestGen.StripOuterParens
(
    @Text NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @t NVARCHAR(MAX) = LTRIM(RTRIM(@Text));
    -- strip a trailing semicolon for the balance check
    IF RIGHT(@t,1) = N';' SET @t = LTRIM(RTRIM(LEFT(@t, LEN(@t)-1)));
    IF LEFT(@t,1) <> N'(' OR RIGHT(@t,1) <> N')' RETURN @Text;
    -- confirm the first '(' matches the last ')' (single enclosing pair)
    DECLARE @len INT = LEN(@t), @i INT = 1, @depth INT = 0, @ok BIT = 1;
    WHILE @i <= @len
    BEGIN
        DECLARE @c NCHAR(1) = SUBSTRING(@t,@i,1);
        IF @c=N'(' SET @depth+=1;
        ELSE IF @c=N')' BEGIN SET @depth-=1; IF @depth=0 AND @i<@len BEGIN SET @ok=0; BREAK; END; END;
        SET @i+=1;
    END;
    IF @ok=0 RETURN @Text;
    RETURN SUBSTRING(@t, 2, LEN(@t)-2);
END;
GO
PRINT 'TestGen.StripOuterParens installed.';
GO

/*===========================================================================
 * TestGen.BuildShadowProcForFunction
 *   Creates <schema>.<fn>_covfn as a PROCEDURE equivalent to the function
 *   body, suitable for the existing coverage pipeline.  Catalog-driven
 *   header synthesis (params + scalar return type from sys.parameters) plus
 *   a string transform of the body.  Populates TestGen.ShadowLineMap.
 *
 *   @Status OUTPUT:  'OK'  or  'UNSUPPORTED:<reason>'  (never emits broken
 *   DDL - on an unparseable shape it sets the status and creates nothing,
 *   so coverage is honestly deferred rather than faked).
 *==========================================================================*/
-- v11 Step1: cap every WHILE..BEGIN loop of a shadow with a local iteration
-- counter so the coverage probe can never run away.  Comment/string/bracket/
-- paren aware; conservative (only clear statement-scope WHILE..BEGIN blocks are
-- touched, on their own lines so they stay instrument-friendly; a single-stmt
-- loop body is left alone).  Returns the body unchanged if nothing was capped.
-- All walker vars are declared once at the top (DECLARE @x=expr inside a loop
-- evaluates the initializer once at parse - see CLAUDE.md).
IF OBJECT_ID('TestGen.InjectLoopGuards','FN') IS NOT NULL
    DROP FUNCTION TestGen.InjectLoopGuards;
GO
CREATE FUNCTION TestGen.InjectLoopGuards(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @CR NCHAR(2) = CHAR(13)+CHAR(10);
    DECLARE @out NVARCHAR(MAX)=N'', @decls NVARCHAR(MAX)=N'';
    DECLARE @len INT=LEN(@Body), @i INT=1, @nLoop INT=0;
    DECLARE @inLine BIT=0,@inBlock BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1);
    DECLARE @cp INT,@cs BIT,@cbl BIT,@cbk BIT,@done BIT,@cc NCHAR(1),@cn NCHAR(1),@cpv NCHAR(1),@k NVARCHAR(9);

    WHILE @i<=@len
    BEGIN
        SET @ch=SUBSTRING(@Body,@i,1);
        SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
        IF @inLine=1  BEGIN SET @out+=@ch; IF @ch=CHAR(10) SET @inLine=0; SET @i+=1; CONTINUE; END;
        IF @inBlock=1 BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlock=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1   BEGIN SET @out+=@ch; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1    BEGIN SET @out+=@ch; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;
        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlock=1; CONTINUE; END;
        IF @ch=N''''  BEGIN SET @out+=@ch; SET @inStr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'['   BEGIN SET @out+=@ch; SET @inBr=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'('   BEGIN SET @paren+=1; SET @out+=@ch; SET @i+=1; CONTINUE; END;
        IF @ch=N')'   BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @out+=@ch; SET @i+=1; CONTINUE; END;

        SET @pv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF @paren=0 AND UPPER(SUBSTRING(@Body,@i,5))=N'WHILE'
           AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1
           AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+5,1))=1
        BEGIN
            SET @out+=SUBSTRING(@Body,@i,5); SET @i+=5;     -- copy 'WHILE'
            SET @cp=0; SET @cs=0; SET @cbl=0; SET @cbk=0; SET @done=0;
            WHILE @i<=@len AND @done=0
            BEGIN
                SET @cc=SUBSTRING(@Body,@i,1);
                SET @cn=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
                IF @cbl=1 BEGIN SET @out+=@cc; IF @cc=CHAR(10) SET @cbl=0; SET @i+=1; CONTINUE; END;
                IF @cbk=1 BEGIN SET @out+=@cc; IF @cc=N']' SET @cbk=0; SET @i+=1; CONTINUE; END;
                IF @cs=1  BEGIN SET @out+=@cc; IF @cc=N'''' AND @cn=N'''' BEGIN SET @out+=@cn; SET @i+=2; CONTINUE; END; IF @cc=N'''' SET @cs=0; SET @i+=1; CONTINUE; END;
                IF @cc=N'-' AND @cn=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @cbl=1; CONTINUE; END;
                IF @cc=N'''' BEGIN SET @out+=@cc; SET @cs=1; SET @i+=1; CONTINUE; END;
                IF @cc=N'['  BEGIN SET @out+=@cc; SET @cbk=1; SET @i+=1; CONTINUE; END;
                IF @cc=N'('  BEGIN SET @cp+=1; SET @out+=@cc; SET @i+=1; CONTINUE; END;
                IF @cc=N')'  BEGIN SET @cp=CASE WHEN @cp>0 THEN @cp-1 ELSE 0 END; SET @out+=@cc; SET @i+=1; CONTINUE; END;
                SET @cpv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
                IF @cp=0 AND UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@cpv)=1
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',SUBSTRING(@Body,@i+5,1))=1
                BEGIN
                    SET @nLoop+=1; SET @k=CAST(@nLoop AS NVARCHAR(9));
                    SET @out+=SUBSTRING(@Body,@i,5)                       -- 'BEGIN'
                            + @CR + N'SET @__lc'+@k+N'=@__lc'+@k+N'+1;'
                            + @CR + N'IF @__lc'+@k+N'>1000 BREAK;';
                    SET @decls += N'DECLARE @__lc'+@k+N' INT=0;'+@CR;
                    SET @i+=5; SET @done=1; CONTINUE;
                END;
                IF @cp=0 AND @cc=N';' BEGIN SET @done=1; CONTINUE; END;  -- single-stmt body: stop, no inject
                SET @out+=@cc; SET @i+=1;
            END;
            CONTINUE;
        END;

        SET @out+=@ch; SET @i+=1;
    END;

    IF @decls=N'' RETURN @Body;     -- no loop capped -> unchanged
    RETURN @decls + @out;
END;
GO
PRINT 'TestGen.InjectLoopGuards installed.';
GO

-- Gap fix: reflow a shadow body to one-statement-per-line so the line-oriented
-- instrumenter can decompose a one-line compound block (e.g.
-- `BEGIN SET @s+=@i; SET @i+=1; END`).  Only inserts newlines where a keyword
-- shares a line with code (BEGIN/END/ELSE on their own line; ';' splits), so an
-- already-multi-line body passes through byte-unchanged (no regression).
-- Comment/string/bracket/paren aware; BEGIN/END TRY/CATCH kept intact as units.
-- All walker vars declared once at the top (DECLARE @x=expr in a loop evaluates
-- the initializer once at parse - see CLAUDE.md).
IF OBJECT_ID('TestGen.NormalizeShadowBody','FN') IS NOT NULL
    DROP FUNCTION TestGen.NormalizeShadowBody;
GO
CREATE FUNCTION TestGen.NormalizeShadowBody(@Body NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @CR NCHAR(2)=CHAR(13)+CHAR(10);
    DECLARE @out NVARCHAR(MAX)=N'';
    DECLARE @len INT=LEN(@Body), @i INT=1;
    DECLARE @inLine BIT=0,@inBlk BIT=0,@inStr BIT=0,@inBr BIT=0,@paren INT=0,@dirty BIT=0;
    DECLARE @ch NCHAR(1),@nx NCHAR(1),@pv NCHAR(1),@aft NCHAR(1),@pk NCHAR(1);
    DECLARE @j INT,@adv INT,@unit NVARCHAR(20);

    WHILE @i<=@len
    BEGIN
        SET @ch=SUBSTRING(@Body,@i,1);
        SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;

        IF @inLine=1 BEGIN SET @out+=@ch; IF @ch=CHAR(10) BEGIN SET @inLine=0; SET @dirty=0; END; SET @i+=1; CONTINUE; END;
        IF @inBlk=1  BEGIN SET @out+=@ch; IF @ch=N'*' AND @nx=N'/' BEGIN SET @out+=@nx; SET @i+=2; SET @inBlk=0; CONTINUE; END; SET @i+=1; CONTINUE; END;
        IF @inStr=1  BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N'''' AND @nx=N'''' BEGIN SET @out+=@nx; SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @inStr=0; SET @i+=1; CONTINUE; END;
        IF @inBr=1   BEGIN SET @out+=@ch; SET @dirty=1; IF @ch=N']' SET @inBr=0; SET @i+=1; CONTINUE; END;

        IF @ch=N'-' AND @nx=N'-' BEGIN SET @out+=N'--'; SET @i+=2; SET @inLine=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'/' AND @nx=N'*' BEGIN SET @out+=N'/*'; SET @i+=2; SET @inBlk=1; SET @dirty=1; CONTINUE; END;
        IF @ch=N'''' BEGIN SET @out+=@ch; SET @inStr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'['  BEGIN SET @out+=@ch; SET @inBr=1; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N'('  BEGIN SET @paren+=1; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;
        IF @ch=N')'  BEGIN SET @paren=CASE WHEN @paren>0 THEN @paren-1 ELSE 0 END; SET @out+=@ch; SET @dirty=1; SET @i+=1; CONTINUE; END;

        IF @ch=CHAR(13) BEGIN SET @out+=@ch; SET @i+=1; CONTINUE; END;
        IF @ch=CHAR(10) BEGIN SET @out+=@ch; SET @dirty=0; SET @i+=1; CONTINUE; END;

        IF @ch=N';' AND @paren=0
        BEGIN
            SET @out+=@ch; SET @i+=1;
            SET @j=@i;
            WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
            SET @pk=CASE WHEN @j<=@len THEN SUBSTRING(@Body,@j,1) ELSE N'' END;
            IF @pk<>N'' AND @pk<>CHAR(13) AND @pk<>CHAR(10)
            BEGIN SET @out+=@CR; SET @dirty=0; SET @i=@j; END;
            CONTINUE;
        END;

        SET @pv=CASE WHEN @i=1 THEN N' ' ELSE SUBSTRING(@Body,@i-1,1) END;
        IF PATINDEX(N'%[^A-Za-z0-9_@#]%',@pv)=1
        BEGIN
            SET @aft=CASE WHEN @i+5<=@len THEN SUBSTRING(@Body,@i+5,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,5))=N'BEGIN' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                SET @unit=N'BEGIN'; SET @adv=5;
                SET @j=@i+5; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                IF UPPER(SUBSTRING(@Body,@j,3))=N'TRY'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+3<=@len THEN SUBSTRING(@Body,@j+3,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'BEGIN TRY'; SET @adv=@j+3-@i; END
                ELSE IF UPPER(SUBSTRING(@Body,@j,5))=N'CATCH'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+5<=@len THEN SUBSTRING(@Body,@j+5,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'BEGIN CATCH'; SET @adv=@j+5-@i; END;
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=@unit; SET @i+=@adv;
                SET @j=@i; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                SET @pk=CASE WHEN @j<=@len THEN SUBSTRING(@Body,@j,1) ELSE N'' END;
                IF @pk<>N'' AND @pk<>CHAR(13) AND @pk<>CHAR(10) BEGIN SET @out+=@CR; SET @i=@j; END;
                SET @dirty=0;
                CONTINUE;
            END;
            SET @aft=CASE WHEN @i+3<=@len THEN SUBSTRING(@Body,@i+3,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,3))=N'END' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                SET @unit=N'END'; SET @adv=3;
                SET @j=@i+3; WHILE @j<=@len AND (SUBSTRING(@Body,@j,1)=N' ' OR SUBSTRING(@Body,@j,1)=CHAR(9)) SET @j+=1;
                IF UPPER(SUBSTRING(@Body,@j,3))=N'TRY'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+3<=@len THEN SUBSTRING(@Body,@j+3,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'END TRY'; SET @adv=@j+3-@i; END
                ELSE IF UPPER(SUBSTRING(@Body,@j,5))=N'CATCH'
                   AND PATINDEX(N'%[^A-Za-z0-9_@#]%',CASE WHEN @j+5<=@len THEN SUBSTRING(@Body,@j+5,1) ELSE N' ' END)=1
                    BEGIN SET @unit=N'END CATCH'; SET @adv=@j+5-@i; END;
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=@unit; SET @i+=@adv; SET @dirty=1;
                CONTINUE;
            END;
            SET @aft=CASE WHEN @i+4<=@len THEN SUBSTRING(@Body,@i+4,1) ELSE N' ' END;
            IF UPPER(SUBSTRING(@Body,@i,4))=N'ELSE' AND PATINDEX(N'%[^A-Za-z0-9_@#]%',@aft)=1
            BEGIN
                IF @dirty=1 BEGIN SET @out+=@CR; SET @dirty=0; END;
                SET @out+=N'ELSE'; SET @i+=4; SET @dirty=1;
                CONTINUE;
            END;
        END;

        SET @out+=@ch;
        IF @ch<>N' ' AND @ch<>CHAR(9) SET @dirty=1;
        SET @i+=1;
    END;

    RETURN @out;
END;
GO
PRINT 'TestGen.NormalizeShadowBody installed.';
GO

IF OBJECT_ID('TestGen.BuildShadowProcForFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.BuildShadowProcForFunction;
GO
CREATE PROCEDURE TestGen.BuildShadowProcForFunction
    @SchemaName   SYSNAME,
    @FunctionName SYSNAME,
    @ShadowName   SYSNAME       = NULL OUTPUT,
    @Status       NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2) = CHAR(13) + CHAR(10);
    SET @Status = N'OK';
    SET @ShadowName = @FunctionName + N'_covfn';

    DECLARE @kind VARCHAR(10) = TestGen.GetFunctionKind(@SchemaName, @FunctionName);
    IF @kind NOT IN ('FN','IF','TF')
    BEGIN
        SET @Status = N'UNSUPPORTED:not a T-SQL function (' + @kind + N')';
        RETURN;
    END;

    DECLARE @ObjId INT = OBJECT_ID(QUOTENAME(@SchemaName) + '.' + QUOTENAME(@FunctionName));
    DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(@ObjId);
    IF @def IS NULL BEGIN SET @Status = N'UNSUPPORTED:no definition (encrypted?)'; RETURN; END;

    /* ---- synthesize the input parameter list from the catalog ---- */
    DECLARE @params NVARCHAR(MAX) = N'';
    SELECT @params = @params
         + CASE WHEN @params = N'' THEN N'' ELSE N', ' END
         + p.name + N' '
         + dbo.TestGen_RebuildTypeName(TYPE_NAME(p.user_type_id), p.max_length, p.precision, p.scale)
    FROM sys.parameters p
    WHERE p.object_id = @ObjId AND p.parameter_id > 0
    ORDER BY p.parameter_id;

    /* ---- locate the body: everything after the first top-level AS ---- */
    DECLARE @AsPos INT = TestGen.FindTopLevelAs(@def);
    IF @AsPos = 0 BEGIN SET @Status = N'UNSUPPORTED:could not locate body AS keyword'; RETURN; END;
    DECLARE @body NVARCHAR(MAX) = LTRIM(SUBSTRING(@def, @AsPos + 2, LEN(@def)));

    DECLARE @shadowFull NVARCHAR(400) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ShadowName);
    DECLARE @header NVARCHAR(MAX);
    DECLARE @procBody NVARCHAR(MAX);

    IF @kind = 'FN'
    BEGIN
        -- scalar return type from sys.parameters (parameter_id = 0)
        DECLARE @rt SYSNAME, @rml SMALLINT, @rp TINYINT, @rs TINYINT;
        SELECT @rt = TYPE_NAME(user_type_id), @rml = max_length, @rp = precision, @rs = scale
        FROM sys.parameters WHERE object_id = @ObjId AND parameter_id = 0;
        IF @rt IS NULL BEGIN SET @Status = N'UNSUPPORTED:scalar return type not found'; RETURN; END;

        DECLARE @rtName NVARCHAR(200) = dbo.TestGen_RebuildTypeName(@rt, @rml, @rp, @rs);
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' ('
                    + @params + CASE WHEN @params = N'' THEN N'' ELSE N', ' END
                    + N'@__ret ' + @rtName + N' OUTPUT) AS' + @CRLF;
        SET @procBody = TestGen.RewriteScalarReturns(@body);
    END
    ELSE IF @kind = 'TF'
    BEGIN
        -- RETURNS @var TABLE(<cols>) AS BEGIN ... RETURN END
        -- pull the table-variable name and column spec from the header text.
        DECLARE @ret2 NVARCHAR(MAX);
        DECLARE @retKw INT = TestGen.FindKeyword(@def, N'RETURNS', 1);
        IF @retKw = 0 BEGIN SET @Status = N'UNSUPPORTED:RETURNS clause not found'; RETURN; END;
        SET @ret2 = SUBSTRING(@def, @retKw + 7, @AsPos - (@retKw + 7));   -- between RETURNS and AS
        SET @ret2 = LTRIM(RTRIM(@ret2));
        -- expect: @name TABLE ( ... )
        DECLARE @atPos INT = CHARINDEX(N'@', @ret2);
        DECLARE @tblKw INT = TestGen.FindKeyword(@ret2, N'TABLE', 1);
        IF @atPos = 0 OR @tblKw = 0 BEGIN SET @Status = N'UNSUPPORTED:multi-statement TABLE() spec not parseable'; RETURN; END;
        DECLARE @tvName NVARCHAR(200) = LTRIM(RTRIM(SUBSTRING(@ret2, @atPos, @tblKw - @atPos)));
        DECLARE @colSpec NVARCHAR(MAX) = LTRIM(SUBSTRING(@ret2, @tblKw + 5, LEN(@ret2)));  -- "(...)"

        -- Wrap the function body verbatim inside an outer BEGIN/END after
        -- declaring the return table variable.  The body already contains its
        -- own BEGIN ... INSERT @tv ... RETURN END; nesting is legal and keeps
        -- the body lines byte-identical, so the line map stays a fixed offset.
        -- The trailing bare RETURN is a control-transfer statement the
        -- instrumenter records; we do not need to SELECT the table var for
        -- coverage (the driver only needs the body executed).
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' ('
                    + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF
                    + N'DECLARE ' + @tvName + N' TABLE ' + @colSpec + N';' + @CRLF;
        SET @procBody = @body + @CRLF + N'END;';
    END
    ELSE  -- IF : RETURNS TABLE AS RETURN ( SELECT ... )
    BEGIN
        -- body is:  RETURN ( SELECT ... )   (possibly with surrounding whitespace)
        DECLARE @rk INT = TestGen.FindKeyword(@body, N'RETURN', 1);
        IF @rk = 0 BEGIN SET @Status = N'UNSUPPORTED:inline RETURN not found'; RETURN; END;
        DECLARE @sel NVARCHAR(MAX) = LTRIM(SUBSTRING(@body, @rk + 6, LEN(@body)));
        -- strip one outer ( ... ) pair if present
        SET @sel = TestGen.StripOuterParens(@sel);
        SET @header = N'CREATE PROCEDURE ' + @shadowFull + N' (' + @params + N') AS' + @CRLF
                    + N'BEGIN' + @CRLF;
        SET @procBody = @sel + @CRLF + N'END;';
    END;

    -- v11 #11: expand a SET=CASE / RETURN CASE into an IF/ELSE chain so each arm
    -- becomes an instrumentable branch (no-op on bodies without a top-level CASE
    -- assignment).  Runs before Normalize so the emitted IF lines get reflowed too.
    SET @procBody = TestGen.ExpandCaseToIf(@procBody);
    -- Gap fix: reflow one-line compound blocks to one-statement-per-line so the
    -- line-oriented instrumenter can decompose them (no-op on multi-line code).
    SET @procBody = TestGen.NormalizeShadowBody(@procBody);
    -- v11 Step1: cap every WHILE..BEGIN loop in the shadow so the coverage probe
    -- can never run away (local counter; ~nanoseconds/iteration; preserves
    -- coverage - one iteration already covers the body).
    SET @procBody = TestGen.InjectLoopGuards(@procBody);

    /* ---- (re)create the shadow procedure ----
     * Defensively clear EVERY stale artifact a prior or interrupted run could
     * have left under this shadow name, not just a same-named PROCEDURE.  The
     * coverage instrument-swap leaves a SYNONYM at the base shadow name plus
     * _cov / _orig procedures; if RunCoverage died mid-swap (or its teardown was
     * skipped) the synonym survives, and a bare OBJECT_ID(...,'P') check misses
     * it - so CREATE PROCEDURE then fails with "There is already an object named
     * '<fn>_covfn'" and the function reports a false generation failure on every
     * subsequent sweep.  Drop the synonym FIRST (it occupies the base name),
     * then the _cov / _orig copies, then any same-named procedure. */
    DECLARE @covFull  NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ShadowName+N'_cov');
    DECLARE @origFull NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@ShadowName+N'_orig');
    BEGIN TRY IF OBJECT_ID(@shadowFull,'SN') IS NOT NULL EXEC('DROP SYNONYM '  +@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@covFull,'P')     IS NOT NULL EXEC('DROP PROCEDURE '+@covFull);    END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@origFull,'P')    IS NOT NULL EXEC('DROP PROCEDURE '+@origFull);   END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'P')  IS NOT NULL EXEC('DROP PROCEDURE '+@shadowFull);  END TRY BEGIN CATCH END CATCH;

    DECLARE @full NVARCHAR(MAX) = @header + @procBody;
    BEGIN TRY
        EXEC sys.sp_executesql @full;
    END TRY
    BEGIN CATCH
        SET @Status = N'UNSUPPORTED:shadow compile failed: ' + ERROR_MESSAGE();
        -- diagnostic: surface the exact DDL we tried to compile so a transform
        -- edge case can be pinpointed instead of guessed at.
        PRINT '  [shadow-compile-failed] ' + QUOTENAME(@SchemaName) + N'.' + @FunctionName;
        PRINT '  ---- attempted shadow DDL ----';
        PRINT @full;
        PRINT '  ------------------------------';
        RETURN;
    END CATCH;

    /* ---- build the line map (header offset + verbatim body) ---- *
     * The body lines are copied verbatim into the shadow after a fixed
     * header-line count, so FunctionLine N maps to ShadowLine N + offset.
     * For scalar/mTVF the RETURN rewrites stay on their original lines (the
     * BEGIN..END replacement is single-line), so the offset is constant. */
    DECLARE @hdrLines INT = LEN(@header) - LEN(REPLACE(@header, CHAR(10), N''));
    DECLARE @bodyStartInDef INT =
        (SELECT LEN(SUBSTRING(@def,1,@AsPos)) - LEN(REPLACE(SUBSTRING(@def,1,@AsPos), CHAR(10), N'')));

    DELETE FROM TestGen.ShadowLineMap WHERE SchemaName=@SchemaName AND FunctionName=@FunctionName;
    ;WITH n AS (
        SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
        FROM sys.all_objects
    )
    INSERT INTO TestGen.ShadowLineMap (SchemaName, FunctionName, FunctionLine, ShadowLine)
    SELECT @SchemaName, @FunctionName, rn, rn + (@hdrLines - @bodyStartInDef)
    FROM n
    WHERE rn <= (LEN(@def) - LEN(REPLACE(@def, CHAR(10), N'')) + 1);

    RETURN;
END;
GO
PRINT 'TestGen.BuildShadowProcForFunction installed.';
GO

/*===========================================================================
 * TestGen.Fn_HasTableDependency
 *   1 if the function references any USER_TABLE, else 0.  Drives whether the
 *   generator can bless concrete return values at generation time (pure
 *   functions) or must fall back to determinism/shape + SkipTest residue.
 *==========================================================================*/
IF OBJECT_ID('TestGen.Fn_HasTableDependency','FN') IS NOT NULL DROP FUNCTION TestGen.Fn_HasTableDependency;
GO
CREATE FUNCTION TestGen.Fn_HasTableDependency
(
    @SchemaName SYSNAME, @FunctionName SYSNAME
)
RETURNS BIT
AS
BEGIN
    DECLARE @objid INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    IF @objid IS NULL RETURN 0;
    IF EXISTS (
        SELECT 1
        FROM sys.sql_expression_dependencies d
        JOIN sys.objects o ON o.object_id = d.referenced_id
        WHERE d.referencing_id = @objid AND o.type = 'U'
    ) RETURN 1;
    RETURN 0;
END;
GO
PRINT 'TestGen.Fn_HasTableDependency installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForScalarFunction
 *   Emits test_<fn> for a scalar (FN) function.  Assertions, honest:
 *     - determinism: fn() called twice is equal (real; catches NEWID/GETDATE)
 *     - blessed value (PURE functions only): fn(args) = a value captured at
 *       generation time, emitted as AssertEquals - correct because no table
 *       state can change a pure function's result
 *     - NULL-argument characterization (pure: blessed; else SkipTest)
 *   Table-dependent functions get determinism + a SkipTest value placeholder.
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForScalarFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForScalarFunction;
GO
CREATE PROCEDURE TestGen.GenerateTestsForScalarFunction
    @SchemaName      SYSNAME,
    @FunctionName    SYSNAME,
    @TestClassName   SYSNAME       = NULL,
    @ExecuteScript   BIT           = 1,
    @GeneratedScript NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2) = CHAR(13)+CHAR(10);
    IF @TestClassName IS NULL SET @TestClassName = N'test_' + @FunctionName;

    IF TestGen.GetFunctionKind(@SchemaName,@FunctionName) <> 'FN'
    BEGIN RAISERROR('%s.%s is not a scalar function.',16,1,@SchemaName,@FunctionName); RETURN; END;

    DECLARE @objid INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @fnFull NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@FunctionName);

    -- return type
    DECLARE @rt SYSNAME,@rml SMALLINT,@rp TINYINT,@rs TINYINT;
    SELECT @rt=TYPE_NAME(user_type_id),@rml=max_length,@rp=precision,@rs=scale
    FROM sys.parameters WHERE object_id=@objid AND parameter_id=0;
    DECLARE @rtName NVARCHAR(200) = dbo.TestGen_RebuildTypeName(@rt,@rml,@rp,@rs);
    DECLARE @blessable BIT = CASE WHEN LOWER(@rt) IN
        ('tinyint','smallint','int','bigint','bit','decimal','numeric','money',
         'smallmoney','float','real','char','varchar','nchar','nvarchar','date',
         'datetime','datetime2','smalldatetime','datetimeoffset','time') THEN 1 ELSE 0 END;

    -- positional literal lists (happy variant 0, and all-NULL)
    DECLARE @litHappy NVARCHAR(MAX)=N'', @litNull NVARCHAR(MAX)=N'';
    SELECT @litHappy = @litHappy + CASE WHEN @litHappy=N'' THEN N'' ELSE N', ' END
             + TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0),
           @litNull  = @litNull  + CASE WHEN @litNull=N''  THEN N'' ELSE N', ' END + N'NULL'
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0
    ORDER BY parameter_id;

    DECLARE @hasTables BIT = TestGen.Fn_HasTableDependency(@SchemaName,@FunctionName);

    -- FakeTable referenced user tables (isolation for the determinism test)
    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes = @fakes + N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                  + SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;' + @CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- bless concrete values at generation time for PURE + blessable functions
    DECLARE @blessHappy NVARCHAR(MAX)=NULL, @blessNull NVARCHAR(MAX)=NULL, @nullIsNull BIT=NULL;
    IF @hasTables=0 AND @blessable=1
    BEGIN
        DECLARE @cv NVARCHAR(MAX), @sql NVARCHAR(MAX);
        BEGIN TRY
            SET @sql=N'SELECT @v=CONVERT(NVARCHAR(MAX),'+@fnFull+N'('+@litHappy+N'),121)';
            EXEC sys.sp_executesql @sql,N'@v NVARCHAR(MAX) OUTPUT',@v=@cv OUTPUT;
            SET @blessHappy=@cv;
        END TRY BEGIN CATCH SET @blessHappy=NULL; SET @blessable=0; END CATCH;

        IF @blessable=1 AND @litNull<>N''
        BEGIN
            BEGIN TRY
                SET @sql=N'SELECT @v=CONVERT(NVARCHAR(MAX),'+@fnFull+N'('+@litNull+N'),121)';
                EXEC sys.sp_executesql @sql,N'@v NVARCHAR(MAX) OUTPUT',@v=@cv OUTPUT;
                SET @blessNull=@cv; SET @nullIsNull=CASE WHEN @cv IS NULL THEN 1 ELSE 0 END;
            END TRY BEGIN CATCH SET @blessNull=NULL; SET @nullIsNull=NULL; END CATCH;
        END;
    END;

    DECLARE @isStr BIT = CASE WHEN LOWER(@rt) IN ('char','varchar','nchar','nvarchar') THEN 1 ELSE 0 END;

    -----------------------------------------------------------------------
    -- assemble the script
    -----------------------------------------------------------------------
    DECLARE @s NVARCHAR(MAX) =
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@TestClassName+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- determinism test (always)
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' is deterministic]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    DECLARE @a '+@rtName+N', @b '+@rtName+N';'+@CRLF+
        N'    SELECT @a = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    SELECT @b = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEquals @a, @b, ''Function is not deterministic for the sample inputs.'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- blessed happy-path value test (pure + blessable) OR honest placeholder
    IF @blessHappy IS NOT NULL OR (@hasTables=0 AND @blessable=1)
    BEGIN
        DECLARE @expHappy NVARCHAR(MAX) =
            CASE WHEN @blessHappy IS NULL THEN N'NULL'
                 WHEN @isStr=1 THEN N'N'''+REPLACE(@blessHappy,N'''',N'''''')+N''''
                 ELSE N'CAST(N'''+REPLACE(@blessHappy,N'''',N'''''')+N''' AS '+@rtName+N')' END;
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns blessed value for sample inputs]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    DECLARE @expected '+@rtName+N' = '+@expHappy+N';'+@CRLF+
            N'    DECLARE @actual '+@rtName+N' = '+@fnFull+N'('+@litHappy+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEquals @expected, @actual;'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END
    ELSE
    BEGIN
        SET @s += N'--[@tSQLt:SkipTest](''value characterization needs a blessed baseline under seeded data'')'+@CRLF+
            N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' value characterization - needs manual bless]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    -- '+@FunctionName+N' reads tables; its return value depends on seeded data.'+@CRLF+
            N'    -- Seed the faked tables in Assemble, capture the expected value, then'+@CRLF+
            N'    -- replace this SkipTest with an AssertEquals.  Coverage is still'+@CRLF+
            N'    -- measured independently via TestGen.RunCoverageForFunction.'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END;

    -- NULL-argument test (pure + blessable only; else covered by determinism)
    IF @litNull <> N'' AND @hasTables=0 AND @blessable=1
    BEGIN
        DECLARE @expNull NVARCHAR(MAX) =
            CASE WHEN @nullIsNull=1 OR @blessNull IS NULL THEN N'NULL'
                 WHEN @isStr=1 THEN N'N'''+REPLACE(@blessNull,N'''',N'''''')+N''''
                 ELSE N'CAST(N'''+REPLACE(@blessNull,N'''',N'''''')+N''' AS '+@rtName+N')' END;
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' handles NULL arguments]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    DECLARE @expected '+@rtName+N' = '+@expNull+N';'+@CRLF+
            N'    DECLARE @actual '+@rtName+N' = '+@fnFull+N'('+@litNull+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEquals @expected, @actual;'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    END;

    SET @GeneratedScript = @s;
    IF @ExecuteScript = 1
        EXEC TestGen.ExecuteBatchedScript @s;
END;
GO
PRINT 'TestGen.GenerateTestsForScalarFunction installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForTableFunction   (IF + TF)
 *   Emits test_<fn> for a table-valued function.  Assertions, honest:
 *     - result-set shape: SELECT TOP 0 * INTO #actual FROM fn(args) and assert
 *       it matches the function's catalogued RETURNS columns (real)
 *     - determinism: two materializations of fn(args) are AssertEqualsTable
 *   Row-level value blessing under seeded data is left as a SkipTest
 *   placeholder (follow-up); coverage is measured via RunCoverageForFunction.
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForTableFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForTableFunction;
GO
CREATE PROCEDURE TestGen.GenerateTestsForTableFunction
    @SchemaName      SYSNAME,
    @FunctionName    SYSNAME,
    @TestClassName   SYSNAME       = NULL,
    @ExecuteScript   BIT           = 1,
    @GeneratedScript NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2)=CHAR(13)+CHAR(10);
    IF @TestClassName IS NULL SET @TestClassName=N'test_'+@FunctionName;

    DECLARE @kind VARCHAR(10)=TestGen.GetFunctionKind(@SchemaName,@FunctionName);
    IF @kind NOT IN ('IF','TF')
    BEGIN RAISERROR('%s.%s is not a table-valued function.',16,1,@SchemaName,@FunctionName); RETURN; END;

    DECLARE @objid INT=OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @fnFull NVARCHAR(400)=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@FunctionName);

    DECLARE @litHappy NVARCHAR(MAX)=N'';
    SELECT @litHappy=@litHappy+CASE WHEN @litHappy=N'' THEN N'' ELSE N', ' END
             +TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0)
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0 ORDER BY parameter_id;

    -- catalogued return columns -> a typed empty table for the shape assertion
    DECLARE @expCols NVARCHAR(MAX)=N'';
    SELECT @expCols=@expCols+CASE WHEN @expCols=N'' THEN N'' ELSE N', ' END
             +QUOTENAME(c.name)+N' '
             +dbo.TestGen_RebuildTypeName(TYPE_NAME(c.user_type_id),c.max_length,c.precision,c.scale)
    FROM sys.columns c WHERE c.object_id=@objid ORDER BY c.column_id;

    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes=@fakes+N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                +SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;'+@CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- [item 4] PURE TVF (no table deps) -> snapshot the current output into a
    -- persistent baseline table and AssertEqualsTable against it.  Table-
    -- dependent TVFs keep the honest SkipTest below.
    DECLARE @hasTables BIT = TestGen.Fn_HasTableDependency(@SchemaName,@FunctionName);
    DECLARE @blessOK   BIT = 0;
    DECLARE @blessName SYSNAME = LEFT(N'FnBless_'+@SchemaName+N'_'+@FunctionName,128);
    DECLARE @blessFull NVARCHAR(400) = N'TestGenLog.'+QUOTENAME(@blessName);
    IF @hasTables=0
    BEGIN
        BEGIN TRY
            IF OBJECT_ID(@blessFull) IS NOT NULL EXEC('DROP TABLE '+@blessFull);
            EXEC('SELECT * INTO '+@blessFull+' FROM '+@fnFull+'('+@litHappy+')');
            SET @blessOK=1;
        END TRY BEGIN CATCH SET @blessOK=0; END CATCH;
    END;

    DECLARE @s NVARCHAR(MAX)=
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@TestClassName+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@TestClassName+N''';'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- shape test
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns the declared result shape]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    SELECT TOP 0 * INTO #actual FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    CREATE TABLE #expected ('+@expCols+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEqualsTableSchema ''#expected'', ''#actual'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- determinism test
    SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' is deterministic]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+
        N'    SELECT * INTO #a FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    SELECT * INTO #b FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
        N'    EXEC tSQLt.AssertEqualsTable ''#a'', ''#b'';'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    -- [item 4] row-value test: pure TVF -> AssertEqualsTable vs the blessed
    -- snapshot; table-dependent TVF -> honest SkipTest.
    IF @blessOK=1
        SET @s += N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' returns blessed rows]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    SELECT * INTO #actual FROM '+@fnFull+N'('+@litHappy+N');'+@CRLF+
            N'    EXEC tSQLt.AssertEqualsTable '''+@blessFull+N''', ''#actual'';'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;
    ELSE
        SET @s += N'--[@tSQLt:SkipTest](''row-value characterization needs a blessed baseline under seeded data'')'+@CRLF+
            N'CREATE PROCEDURE '+QUOTENAME(@TestClassName)+N'.[test '+@FunctionName+N' row characterization - needs manual bless]'+@CRLF+
            N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+
            N'    -- Table-dependent: seed the faked tables, materialize '+@fnFull+N'(...),'+@CRLF+
            N'    -- and AssertEqualsTable against a blessed baseline.  Coverage is'+@CRLF+
            N'    -- measured independently via TestGen.RunCoverageForFunction.'+@CRLF+
            N'END;'+@CRLF+N'GO'+@CRLF+@CRLF;

    SET @GeneratedScript=@s;
    IF @ExecuteScript=1 EXEC TestGen.ExecuteBatchedScript @s;
END;
GO
PRINT 'TestGen.GenerateTestsForTableFunction installed.';
GO

/*===========================================================================
 * TestGen.GenerateTestsForObject  -  dispatcher
 *==========================================================================*/
IF OBJECT_ID('TestGen.GenerateTestsForObject','P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateTestsForObject;
GO
CREATE PROCEDURE TestGen.GenerateTestsForObject
    @SchemaName    SYSNAME,
    @ObjectName    SYSNAME,
    @ExecuteScript BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ObjectName));
    IF @id IS NULL BEGIN RAISERROR('%s.%s does not exist.',16,1,@SchemaName,@ObjectName); RETURN; END;
    DECLARE @type CHAR(2) = (SELECT type FROM sys.objects WHERE object_id=@id);

    IF @type='P'
        EXEC TestGen.GenerateTestsForProcedure @SchemaName=@SchemaName,@ProcName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE IF @type='FN'
        EXEC TestGen.GenerateTestsForScalarFunction @SchemaName=@SchemaName,@FunctionName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE IF @type IN ('IF','TF')
        EXEC TestGen.GenerateTestsForTableFunction @SchemaName=@SchemaName,@FunctionName=@ObjectName,@ExecuteScript=@ExecuteScript;
    ELSE
        RAISERROR('%s.%s is type %s - not a supported testable object (P/FN/IF/TF).',16,1,@SchemaName,@ObjectName,@type);
END;
GO
PRINT 'TestGen.GenerateTestsForObject installed.';
GO

/*===========================================================================
 * TestGen.RunCoverageForFunction
 *   1. build shadow proc   2. generate driver class test_<fn>_covfn
 *   3. call unchanged TestGen.RunCoverage on the shadow
 *   4. relabel CoverageResult to the function   5. clean up
 *==========================================================================*/
/*===========================================================================
 * v11 Step 2 (design/DESIGN_v11_BranchSeeding.md, Layer B): predicate-inversion
 * branch seeding.  SeedFromLeaf inverts one comparison leaf to a value that
 * makes the predicate TRUE; ExtractBranchSeeds pulls (param, satisfying value)
 * leaves from a function body.  RunCoverageForFunction then drives the shadow
 * once per leaf (target param satisfied, others happy), reaching value-gated
 * branches on purpose.  A wrong seed is harmless (each seed EXEC is TRY/CATCH'd
 * and the Step-1 loop cap makes it hang-proof); unsolvable predicates yield no
 * seed and stay honest residue.
 *==========================================================================*/
IF OBJECT_ID('TestGen.SeedFromLeaf','FN') IS NOT NULL
    DROP FUNCTION TestGen.SeedFromLeaf;
GO
CREATE FUNCTION TestGen.SeedFromLeaf(@op VARCHAR(12), @lit NVARCHAR(500))
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
PRINT 'TestGen.SeedFromLeaf installed.';
GO
IF OBJECT_ID('TestGen.ExtractBranchSeeds','TF') IS NOT NULL
    DROP FUNCTION TestGen.ExtractBranchSeeds;
GO
-- v11 Step 2.1: predicate-aware + ancestor-chaining.  Tracks BEGIN/END nesting
-- and a stack of enclosing IF/WHILE gates; each branch's seed = its own leaves
-- PLUS every ancestor gate's satisfying assignment.  Returns BranchId so the
-- caller drives one shadow EXEC per branch with all assigned params overridden.
-- See design/DESIGN_v11_AncestorChaining.md.
CREATE FUNCTION TestGen.ExtractBranchSeeds(@Body NVARCHAR(MAX), @ParamCsv NVARCHAR(MAX))
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
    DECLARE @pp INT,@psA BIT,@pcl BIT,@pbk BIT,@stop BIT,@lhsOk BIT,@callDepth INT;
    DECLARE @pstk NVARCHAR(400);
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
                SET @pp=0; SET @psA=0; SET @pcl=0; SET @pbk=0; SET @stop=0; SET @bodyIsBegin=0; SET @lhsOk=1; SET @callDepth=0; SET @pstk=N'';
                WHILE @i<=@len AND @stop=0
                BEGIN
                    SET @ch=SUBSTRING(@Body,@i,1);
                    SET @nx=CASE WHEN @i<@len THEN SUBSTRING(@Body,@i+1,1) ELSE N'' END;
                    IF @pcl=1 BEGIN IF @ch=CHAR(10) SET @pcl=0; SET @i+=1; CONTINUE; END;
                    IF @psA=1 BEGIN IF @ch=N'''' AND @nx=N'''' BEGIN SET @i+=2; CONTINUE; END; IF @ch=N'''' SET @psA=0; SET @i+=1; CONTINUE; END;
                    IF @pbk=1 BEGIN IF @ch=N']' SET @pbk=0; SET @i+=1; CONTINUE; END;
                    IF @ch=N'-' AND @nx=N'-' BEGIN SET @i+=2; SET @pcl=1; CONTINUE; END;
                    -- v11 #9: reversed STRING predicate  'literal' <op> @param  (e.g. 'US' = @code).
                    -- A string at operand position (not a recognised @param RHS, which the @-handler
                    -- already consumes) may be the LHS of a reversed comparison; read it, mirror the
                    -- operator, seed the param.  Falls through to the normal string-skip otherwise.
                    IF @lhsOk=1 AND @callDepth=0 AND @ch=N''''
                    BEGIN
                        SET @operand=N''''; SET @k=@i+1;
                        WHILE @k<=@len BEGIN SET @kc=SUBSTRING(@Body,@k,1); IF @kc=N'''' AND SUBSTRING(@Body,@k+1,1)=N'''' BEGIN SET @operand+=N''''''; SET @k+=2; CONTINUE; END; SET @operand+=@kc; SET @k+=1; IF @kc=N'''' BREAK; END;
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
                            SET @lhsOk=0; SET @i=@k; CONTINUE;
                        END;
                    END;
                    IF @ch=N'''' BEGIN SET @i+=1; SET @psA=1; CONTINUE; END;
                    IF @ch=N'[' BEGIN SET @i+=1; SET @pbk=1; CONTINUE; END;
                    -- v11 #1: classify each '(' as a GROUPING paren (a boolean/comparison
                    -- sub-expression - extract leaves inside it) or a function-CALL paren
                    -- (dbo.f(...), ISNULL(...) - suppress, its args aren't seedable leaves).
                    -- @lhsOk=1 means we're at an operand position => grouping; =0 means we
                    -- just read an identifier/function name => call.  @callDepth counts only
                    -- call parens, so extraction is gated on @callDepth=0 (was @pp=0), which
                    -- now lets IF (@x > 5) / (5 = @x) / (@a AND @b) through.
                    IF @ch=N'(' BEGIN IF @lhsOk=1 SET @pstk=@pstk+N'G'; ELSE BEGIN SET @pstk=@pstk+N'C'; SET @callDepth+=1; END; SET @pp+=1; SET @lhsOk=1; SET @i+=1; CONTINUE; END;
                    IF @ch=N')' BEGIN IF LEN(@pstk)>0 BEGIN IF RIGHT(@pstk,1)=N'C' SET @callDepth=CASE WHEN @callDepth>0 THEN @callDepth-1 ELSE 0 END; SET @pstk=LEFT(@pstk,LEN(@pstk)-1); END; SET @pp=CASE WHEN @pp>0 THEN @pp-1 ELSE 0 END; SET @lhsOk=0; SET @i+=1; CONTINUE; END;

                    IF @callDepth=0
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
                                -- v11 #5/#7: @param <op> NON-LITERAL RHS (another param, GETDATE(),
                                -- @@SPID, dbo.f(), ...).  We can't read a literal, but an inequality
                                -- is still satisfiable by driving @param to a type extreme regardless
                                -- of the RHS value: <,<= -> type MIN ; >,>= -> type MAX.  The <<MIN>>/
                                -- <<MAX>> sentinel is resolved per-param-type in RunCoverageForFunction.
                                -- =,<> against a non-literal stays residue (can't match an unknown).
                                ELSE IF @op IN ('<','<=') AND @operand IS NULL INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,N'<<MIN>>');
                                ELSE IF @op IN ('>','>=') AND @operand IS NULL INSERT @leaf(ParamName,SeedLiteral) VALUES(@tok,N'<<MAX>>');
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
PRINT 'TestGen.ExtractBranchSeeds installed.';
GO

IF OBJECT_ID('TestGen.RunCoverageForFunction','P') IS NOT NULL
    DROP PROCEDURE TestGen.RunCoverageForFunction;
GO
CREATE PROCEDURE TestGen.RunCoverageForFunction
    @SchemaName   SYSNAME,
    @FunctionName SYSNAME,
    @OutputMode   VARCHAR(10) = 'TEXT',
    @BatchId      DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CRLF NCHAR(2)=CHAR(13)+CHAR(10);
    DECLARE @kind VARCHAR(10)=TestGen.GetFunctionKind(@SchemaName,@FunctionName);
    IF @kind NOT IN ('FN','IF','TF')
    BEGIN
        PRINT 'RunCoverageForFunction: '+@SchemaName+'.'+@FunctionName+' is not a T-SQL function ('+@kind+'). Coverage deferred.';
        RETURN;
    END;

    -- 1. shadow
    DECLARE @shadow SYSNAME, @status NVARCHAR(200);
    EXEC TestGen.BuildShadowProcForFunction @SchemaName=@SchemaName,@FunctionName=@FunctionName,
         @ShadowName=@shadow OUTPUT,@Status=@status OUTPUT;
    IF @status <> N'OK'
    BEGIN
        PRINT '=============================================================';
        PRINT ' COVERAGE DEFERRED: '+@SchemaName+'.'+@FunctionName;
        PRINT ' '+@status;
        PRINT ' Shadow procedure could not be built - honest deferral, not a false 0%.';
        PRINT '=============================================================';
        IF @BatchId IS NOT NULL
            INSERT TestGen.CoverageResult
                (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
                 TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
                 TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
            VALUES (@BatchId,@SchemaName,@FunctionName,0,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,0,0,
                 @status,N'NOT_TESTABLE',@status,SYSUTCDATETIME());
        RETURN;
    END;

    DECLARE @objid INT=OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@FunctionName));
    DECLARE @shadowFull NVARCHAR(400)=QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow);
    DECLARE @driverClass SYSNAME = N'test_'+@shadow;

    -- per-parameter happy literal (drives @namedHappy below + the seed args)
    -- happyLit drives the @namedHappy list; minLit/maxLit (type boundary-low /
    -- boundary-high) resolve the <<MIN>>/<<MAX>> sentinels the extractor emits for
    -- @param <op> non-literal-RHS branches (v11 #5/#7).
    DECLARE @ph TABLE (ord INT, name SYSNAME, happyLit NVARCHAR(MAX), minLit NVARCHAR(MAX), maxLit NVARCHAR(MAX));
    INSERT @ph (ord,name,happyLit,minLit,maxLit)
    SELECT parameter_id, name,
           TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,0),
           TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,1),
           TestGen.GetSampleValueLiteral(TYPE_NAME(user_type_id),max_length,precision,scale,2)
    FROM sys.parameters WHERE object_id=@objid AND parameter_id>0;

    DECLARE @namedHappy NVARCHAR(MAX)=N'', @namedNull NVARCHAR(MAX)=N'';
    SELECT @namedHappy=@namedHappy+name+N'='+happyLit+N', ',
           @namedNull =@namedNull +name+N'=NULL, '
    FROM @ph ORDER BY ord;

    -- FakeTable list for the driver
    DECLARE @fakes NVARCHAR(MAX)=N'';
    SELECT @fakes=@fakes+N'    BEGIN TRY EXEC TestGen.SafeFakeTable N'''
                +SCHEMA_NAME(o.schema_id)+N'.'+o.name+N'''; END TRY BEGIN CATCH END CATCH;'+@CRLF
    FROM (SELECT DISTINCT d.referenced_id
          FROM sys.sql_expression_dependencies d
          JOIN sys.objects o2 ON o2.object_id=d.referenced_id AND o2.type='U'
          WHERE d.referencing_id=@objid) x
    JOIN sys.objects o ON o.object_id=x.referenced_id;

    -- shadow OUTPUT clause for scalar
    DECLARE @ret NVARCHAR(100) = CASE WHEN @kind='FN' THEN N'@__ret=@o OUTPUT' ELSE N'' END;
    DECLARE @retDecl NVARCHAR(200)=N'';
    IF @kind='FN'
    BEGIN
        DECLARE @rt2 SYSNAME,@rml2 SMALLINT,@rp2 TINYINT,@rs2 TINYINT;
        SELECT @rt2=TYPE_NAME(user_type_id),@rml2=max_length,@rp2=precision,@rs2=scale
        FROM sys.parameters WHERE object_id=@objid AND parameter_id=0;
        SET @retDecl=N'    DECLARE @o '+dbo.TestGen_RebuildTypeName(@rt2,@rml2,@rp2,@rs2)+N';'+@CRLF;
    END;

    -- trim trailing ", " from named lists
    IF RIGHT(@namedHappy,1)=N' ' SET @namedHappy=LEFT(@namedHappy,LEN(@namedHappy)-1);
    IF RIGHT(@namedHappy,1)=N',' SET @namedHappy=LEFT(@namedHappy,LEN(@namedHappy)-1);
    IF RIGHT(@namedNull,1)=N' '  SET @namedNull=LEFT(@namedNull,LEN(@namedNull)-1);
    IF RIGHT(@namedNull,1)=N','  SET @namedNull=LEFT(@namedNull,LEN(@namedNull)-1);

    DECLARE @execHappy NVARCHAR(MAX)=N'    EXEC '+@shadowFull
        +CASE WHEN @namedHappy=N'' THEN N'' ELSE N' '+@namedHappy END
        +CASE WHEN @ret=N'' THEN N'' ELSE CASE WHEN @namedHappy=N'' THEN N' ' ELSE N', ' END+@ret END+N';';
    DECLARE @execNull NVARCHAR(MAX)=N'    EXEC '+@shadowFull
        +CASE WHEN @namedNull=N'' THEN N'' ELSE N' '+@namedNull END
        +CASE WHEN @ret=N'' THEN N'' ELSE CASE WHEN @namedNull=N'' THEN N' ' ELSE N', ' END+@ret END+N';';

    -- Step 2: predicate-inversion seed calls (one per branch leaf; target param
    -- satisfied, others happy).  Wrapped so any extractor failure is non-fatal -
    -- coverage then falls back to happy+NULL only.
    DECLARE @execSeeds NVARCHAR(MAX)=N'', @seedCount INT=0;
    BEGIN TRY
        DECLARE @fndef NVARCHAR(MAX)=OBJECT_DEFINITION(@objid);
        DECLARE @asp INT = TestGen.FindTopLevelAs(@fndef);
        DECLARE @fnbody NVARCHAR(MAX)= CASE WHEN @asp>0 THEN SUBSTRING(@fndef,@asp+2,LEN(@fndef)) ELSE @fndef END;
        -- v11 #11: expand SET=CASE / RETURN CASE so the seeder sees the same IF arms
        -- the shadow does, and derives a value for each (no-op when there is no CASE).
        SET @fnbody = TestGen.ExpandCaseToIf(@fnbody);
        DECLARE @paramCsv NVARCHAR(MAX)=N'';
        SELECT @paramCsv=@paramCsv+name+N',' FROM @ph ORDER BY ord;
        DECLARE @retClause NVARCHAR(120)=CASE WHEN @ret=N'' THEN N'' ELSE N', '+@ret END;
        ;WITH raw AS (SELECT BranchId, ParamName, SeedLiteral FROM TestGen.ExtractBranchSeeds(@fnbody,@paramCsv)),
              asg AS (SELECT BranchId, ParamName, MAX(SeedLiteral) AS SeedLiteral FROM raw GROUP BY BranchId, ParamName)
        SELECT @execSeeds = @execSeeds
             + N'    BEGIN TRY EXEC '+@shadowFull+N' '+ z.args + @retClause + N'; END TRY BEGIN CATCH END CATCH;'+@CRLF,
               @seedCount = @seedCount + 1
        FROM (
            SELECT b.BranchId,
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                        p.name + N'=' + CASE a.SeedLiteral
                                          WHEN N'<<MIN>>' THEN p.minLit
                                          WHEN N'<<MAX>>' THEN p.maxLit
                                          ELSE ISNULL(a.SeedLiteral, p.happyLit) END),
                        N', ') WITHIN GROUP (ORDER BY p.ord) AS args
            FROM (SELECT DISTINCT BranchId FROM asg) b
            CROSS JOIN @ph p
            LEFT JOIN asg a ON a.BranchId=b.BranchId AND UPPER(a.ParamName)=UPPER(p.name)
            GROUP BY b.BranchId
        ) z;
    END TRY
    BEGIN CATCH
        SET @execSeeds = N'';
        PRINT 'RunCoverageForFunction: branch seeding skipped ('+ERROR_MESSAGE()+')';
    END CATCH;

    DECLARE @drv NVARCHAR(MAX)=
        N'IF EXISTS (SELECT 1 FROM sys.schemas WHERE name=N'''+@driverClass+N''')'+@CRLF+
        N'    EXEC tSQLt.DropClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'EXEC tSQLt.NewTestClass '''+@driverClass+N''';'+@CRLF+N'GO'+@CRLF+@CRLF+
        N'CREATE PROCEDURE '+QUOTENAME(@driverClass)+N'.[test drive '+@shadow+N' sample inputs]'+@CRLF+
        N'AS'+@CRLF+N'BEGIN'+@CRLF+N'    SET NOCOUNT ON;'+@CRLF+ISNULL(@fakes,N'')+@retDecl+
        N'    BEGIN TRY'+@CRLF+@execHappy+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        N'    BEGIN TRY'+@CRLF+@execNull+@CRLF+N'    END TRY BEGIN CATCH END CATCH;'+@CRLF+
        ISNULL(@execSeeds,N'')+
        N'    EXEC tSQLt.AssertEquals 1, 1; -- driver: execution drives coverage'+@CRLF+
        N'END;'+@CRLF+N'GO'+@CRLF;
    EXEC TestGen.ExecuteBatchedScript @drv;
    IF @seedCount > 0 PRINT 'RunCoverageForFunction: '+CAST(@seedCount AS VARCHAR)+' branch-seed driver call(s) added for '+@SchemaName+'.'+@FunctionName+'.';

    -- 3. measure coverage on the shadow, capturing test outcomes so we can
    --    persist a CoverageResult row keyed by the FUNCTION (the shadow is an
    --    internal artifact).  @OutputMode='NONE' silences the per-object report
    --    when called from GenerateAndCoverDatabase.
    DECLARE @run INT=0,@pass INT=0,@fail INT=0,@errc INT=0,@skip INT=0;
    DECLARE @tot INT=0,@cov INT=0,@tb INT=0,@cb INT=0,@lp DECIMAL(5,1),@bp DECIMAL(5,1);
    BEGIN TRY
        EXEC TestGen.RunCoverage @SchemaName=@SchemaName, @ProcName=@shadow, @OutputMode=@OutputMode,
             @TestsRun=@run OUTPUT, @TestsPassed=@pass OUTPUT, @TestsFailed=@fail OUTPUT,
             @TestsErrored=@errc OUTPUT, @TestsSkipped=@skip OUTPUT;
    END TRY
    BEGIN CATCH
        PRINT 'RunCoverageForFunction: RunCoverage on shadow failed: '+ERROR_MESSAGE();
    END CATCH;

    -- A (honest-deferred): if the instrumented shadow copy never compiled,
    -- RunCoverage measured nothing - the 0 hits mean "the instrumented copy did
    -- not run", NOT "this code is uncovered".  Detect the absent _cov and record
    -- COVERAGE DEFERRED instead of a misleading GenSucceeded=1 / 0% row.  With
    -- the v5.3 wrap-close fix this is rare; it is the residual-case net for
    -- shadow bodies the line-walker still cannot wrap into compilable SQL.
    DECLARE @covChk NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_cov');
    DECLARE @deferred BIT = CASE WHEN OBJECT_ID(@covChk,'P') IS NULL THEN 1 ELSE 0 END;
    IF @deferred = 1
    BEGIN
        PRINT '=============================================================';
        PRINT ' COVERAGE DEFERRED: '+@SchemaName+'.'+@FunctionName;
        PRINT ' The instrumented shadow copy ('+@shadow+'_cov) did not compile,';
        PRINT ' so no coverage could be measured.  Reported DEFERRED, not 0%';
        PRINT ' (instrumenter limitation - please report this function body).';
        PRINT '=============================================================';
        IF @BatchId IS NOT NULL
            INSERT TestGen.CoverageResult
                (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
                 TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
                 TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
            VALUES (@BatchId,@SchemaName,@FunctionName,0,NULL,NULL,NULL,NULL,NULL,NULL,0,0,0,0,0,0,
                 N'instrumented _cov failed to compile',N'NOT_TESTABLE',
                 N'coverage deferred: instrumenter could not produce a compiling _cov',SYSUTCDATETIME());
    END;

    -- 4. compute coverage from the shadow's line catalogue + hits (same rule as
    --    GenerateAndCoverDatabase) and persist a CoverageResult row under the
    --    FUNCTION name.
    ;WITH ln AS (
        SELECT cl.LineNum, cl.IsExec, cl.IsBranch,
               CASE WHEN EXISTS (SELECT 1 FROM TestGen.CoverageHits ch
                                 WHERE ch.SchemaName=cl.SchemaName AND ch.ProcName=cl.ProcName
                                   AND ch.LineNum=cl.LineNum) THEN 1 ELSE 0 END AS DirectHit
        FROM TestGen.CoverageLines cl
        WHERE cl.SchemaName=@SchemaName AND cl.ProcName=@shadow
    ),
    nx AS (
        SELECT l.LineNum,
               (SELECT TOP 1 e.LineNum FROM ln e WHERE e.IsExec=1 AND e.LineNum>l.LineNum ORDER BY e.LineNum) AS NextExecLine
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
    SET @lp = CASE WHEN @tot>0 THEN CAST(@cov AS DECIMAL(9,2))/@tot*100 ELSE 0 END;
    SET @bp = CASE WHEN @tb >0 THEN CAST(@cb  AS DECIMAL(9,2))/@tb *100 ELSE 0 END;

    -- Report the FUNCTION's assertion suite (test_<fn>: determinism / blessed
    -- value / result-shape) as its Tests counts, if that class exists - the
    -- coverage driver's single trivial AssertEquals is not meaningful.  Run it
    -- here (independent of the dropped shadow) and read tSQLt.TestResult.
    DECLARE @asclass SYSNAME = N'test_'+@FunctionName;
    IF SCHEMA_ID(@asclass) IS NOT NULL
    BEGIN
        SET @run=0; SET @pass=0; SET @fail=0; SET @errc=0; SET @skip=0;
        BEGIN TRY EXEC tSQLt.Run @asclass; END TRY BEGIN CATCH END CATCH;
        IF OBJECT_ID('tSQLt.TestResult','U') IS NOT NULL
            SELECT @run =ISNULL(COUNT(*),0),
                   @pass=ISNULL(SUM(CASE WHEN Result='Success' THEN 1 ELSE 0 END),0),
                   @fail=ISNULL(SUM(CASE WHEN Result='Failure' THEN 1 ELSE 0 END),0),
                   @errc=ISNULL(SUM(CASE WHEN Result='Error'   THEN 1 ELSE 0 END),0),
                   @skip=ISNULL(SUM(CASE WHEN Result IN ('Skipped','Skip','Ignored') THEN 1 ELSE 0 END),0)
            FROM tSQLt.TestResult WHERE Class=@asclass;
    END;
    IF @deferred = 0
    BEGIN TRY
        INSERT TestGen.CoverageResult
            (BatchId,SchemaName,ProcName,GenSucceeded,TotalLines,CoveredLines,LinePct,
             TotalBranches,CoveredBranches,BranchPct,TestsRun,TestsPassed,TestsFailed,
             TestsErrored,TestsSkipped,TestsPreserved,ErrorText,Testability,NotTestableReason,RunAt)
        VALUES
            (ISNULL(@BatchId,SYSUTCDATETIME()),@SchemaName,@FunctionName,1,@tot,@cov,@lp,
             @tb,@cb,@bp,@run,@pass,@fail,@errc,@skip,0,NULL,N'TESTABLE',NULL,SYSUTCDATETIME());
    END TRY BEGIN CATCH END CATCH;

    -- 5. cleanup: driver class, the instrumented _cov copy, the shadow, and
    --    any stranded synonym / _orig left if RunCoverage died mid-swap.
    --    The _cov / _orig suffixes are part of the OBJECT NAME, so they must go
    --    INSIDE QUOTENAME - QUOTENAME(@shadow + N'_cov') - not @shadowFull + a
    --    suffix, which would put it outside the brackets and match nothing.
    DECLARE @covF  NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_cov');
    DECLARE @origF NVARCHAR(400) = QUOTENAME(@SchemaName)+N'.'+QUOTENAME(@shadow+N'_orig');
    BEGIN TRY EXEC tSQLt.DropClass @driverClass; END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'SN') IS NOT NULL EXEC('DROP SYNONYM '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@covF,'P')       IS NOT NULL EXEC('DROP PROCEDURE '+@covF);      END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@shadowFull,'P') IS NOT NULL EXEC('DROP PROCEDURE '+@shadowFull); END TRY BEGIN CATCH END CATCH;
    BEGIN TRY IF OBJECT_ID(@origF,'P')      IS NOT NULL EXEC('DROP PROCEDURE '+@origF);     END TRY BEGIN CATCH END CATCH;
END;
GO
PRINT 'TestGen.RunCoverageForFunction installed.';
GO

/*===========================================================================
 * v0.9.5: Recovery procedures for interrupted coverage runs.
 *
 * When a coverage run is killed mid-flight (test cancelled, agent crashed,
 * connection dropped), the procedure being instrumented is left in this
 * broken state:
 *   - synonym   [schema].[proc]      -> [schema].[proc]_cov  (wrong target)
 *   - procedure [schema].[proc]_cov                          (instrumented copy)
 *   - procedure [schema].[proc]_orig                         (the renamed original)
 * The base name [schema].[proc] is now a synonym, so any caller of the
 * procedure routes through a synonym to a stale instrumented copy. Production
 * would break.
 *
 * Recovery is safe and reversible: rename _orig BACK to the original name
 * (sp_rename preserves the body and metadata) after dropping the synonym
 * and the _cov copy. We explicitly never DROP _orig - the original body
 * lives in it.
 *
 * Two public procedures:
 *   TestGen.CleanupInterruptedRunForProc - single-procedure targeted recovery
 *   TestGen.CleanupInterruptedRuns       - database-wide sweep with @WhatIf preview
 *==========================================================================*/

IF OBJECT_ID('TestGen.CleanupInterruptedRunForProc','P') IS NOT NULL
    DROP PROCEDURE TestGen.CleanupInterruptedRunForProc;
GO
CREATE PROCEDURE TestGen.CleanupInterruptedRunForProc
    @SchemaName SYSNAME,
    @ProcName   SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @origName SYSNAME       = @ProcName + '_orig';
    DECLARE @covName  SYSNAME       = @ProcName + '_cov';
    DECLARE @origObj  NVARCHAR(300) = QUOTENAME(@SchemaName) + '.' + QUOTENAME(@origName);
    DECLARE @covObj   NVARCHAR(300) = QUOTENAME(@SchemaName) + '.' + QUOTENAME(@covName);
    DECLARE @baseObj  NVARCHAR(300) = QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName);
    DECLARE @SQL      NVARCHAR(MAX);

    -- No _orig means no interrupted run for this procedure.
    IF OBJECT_ID(@origObj, 'P') IS NULL
        RETURN;

    -- (1) Drop the synonym if present.
    IF EXISTS (
        SELECT 1 FROM sys.synonyms
        WHERE name = @ProcName AND schema_id = SCHEMA_ID(@SchemaName)
    )
    BEGIN
        SET @SQL = N'DROP SYNONYM ' + @baseObj;
        EXEC sp_executesql @SQL;
    END;

    -- (2) Drop the _cov instrumented copy if present.
    IF OBJECT_ID(@covObj, 'P') IS NOT NULL
    BEGIN
        SET @SQL = N'DROP PROCEDURE ' + @covObj;
        EXEC sp_executesql @SQL;
    END;

    -- (3) Rename _orig back to the original name.  NEVER drop _orig.
    --     The original procedure body lives in _orig.  sp_rename preserves
    --     the body, parameters, permissions chain, and dependency metadata.
    SET @SQL = N'EXEC sp_rename ''' + @SchemaName + N'.' + @origName + N''', ''' + @ProcName + N'''';
    EXEC sp_executesql @SQL;

    PRINT 'Self-healed: ' + @baseObj + ' restored from interrupted prior coverage run (original body preserved via _orig rename).';
END;
GO
PRINT 'TestGen.CleanupInterruptedRunForProc installed.';
GO

IF OBJECT_ID('TestGen.CleanupInterruptedRuns','P') IS NOT NULL
    DROP PROCEDURE TestGen.CleanupInterruptedRuns;
GO
CREATE PROCEDURE TestGen.CleanupInterruptedRuns
    @SchemaFilter SYSNAME = NULL,
    @WhatIf       BIT     = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Find every procedure ending in _orig whose base name is held by a
    -- synonym - that combination indicates a broken half-instrumented state.
    DECLARE @Orphans TABLE (
        SchemaName SYSNAME,
        ProcName   SYSNAME
    );

    INSERT @Orphans (SchemaName, ProcName)
    SELECT
        s.name,
        LEFT(o.name, LEN(o.name) - 5)  -- strip the '_orig' suffix
    FROM sys.objects o
    JOIN sys.schemas s ON s.schema_id = o.schema_id
    WHERE o.type = 'P'
      AND o.name LIKE '%[_]orig'
      AND (@SchemaFilter IS NULL OR s.name = @SchemaFilter)
      AND EXISTS (
          SELECT 1 FROM sys.synonyms syn
          WHERE syn.schema_id = o.schema_id
            AND syn.name      = LEFT(o.name, LEN(o.name) - 5)
      );

    DECLARE @count INT = (SELECT COUNT(*) FROM @Orphans);

    IF @count = 0
    BEGIN
        PRINT 'TestGen.CleanupInterruptedRuns: no interrupted runs detected. Database is clean.';
        RETURN;
    END;

    PRINT 'TestGen.CleanupInterruptedRuns: detected ' + CAST(@count AS VARCHAR(10)) + ' procedure(s) with orphaned coverage state.';

    DECLARE @s SYSNAME, @p SYSNAME;

    IF @WhatIf = 1
    BEGIN
        PRINT '[WhatIf] Would clean up the following procedures:';
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT SchemaName, ProcName FROM @Orphans;
        OPEN c;
        FETCH NEXT FROM c INTO @s, @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            PRINT '  [WhatIf]   ' + QUOTENAME(@s) + N'.' + QUOTENAME(@p);
            FETCH NEXT FROM c INTO @s, @p;
        END;
        CLOSE c; DEALLOCATE c;
        PRINT '[WhatIf] Re-run with @WhatIf = 0 to perform the cleanup.';
        RETURN;
    END;

    DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
        SELECT SchemaName, ProcName FROM @Orphans;
    OPEN c2;
    FETCH NEXT FROM c2 INTO @s, @p;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC TestGen.CleanupInterruptedRunForProc @SchemaName = @s, @ProcName = @p;
        FETCH NEXT FROM c2 INTO @s, @p;
    END;
    CLOSE c2; DEALLOCATE c2;

    PRINT 'TestGen.CleanupInterruptedRuns: cleanup complete.';
END;
GO
PRINT 'TestGen.CleanupInterruptedRuns installed.';
GO

/*===========================================================================
 * v11: function-aware override of TestGen.GenerateAndCoverDatabase.
 * Identical to the base proc for stored procedures; additionally
 * enumerates user functions (FN/IF/TF) and routes them through
 * RunCoverageForFunction (shadow-procedure coverage).  Appended AFTER
 * the base definition so this version wins.
 *==========================================================================*/
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

    -- v0.9.5: defensively self-heal any procedures left in a broken state
    -- by a previously-killed coverage run.  Safe no-op if database is clean.
    -- Runs once at the start as a database-wide sweep (more efficient than
    -- per-procedure checks while iterating).
    IF OBJECT_ID('TestGen.CleanupInterruptedRuns','P') IS NOT NULL
        EXEC TestGen.CleanupInterruptedRuns @SchemaFilter = @SchemaFilter;

    DECLARE @BatchId DATETIME2(3) = SYSUTCDATETIME();

    -- loop variables (declared once; SET per iteration - never DECLARE = expr in a loop)
    DECLARE @Seq INT, @s SYSNAME, @p SYSNAME, @cls SYSNAME;
    DECLARE @k CHAR(2);
    DECLARE @genOK BIT, @err NVARCHAR(2000), @Total INT;
    DECLARE @run INT,@pass INT,@fail INT,@errc INT,@skip INT;
    DECLARE @tot INT,@cov INT,@tb INT,@cb INT;
    DECLARE @lp DECIMAL(5,1), @bp DECIMAL(5,1);
    DECLARE @testability VARCHAR(20), @reason NVARCHAR(400);   -- v9.4.3 testability gate
    DECLARE @pres INT;                                          -- v9.4.4 preservation count from GenerateTestsForProcedure
    DECLARE @resync INT;   -- v11.x: connection-recovery resync probe (see loop)

    -- v11: enumerate stored procedures AND user functions (FN/IF/TF).
    DECLARE @work TABLE (Seq INT IDENTITY(1,1), s SYSNAME, p SYSNAME, k CHAR(2));
    INSERT @work (s,p,k)
    SELECT SCHEMA_NAME(o.schema_id), o.name, o.type
    FROM   sys.objects o
    WHERE  o.type IN ('P','FN','IF','TF')
      AND  o.is_ms_shipped = 0
      AND  SCHEMA_NAME(o.schema_id) NOT IN ('tSQLt','TestGen','TestGenLog')
      AND  SCHEMA_NAME(o.schema_id) NOT LIKE 'test[_]%'      -- exclude generated test classes
      AND  (@SchemaFilter   IS NULL OR SCHEMA_NAME(o.schema_id) = @SchemaFilter)
      AND  (@ExcludePattern IS NULL OR o.name NOT LIKE @ExcludePattern)
      AND  o.name NOT LIKE '%[_]cov'     -- _cov instrumentation copies
      AND  o.name NOT LIKE '%[_]covfn'   -- v11 shadow procedures
      AND  o.name NOT LIKE '%[_]orig'    -- stranded _orig originals
      AND  o.name NOT LIKE 'TestGen[_]%' -- framework helper(s) placed in dbo
    ORDER  BY 1,2;

    SET @Total = (SELECT COUNT(*) FROM @work);
    PRINT 'GenerateAndCoverDatabase: ' + CAST(@Total AS VARCHAR) + ' object(s) (procedures + functions) to process.';
    PRINT '';
    PRINT 'NOTE: turn SYSTEM_VERSIONING OFF on any system-versioned temporal';
    PRINT '      tables before this run, and back ON afterwards - see the';
    PRINT '      README_v9_4 temporal prerequisite.  A procedure still';
    PRINT '      system-versioned, or using FOR SYSTEM_TIME, is reported';
    PRINT '      NOT TESTABLE.';

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Seq,s,p,k FROM @work ORDER BY Seq;
    OPEN cur;
    FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @genOK=0; SET @err=NULL; SET @cls=N'test_'+@p;
        SET @run=0; SET @pass=0; SET @fail=0; SET @errc=0; SET @skip=0;
        SET @tot=0; SET @cov=0; SET @tb=0; SET @cb=0;
        SET @pres=0;   -- v9.4.4: preservation count reset per iteration
        -- v11.x resilience: a transient connection-recovery during this long
        -- multi-object run leaves @@ROWCOUNT unusable ("the connection was
        -- recovered ... execute another query to get a valid rowcount"), which
        -- otherwise CASCADES - every remaining object then fails generation with
        -- that same message (2026-05-31: all 8 procs after the functions failed
        -- in 0.37s total).  A trivial query each iteration re-syncs the session
        -- so a recovery on a prior object cannot poison this one.
        -- v0.13: the bare assignment SELECT did NOT always clear it - the recovery can
        -- land right after the in-session SQLCLR predicate parser, and the driver throws
        -- the "first query after recovery" error on the next real query. Use two
        -- throwaway round-trips, each swallowed, so that first-query penalty is consumed
        -- HERE and the generation below starts on a clean session (and the probe itself
        -- can never abort the sweep).
        BEGIN TRY SELECT @resync = COUNT(*) FROM sys.objects; END TRY BEGIN CATCH END CATCH;
        BEGIN TRY SELECT @resync = COUNT(*) FROM sys.objects; END TRY BEGIN CATCH END CATCH;

        PRINT '  [' + CAST(@Seq AS VARCHAR) + '/' + CAST(@Total AS VARCHAR) + '] ' + @s + '.' + @p;

        -- v11: functions (FN/IF/TF) route through the shadow-procedure coverage
        -- path, which persists its own CoverageResult row keyed by the function.
        IF @k <> 'P'
        BEGIN
            BEGIN TRY
                EXEC TestGen.GenerateTestsForObject @SchemaName=@s, @ObjectName=@p, @ExecuteScript=1;
            END TRY BEGIN CATCH SET @err=N'GEN: '+ERROR_MESSAGE(); END CATCH
            BEGIN TRY
                EXEC TestGen.RunCoverageForFunction @SchemaName=@s, @FunctionName=@p,
                     @OutputMode='NONE', @BatchId=@BatchId;
            END TRY BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'COV: '+ERROR_MESSAGE(); END CATCH
            PRINT '      -> function ('+@k+') coverage measured';
            FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
            CONTINUE;
        END;

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
            FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
            CONTINUE;
        END;


        -- 1. generate + install the test class
        BEGIN TRY
            EXEC TestGen.GenerateTestsForProcedure @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                 @TestsPreservedCount=@pres OUTPUT;
            SET @genOK=1;
        END TRY
        BEGIN CATCH
            SET @err=N'GEN: '+ERROR_MESSAGE();
            -- v11.x resilience: if generation tripped a transient connection-recovery
            -- (rowcount unavailable), re-sync and retry ONCE - the generator is
            -- deterministic and succeeds on a clean session, so one blip never costs
            -- the object (it used to cost every REMAINING object in the sweep).
            IF @err LIKE N'%connection was recovered%' OR @err LIKE N'%valid rowcount%'
            BEGIN
                BEGIN TRY SELECT @resync = COUNT(*) FROM sys.objects; END TRY BEGIN CATCH END CATCH;
                BEGIN TRY SELECT @resync = COUNT(*) FROM sys.objects; END TRY BEGIN CATCH END CATCH;
                BEGIN TRY
                    EXEC TestGen.GenerateTestsForProcedure @SchemaName=@s, @ProcName=@p, @ExecuteScript=1,
                         @TestsPreservedCount=@pres OUTPUT;
                    SET @genOK=1; SET @err=NULL;
                END TRY
                BEGIN CATCH SET @err=N'GEN: '+ERROR_MESSAGE(); END CATCH
            END;
        END CATCH

        IF @genOK = 1
        BEGIN
            -- v0.10: add seeded predicate-branch tests BEFORE measuring, so the
            -- single coverage pass also reaches the data-shape arms (~0.6s/proc).
            -- Gated on the proc having been parsed (PredicateInbox rows); unparsed
            -- procs are untouched, so the baseline is unchanged.
            IF OBJECT_ID('TestGen.GeneratePredicateBranchTests','P') IS NOT NULL
               AND EXISTS (SELECT 1 FROM TestGen.PredicateInbox pi WHERE pi.SchemaName=@s AND pi.ProcName=@p)
            BEGIN TRY
                EXEC TestGen.GeneratePredicateBranchTests @SchemaName=@s, @ProcName=@p;
            END TRY BEGIN CATCH SET @err=ISNULL(@err+N' | ',N'')+N'V10: '+ERROR_MESSAGE(); END CATCH

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

        FETCH NEXT FROM cur INTO @Seq,@s,@p,@k;
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
        PRINT 'Objects         : ' + CAST(@gProcs AS VARCHAR) + '   (generation failed: ' + CAST(@gGenFail AS VARCHAR) + ')';
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
PRINT 'TestGen.GenerateAndCoverDatabase (v11 function-aware) installed.';
GO

PRINT '';
PRINT '== v11 function support (30_Function_Support_v1.sql) installed ==';
PRINT '   Generate:  EXEC TestGen.GenerateTestsForObject  @SchemaName=N''dbo'', @ObjectName=N''YourFunction'';';
PRINT '   Coverage:  EXEC TestGen.RunCoverageForFunction  @SchemaName=N''dbo'', @FunctionName=N''YourFunction'';';
GO
/* >>> UAG v0.10 predicate-seeding BEGIN (auto-spliced; do not hand-edit) <<< */
/* === v0.10 predicate-aware seeding (modules 31-35) === */
PRINT '== Installing v0.10 predicate-seeding (modules 31-35) ==';
GO

/* === modules/31_PredicateInbox_v1.sql (v0.10) === */
/*=============================================================================
 * MODULE 31 - PredicateInbox (v0.10 predicate-aware seeding)
 * Staging table written by the PowerShell ScriptDom parser
 * (powershell/UnitAutogen/Get-ParsedPredicates.ps1) and read by the T-SQL
 * seeder (modules/32_Seeder_v1.sql). One row per branch predicate.
 *===========================================================================*/

SET NOCOUNT ON;
GO

IF SCHEMA_ID('TestGen') IS NULL
    EXEC('CREATE SCHEMA TestGen;');
GO

IF OBJECT_ID('TestGen.PredicateInbox', 'U') IS NULL
BEGIN
    CREATE TABLE TestGen.PredicateInbox
    (
        InboxId          INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_PredicateInbox PRIMARY KEY,
        SchemaName       SYSNAME          NOT NULL,
        ProcName         SYSNAME          NOT NULL,
        BranchId         INT              NOT NULL,
        StartLine        INT              NULL,
        Context          VARCHAR(16)      NOT NULL
            CONSTRAINT DF_PredicateInbox_Context DEFAULT ('IF'),
        Shape            VARCHAR(32)      NOT NULL,
        AggregateColumn  NVARCHAR(256)    NULL,
        Comparator       VARCHAR(16)      NULL,
        Comparand        NVARCHAR(MAX)    NULL,
        TargetTablesJson NVARCHAR(MAX)    NOT NULL
            CONSTRAINT DF_PredicateInbox_Tables DEFAULT ('[]'),
        JoinsJson        NVARCHAR(MAX)    NULL,
        WhereAstJson     NVARCHAR(MAX)    NULL,
        -- v0.12 unified engine: predicate TREE + per-direction per-table seed
        -- plans (design/DESIGN_v0_12_UnifiedReverseSeeder.md). When
        -- PredicateTreeJson is present the seeder uses the tree path; otherwise
        -- it falls back to the v0.11 flat fields above.
        PredicateTreeJson NVARCHAR(MAX)   NULL,
        SeedPlanTrueJson  NVARCHAR(MAX)   NULL,
        SeedPlanFalseJson NVARCHAR(MAX)   NULL,
        PredicateText    NVARCHAR(MAX)    NOT NULL,
        UnsupportedReason NVARCHAR(400)   NULL,
        ParserVersion    VARCHAR(32)      NULL,
        RunId            UNIQUEIDENTIFIER NOT NULL,
        CreatedAt        DATETIME2(3)     NOT NULL
            CONSTRAINT DF_PredicateInbox_CreatedAt DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_PredicateInbox_Shape CHECK (Shape IN (
            'EXISTS','NOT_EXISTS',
            'COUNT_CMP','COUNT_IN','COUNT_BETWEEN',
            'SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP',
            'SCALAR_CMP','SCALAR_NULL',
            'PREDTREE',          -- v0.12: row carries a full predicate tree
            'UNRECOGNISED')),
        CONSTRAINT UQ_PredicateInbox_Branch
            UNIQUE (RunId, SchemaName, ProcName, BranchId)
    );

    CREATE INDEX IX_PredicateInbox_Lookup
        ON TestGen.PredicateInbox (SchemaName, ProcName, RunId)
        INCLUDE (BranchId, Shape);

    ALTER TABLE TestGen.PredicateInbox
        ADD CONSTRAINT CK_PredicateInbox_TablesJson CHECK (ISJSON(TargetTablesJson) = 1);
    ALTER TABLE TestGen.PredicateInbox
        ADD CONSTRAINT CK_PredicateInbox_JoinsJson CHECK (JoinsJson IS NULL OR ISJSON(JoinsJson) = 1);
    ALTER TABLE TestGen.PredicateInbox
        ADD CONSTRAINT CK_PredicateInbox_WhereJson CHECK (WhereAstJson IS NULL OR ISJSON(WhereAstJson) = 1);

    PRINT 'TestGen.PredicateInbox created.';
END
ELSE
    PRINT 'TestGen.PredicateInbox already exists - left as-is.';
GO

-- Upgrade-safe: add StartLine to a pre-existing table from an earlier install.
IF OBJECT_ID('TestGen.PredicateInbox','U') IS NOT NULL
   AND COL_LENGTH('TestGen.PredicateInbox','StartLine') IS NULL
BEGIN
    ALTER TABLE TestGen.PredicateInbox ADD StartLine INT NULL;
    PRINT 'TestGen.PredicateInbox: added StartLine column (upgrade).';
END
GO

-- Upgrade-safe: add the v0.12 tree + seed-plan columns to a pre-existing table.
IF OBJECT_ID('TestGen.PredicateInbox','U') IS NOT NULL
   AND COL_LENGTH('TestGen.PredicateInbox','PredicateTreeJson') IS NULL
BEGIN
    ALTER TABLE TestGen.PredicateInbox
        ADD PredicateTreeJson NVARCHAR(MAX) NULL,
            SeedPlanTrueJson  NVARCHAR(MAX) NULL,
            SeedPlanFalseJson NVARCHAR(MAX) NULL;
    PRINT 'TestGen.PredicateInbox: added v0.12 tree + seed-plan columns (upgrade).';
END
GO

-- Upgrade-safe: allow the PREDTREE shape on a pre-existing CHECK constraint.
IF OBJECT_ID('TestGen.PredicateInbox','U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE parent_object_id = OBJECT_ID('TestGen.PredicateInbox')
                 AND name = 'CK_PredicateInbox_Shape'
                 AND definition NOT LIKE '%PREDTREE%')
BEGIN
    ALTER TABLE TestGen.PredicateInbox DROP CONSTRAINT CK_PredicateInbox_Shape;
    ALTER TABLE TestGen.PredicateInbox ADD CONSTRAINT CK_PredicateInbox_Shape CHECK (Shape IN (
        'EXISTS','NOT_EXISTS',
        'COUNT_CMP','COUNT_IN','COUNT_BETWEEN',
        'SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP',
        'SCALAR_CMP','SCALAR_NULL',
        'PREDTREE',
        'UNRECOGNISED'));
    PRINT 'TestGen.PredicateInbox: CK_PredicateInbox_Shape now allows PREDTREE (upgrade).';
END
GO

IF OBJECT_ID('TestGen.ClearPredicateInbox', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.ClearPredicateInbox;
GO
CREATE PROCEDURE TestGen.ClearPredicateInbox
    @SchemaName   SYSNAME          = NULL,
    @ProcName     SYSNAME          = NULL,
    @RunId        UNIQUEIDENTIFIER = NULL,
    @OlderThanUtc DATETIME2(3)     = NULL,
    @RowsDeleted  INT              = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @SchemaName IS NULL AND @ProcName IS NULL
       AND @RunId IS NULL AND @OlderThanUtc IS NULL
        PRINT 'WARNING: ClearPredicateInbox called with no filter - clearing ALL rows.';
    DELETE FROM TestGen.PredicateInbox
    WHERE (@SchemaName   IS NULL OR SchemaName = @SchemaName)
      AND (@ProcName     IS NULL OR ProcName   = @ProcName)
      AND (@RunId        IS NULL OR RunId      = @RunId)
      AND (@OlderThanUtc IS NULL OR CreatedAt  < @OlderThanUtc);
    SET @RowsDeleted = @@ROWCOUNT;
END;
GO

IF OBJECT_ID('TestGen.AddParsedPredicate', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.AddParsedPredicate;
GO
CREATE PROCEDURE TestGen.AddParsedPredicate
    @RunId            UNIQUEIDENTIFIER,
    @SchemaName       SYSNAME,
    @ProcName         SYSNAME,
    @BranchId         INT,
    @Shape            VARCHAR(32),
    @PredicateText    NVARCHAR(MAX),
    @StartLine        INT           = NULL,
    @Context          VARCHAR(16)   = 'IF',
    @AggregateColumn  NVARCHAR(256) = NULL,
    @Comparator       VARCHAR(16)   = NULL,
    @Comparand        NVARCHAR(MAX) = NULL,
    @TargetTablesJson NVARCHAR(MAX) = N'[]',
    @JoinsJson        NVARCHAR(MAX) = NULL,
    @WhereAstJson     NVARCHAR(MAX) = NULL,
    @PredicateTreeJson NVARCHAR(MAX)= NULL,
    @SeedPlanTrueJson  NVARCHAR(MAX)= NULL,
    @SeedPlanFalseJson NVARCHAR(MAX)= NULL,
    @UnsupportedReason NVARCHAR(400)= NULL,
    @ParserVersion    VARCHAR(32)   = NULL,
    @InboxId          INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Shape      = UPPER(LTRIM(RTRIM(@Shape)));
    SET @Comparator = NULLIF(UPPER(LTRIM(RTRIM(@Comparator))), '');
    SET @Context    = ISNULL(NULLIF(UPPER(LTRIM(RTRIM(@Context))), ''), 'IF');
    IF @TargetTablesJson IS NULL OR LTRIM(RTRIM(@TargetTablesJson)) = N''
        SET @TargetTablesJson = N'[]';
    INSERT TestGen.PredicateInbox
        (SchemaName, ProcName, BranchId, StartLine, Context, Shape,
         AggregateColumn, Comparator, Comparand,
         TargetTablesJson, JoinsJson, WhereAstJson,
         PredicateTreeJson, SeedPlanTrueJson, SeedPlanFalseJson,
         PredicateText, UnsupportedReason, ParserVersion, RunId)
    VALUES
        (@SchemaName, @ProcName, @BranchId, @StartLine, @Context, @Shape,
         @AggregateColumn, @Comparator, @Comparand,
         @TargetTablesJson, @JoinsJson, @WhereAstJson,
         @PredicateTreeJson, @SeedPlanTrueJson, @SeedPlanFalseJson,
         @PredicateText, @UnsupportedReason, @ParserVersion, @RunId);
    SET @InboxId = SCOPE_IDENTITY();
END;
GO

IF OBJECT_ID('TestGen.GetPredicatesForProc', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GetPredicatesForProc;
GO
CREATE PROCEDURE TestGen.GetPredicatesForProc
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @RunId      UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
        ORDER  BY CreatedAt DESC, InboxId DESC;
    SELECT InboxId, SchemaName, ProcName, BranchId, StartLine, Context, Shape,
           AggregateColumn, Comparator, Comparand,
           TargetTablesJson, JoinsJson, WhereAstJson,
           PredicateTreeJson, SeedPlanTrueJson, SeedPlanFalseJson,
           PredicateText, UnsupportedReason, ParserVersion, RunId, CreatedAt
    FROM   TestGen.PredicateInbox
    WHERE  SchemaName = @SchemaName
      AND  ProcName   = @ProcName
      AND  (@RunId IS NULL OR RunId = @RunId)
    ORDER  BY BranchId;
END;
GO

PRINT 'Module 31 (PredicateInbox + helpers) installed.';
GO

/* === modules/32_Seeder_v1.sql (v0.10) === */
/*=============================================================================
 * MODULE 32 - Predicate seeder (v0.10 predicate-aware seeding)
 * -----------------------------------------------------------------------------
 * Reads one TestGen.PredicateInbox row and emits the T-SQL that, run AFTER the
 * SafeFakeTable calls and BEFORE the Act/EXEC, makes the branch predicate
 * evaluate to a chosen @Direction ('TRUE' or 'FALSE').
 *
 * Single case-analysis procedure - NO strategy registry (design sec 3.3,
 * resolved open Q).  The cases implement DESIGN_v0_10_PredicateSeeding sec 3.2.
 *
 * Reuses the v9.2/v9.4 identity/computed/rowversion exclusion (resolved Q4):
 * INSERT column lists never include identity, computed, or rowversion columns.
 *
 * Bounded by design (resolved Q5): single faked target table; WHERE conjuncts
 * are AND-composed equality / numeric-inequality predicates on that table.
 * Anything outside that grammar returns @Supported = 0 with a reason, which the
 * test generator (module 33) turns into a NOT_TESTABLE placeholder test.
 *===========================================================================*/

SET NOCOUNT ON;
GO

/*-----------------------------------------------------------------------------
 * TestGen.SatisfyingValue
 * Given a comparator and a comparand literal, return a T-SQL literal that
 * (when a column is set to it) makes "<col> <op> <comparand>" evaluate to
 * @Satisfy.  Returns NULL when the (op, literal) pair is outside the supported
 * grammar (e.g. a non-numeric inequality), signalling "unsupported".
 *
 *   '=', '<>', '!=' : supported for ANY literal (numeric or quoted string).
 *   '<','<=','>','>=': supported for NUMERIC literals only.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.SatisfyingValue', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.SatisfyingValue;
GO
CREATE FUNCTION TestGen.SatisfyingValue
(
    @Op      VARCHAR(16),
    @Literal NVARCHAR(400),
    @Satisfy BIT
)
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @op2 VARCHAR(16) = REPLACE(UPPER(LTRIM(RTRIM(@Op))), '!=', '<>');
    DECLARE @num FLOAT       = TRY_CAST(@Literal AS FLOAT);
    DECLARE @isStr BIT       = CASE WHEN LEFT(LTRIM(@Literal),1) IN ('''','N') THEN 1 ELSE 0 END;

    -- A literal guaranteed not to equal a "normal" seeded value.
    DECLARE @diffStr NVARCHAR(64) = N'N''__UAG_NOMATCH__''';

    -- Helper formatting: emit an integer when the number is whole, else float.
    DECLARE @numPlus  NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num + 1 AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num + 1 AS NVARCHAR(50)) END;
    DECLARE @numMinus NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num - 1 AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num - 1 AS NVARCHAR(50)) END;
    DECLARE @numSame  NVARCHAR(50) = CASE WHEN @num = FLOOR(@num)
                                          THEN CAST(CAST(@num AS BIGINT) AS NVARCHAR(50))
                                          ELSE CAST(@num AS NVARCHAR(50)) END;

    IF @op2 = '='
        RETURN CASE WHEN @Satisfy = 1 THEN @Literal
                    WHEN @num IS NOT NULL THEN @numPlus
                    ELSE @diffStr END;

    IF @op2 = '<>'
        RETURN CASE WHEN @Satisfy = 0 THEN @Literal
                    WHEN @num IS NOT NULL THEN @numPlus
                    ELSE @diffStr END;

    -- Numeric inequalities require a numeric comparand.
    IF @num IS NULL RETURN NULL;

    IF @op2 = '>'  RETURN CASE WHEN @Satisfy = 1 THEN @numPlus  ELSE @numSame  END;
    IF @op2 = '>=' RETURN CASE WHEN @Satisfy = 1 THEN @numSame  ELSE @numMinus END;
    IF @op2 = '<'  RETURN CASE WHEN @Satisfy = 1 THEN @numMinus ELSE @numSame  END;
    IF @op2 = '<=' RETURN CASE WHEN @Satisfy = 1 THEN @numSame  ELSE @numPlus  END;

    RETURN NULL;   -- unknown operator
END;
GO

/*-----------------------------------------------------------------------------
 * TestGen.BuildSeedInsert
 * Build an INSERT that puts @Count identical rows into a faked table.
 *   - Column list excludes identity / computed / rowversion (resolved Q4).
 *   - Each column gets a "typical valid" sample literal, UNLESS overridden by
 *     @OverridesJson, a JSON array of {"col":"<name>","val":"<T-SQL literal>"}.
 *   - @Count = 1 -> single VALUES row; @Count > 1 -> SELECT TOP(@Count) from a
 *     tally so any row multiplicity is expressed without N copies of text.
 * Returns NULL if the table is missing or has no insertable columns.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.BuildSeedInsert', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.BuildSeedInsert;
GO
CREATE FUNCTION TestGen.BuildSeedInsert
(
    @SchemaName    SYSNAME,
    @TableName     SYSNAME,
    @OverridesJson NVARCHAR(MAX),
    @Count         INT
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @full NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    DECLARE @objid INT = OBJECT_ID(@full);
    IF @objid IS NULL RETURN NULL;
    IF @Count IS NULL OR @Count < 1 RETURN NULL;

    DECLARE @cols NVARCHAR(MAX), @vals NVARCHAR(MAX);

    ;WITH ov AS (
        SELECT  col = JSON_VALUE([value], '$.col'),
                val = JSON_VALUE([value], '$.val')
        FROM    OPENJSON(ISNULL(NULLIF(@OverridesJson, N''), N'[]'))
    )
    SELECT
        @cols = STRING_AGG(QUOTENAME(c.name), N', ')
                  WITHIN GROUP (ORDER BY c.column_id),
        @vals = STRING_AGG(
                  CONVERT(NVARCHAR(MAX),
                    ISNULL(ov.val,
                      TestGen.GetSampleValueLiteral(t.name, c.max_length,
                                                    c.precision, c.scale, 0))),
                  N', ')
                  WITHIN GROUP (ORDER BY c.column_id)
    FROM    sys.columns c
    JOIN    sys.types   t ON c.user_type_id = t.user_type_id
    LEFT JOIN ov ON ov.col = c.name
    WHERE   c.object_id = @objid
      AND   ( ov.val IS NOT NULL          -- a WHERE/scalar override needs this column,
                                          -- e.g. an IDENTITY PK the gate filters on:
                                          -- tSQLt.FakeTable drops identity/computed/
                                          -- rowversion, so the faked table accepts an
                                          -- explicit insert into it. Include it.
              OR ( c.is_identity = 0 AND c.is_computed = 0
                   AND t.name NOT IN ('timestamp','rowversion') ) );

    IF @cols IS NULL RETURN NULL;

    IF @Count = 1
        RETURN N'INSERT ' + @full + N' (' + @cols + N')' + CHAR(13) + CHAR(10)
             + N'    VALUES (' + @vals + N');';

    -- @Count > 1: pull exactly @Count rows from a guaranteed-large tally.
    RETURN N'INSERT ' + @full + N' (' + @cols + N')' + CHAR(13) + CHAR(10)
         + N'    SELECT TOP (' + CAST(@Count AS NVARCHAR(10)) + N') '
         + @vals + CHAR(13) + CHAR(10)
         + N'    FROM sys.all_columns a CROSS JOIN sys.all_columns b;';
END;
GO

/*=============================================================================
 * v0.12 UNIFIED ENGINE helpers (design/DESIGN_v0_12_UnifiedReverseSeeder.md)
 *   TestGen.CountForCase   - rows the base table needs for an atom's comparator
 *   TestGen.ResolveVspec   - symbolic value spec -> a concrete T-SQL literal
 *   TestGen.ExecuteSeedPlan- run a per-direction per-table seed plan
 *===========================================================================*/
IF OBJECT_ID('TestGen.CountForCase', 'FN') IS NOT NULL DROP FUNCTION TestGen.CountForCase;
GO
CREATE FUNCTION TestGen.CountForCase
(
    @shape      VARCHAR(32),
    @comparator VARCHAR(16),
    @comparand  NVARCHAR(MAX),   -- already param-resolved literal / list
    @want       BIT
)
RETURNS INT
AS
BEGIN
    -- Rows the base table needs so the atom evaluates to @want. NULL = degenerate
    -- / unsupported (caller turns that into a Skip). A negative result is also
    -- degenerate (cannot make a count negative).
    DECLARE @op VARCHAR(16) = REPLACE(UPPER(ISNULL(@comparator, '')), '!=', '<>');
    DECLARE @K INT = NULL;

    IF @shape = 'EXISTS'
        SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    ELSE IF @shape = 'SCALAR_NULL'
    BEGIN
        IF      @op = 'IS_NULL'     SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;
        ELSE IF @op = 'IS_NOT_NULL' SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    END
    ELSE IF @shape IN ('SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP','SCALAR_CMP')
        SET @K = 1;                                  -- one row; the value override drives it
    ELSE IF @shape = 'COUNT_CMP'
    BEGIN
        DECLARE @N FLOAT = TRY_CAST(@comparand AS FLOAT);
        IF @N IS NOT NULL AND @N = FLOOR(@N)
        BEGIN
            DECLARE @Ni INT = CAST(@N AS INT);
            IF      @op = '='  SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni + 1 END;
            ELSE IF @op = '<>' SET @K = CASE WHEN @want = 1 THEN @Ni + 1 ELSE @Ni     END;
            ELSE IF @op = '>'  SET @K = CASE WHEN @want = 1 THEN @Ni + 1 ELSE 0       END;
            ELSE IF @op = '>=' SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni - 1 END;
            ELSE IF @op = '<'  SET @K = CASE WHEN @want = 1 THEN @Ni - 1 ELSE @Ni     END;
            ELSE IF @op = '<=' SET @K = CASE WHEN @want = 1 THEN @Ni     ELSE @Ni + 1 END;
        END
    END
    ELSE IF @shape = 'COUNT_IN'
    BEGIN
        DECLARE @first INT, @maxv INT, @bad INT = 0;
        SELECT  @first = MIN(CASE WHEN ord = 1 THEN v END),
                @maxv  = MAX(v),
                @bad   = SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END)
        FROM ( SELECT TRY_CAST(LTRIM(RTRIM([value])) AS INT) AS v,
                      ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS ord
               FROM   STRING_SPLIT(ISNULL(@comparand, N''), ',') ) s;
        IF @bad = 0 AND @first IS NOT NULL
        BEGIN
            IF @op = 'NOT_IN' SET @K = CASE WHEN @want = 1 THEN @maxv + 1 ELSE @first END;
            ELSE              SET @K = CASE WHEN @want = 1 THEN @first    ELSE @maxv + 1 END;
        END
    END
    ELSE IF @shape = 'COUNT_BETWEEN'
    BEGIN
        DECLARE @up NVARCHAR(MAX) = UPPER(@comparand);
        DECLARE @ap INT = CHARINDEX(' AND ', @up);
        IF @ap > 0
        BEGIN
            DECLARE @A INT = TRY_CAST(LTRIM(RTRIM(LEFT(@comparand, @ap - 1))) AS INT);
            DECLARE @B INT = TRY_CAST(LTRIM(RTRIM(SUBSTRING(@comparand, @ap + 5, 4000))) AS INT);
            IF @A IS NOT NULL AND @B IS NOT NULL
                SET @K = CASE WHEN @want = 1 THEN @A
                              WHEN @A >= 1   THEN @A - 1
                              ELSE @B + 1 END;
        END
    END;

    IF @K < 0 SET @K = NULL;     -- degenerate (e.g. COUNT < 0)
    RETURN @K;
END;
GO

IF OBJECT_ID('TestGen.ResolveVspec', 'FN') IS NOT NULL DROP FUNCTION TestGen.ResolveVspec;
GO
CREATE FUNCTION TestGen.ResolveVspec
(
    @vspec   NVARCHAR(MAX),
    @procObj INT,
    @objid   INT,
    @col     SYSNAME
)
RETURNS NVARCHAR(400)
AS
BEGIN
    IF @vspec IS NULL OR ISJSON(@vspec) = 0 RETURN NULL;

    -- { "lit": <literal> }
    IF JSON_VALUE(@vspec, '$.lit') IS NOT NULL
        RETURN JSON_VALUE(@vspec, '$.lit');

    -- { "param": "@Name" } -> the proc-parameter sample value
    DECLARE @p NVARCHAR(200) = JSON_VALUE(@vspec, '$.param');
    IF @p IS NOT NULL
    BEGIN
        DECLARE @pv NVARCHAR(400) = NULL;
        SELECT @pv = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
        WHERE  pr.object_id = @procObj AND pr.name = @p;
        RETURN @pv;
    END;

    -- { "sample": true } -> a typed sample of the target column
    IF JSON_VALUE(@vspec, '$.sample') IS NOT NULL
    BEGIN
        DECLARE @sv NVARCHAR(400) = NULL;
        SELECT @sv = TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0)
        FROM   sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE  c.object_id = @objid AND c.name = @col;
        RETURN @sv;
    END;

    -- { "satisfy": { op, val, valKind, want } }
    DECLARE @sat NVARCHAR(MAX) = JSON_QUERY(@vspec, '$.satisfy');
    IF @sat IS NOT NULL
    BEGIN
        DECLARE @op  VARCHAR(8)     = JSON_VALUE(@sat, '$.op');
        DECLARE @val NVARCHAR(400)  = JSON_VALUE(@sat, '$.val');
        DECLARE @vk  VARCHAR(16)    = JSON_VALUE(@sat, '$.valKind');
        DECLARE @w   BIT            = TRY_CAST(JSON_VALUE(@sat, '$.want') AS BIT);
        IF @vk = 'param'
            SELECT @val = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  pr.object_id = @procObj AND pr.name = @val;
        RETURN TestGen.SatisfyingValue(@op, @val, @w);
    END;

    -- { "satisfysample": { op, want } } -> SatisfyingValue against THIS column's
    -- own typed sample. For a non-equi join a.x <op> b.y, b.y gets {sample} and
    -- a.x gets this; same column type -> same sample -> a.x <op> b.y holds.
    DECLARE @ss NVARCHAR(MAX) = JSON_QUERY(@vspec, '$.satisfysample');
    IF @ss IS NOT NULL
    BEGIN
        DECLARE @ssop VARCHAR(8) = JSON_VALUE(@ss, '$.op');
        DECLARE @ssw  BIT        = TRY_CAST(JSON_VALUE(@ss, '$.want') AS BIT);
        DECLARE @ssrv NVARCHAR(400) = NULL;
        SELECT @ssrv = TestGen.GetSampleValueLiteral(t.name, c.max_length, c.precision, c.scale, 0)
        FROM   sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE  c.object_id = @objid AND c.name = @col;
        RETURN TestGen.SatisfyingValue(@ssop, @ssrv, @ssw);
    END;

    RETURN NULL;
END;
GO

IF OBJECT_ID('TestGen.OverridesContain', 'FN') IS NOT NULL DROP FUNCTION TestGen.OverridesContain;
GO
CREATE FUNCTION TestGen.OverridesContain
(
    @super NVARCHAR(MAX),   -- resolved override array [{col,val}...]
    @sub   NVARCHAR(MAX)
)
RETURNS BIT
AS
BEGIN
    -- 1 when every (col,val) in @sub also appears in @super (i.e. a row carrying
    -- @super's overrides also satisfies @sub's predicate).
    IF @sub IS NULL OR @sub = N'[]' RETURN 1;
    IF EXISTS (
        SELECT 1
        FROM   OPENJSON(@sub) s
        WHERE  NOT EXISTS (
            SELECT 1 FROM OPENJSON(ISNULL(@super, N'[]')) u
            WHERE  JSON_VALUE(u.[value], '$.col') = JSON_VALUE(s.[value], '$.col')
              AND  JSON_VALUE(u.[value], '$.val') = JSON_VALUE(s.[value], '$.val') )
    ) RETURN 0;
    RETURN 1;
END;
GO

IF OBJECT_ID('TestGen.ExecuteSeedPlan', 'P') IS NOT NULL DROP PROCEDURE TestGen.ExecuteSeedPlan;
GO
CREATE PROCEDURE TestGen.ExecuteSeedPlan
    @Direction    VARCHAR(8),
    @ProcSchema   SYSNAME,
    @ProcName     SYSNAME,
    @PlanTrue     NVARCHAR(MAX),
    @PlanFalse    NVARCHAR(MAX),
    @PredText     NVARCHAR(MAX),
    @SeedSql      NVARCHAR(MAX) = NULL OUTPUT,
    @Supported    BIT           = NULL OUTPUT,
    @Reason       NVARCHAR(400) = NULL OUTPUT,
    @PredicateSql NVARCHAR(MAX) = NULL OUTPUT,
    @ExpectedBit  BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @SeedSql = NULL; SET @Supported = 0; SET @Reason = NULL;
    SET @PredicateSql = NULL; SET @ExpectedBit = NULL;

    DECLARE @MaxSeedRows INT = 500;
    DECLARE @plan NVARCHAR(MAX) = CASE WHEN UPPER(@Direction) = 'TRUE' THEN @PlanTrue ELSE @PlanFalse END;
    IF @plan IS NULL OR ISJSON(@plan) = 0
    BEGIN SET @Reason = N'no seed plan for direction ' + @Direction; RETURN; END;

    SET @PredicateSql = JSON_VALUE(@plan, '$.predSql');
    SET @ExpectedBit  = TRY_CAST(JSON_VALUE(@plan, '$.expectedBit') AS BIT);
    DECLARE @skip NVARCHAR(MAX) = JSON_VALUE(@plan, '$.skip');
    IF @skip IS NOT NULL BEGIN SET @Reason = LEFT(@skip, 400); RETURN; END;

    DECLARE @procObj INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName));

    -- Resolve @param tokens in the assertion predicate to their sample literals
    -- (longest name first so @Order does not clobber @OrderId).
    IF @PredicateSql IS NOT NULL AND @procObj IS NOT NULL
    BEGIN
        DECLARE @pn SYSNAME, @pv NVARCHAR(400);
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
            SELECT pr.name, TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  pr.object_id = @procObj AND pr.name <> N''
            ORDER  BY LEN(pr.name) DESC;
        OPEN pc; FETCH NEXT FROM pc INTO @pn, @pv;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @pv IS NOT NULL SET @PredicateSql = REPLACE(@PredicateSql, @pn, @pv);
            FETCH NEXT FROM pc INTO @pn, @pv;
        END;
        CLOSE pc; DEALLOCATE pc;
    END;

    -- Walk the per-table plan. Each table carries one or more demands (two atoms,
    -- or a self-join's two aliases). Reconcile them greedily, most-specific demand
    -- first: a more-specific row already counts toward a broader demand, so a
    -- COUNT total is back-filled and an over-constrained EXACT/MAX demand is a
    -- genuine contradiction (-> honest Skip). The strong assertion is the backstop.
    DECLARE @seed NVARCHAR(MAX) = N'';
    DECLARE @ovt  TABLE (col SYSNAME, val NVARCHAR(400));
    DECLARE @demT TABLE (idx INT IDENTITY(1,1), K INT, ovJson NVARCHAR(MAX), spec INT, mode VARCHAR(8));
    DECLARE @emit TABLE (idx INT IDENTITY(1,1), ovJson NVARCHAR(MAX), n INT);
    DECLARE @tsch SYSNAME, @ttbl SYSNAME, @tdemands NVARCHAR(MAX);
    DECLARE @objid INT, @ins NVARCHAR(MAX);
    DECLARE @dkspec NVARCHAR(MAX), @dcount NVARCHAR(20), @dov NVARCHAR(MAX);
    DECLARE @K INT, @kshape VARCHAR(32), @kcmp VARCHAR(16), @kcd NVARCHAR(MAX), @kwant BIT, @mode VARCHAR(8), @spec INT, @dovJson NVARCHAR(MAX);
    DECLARE @dK INT, @dmode VARCHAR(8), @satisfied INT, @need INT, @eOv NVARCHAR(MAX), @eN INT, @tot INT;

    DECLARE tc CURSOR LOCAL FAST_FORWARD FOR
        SELECT JSON_VALUE([value], '$.schema'), JSON_VALUE([value], '$.table'), JSON_QUERY([value], '$.demands')
        FROM   OPENJSON(@plan, '$.tables');
    OPEN tc; FETCH NEXT FROM tc INTO @tsch, @ttbl, @tdemands;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @objid = OBJECT_ID(QUOTENAME(@tsch) + N'.' + QUOTENAME(@ttbl));
        IF @objid IS NULL
        BEGIN SET @Reason = N'tree target table not found: ' + @tsch + N'.' + @ttbl; CLOSE tc; DEALLOCATE tc; RETURN; END;

        -- 1. resolve each demand of this table into (K, resolved overrides, mode)
        DELETE FROM @demT;
        DECLARE ddc CURSOR LOCAL FAST_FORWARD FOR
            SELECT JSON_QUERY([value], '$.kspec'), JSON_VALUE([value], '$.count'), JSON_QUERY([value], '$.overrides')
            FROM   OPENJSON(ISNULL(@tdemands, N'[]'));
        OPEN ddc; FETCH NEXT FROM ddc INTO @dkspec, @dcount, @dov;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            IF @dkspec IS NOT NULL
            BEGIN
                SET @kshape = JSON_VALUE(@dkspec, '$.shape');
                SET @kcmp   = JSON_VALUE(@dkspec, '$.comparator');
                SET @kcd    = JSON_VALUE(@dkspec, '$.comparand');
                SET @kwant  = TRY_CAST(JSON_VALUE(@dkspec, '$.want') AS BIT);
                IF @kcd LIKE '@%'
                    SELECT @kcd = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
                    FROM   sys.parameters pr JOIN sys.types t ON t.user_type_id = pr.user_type_id
                    WHERE  pr.object_id = @procObj AND pr.name = @kcd;
                SET @K = TestGen.CountForCase(@kshape, @kcmp, @kcd, @kwant);
                IF @K IS NULL
                BEGIN SET @Reason = N'degenerate/unsupported count: ' + @kshape + N' ' + ISNULL(@kcmp, N''); CLOSE ddc; DEALLOCATE ddc; CLOSE tc; DEALLOCATE tc; RETURN; END;
                -- Effective row-count constraint (mode) DEPENDS on @kwant: e.g.
                -- "COUNT > 0" wanted FALSE means "<= 0 rows" (a MAX/upper bound).
                SET @mode = CASE
                    WHEN @kshape = 'EXISTS'      THEN CASE WHEN @kwant = 1 THEN 'min' ELSE 'max' END
                    WHEN @kshape = 'SCALAR_NULL' THEN 'exact'
                    WHEN @kshape IN ('COUNT_IN','COUNT_BETWEEN') THEN 'exact'
                    WHEN @kshape = 'COUNT_CMP' THEN
                         CASE @kcmp
                             WHEN '='  THEN CASE WHEN @kwant = 1 THEN 'exact' ELSE 'min' END
                             WHEN '<>' THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'exact' END
                             WHEN '>'  THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'max' END
                             WHEN '>=' THEN CASE WHEN @kwant = 1 THEN 'min'   ELSE 'max' END
                             WHEN '<'  THEN CASE WHEN @kwant = 1 THEN 'max'   ELSE 'min' END
                             WHEN '<=' THEN CASE WHEN @kwant = 1 THEN 'max'   ELSE 'min' END
                             ELSE 'min' END
                    ELSE 'min' END;   -- SUM/MIN/MAX/AVG/SCALAR_CMP: one value-driven row
            END
            ELSE
            BEGIN SET @K = TRY_CAST(@dcount AS INT); SET @mode = 'min'; END;
            IF @K IS NULL SET @K = 0;

            DELETE FROM @ovt;
            INSERT @ovt (col, val)
            SELECT JSON_VALUE(o.[value], '$.col'),
                   TestGen.ResolveVspec(JSON_QUERY(o.[value], '$.vspec'), @procObj, @objid, JSON_VALUE(o.[value], '$.col'))
            FROM   OPENJSON(ISNULL(@dov, N'[]')) o;
            SET @dovJson = ISNULL((SELECT col AS [col], MAX(val) AS [val] FROM @ovt GROUP BY col FOR JSON PATH), N'[]');
            SET @spec = (SELECT COUNT(DISTINCT col) FROM @ovt);
            INSERT @demT (K, ovJson, spec, mode) VALUES (@K, @dovJson, @spec, @mode);

            FETCH NEXT FROM ddc INTO @dkspec, @dcount, @dov;
        END;
        CLOSE ddc; DEALLOCATE ddc;

        -- 2. greedy reconcile, most-specific first
        DELETE FROM @emit;
        DECLARE dc2 CURSOR LOCAL FAST_FORWARD FOR SELECT K, ovJson, mode FROM @demT ORDER BY spec DESC, idx;
        OPEN dc2; FETCH NEXT FROM dc2 INTO @dK, @dovJson, @dmode;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @satisfied = ISNULL((SELECT SUM(n) FROM @emit WHERE TestGen.OverridesContain(ovJson, @dovJson) = 1), 0);
            IF @dmode IN ('exact','max') AND @satisfied > @dK
            BEGIN
                SET @Reason = N'unsatisfiable predicate on ' + @tsch + N'.' + @ttbl
                            + N' (needs ' + CAST(@dK AS NVARCHAR(12)) + N' rows but '
                            + CAST(@satisfied AS NVARCHAR(12)) + N' already required)';
                CLOSE dc2; DEALLOCATE dc2; CLOSE tc; DEALLOCATE tc; RETURN;
            END;
            SET @need = @dK - @satisfied;
            IF @need > 0 INSERT @emit (ovJson, n) VALUES (@dovJson, @need);
            FETCH NEXT FROM dc2 INTO @dK, @dovJson, @dmode;
        END;
        CLOSE dc2; DEALLOCATE dc2;

        -- 2b. validate EXACT/MAX demands against the FINAL row set (a later
        -- min-demand may have added rows a max/exact demand cannot tolerate ->
        -- genuine contradiction / unreachable arm -> honest Skip).
        DECLARE vc CURSOR LOCAL FAST_FORWARD FOR SELECT K, ovJson, mode FROM @demT WHERE mode IN ('exact','max');
        OPEN vc; FETCH NEXT FROM vc INTO @dK, @dovJson, @dmode;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @tot = ISNULL((SELECT SUM(n) FROM @emit WHERE TestGen.OverridesContain(ovJson, @dovJson) = 1), 0);
            IF (@dmode = 'max' AND @tot > @dK) OR (@dmode = 'exact' AND @tot <> @dK)
            BEGIN
                SET @Reason = N'unsatisfiable predicate on ' + @tsch + N'.' + @ttbl
                            + N' (needs ' + @dmode + N' ' + CAST(@dK AS NVARCHAR(12))
                            + N' rows but ' + CAST(@tot AS NVARCHAR(12)) + N' present)';
                CLOSE vc; DEALLOCATE vc; CLOSE tc; DEALLOCATE tc; RETURN;
            END;
            FETCH NEXT FROM vc INTO @dK, @dovJson, @dmode;
        END;
        CLOSE vc; DEALLOCATE vc;

        IF (SELECT ISNULL(SUM(n), 0) FROM @emit) > @MaxSeedRows
        BEGIN SET @Reason = N'seed row count exceeds cap on ' + @tsch + N'.' + @ttbl; CLOSE tc; DEALLOCATE tc; RETURN; END;

        -- 3. emit one INSERT per reconciled row-group
        DECLARE ec CURSOR LOCAL FAST_FORWARD FOR SELECT ovJson, n FROM @emit ORDER BY idx;
        OPEN ec; FETCH NEXT FROM ec INTO @eOv, @eN;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @ins = TestGen.BuildSeedInsert(@tsch, @ttbl, @eOv, @eN);
            IF @ins IS NULL
            BEGIN SET @Reason = N'tree target ' + @tsch + N'.' + @ttbl + N' not insertable'; CLOSE ec; DEALLOCATE ec; CLOSE tc; DEALLOCATE tc; RETURN; END;
            SET @seed = @seed + N'    ' + @ins + CHAR(13) + CHAR(10);
            FETCH NEXT FROM ec INTO @eOv, @eN;
        END;
        CLOSE ec; DEALLOCATE ec;

        FETCH NEXT FROM tc INTO @tsch, @ttbl, @tdemands;
    END;
    CLOSE tc; DEALLOCATE tc;

    SET @SeedSql = N'    -- v0.12 ' + @Direction + N' seed for: ' + LEFT(@PredText, 200) + CHAR(13) + CHAR(10)
                 + CASE WHEN @seed = N'' THEN N'    -- (faked tables left empty for this direction)' ELSE @seed END;
    SET @Supported = 1;
END;
GO

/*-----------------------------------------------------------------------------
 * TestGen.SatisfyPredicate
 * The single case-analysis seeder.  Given a PredicateInbox row (@InboxId) and a
 * @Direction ('TRUE' / 'FALSE'), produce the seed T-SQL (@SeedSql).
 *   @Supported = 1 -> @SeedSql is the seed block (possibly an empty-table
 *                     comment when the satisfying state is "leave it empty").
 *   @Supported = 0 -> @Reason explains why; module 33 emits NOT_TESTABLE.
 *---------------------------------------------------------------------------*/
IF OBJECT_ID('TestGen.SatisfyPredicate', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.SatisfyPredicate;
GO
CREATE PROCEDURE TestGen.SatisfyPredicate
    @InboxId    INT,
    @Direction  VARCHAR(8),                 -- 'TRUE' | 'FALSE'
    @SeedSql    NVARCHAR(MAX) = NULL OUTPUT,
    @Supported  BIT           = NULL OUTPUT,
    @Reason     NVARCHAR(400) = NULL OUTPUT,
    @PredicateSql NVARCHAR(MAX) = NULL OUTPUT,   -- gate boolean, params resolved (strong assertion)
    @ExpectedBit  BIT          = NULL OUTPUT     -- 1 if @Direction makes the gate TRUE, else 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @SeedSql   = NULL;
    SET @Supported = 0;
    SET @Reason    = NULL;
    SET @PredicateSql = NULL;
    DECLARE @whereSql NVARCHAR(MAX) = NULL;

    DECLARE @want BIT = CASE WHEN UPPER(@Direction) = 'TRUE' THEN 1 ELSE 0 END;
    DECLARE @MaxSeedRows INT = 500;

    DECLARE @Shape VARCHAR(32), @Comparator VARCHAR(16), @Comparand NVARCHAR(MAX),
            @AggCol NVARCHAR(256), @TablesJson NVARCHAR(MAX), @WhereJson NVARCHAR(MAX),
            @JoinsJson NVARCHAR(MAX),
            @PredTreeJson NVARCHAR(MAX), @SeedPlanTrue NVARCHAR(MAX), @SeedPlanFalse NVARCHAR(MAX),
            @PredText NVARCHAR(MAX), @ProcSchema SYSNAME, @ProcName2 SYSNAME;

    SELECT @Shape = Shape, @Comparator = Comparator, @Comparand = Comparand,
           @AggCol = AggregateColumn, @TablesJson = TargetTablesJson,
           @WhereJson = WhereAstJson, @JoinsJson = JoinsJson,
           @PredTreeJson = PredicateTreeJson, @SeedPlanTrue = SeedPlanTrueJson,
           @SeedPlanFalse = SeedPlanFalseJson, @PredText = PredicateText,
           @ProcSchema = SchemaName, @ProcName2 = ProcName
    FROM   TestGen.PredicateInbox
    WHERE  InboxId = @InboxId;

    IF @@ROWCOUNT = 0
    BEGIN
        SET @Reason = N'PredicateInbox row not found (InboxId ' + CAST(@InboxId AS NVARCHAR(12)) + N').';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- v0.12 UNIFIED TREE PATH. When the parser emitted a predicate tree, the
    -- per-direction seed plan is authoritative; execute it and return. The flat
    -- (v0.10/v0.11) paths below remain as a one-release fallback.
    -- (design/DESIGN_v0_12_UnifiedReverseSeeder.md)
    --------------------------------------------------------------------------
    IF @PredTreeJson IS NOT NULL AND ISJSON(@PredTreeJson) = 1
    BEGIN
        EXEC TestGen.ExecuteSeedPlan
             @Direction = @Direction, @ProcSchema = @ProcSchema, @ProcName = @ProcName2,
             @PlanTrue = @SeedPlanTrue, @PlanFalse = @SeedPlanFalse, @PredText = @PredText,
             @SeedSql = @SeedSql OUTPUT, @Supported = @Supported OUTPUT, @Reason = @Reason OUTPUT,
             @PredicateSql = @PredicateSql OUTPUT, @ExpectedBit = @ExpectedBit OUTPUT;
        RETURN;
    END;

    IF @Shape = 'UNRECOGNISED'
    BEGIN
        SET @Reason = N'parser marked predicate UNRECOGNISED: ' + LEFT(@PredText, 300);
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- v0.11 JOIN path: EXISTS / NOT EXISTS over a 2-table INNER equi-join.
    -- Seeds coordinated rows across BOTH faked tables (shared join-key value,
    -- per-table WHERE/param overrides) and reconstructs the full joined gate
    -- for the strong assertion. Single-table predicates (@JoinsJson NULL) fall
    -- through to the existing logic below.
    --------------------------------------------------------------------------
    IF @JoinsJson IS NOT NULL AND ISJSON(@JoinsJson) = 1 AND @Shape IN ('EXISTS','NOT_EXISTS')
    BEGIN
        DECLARE @procObjJ INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName2));

        DECLARE @jt TABLE (ord INT, sch SYSNAME, tbl SYSNAME,
                           alias NVARCHAR(128) NULL, effalias NVARCHAR(128) NULL, objid INT NULL);
        INSERT @jt (ord, sch, tbl, alias)
        SELECT CAST([key] AS INT),
               ISNULL(JSON_VALUE([value],'$.schema'), N'dbo'),
               JSON_VALUE([value],'$.table'),
               JSON_VALUE([value],'$.alias')
        FROM   OPENJSON(@TablesJson);
        UPDATE @jt SET effalias = ISNULL(alias, tbl),
                       objid    = OBJECT_ID(QUOTENAME(sch) + N'.' + QUOTENAME(tbl));

        IF (SELECT COUNT(*) FROM @jt) <> 2
        BEGIN SET @Reason = N'join path expects exactly 2 tables (parser bound).'; RETURN; END;
        IF EXISTS (SELECT 1 FROM @jt WHERE objid IS NULL OR tbl IS NULL)
        BEGIN SET @Reason = N'a join target table could not be resolved.'; RETURN; END;

        DECLARE @jn TABLE (lAlias NVARCHAR(128) NULL, lCol SYSNAME, rAlias NVARCHAR(128) NULL, rCol SYSNAME, jval NVARCHAR(400) NULL);
        INSERT @jn (lAlias, lCol, rAlias, rCol)
        SELECT JSON_VALUE([value],'$.lAlias'), JSON_VALUE([value],'$.lCol'),
               JSON_VALUE([value],'$.rAlias'), JSON_VALUE([value],'$.rCol')
        FROM   OPENJSON(@JoinsJson);

        DECLARE @jcj TABLE (col SYSNAME, op VARCHAR(8), val NVARCHAR(400) NULL, valKind VARCHAR(16), tbl NVARCHAR(128) NULL);
        IF @WhereJson IS NOT NULL AND ISJSON(@WhereJson) = 1
        BEGIN
            -- WhereAstJson is DNF (array of OR terms). A joined WHERE with OR is
            -- out of this cut; require a single AND-composed disjunct.
            IF (SELECT COUNT(*) FROM OPENJSON(@WhereJson)) > 1
            BEGIN SET @Reason = N'OR composition in a joined WHERE is not seedable in this cut.'; RETURN; END;
            INSERT @jcj (col, op, val, valKind, tbl)
            SELECT JSON_VALUE(c.[value],'$.col'),
                   ISNULL(JSON_VALUE(c.[value],'$.op'), '='),
                   JSON_VALUE(c.[value],'$.val'),
                   ISNULL(JSON_VALUE(c.[value],'$.valKind'), 'literal'),
                   JSON_VALUE(c.[value],'$.tbl')
            FROM   OPENJSON(@WhereJson) t
            CROSS  APPLY OPENJSON(t.[value]) c
            WHERE  JSON_VALUE(c.[value],'$.col') IS NOT NULL;

            -- reverse-seed: resolve @param comparands to the proc-parameter sample.
            UPDATE cj
               SET val = TestGen.GetSampleValueLiteral(t.name, pr.max_length, pr.precision, pr.scale, 0)
            FROM   @jcj cj
            JOIN   sys.parameters pr ON pr.object_id = @procObjJ AND pr.name = cj.val
            JOIN   sys.types t ON t.user_type_id = pr.user_type_id
            WHERE  cj.valKind = 'param';

            IF EXISTS (SELECT 1 FROM @jcj WHERE valKind = 'param' AND val LIKE '@%')
            BEGIN SET @Reason = N'join WHERE references a parameter that is not a procedure parameter.'; RETURN; END;
            IF EXISTS (SELECT 1 FROM @jcj WHERE tbl IS NULL)
            BEGIN SET @Reason = N'unqualified WHERE column in a joined subquery cannot be routed to a table.'; RETURN; END;
            IF EXISTS (SELECT 1 FROM @jcj c WHERE NOT EXISTS (SELECT 1 FROM @jt t WHERE t.effalias = c.tbl))
            BEGIN SET @Reason = N'a WHERE conjunct references an alias not in the join.'; RETURN; END;
        END;

        -- A joining row is needed for EXISTS-TRUE and NOT_EXISTS-FALSE; otherwise
        -- leaving the faked tables empty makes the join (and the gate) the target.
        DECLARE @needRow BIT =
            CASE WHEN (@Shape = 'EXISTS' AND @want = 1) OR (@Shape = 'NOT_EXISTS' AND @want = 0)
                 THEN 1 ELSE 0 END;

        ----------------------------------------------------------------------
        -- Reconstruct the joined gate boolean for the strong assertion.
        ----------------------------------------------------------------------
        DECLARE @t0 NVARCHAR(400) =
            (SELECT QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                  + CASE WHEN alias IS NOT NULL THEN N' ' + QUOTENAME(alias) ELSE N'' END
             FROM @jt WHERE ord = 0);
        DECLARE @t1 NVARCHAR(400) =
            (SELECT QUOTENAME(sch) + N'.' + QUOTENAME(tbl)
                  + CASE WHEN alias IS NOT NULL THEN N' ' + QUOTENAME(alias) ELSE N'' END
             FROM @jt WHERE ord = 1);
        DECLARE @onSql NVARCHAR(MAX);
        SELECT @onSql = STRING_AGG(
                 QUOTENAME(lAlias) + N'.' + QUOTENAME(lCol) + N' = '
               + QUOTENAME(rAlias) + N'.' + QUOTENAME(rCol), N' AND ') FROM @jn;
        DECLARE @jWhere NVARCHAR(MAX) = NULL;
        IF EXISTS (SELECT 1 FROM @jcj)
            SELECT @jWhere = STRING_AGG(
                     QUOTENAME(tbl) + N'.' + QUOTENAME(col) + N' ' + op + N' ' + val, N' AND ') FROM @jcj;
        DECLARE @jFrom NVARCHAR(MAX) =
            @t0 + N' JOIN ' + @t1 + N' ON ' + @onSql
          + CASE WHEN @jWhere IS NULL THEN N'' ELSE N' WHERE ' + @jWhere END;
        SET @PredicateSql =
            CASE WHEN @Shape = 'EXISTS' THEN N'EXISTS (SELECT 1 FROM '     + @jFrom + N')'
                                        ELSE N'NOT EXISTS (SELECT 1 FROM ' + @jFrom + N')' END;
        SET @ExpectedBit = @want;

        ----------------------------------------------------------------------
        -- Emit the seed.
        ----------------------------------------------------------------------
        IF @needRow = 0
        BEGIN
            SET @SeedSql = N'    -- predicate ' + @Direction
                         + N': leave the faked join tables empty (no joining rows -> gate '
                         + @Direction + N').';
            SET @Supported = 1;
            RETURN;
        END;

        -- Shared join-key value: a WHERE "=" on a join column pins it; else a
        -- type-appropriate sample of the left join column (both sides identical).
        UPDATE jn SET jval = c.val
        FROM   @jn jn
        JOIN   @jcj c ON c.op = '='
                     AND ((c.tbl = jn.lAlias AND c.col = jn.lCol)
                       OR (c.tbl = jn.rAlias AND c.col = jn.rCol));
        UPDATE jn
           SET jval = TestGen.GetSampleValueLiteral(ty.name, col.max_length, col.precision, col.scale, 0)
        FROM   @jn jn
        JOIN   @jt t   ON t.effalias = jn.lAlias
        JOIN   sys.columns col ON col.object_id = t.objid AND col.name = jn.lCol
        JOIN   sys.types ty ON ty.user_type_id = col.user_type_id
        WHERE  jn.jval IS NULL;

        IF EXISTS (SELECT 1 FROM @jn WHERE jval IS NULL)
        BEGIN SET @Reason = N'could not resolve a join-key seed value.'; RETURN; END;

        DECLARE @tov TABLE (col SYSNAME, val NVARCHAR(400));
        DECLARE @tovJson NVARCHAR(MAX), @ins NVARCHAR(MAX), @seedAll NVARCHAR(MAX) = N'';
        DECLARE @co_ord INT, @co_sch SYSNAME, @co_tbl SYSNAME, @co_eff SYSNAME;
        DECLARE jc CURSOR LOCAL FAST_FORWARD FOR
            SELECT ord, sch, tbl, effalias FROM @jt ORDER BY ord;
        OPEN jc;
        FETCH NEXT FROM jc INTO @co_ord, @co_sch, @co_tbl, @co_eff;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE FROM @tov;
            -- join-key columns on this table get the shared value
            INSERT @tov (col, val)
            SELECT lCol, jval FROM @jn WHERE lAlias = @co_eff
            UNION
            SELECT rCol, jval FROM @jn WHERE rAlias = @co_eff;
            -- this table's WHERE conjuncts (satisfying value), excluding join cols
            INSERT @tov (col, val)
            SELECT c.col, TestGen.SatisfyingValue(c.op, c.val, 1)
            FROM   @jcj c
            WHERE  c.tbl = @co_eff
              AND  c.col NOT IN (SELECT col FROM @tov);

            IF EXISTS (SELECT 1 FROM @tov WHERE val IS NULL)
            BEGIN
                SET @Reason = N'join WHERE conjunct on ' + QUOTENAME(@co_tbl)
                            + N' is outside the supported grammar.';
                CLOSE jc; DEALLOCATE jc; RETURN;
            END;

            -- dedupe to one row per column (BuildSeedInsert joins overrides by name)
            SET @tovJson = (SELECT col AS [col], MAX(val) AS [val]
                            FROM @tov GROUP BY col FOR JSON PATH);
            SET @ins = TestGen.BuildSeedInsert(@co_sch, @co_tbl, @tovJson, 1);
            IF @ins IS NULL
            BEGIN
                SET @Reason = N'join target ' + QUOTENAME(@co_sch) + N'.' + QUOTENAME(@co_tbl)
                            + N' not found or has no insertable columns.';
                CLOSE jc; DEALLOCATE jc; RETURN;
            END;
            SET @seedAll = @seedAll + N'    ' + @ins + CHAR(13) + CHAR(10);
            FETCH NEXT FROM jc INTO @co_ord, @co_sch, @co_tbl, @co_eff;
        END;
        CLOSE jc; DEALLOCATE jc;

        SET @SeedSql = N'    -- predicate ' + @Direction + N' seed (join) for: '
                     + LEFT(@PredText, 200) + CHAR(13) + CHAR(10) + @seedAll;
        SET @Supported = 1;
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Resolve the (single) target table.
    --------------------------------------------------------------------------
    DECLARE @sch SYSNAME, @tbl SYSNAME, @raw NVARCHAR(400);
    SELECT TOP 1
        @sch = JSON_VALUE([value], '$.schema'),
        @tbl = JSON_VALUE([value], '$.table'),
        @raw = JSON_VALUE([value], '$.raw')
    FROM OPENJSON(@TablesJson)
    ORDER BY [key];

    -- Fall back to "schema.table" packed in $.table or $.raw.
    IF @tbl IS NULL AND @raw IS NOT NULL SET @tbl = @raw;
    IF @tbl IS NOT NULL AND @sch IS NULL AND CHARINDEX('.', @tbl) > 0
    BEGIN
        SET @sch = PARSENAME(@tbl, 2);
        SET @tbl = PARSENAME(@tbl, 1);
    END;
    IF @sch IS NULL SET @sch = N'dbo';

    IF @tbl IS NULL
    BEGIN
        SET @Reason = N'no target table resolved from TargetTablesJson.';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Build WHERE-match overrides (matching rows must satisfy the WHERE in
    -- BOTH directions; direction is controlled by row count / aggregate value).
    --------------------------------------------------------------------------
    DECLARE @ov TABLE (col SYSNAME, val NVARCHAR(400));
    DECLARE @unsupported BIT = 0;

    DECLARE @procObj INT = OBJECT_ID(QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName2));
    IF @WhereJson IS NOT NULL AND ISJSON(@WhereJson) = 1
    BEGIN
        -- WhereAstJson is DNF: an array of TERMS (OR-composed), each itself a
        -- JSON array of AND-composed conjuncts. Read all conjuncts tagged with
        -- their term index. Reverse-seed: resolve @param comparands to the
        -- proc-parameter sample value (the same GetSampleValueLiteral variant-0
        -- the test passes as the EXEC arg) so the seeded row matches the gate.
        DECLARE @cj TABLE (term INT, col SYSNAME, op VARCHAR(8), val NVARCHAR(400), valKind VARCHAR(16));
        INSERT @cj (term, col, op, val, valKind)
        SELECT t.[key],
               JSON_VALUE(c.[value], '$.col'),
               ISNULL(JSON_VALUE(c.[value], '$.op'), '='),
               JSON_VALUE(c.[value], '$.val'),
               ISNULL(JSON_VALUE(c.[value], '$.valKind'), 'literal')
        FROM   OPENJSON(@WhereJson) t
        CROSS  APPLY OPENJSON(t.[value]) c
        WHERE  JSON_VALUE(c.[value], '$.col') IS NOT NULL;

        UPDATE cj
           SET val = TestGen.GetSampleValueLiteral(t2.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   @cj cj
        JOIN   sys.parameters pr ON pr.object_id = @procObj AND pr.name = cj.val
        JOIN   sys.types t2 ON t2.user_type_id = pr.user_type_id
        WHERE  cj.valKind = 'param';

        IF EXISTS (SELECT 1 FROM @cj WHERE valKind = 'param' AND val LIKE '@%')
        BEGIN
            SET @Reason = N'WHERE references a parameter/variable that is not a '
                        + N'procedure parameter - cannot resolve a deterministic seed value.';
            RETURN;
        END;

        -- Pick the FIRST fully-seedable disjunct as the matching-row driver
        -- (every conjunct in it must yield a satisfying value).
        DECLARE @driver INT = NULL;
        SELECT TOP 1 @driver = term
        FROM   @cj
        GROUP  BY term
        HAVING SUM(CASE WHEN TestGen.SatisfyingValue(op, val, 1) IS NULL THEN 1 ELSE 0 END) = 0
        ORDER  BY term;

        IF @driver IS NULL
        BEGIN
            SET @Reason = N'no WHERE disjunct is fully seedable (a non-numeric '
                        + N'inequality or unknown operator in every OR branch).';
            RETURN;
        END;

        -- A matching row satisfies the driver disjunct -> it satisfies the whole
        -- OR (each seeded row counts once), so row-count case analysis is unchanged.
        INSERT @ov (col, val)
        SELECT col, TestGen.SatisfyingValue(op, val, 1) FROM @cj WHERE term = @driver;

        -- Strong-assertion WHERE = the FULL DNF, params resolved:
        --   (t0c0 AND t0c1) OR (t1c0) OR ...   (parens only when >1 disjunct).
        DECLARE @nterms INT = (SELECT COUNT(DISTINCT term) FROM @cj);
        ;WITH tt AS (
            SELECT term,
                   STRING_AGG(CONVERT(NVARCHAR(MAX),
                       QUOTENAME(col) + N' ' + op + N' ' + val), N' AND ') AS body
            FROM   @cj GROUP BY term )
        SELECT @whereSql = STRING_AGG(CONVERT(NVARCHAR(MAX),
                   CASE WHEN @nterms > 1 THEN N'(' + body + N')' ELSE body END), N' OR ')
        FROM   tt;

        IF EXISTS (SELECT 1 FROM @ov WHERE val IS NULL)
        BEGIN
            SET @Reason = N'WHERE clause has a conjunct outside the supported '
                        + N'grammar (non-numeric inequality or unknown operator).';
            RETURN;
        END;
    END;

    -- Parameter comparand (e.g. (SELECT COUNT(*) FROM T) > @Threshold): resolve
    -- @name to the proc-parameter sample value the test passes, so the seeded
    -- count/aggregate and the runtime gate agree (no ghost).
    IF @Comparand IS NOT NULL AND LEFT(@Comparand, 1) = N'@'
    BEGIN
        DECLARE @cmpVal NVARCHAR(400) = NULL;
        SELECT @cmpVal = TestGen.GetSampleValueLiteral(ty.name, pr.max_length, pr.precision, pr.scale, 0)
        FROM   sys.parameters pr
        JOIN   sys.types ty ON ty.user_type_id = pr.user_type_id
        WHERE  pr.object_id = @procObj AND pr.name = @Comparand;
        IF @cmpVal IS NULL
        BEGIN
            SET @Reason = N'comparand parameter ' + @Comparand
                        + N' is not a procedure parameter - cannot resolve a value.';
            RETURN;
        END;
        SET @Comparand = @cmpVal;
    END;

    --------------------------------------------------------------------------
    -- Case analysis: compute row count @K (and any aggregate-column override).
    --------------------------------------------------------------------------
    DECLARE @K INT = NULL;
    DECLARE @aggColName SYSNAME = NULL, @aggVal NVARCHAR(400) = NULL;
    DECLARE @N FLOAT, @Nint INT;
    DECLARE @op VARCHAR(16) = REPLACE(UPPER(ISNULL(@Comparator,'')), '!=', '<>');

    IF @Shape = 'EXISTS'        SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
    ELSE IF @Shape = 'NOT_EXISTS' SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;

    ELSE IF @Shape = 'SCALAR_NULL'
    BEGIN
        -- IS_NULL true  = empty (scalar subquery -> NULL); IS_NOT_NULL true = 1 row.
        IF @op = 'IS_NULL'      SET @K = CASE WHEN @want = 1 THEN 0 ELSE 1 END;
        ELSE IF @op = 'IS_NOT_NULL' SET @K = CASE WHEN @want = 1 THEN 1 ELSE 0 END;
        ELSE
        BEGIN
            SET @Reason = N'SCALAR_NULL with unexpected comparator ' + ISNULL(@op,'(null)');
            RETURN;
        END;
    END;

    ELSE IF @Shape = 'COUNT_CMP'
    BEGIN
        SET @N = TRY_CAST(@Comparand AS FLOAT);
        IF @N IS NULL OR @N <> FLOOR(@N)
        BEGIN
            SET @Reason = N'COUNT comparand is not an integer literal: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        SET @Nint = CAST(@N AS INT);
        IF      @op = '='  SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint + 1 END;
        ELSE IF @op = '<>' SET @K = CASE WHEN @want = 1 THEN @Nint + 1    ELSE @Nint     END;
        ELSE IF @op = '>'  SET @K = CASE WHEN @want = 1 THEN @Nint + 1    ELSE 0         END;
        ELSE IF @op = '>=' SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint - 1 END;
        ELSE IF @op = '<'  SET @K = CASE WHEN @want = 1 THEN @Nint - 1    ELSE @Nint     END;
        ELSE IF @op = '<=' SET @K = CASE WHEN @want = 1 THEN @Nint        ELSE @Nint + 1 END;
        ELSE
        BEGIN
            SET @Reason = N'COUNT comparator not supported: ' + ISNULL(@op,'(null)');
            RETURN;
        END;
        IF @K < 0
        BEGIN
            SET @Reason = N'degenerate COUNT threshold: cannot make "' + LEFT(@PredText,200)
                        + N'" evaluate ' + @Direction + N' (would need a negative row count).';
            RETURN;
        END;
    END;

    ELSE IF @Shape = 'COUNT_IN'
    BEGIN
        DECLARE @first INT = NULL, @maxv INT = NULL, @bad INT = 0;
        SELECT  @first = MIN(CASE WHEN ord = 1 THEN v END),
                @maxv  = MAX(v),
                @bad   = SUM(CASE WHEN v IS NULL THEN 1 ELSE 0 END)
        FROM (
            SELECT  TRY_CAST(LTRIM(RTRIM([value])) AS INT) AS v,
                    ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS ord
            FROM    STRING_SPLIT(ISNULL(@Comparand, N''), ',')
        ) s;
        IF @bad > 0 OR @first IS NULL
        BEGIN
            SET @Reason = N'COUNT IN(...) list is not all integer literals: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        -- TRUE: count = first list value.  FALSE: a count not in the list (max+1).
        SET @K = CASE WHEN @want = 1 THEN @first ELSE @maxv + 1 END;
    END;

    ELSE IF @Shape = 'COUNT_BETWEEN'
    BEGIN
        DECLARE @A INT = TRY_CAST(LTRIM(RTRIM(
                   LEFT(@Comparand, CHARINDEX(' AND ', ' ' + UPPER(@Comparand) + ' ') - 1))) AS INT);
        -- Robust split on ' AND '
        DECLARE @up NVARCHAR(MAX) = UPPER(@Comparand);
        DECLARE @ap INT = CHARINDEX(' AND ', @up);
        IF @ap > 0
        BEGIN
            SET @A = TRY_CAST(LTRIM(RTRIM(LEFT(@Comparand, @ap - 1))) AS INT);
            DECLARE @B INT = TRY_CAST(LTRIM(RTRIM(SUBSTRING(@Comparand, @ap + 5, 4000))) AS INT);
            IF @A IS NULL OR @B IS NULL
            BEGIN
                SET @Reason = N'COUNT BETWEEN bounds are not integer literals: ' + @Comparand;
                RETURN;
            END;
            SET @K = CASE WHEN @want = 1 THEN @A
                          WHEN @A >= 1   THEN @A - 1
                          ELSE @B + 1 END;
        END
        ELSE
        BEGIN
            SET @Reason = N'COUNT BETWEEN could not be parsed: ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
    END;

    ELSE IF @Shape IN ('SUM_CMP','MIN_CMP','MAX_CMP','AVG_CMP','SCALAR_CMP')
    BEGIN
        -- One row whose aggregate/selected column carries a value that makes the
        -- single-row aggregate satisfy (or violate) the comparator.
        SET @K = 1;
        -- Inner column: between '(' and ')' for aggregates; the bare column for SCALAR.
        DECLARE @inner NVARCHAR(256) = @AggCol;
        DECLARE @op1 INT = CHARINDEX('(', ISNULL(@AggCol,''));
        IF @op1 > 0
            SET @inner = SUBSTRING(@AggCol, @op1 + 1, CHARINDEX(')', @AggCol + ')', @op1) - @op1 - 1);
        -- Strip table/alias qualifier and brackets.
        SET @aggColName = PARSENAME(REPLACE(REPLACE(LTRIM(RTRIM(@inner)), '[',''), ']',''), 1);
        IF @aggColName IS NULL OR @aggColName = N'*'
        BEGIN
            SET @Reason = N'could not resolve aggregate/scalar column from "' + ISNULL(@AggCol,'(null)') + N'".';
            RETURN;
        END;
        SET @aggVal = TestGen.SatisfyingValue(@op, @Comparand, @want);
        IF @aggVal IS NULL
        BEGIN
            SET @Reason = N'aggregate/scalar comparator+comparand outside supported grammar: '
                        + ISNULL(@op,'') + N' ' + ISNULL(@Comparand,'(null)');
            RETURN;
        END;
        -- Aggregate override wins over any WHERE override on the same column.
        DELETE FROM @ov WHERE col = @aggColName;
        INSERT @ov (col, val) VALUES (@aggColName, @aggVal);
    END;

    ELSE
    BEGIN
        SET @Reason = N'unhandled predicate shape: ' + @Shape;
        RETURN;
    END;

    -- Reconstruct the gate boolean (params already resolved in @whereSql) so the
    -- generated test can ASSERT the seed actually drove the predicate the right
    -- way (no ghost pass: a wrong seed fails this assertion).
    SET @ExpectedBit = @want;
    DECLARE @tgtSql NVARCHAR(300) = QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl);
    DECLARE @whereClause NVARCHAR(MAX) = CASE WHEN @whereSql IS NULL OR @whereSql = N'' THEN N'' ELSE N' WHERE ' + @whereSql END;
    DECLARE @scalarCol SYSNAME = ISNULL(@aggColName, @AggCol);
    SET @PredicateSql =
        CASE @Shape
            WHEN 'EXISTS'        THEN N'EXISTS (SELECT 1 FROM '     + @tgtSql + @whereClause + N')'
            WHEN 'NOT_EXISTS'    THEN N'NOT EXISTS (SELECT 1 FROM ' + @tgtSql + @whereClause + N')'
            WHEN 'COUNT_CMP'     THEN N'(SELECT COUNT(*) FROM '     + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'SUM_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'MIN_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'MAX_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'AVG_CMP'       THEN N'(SELECT ' + @AggCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'SCALAR_CMP'    THEN N'(SELECT ' + @scalarCol + N' FROM ' + @tgtSql + @whereClause + N') ' + @op + N' ' + @Comparand
            WHEN 'COUNT_IN'      THEN N'(SELECT COUNT(*) FROM ' + @tgtSql + @whereClause + N')' + CASE WHEN @op = N'NOT_IN' THEN N' NOT IN (' ELSE N' IN (' END + @Comparand + N')'
            WHEN 'COUNT_BETWEEN' THEN N'(SELECT COUNT(*) FROM ' + @tgtSql + @whereClause + N') BETWEEN ' + @Comparand
            WHEN 'SCALAR_NULL'   THEN N'(SELECT ' + @scalarCol + N' FROM ' + @tgtSql + @whereClause + N') ' + CASE WHEN @op = N'IS_NOT_NULL' THEN N'IS NOT NULL' ELSE N'IS NULL' END
        END;

    IF @K IS NULL
    BEGIN
        SET @Reason = N'internal: row count not computed for shape ' + @Shape;
        RETURN;
    END;

    IF @K > @MaxSeedRows
    BEGIN
        SET @Reason = N'seed row count ' + CAST(@K AS NVARCHAR(12)) + N' exceeds cap ('
                    + CAST(@MaxSeedRows AS NVARCHAR(12)) + N') for "' + LEFT(@PredText,160) + N'".';
        RETURN;
    END;

    --------------------------------------------------------------------------
    -- Emit.
    --------------------------------------------------------------------------
    IF @K = 0
    BEGIN
        SET @SeedSql   = N'    -- predicate ' + @Direction + N': leave faked '
                       + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl)
                       + N' empty (no rows satisfy the subquery).';
        SET @Supported = 1;
        RETURN;
    END;

    DECLARE @ovJson NVARCHAR(MAX) =
        (SELECT col AS [col], val AS [val] FROM @ov FOR JSON PATH);

    DECLARE @insert NVARCHAR(MAX) = TestGen.BuildSeedInsert(@sch, @tbl, @ovJson, @K);
    IF @insert IS NULL
    BEGIN
        SET @Reason = N'target table ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl)
                    + N' not found or has no insertable columns.';
        RETURN;
    END;

    SET @SeedSql = N'    -- predicate ' + @Direction + N' seed for: ' + LEFT(@PredText, 200) + CHAR(13) + CHAR(10)
                 + N'    ' + @insert;
    SET @Supported = 1;
END;
GO

PRINT 'Module 32 (predicate seeder) installed.';
GO


/* === modules/33_Predicate_TestGen_v1.sql (v0.10) === */
/*=============================================================================
 * MODULE 33 - Predicate test-gen integration (v0.10 predicate-aware seeding)
 * Bridges PredicateInbox (31) + seeder (32) into the test generator.
 *   1. TestGen.BuildPredicateSeedBlock  - the hook module 04 calls; prefers
 *      matching the branch by SOURCE LINE over the ordinal BranchId.
 *   2. TestGen.BuildNotTestableFailBody - body of a placeholder tSQLt test.
 *   3. TestGen.GeneratePredicateBranchPlan - per branch x direction plan.
 *===========================================================================*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('TestGen.BuildNotTestableFailBody', 'FN') IS NOT NULL
    DROP FUNCTION TestGen.BuildNotTestableFailBody;
GO
CREATE FUNCTION TestGen.BuildNotTestableFailBody
(
    @BranchId      INT,
    @PredicateText NVARCHAR(MAX),
    @Reason        NVARCHAR(400)
)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    -- Use NCHAR(39) for the single quote so the source carries no literal
    -- quote-doubling runs (keeps it readable and lexer-friendly).
    DECLARE @q NCHAR(1) = NCHAR(39);
    DECLARE @msg NVARCHAR(MAX) =
        N'NOT_TESTABLE branch ' + CAST(@BranchId AS NVARCHAR(10))
      + N': predicate ' + @q + REPLACE(ISNULL(@PredicateText, N''), @q, @q + @q) + @q + N' - '
      + REPLACE(ISNULL(@Reason, N'outside the v0.10 predicate grammar'), @q, @q + @q)
      + N'. Hand-author via EnsureCustomTestClass to close this branch.';
    RETURN N'    EXEC tSQLt.Fail N' + @q + REPLACE(@msg, @q, @q + @q) + @q + N';';
END;
GO

IF OBJECT_ID('TestGen.BuildPredicateSeedBlock', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.BuildPredicateSeedBlock;
GO
CREATE PROCEDURE TestGen.BuildPredicateSeedBlock
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @BranchId   INT,
    @Direction  VARCHAR(8),
    @RunId      UNIQUEIDENTIFIER = NULL,
    @SeedBlock  NVARCHAR(MAX) = NULL OUTPUT,
    @Supported  BIT           = NULL OUTPUT,
    @Reason     NVARCHAR(400) = NULL OUTPUT,
    @Shape      VARCHAR(32)   = NULL OUTPUT,
    @PredicateText NVARCHAR(MAX) = NULL OUTPUT,
    @StartLine  INT           = NULL OUTPUT,
    @MatchByLine INT          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @SeedBlock = NULL; SET @Supported = 0; SET @Reason = NULL;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
        ORDER  BY CreatedAt DESC, InboxId DESC;

    -- Preferred match is by source line: both sides agree a gate exists at line
    -- N without agreeing on ordinal numbering. Falls back to BranchId.
    DECLARE @InboxId INT;
    SELECT TOP 1 @InboxId = InboxId, @Shape = Shape, @PredicateText = PredicateText, @StartLine = StartLine
    FROM   TestGen.PredicateInbox
    WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
      AND  (@RunId IS NULL OR RunId = @RunId)
      AND  (   (@MatchByLine IS NOT NULL AND StartLine = @MatchByLine)
            OR (@MatchByLine IS NULL     AND BranchId  = @BranchId) )
    ORDER  BY BranchId;

    IF @InboxId IS NULL
    BEGIN
        SET @Reason = N'no PredicateInbox row for branch ' + CAST(@BranchId AS NVARCHAR(10))
                    + N' - proc not parsed or branch is parameter-only; fall back to existing seeding.';
        RETURN;
    END;

    EXEC TestGen.SatisfyPredicate
        @InboxId   = @InboxId,
        @Direction = @Direction,
        @SeedSql   = @SeedBlock OUTPUT,
        @Supported = @Supported OUTPUT,
        @Reason    = @Reason    OUTPUT;
END;
GO

IF OBJECT_ID('TestGen.GeneratePredicateBranchPlan', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GeneratePredicateBranchPlan;
GO
CREATE PROCEDURE TestGen.GeneratePredicateBranchPlan
    @SchemaName SYSNAME,
    @ProcName   SYSNAME,
    @RunId      UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
        SELECT TOP 1 @RunId = RunId
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
        ORDER  BY CreatedAt DESC, InboxId DESC;

    DECLARE @plan TABLE (
        BranchId INT, StartLine INT, Context VARCHAR(16), Shape VARCHAR(32), Direction VARCHAR(8),
        Supported BIT, SeedSql NVARCHAR(MAX), NotTestableReason NVARCHAR(400),
        FailBody NVARCHAR(MAX), PredicateText NVARCHAR(MAX)
    );

    DECLARE @InboxId INT, @BranchId INT, @StartLine INT, @Context VARCHAR(16), @Shape VARCHAR(32), @PredText NVARCHAR(MAX);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT InboxId, BranchId, StartLine, Context, Shape, PredicateText
        FROM   TestGen.PredicateInbox
        WHERE  SchemaName = @SchemaName AND ProcName = @ProcName
          AND  (@RunId IS NULL OR RunId = @RunId)
        ORDER  BY BranchId;
    OPEN c;
    FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Context, @Shape, @PredText;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @dir VARCHAR(8), @i INT = 0;
        WHILE @i < 2
        BEGIN
            SET @dir = CASE @i WHEN 0 THEN 'TRUE' ELSE 'FALSE' END;
            DECLARE @seed NVARCHAR(MAX), @sup BIT, @rsn NVARCHAR(400);
            EXEC TestGen.SatisfyPredicate @InboxId = @InboxId, @Direction = @dir,
                 @SeedSql = @seed OUTPUT, @Supported = @sup OUTPUT, @Reason = @rsn OUTPUT;

            INSERT @plan (BranchId, StartLine, Context, Shape, Direction, Supported, SeedSql, NotTestableReason, FailBody, PredicateText)
            VALUES (@BranchId, @StartLine, @Context, @Shape, @dir, @sup, @seed, @rsn,
                    CASE WHEN @sup = 0 THEN TestGen.BuildNotTestableFailBody(@BranchId, @PredText, @rsn) END,
                    @PredText);
            SET @i = @i + 1;
        END;
        FETCH NEXT FROM c INTO @InboxId, @BranchId, @StartLine, @Context, @Shape, @PredText;
    END;
    CLOSE c; DEALLOCATE c;

    SELECT BranchId, StartLine, Context, Shape, Direction, Supported, SeedSql, NotTestableReason, FailBody, PredicateText
    FROM   @plan
    ORDER  BY BranchId, CASE Direction WHEN 'TRUE' THEN 0 ELSE 1 END;
END;
GO

PRINT 'Module 33 (predicate test-gen integration) installed.';
GO

/* === modules/34_Predicate_BranchTests_v1.sql (v0.10) === */
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

/* === modules/35_Predicate_Orchestrator_v1.sql (v0.10) === */
/*=============================================================================
 * MODULE 35 - Predicate-aware sweep (v0.10) - now a thin alias
 * -----------------------------------------------------------------------------
 * GenerateAndCoverDatabase is now predicate-aware INLINE: its per-proc loop adds
 * the seeded predicate-branch tests (TestGen.GeneratePredicateBranchTests, ~0.6s)
 * BEFORE its single RunCoverage, gated on the proc having PredicateInbox rows.
 * So a plain sweep reflects the v0.10 lift in ONE coverage pass - no second
 * measure. This proc remains only as a backward-compatible alias.
 *
 * Flow for a v0.10 run:  parse (Get-ParsedPredicates) -> GenerateAndCoverDatabase.
 *===========================================================================*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('TestGen.GenerateAndCoverDatabaseV10', 'P') IS NOT NULL
    DROP PROCEDURE TestGen.GenerateAndCoverDatabaseV10;
GO
CREATE PROCEDURE TestGen.GenerateAndCoverDatabaseV10
    @SchemaFilter   SYSNAME        = NULL,
    @ExcludePattern NVARCHAR(4000) = NULL,
    @OutputMode     VARCHAR(10)    = 'NONE'
AS
BEGIN
    SET NOCOUNT ON;
    PRINT 'NOTE: GenerateAndCoverDatabase is now predicate-aware inline; '
        + 'GenerateAndCoverDatabaseV10 is a compatibility alias.';
    EXEC TestGen.GenerateAndCoverDatabase
         @SchemaFilter = @SchemaFilter, @ExcludePattern = @ExcludePattern, @OutputMode = @OutputMode;
END;
GO

PRINT 'Module 35 (predicate-aware sweep alias) installed.';
GO
/* >>> UAG v0.10 predicate-seeding END <<< */



/*---------------------------------------------------------------------------
 * End-of-install: re-enable execution. Pairs with SET NOEXEC ON in the
 * pre-flight check at the top. If the pre-flight tripped, this restores
 * the session to a normal state; if it didn't, this is a no-op.
 *
 * The success / failure banner below is guarded on whether tSQLt is
 * present AND a core framework procedure actually got created, so we
 * never lie about a successful install when the pre-flight aborted.
 *--------------------------------------------------------------------------*/
SET NOEXEC OFF;
GO

IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'tSQLt')
   AND OBJECT_ID('TestGen.GenerateTestsForProcedure','P') IS NOT NULL
BEGIN
    PRINT '----------------------------------------------------------------';
    PRINT 'UnitAutogen framework installed successfully.';
    PRINT '----------------------------------------------------------------';
END
ELSE
BEGIN
    PRINT '****************************************************************';
    PRINT '* UnitAutogen install did NOT complete. See errors above.      *';
    PRINT '* Most common cause: tSQLt is not installed in this database.  *';
    PRINT '* Install tSQLt from https://tsqlt.org and re-run this script. *';
    PRINT '****************************************************************';
END
GO
