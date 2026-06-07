/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * GNU Affero General Public License v3.0. See LICENSE / COPYRIGHT.
 * Distributed WITHOUT ANY WARRANTY. Commercial licence: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

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
        -- v0.12: seed overrides lifted from a guarded UPDATE/DELETE's WHERE so the
        -- boundary test seeds rows the DML will hit. {"schema","table","overrides":[{"col","val"}]}.
        BodyDmlSeedJson  NVARCHAR(MAX)    NULL,
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

-- Upgrade-safe: add the v0.12 body-DML seed-overrides column to a pre-existing table.
IF OBJECT_ID('TestGen.PredicateInbox','U') IS NOT NULL
   AND COL_LENGTH('TestGen.PredicateInbox','BodyDmlSeedJson') IS NULL
BEGIN
    ALTER TABLE TestGen.PredicateInbox ADD BodyDmlSeedJson NVARCHAR(MAX) NULL;
    PRINT 'TestGen.PredicateInbox: added BodyDmlSeedJson column (upgrade).';
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
    @BodyDmlSeedJson  NVARCHAR(MAX) = NULL,
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
         PredicateTreeJson, SeedPlanTrueJson, SeedPlanFalseJson, BodyDmlSeedJson,
         PredicateText, UnsupportedReason, ParserVersion, RunId)
    VALUES
        (@SchemaName, @ProcName, @BranchId, @StartLine, @Context, @Shape,
         @AggregateColumn, @Comparator, @Comparand,
         @TargetTablesJson, @JoinsJson, @WhereAstJson,
         @PredicateTreeJson, @SeedPlanTrueJson, @SeedPlanFalseJson, @BodyDmlSeedJson,
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