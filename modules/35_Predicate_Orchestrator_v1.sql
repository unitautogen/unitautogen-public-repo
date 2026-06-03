/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 * GNU Affero General Public License v3.0. See LICENSE / COPYRIGHT.
 * Distributed WITHOUT ANY WARRANTY. Commercial licence: licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

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