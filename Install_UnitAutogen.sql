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
    CREATE TABLE #ExpectedShape
    (
        ColumnOrdinal INT,
        ColumnName    SYSNAME NULL,
        SqlTypeName   SYSNAME,
        MaxLength     SMALLINT,
        [Precision]   TINYINT,
        Scale         TINYINT,
        IsNullable    BIT
    );
    CREATE TABLE #ActualShape
    (
        ColumnOrdinal INT,
        ColumnName    SYSNAME NULL,
        SqlTypeName   SYSNAME,
        MaxLength     SMALLINT,
        [Precision]   TINYINT,
        Scale         TINYINT,
        IsNullable    BIT
    );

    INSERT #ExpectedShape (ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale, IsNullable)
    SELECT ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale, IsNullable
    FROM TestGenLog.ResultShapeBaseline
    WHERE TestClass = @TestClass;

    INSERT #ActualShape (ColumnOrdinal, ColumnName, SqlTypeName, MaxLength, [Precision], Scale, IsNullable)
    SELECT column_ordinal, name, system_type_name, max_length,
           [precision], scale, is_nullable
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
    @CaptureRows                   BIT           = 0,    -- when 1, also emit a golden-row baseline test
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
                    -- Pin to "1" - the first seeded integer value. For strings
                    -- the seeder writes 'SampleText_1' / 'Sa1' / etc.; for now
                    -- we only override int-like params because string-key
                    -- matching is much rarer and trickier.
                    IF LOWER(@ptype) IN ('int','bigint','smallint','tinyint')
                        SET @happyVal = N'1';
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
        SET @S = @S + N'    -- Act' + @CRLF;
        SET @S = @S + N'    EXEC ' + @FullProc;
        IF LEN(@ArgListHappy) > 0
            SET @S = @S + N' ' + @ArgListHappy;
        SET @S = @S + N';' + @CRLF + @CRLF;
        SET @S = @S + N'    -- Assert (smoke - did not throw)' + @CRLF;
        SET @S = @S + N'    EXEC tSQLt.AssertEquals 1, 1, ''Procedure executed without error.'';' + @CRLF;
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
                SET @S = @S + N'    -- Proc has input validation; boundary values are expected to be rejected.' + @CRLF
                            + N'    EXEC tSQLt.ExpectException;' + @CRLF;
            SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListBoundary + N';' + @CRLF;
            IF @UseExpectExceptionForInvalid = 0
                SET @S = @S + N'    EXEC tSQLt.AssertEquals 1, 1;' + @CRLF;
            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

            -- Test 2b: high boundary
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' ' + @boundaryVerb
                       + N' high boundary values]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            IF @UseExpectExceptionForInvalid = 1
                SET @S = @S + N'    -- Proc has input validation; boundary values are expected to be rejected.' + @CRLF
                            + N'    EXEC tSQLt.ExpectException;' + @CRLF;
            SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListHighBnd + N';' + @CRLF;
            IF @UseExpectExceptionForInvalid = 0
                SET @S = @S + N'    EXEC tSQLt.AssertEquals 1, 1;' + @CRLF;
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
                SET @S = @S + N'    -- This parameter is not one the procedure is known to' + @CRLF;
                SET @S = @S + N'    -- validate, so a NULL is not expected to raise; this is a' + @CRLF;
                SET @S = @S + N'    -- smoke test that the procedure still runs cleanly.' + @CRLF;
                SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgsNull + N';' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.AssertEquals 1, 1;' + @CRLF;
            END;

            SET @S = @S + N'END;' + @CRLF + N'GO' + @CRLF + @CRLF;

            FETCH NEXT FROM ncur INTO @nullParamId, @nullParamName;
        END;
        CLOSE ncur; DEALLOCATE ncur;

        /* -- Test 4: side-effect isolation on referenced tables --------- */
        IF EXISTS (SELECT 1 FROM @Deps WHERE DepKind IN ('TABLE','VIEW'))
        BEGIN
            DECLARE @v94IsReadOnly BIT;
            SET @v94IsReadOnly =
                CASE WHEN N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]INSERT[^A-Z0-9_]%'
                       OR N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]UPDATE[^A-Z0-9_]%'
                       OR N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]DELETE[^A-Z0-9_]%'
                       OR N' ' + UPPER(@ProcSource) + N' ' LIKE N'%[^A-Z0-9_]MERGE[^A-Z0-9_]%'
                     THEN 0 ELSE 1 END;
            -- This is an isolation test.  A read-only procedure additionally gets a
            -- strong per-table "row counts unchanged" assertion below; a DML
            -- procedure legitimately changes its (faked) tables, so for it this is
            -- an isolation smoke test - it must run cleanly against faked + seeded
            -- copies of every dependency (the EXEC below is TRY/CATCH-guarded).
            SET @S = @S + N'CREATE PROCEDURE ' + QUOTENAME(@TC)
                       + N'.[test ' + @ProcName + N' touches only mocked tables]' + @CRLF;
            SET @S = @S + N'AS' + @CRLF + N'BEGIN' + @CRLF + @MockBlock + ISNULL(@OutputDecls, N'');
            SET @S = @S + N'    -- Capture row counts before execution' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #v94_RcBefore (TableName SYSNAME, [RowCount] INT);' + @CRLF;
            SET @S = @S + N'    CREATE TABLE #v94_RcAfter  (TableName SYSNAME, [RowCount] INT);' + @CRLF;
            
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
                FETCH NEXT FROM tcur INTO @TableSchema, @TableName;
            END;
            CLOSE tcur;
            DEALLOCATE tcur;
            
            SET @S = @S + N'' + @CRLF;
            SET @S = @S + N'    -- v9.4.2: per-table isolation check (was a cross-table SUM,' + @CRLF;
            SET @S = @S + N'    --         which hid offsetting changes and was never asserted).' + @CRLF;
            IF @v94IsReadOnly = 1
            BEGIN
                SET @S = @S + N'    -- Read-only procedure: every faked table''s row count must be' + @CRLF;
                SET @S = @S + N'    -- identical before and after.  AssertEqualsTable compares the two' + @CRLF;
                SET @S = @S + N'    -- capture tables row-for-row, so a change in ANY single table is' + @CRLF;
                SET @S = @S + N'    -- caught - a cross-table sum would hide offsetting changes.' + @CRLF;
                SET @S = @S + N'    EXEC tSQLt.AssertEqualsTable ''#v94_RcBefore'', ''#v94_RcAfter'';' + @CRLF;
            END
            ELSE
            BEGIN
                SET @S = @S + N'    -- DML procedure: per-table counts change by design, so there is no' + @CRLF;
                SET @S = @S + N'    -- counts-unchanged assertion.  The isolation assertion is the' + @CRLF;
                SET @S = @S + N'    -- TRY/CATCH around the EXEC above; the per-table delta below is' + @CRLF;
                SET @S = @S + N'    -- printed for reference (specific table effects: see branch tests).' + @CRLF;
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
            SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListHappy + N';' + @CRLF;
            SET @S = @S + N'    -- TODO: replace below with type-appropriate AssertEquals checks per OUTPUT param.' + @CRLF;
            SET @S = @S + N'    EXEC tSQLt.AssertEquals 1, 1;' + @CRLF;
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

            IF @CaptureRows = 1
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
    @CaptureRows                   BIT           = 0,
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
    @OutputMode     VARCHAR(10)   = 'HTML'  -- HTML or TEXT
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

    /*-------------------------------- HTML ---------------------------------*/
    DECLARE @H NVARCHAR(MAX) = N'';
    SET @H = @H + N'<!DOCTYPE html><html><head><meta charset="utf-8"><title>tSQLt Auto-Gen Coverage</title><style>';
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
    SET @H = @H + N'<h2>tSQLt Auto-Gen &mdash; Database Coverage Report</h2>';
    SET @H = @H + N'<p class="meta">' + DB_NAME() + N' &middot; ' + CONVERT(VARCHAR,@BatchId,120)
                 + N' &middot; ' + CAST(@gProcs AS VARCHAR) + N' procedures ('
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
        + N'<th class="l">Schema</th><th class="l">Procedure</th>'
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
        + CAST(@gProcs AS VARCHAR) + N' procedures ('
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

    -- Also clean up any leftover synonym/backup from previous failed run
    BEGIN TRY
        IF OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName), 'SN') IS NOT NULL
        BEGIN
            SET @SQL = N'DROP SYNONYM ' + QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName);
            EXEC(@SQL);
        END;
    END TRY BEGIN CATCH END CATCH;
    BEGIN TRY
        IF OBJECT_ID(@BackupFull,'P') IS NOT NULL AND OBJECT_ID(QUOTENAME(@SchemaName)+'.'+QUOTENAME(@ProcName),'P') IS NULL
        BEGIN
            SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + '_orig'', ''' + @ProcName + '''';
            EXEC(@SQL);
        END;
    END TRY BEGIN CATCH END CATCH;

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

    SET @OrigFull = QUOTENAME(@SchemaName) + '.' + QUOTENAME(@ProcName);
    SET @SynFull  = @OrigFull;

    -- Rename original to _orig
    IF OBJECT_ID(@BackupFull, 'P') IS NOT NULL
    BEGIN
        SET @SQL = N'DROP PROCEDURE ' + @BackupFull;
        EXEC(@SQL);
    END;
    SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + ''', ''' + @ProcName + '_orig''';
    EXEC(@SQL);
    PRINT 'Original renamed to _orig.';

    -- Create synonym: original name -> _cov
    IF OBJECT_ID(@SynFull, 'SN') IS NOT NULL
    BEGIN
        SET @SQL = N'DROP SYNONYM ' + @SynFull;
        EXEC(@SQL);
    END;
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

    ---------------------------------------------------------------------------
    -- Step 5: Restore - drop synonym, rename _orig back to original
    ---------------------------------------------------------------------------
    IF OBJECT_ID(@SynFull, 'SN') IS NOT NULL
    BEGIN
        SET @SQL = N'DROP SYNONYM ' + @SynFull;
        EXEC(@SQL);
    END;
    IF OBJECT_ID(@BackupFull, 'P') IS NOT NULL
    BEGIN
        SET @SQL = N'EXEC sp_rename ''' + @SchemaName + '.' + @ProcName + '_orig'', ''' + @ProcName + '''';
        EXEC(@SQL);
    END;
    PRINT 'Original proc restored.';

    ---------------------------------------------------------------------------
    -- Step 5: Wait for events to flush to disk
    ---------------------------------------------------------------------------
    WAITFOR DELAY '00:00:03';

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
