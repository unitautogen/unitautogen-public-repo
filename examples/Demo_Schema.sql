/*-----------------------------------------------------------------------------
 * UnitAutogen - auto-generated tSQLt unit tests with real branch coverage
 * Copyright (C) 2026  Munaf Ibrahim Khatri
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License v3.0.  See LICENSE.
 * A separate commercial licence is available - licensing@unitautogen.com
 *----------------------------------------------------------------------------*/

/*=============================================================================
 * UnitAutogen CAPABILITY DEMO  -  schema [uaDemo]
 *=============================================================================
 * A self-contained showcase of what UnitAutogen automatic branch seeding can
 * reach.  Each function isolates ONE capability so the generated coverage report
 * tells a clear story.  Nothing here depends on AdventureWorks or Northwind.
 *
 * RUN IT (in SSMS / sqlcmd - NOT through a pooled MCP session, whose transaction
 * blocks the XEvent coverage capture):
 *
 *     1.  Install the framework + tSQLt into a database.
 *     2.  Run this whole script (creates schema [uaDemo] + demo objects).
 *     3.  EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter='uaDemo',
 *                                               @OutputMode='HTML';
 *     4.  Read the report.  Every seeded branch should be reached on purpose;
 *         the "honest residue" rows stay an HONEST partial (never a fake 100%).
 *
 * Tear down with the DROP block at the foot of this file.
 *===========================================================================*/

IF SCHEMA_ID('uaDemo') IS NULL EXEC('CREATE SCHEMA uaDemo');
GO

/* A tiny table so the table-valued demos have something to read.  UnitAutogen
 * FakeTable-isolates it during coverage, so the rows are illustrative only. */
DROP TABLE IF EXISTS uaDemo.Product;
GO
CREATE TABLE uaDemo.Product
( ProductID    INT          NOT NULL PRIMARY KEY,
  Name         NVARCHAR(50) NOT NULL,
  ListPrice    MONEY        NOT NULL,
  Discontinued BIT          NOT NULL );
GO
INSERT uaDemo.Product (ProductID,Name,ListPrice,Discontinued) VALUES
  (1,N'Widget',9.99,0), (2,N'Gadget',24.50,0), (3,N'Gizmo',99.00,1), (4,N'Doohickey',4.25,0);
GO

/*--------------------------------------------------------------------------
 * 1. VALUE-GATED ARMS  -  the core of branch seeding.  The seeder derives
 *    @score = 90 / 80 / 70 from the predicate literals and drives every arm.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnGrade(@score INT) RETURNS CHAR(1)
AS BEGIN
    IF @score IS NULL    RETURN 'N';
    IF @score >= 90      RETURN 'A';
    IF @score >= 80      RETURN 'B';
    IF @score >= 70      RETURN 'C';
    RETURN 'F';
END;
GO

/*--------------------------------------------------------------------------
 * 2. REVERSED NUMERIC PREDICATES  -  literal <op> @param (param on the RIGHT).
 *    The seeder mirrors the operator: 5 = @status -> @status=5, 0 < @qty -> 1.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnReversed(@status INT, @qty INT) RETURNS INT
AS BEGIN
    IF 5 = @status RETURN 1;
    IF 0 < @qty    RETURN 2;
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 3. REVERSED STRING + IN  -  'US' = @code -> @code='US' ; the IN-list first
 *    element seeds the next arm.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnRegion(@code NCHAR(2)) RETURNS VARCHAR(20)
AS BEGIN
    IF 'US' = @code           RETURN 'United States';
    IF @code IN ('GB','UK')   RETURN 'United Kingdom';
    IF @code = 'CA'           RETURN 'Canada';
    RETURN 'Other';
END;
GO

/*--------------------------------------------------------------------------
 * 4. NON-NUMERIC < > <>  -  lexical seeds for string comparands.
 *    @grade < 'M' -> '' ; @grade > 'M' -> 'M~' ; @grade <> 'X' -> 'X~'.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnGradeBand(@grade CHAR(1)) RETURNS VARCHAR(10)
AS BEGIN
    IF @grade < 'M'  RETURN 'early';
    IF @grade > 'M'  RETURN 'late';
    IF @grade <> 'X' RETURN 'mid';
    RETURN 'x-only';
END;
GO

/*--------------------------------------------------------------------------
 * 5. NEGATED SET / PATTERN / RANGE  -  NOT IN / NOT LIKE / NOT BETWEEN.
 *    Best-effort satisfying seeds: NOT IN ('US','GB') -> 'US~';
 *    NOT LIKE 'A%' -> '' ; NOT BETWEEN 100 AND 200 -> 99.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnFilter(@code NCHAR(2), @name VARCHAR(50), @amt INT) RETURNS INT
AS BEGIN
    IF @code NOT IN ('US','GB')      RETURN 1;
    IF @name NOT LIKE 'A%'           RETURN 2;
    IF @amt  NOT BETWEEN 100 AND 200 RETURN 3;
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 6. PARENTHESISED COMPARISONS  -  IF (@x > 5), and a grouped AND with two
 *    leaves.  Function-call parens (ABS(@y)) are NOT mistaken for these.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnParen(@x INT, @y INT) RETURNS INT
AS BEGIN
    IF (@x > 5)              RETURN 1;
    IF (@x >= 1 AND @y < 3)  RETURN 2;
    IF (ABS(@y) = 7)         RETURN 3;   -- call paren: honest residue (non-param value)
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 7. NON-LITERAL RHS  -  clock/env and another parameter.  An inequality is
 *    satisfiable by driving the param to a TYPE EXTREME regardless of the RHS:
 *    @asOf < GETDATE() -> @asOf = 1900-01-01 ; @lo > @hi -> @lo = INT max.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnFreshness(@asOf DATE, @lo INT, @hi INT) RETURNS INT
AS BEGIN
    IF @asOf < GETDATE() RETURN 1;
    IF @lo > @hi         RETURN 2;
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 8. ANCESTOR-CHAINING  -  a branch gated on a DIFFERENT parameter than its
 *    enclosing IF.  To reach 'GOLD' the seeder must satisfy BOTH @region='US'
 *    (the ancestor) AND @amount>=1000 (the leaf) in one driver call.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnTier(@region NCHAR(2), @amount MONEY) RETURNS VARCHAR(8)
AS BEGIN
    IF @region = 'US'
    BEGIN
        IF @amount >= 1000 RETURN 'GOLD';
        RETURN 'SILVER';
    END
    RETURN 'BRONZE';
END;
GO

/*--------------------------------------------------------------------------
 * 9. SELF-CAPPING LOOP  -  the coverage probe injects a local per-loop cap so
 *    even a parameter-bounded WHILE can never hang (capped at 1000 iterations).
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnCountdown(@start INT) RETURNS INT
AS BEGIN
    DECLARE @i INT = 0, @sum INT = 0;
    WHILE @i < @start
    BEGIN
        SET @sum = @sum + @i;
        SET @i = @i + 1;
    END;
    IF @sum > 1000000 RETURN 1;   -- accumulated value: honest residue (see #12)
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 10. INLINE TABLE-VALUED FUNCTION (kind IF)  -  RETURNS TABLE AS RETURN
 *     (SELECT ...) with a parameterised WHERE.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnPricedAtLeast(@minPrice MONEY)
RETURNS TABLE
AS RETURN
( SELECT ProductID, Name, ListPrice
  FROM uaDemo.Product
  WHERE ListPrice >= @minPrice AND Discontinued = 0 );
GO

/*--------------------------------------------------------------------------
 * 11. MULTI-STATEMENT TABLE-VALUED FUNCTION (kind TF)  -  RETURNS @t TABLE
 *     ... BEGIN ... RETURN END with its own loop.  Exercises the shadow-proc
 *     transform + the defensive teardown (no stale-synonym collisions).
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnFirstN(@n INT)
RETURNS @t TABLE (ProductID INT, Name NVARCHAR(50))
AS BEGIN
    DECLARE @i INT = 1;
    WHILE @i <= @n
    BEGIN
        INSERT @t (ProductID, Name)
        SELECT ProductID, Name FROM uaDemo.Product WHERE ProductID = @i;
        SET @i = @i + 1;
    END;
    RETURN;
END;
GO

/*--------------------------------------------------------------------------
 * 12. HONEST RESIDUE  -  a branch gated on an ACCUMULATED value (@hits is
 *     built by a query; no parameter steers it).  UnitAutogen does NOT fake
 *     this - the @hits>3 arm stays uncovered and the report shows an HONEST
 *     partial.  The visible red is the whole point: it tells the truth.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnHonest(@priceFloor MONEY) RETURNS INT
AS BEGIN
    DECLARE @hits INT;
    SELECT @hits = COUNT(*) FROM uaDemo.Product WHERE ListPrice > @priceFloor;
    IF @hits > 3 RETURN 1;
    RETURN 0;
END;
GO

/*--------------------------------------------------------------------------
 * 13. CASE-IN-RETURN  -  a SET = CASE / RETURN CASE expression is atomic to a
 *     line-based instrumenter, so it would otherwise report 0 branches.  The
 *     framework rewrites each CASE arm into an IF branch, so all six WHEN arms
 *     (plus the ELSE) are counted AND seeded (@status = 1..6).  This is the
 *     shape of the AdventureWorks ufnGetSalesOrderStatusText function.
 *------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION uaDemo.fnStatusText(@status TINYINT) RETURNS VARCHAR(15)
AS BEGIN
    DECLARE @ret VARCHAR(15);
    SET @ret =
        CASE @status
            WHEN 1 THEN 'In process'
            WHEN 2 THEN 'Approved'
            WHEN 3 THEN 'Backordered'
            WHEN 4 THEN 'Rejected'
            WHEN 5 THEN 'Shipped'
            WHEN 6 THEN 'Cancelled'
            ELSE '** Invalid **'
        END;
    RETURN @ret;
END;
GO

PRINT 'uaDemo capability demo installed.  Now run:';
PRINT '    EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter=''uaDemo'', @OutputMode=''HTML'';';
GO

/*=============================================================================
 * TEARDOWN  -  uncomment to remove the demo entirely.
 *=============================================================================
-- DECLARE @d NVARCHAR(MAX)=N'';
-- SELECT @d=@d+N'DROP FUNCTION '+QUOTENAME(s.name)+N'.'+QUOTENAME(o.name)+N';'+CHAR(10)
-- FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id
-- WHERE s.name='uaDemo' AND o.type IN ('FN','IF','TF');
-- EXEC sys.sp_executesql @d;
-- DROP TABLE IF EXISTS uaDemo.Product;
-- DROP SCHEMA uaDemo;
-- GO
 *===========================================================================*/
