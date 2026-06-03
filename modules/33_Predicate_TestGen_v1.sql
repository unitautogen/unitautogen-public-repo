/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * GNU Affero General Public License v3.0. See LICENSE / COPYRIGHT.
 * Distributed WITHOUT ANY WARRANTY. Commercial licence: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

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