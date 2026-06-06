/*=============================================================================
 * PredicateZoo - v0.10 predicate-aware seeding regression corpus
 * 01_Procedures.sql - one procedure per recognised predicate shape, plus a
 * block of UNRECOGNISED-grammar procedures the parser must mark NOT_TESTABLE.
 *
 * Every gated branch is a DATA-SHAPE predicate (subquery over a table), which
 * is exactly what v0.10 seeds.  Each proc just SELECTs a tag for the arm taken
 * so a generated test has something to assert and coverage is observable.
 *===========================================================================*/

------------------------------------------------------------------- RECOGNISED
GO
CREATE OR ALTER PROCEDURE pz.ExistsGate @CustomerId INT
AS
BEGIN
    IF EXISTS (SELECT 1 FROM pz.Orders WHERE CustomerId = @CustomerId)
        SELECT 'HAS_ORDERS' AS Arm;
    ELSE
        SELECT 'NO_ORDERS'  AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.NotExistsGate
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pz.Students WHERE Active = 1)
        SELECT 'NONE_ACTIVE' AS Arm;
    ELSE
        SELECT 'SOME_ACTIVE' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CountEqGate
AS
BEGIN
    IF (SELECT COUNT(*) FROM pz.Students WHERE Active = 1) = 2
        SELECT 'EXACTLY_TWO' AS Arm;
    ELSE
        SELECT 'NOT_TWO'     AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CountGtGate
AS
BEGIN
    IF (SELECT COUNT(*) FROM pz.Orders) > 5
        SELECT 'MANY' AS Arm;
    ELSE
        SELECT 'FEW'  AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CountInGate
AS
BEGIN
    IF (SELECT COUNT(*) FROM pz.Students) IN (1, 3, 5)
        SELECT 'ODD_SMALL' AS Arm;
    ELSE
        SELECT 'OTHER'     AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CountBetweenGate
AS
BEGIN
    IF (SELECT COUNT(*) FROM pz.Orders) BETWEEN 2 AND 4
        SELECT 'MID' AS Arm;
    ELSE
        SELECT 'OUT' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.SumGate
AS
BEGIN
    IF (SELECT SUM(Amount) FROM pz.Orders) > 1000
        SELECT 'BIG_REVENUE' AS Arm;
    ELSE
        SELECT 'SMALL'       AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.MinGate
AS
BEGIN
    IF (SELECT MIN(Score) FROM pz.Students) < 50
        SELECT 'HAS_FAIL' AS Arm;
    ELSE
        SELECT 'ALL_PASS' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.MaxGate
AS
BEGIN
    IF (SELECT MAX(Score) FROM pz.Students) >= 90
        SELECT 'HAS_TOP' AS Arm;
    ELSE
        SELECT 'NO_TOP'  AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.AvgGate
AS
BEGIN
    IF (SELECT AVG(Amount) FROM pz.Orders) > 100
        SELECT 'HIGH_AOV' AS Arm;
    ELSE
        SELECT 'LOW_AOV'  AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.ScalarCmpGate @OrderId INT
AS
BEGIN
    IF (SELECT Status FROM pz.Orders WHERE OrderId = @OrderId) = N'OPEN'
        SELECT 'IS_OPEN'  AS Arm;
    ELSE
        SELECT 'NOT_OPEN' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.ScalarNullGate @OrderId INT
AS
BEGIN
    IF (SELECT Status FROM pz.Orders WHERE OrderId = @OrderId) IS NULL
        SELECT 'MISSING' AS Arm;
    ELSE
        SELECT 'PRESENT' AS Arm;
END;
GO

------------------------------------------------- RECOGNISED (added in v0.11)
-- These were UNRECOGNISED through v0.10; v0.11 added OR/DNF WHERE seeding,
-- parameter-comparand seeding, and 2-table inner-join seeding, so all three
-- are now recognised and coverable (see 02_Expected_Shapes.md).
GO
CREATE OR ALTER PROCEDURE pz.OrCompositionGate
AS
BEGIN
    -- WHERE uses OR composition -> v0.11 DNF seeding (seed one disjunct).
    IF (SELECT COUNT(*) FROM pz.Students WHERE Active = 1 OR Score > 50) = 2
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.JoinFromGate
AS
BEGIN
    -- 2-table INNER equi-join inside the subquery -> v0.11 join seeding.
    IF EXISTS (SELECT 1 FROM pz.Orders o JOIN pz.Students s ON s.StudentId = o.CustomerId WHERE s.Active = 1)
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.ParamComparandGate @Threshold INT
AS
BEGIN
    -- comparand is a parameter -> v0.11 resolves @Threshold to the proc-param
    -- sample value the test passes (reverse seeding), then seeds the count.
    IF (SELECT COUNT(*) FROM pz.Orders) > @Threshold
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

------------------------------------------------- RECOGNISED (added in v0.12)
-- The unified reverse-seeder (design/DESIGN_v0_12_UnifiedReverseSeeder.md)
-- handles general joins, OR across atoms, the per-table merge, and local-
-- variable inlining. These gates exercise each new capability.
GO
CREATE OR ALTER PROCEDURE pz.LeftJoinGate
AS
BEGIN
    -- outer join: a matching seeded row satisfies a LEFT JOIN too.
    IF EXISTS (SELECT 1 FROM pz.Orders o LEFT JOIN pz.Students s ON s.StudentId = o.CustomerId WHERE o.Amount > 0)
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.NonEquiJoinGate
AS
BEGIN
    -- non-equi ON: seed b.y to a sample and a.x to satisfy a.x > b.y.
    IF EXISTS (SELECT 1 FROM pz.Orders o JOIN pz.Students s ON s.StudentId > o.CustomerId WHERE s.Active = 1)
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CountOverJoinGate
AS
BEGIN
    -- aggregate over a join: K coordinated joined rows.
    IF (SELECT COUNT(*) FROM pz.Orders o JOIN pz.Students s ON s.StudentId = o.CustomerId WHERE s.Active = 1) > 3
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.SumOverJoinGate
AS
BEGIN
    -- SUM over a join: one joined row whose summed column drives the value.
    IF (SELECT SUM(o.Amount) FROM pz.Orders o JOIN pz.Students s ON s.StudentId = o.CustomerId) > 100
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.SelfJoinGate
AS
BEGIN
    -- self-join: Students twice; the per-table merge collapses the two aliases.
    -- (IF condition on one line: the line-based instrumenter needs it that way.)
    IF EXISTS (SELECT 1 FROM pz.Orders o JOIN pz.Students s ON s.StudentId = o.CustomerId JOIN pz.Students s2 ON s2.StudentId = o.CustomerId WHERE s.Active = 1)
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.SharedTableGate
AS
BEGIN
    -- two atoms over the SAME table: the merge seeds 1 OPEN + filler = total.
    IF (SELECT COUNT(*) FROM pz.Orders) >= 4 AND (SELECT COUNT(*) FROM pz.Orders WHERE Status = 'OPEN') = 1
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.LocalSubqueryGate
AS
BEGIN
    -- local gated branch: @cnt's defining subquery is inlined, then seeded.
    DECLARE @cnt INT = (SELECT COUNT(*) FROM pz.Students WHERE Active = 1);
    IF @cnt > 3
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.LocalChainGate
AS
BEGIN
    -- chained locals: @f <- @n <- subquery (iterative inlining).
    DECLARE @n INT = (SELECT COUNT(*) FROM pz.Students WHERE Active = 1);
    DECLARE @f INT;
    SET @f = @n;
    IF @f >= 2
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.CondLocalGate
AS
BEGIN
    -- @x is assigned in BOTH arms of an IF/ELSE. The gate is reachable on either
    -- path, so the parser expands it to (cond AND x>3@then) OR (NOT cond AND
    -- x>3@else) and seeds the ANCESTOR condition to route to the needed value.
    DECLARE @x INT;
    IF (SELECT COUNT(*) FROM pz.Orders) > 0
        SET @x = 5;
    ELSE
        SET @x = 0;
    IF @x > 3
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

------------------------------------------------- HONEST RESIDUE (added in v0.12)
-- These prove the no-ghost guarantee: an arm that is genuinely unseedable is
-- Skipped (amber, flagged for a human), never silently green.
GO
CREATE OR ALTER PROCEDURE pz.ContradictionGate
AS
BEGIN
    -- unsatisfiable TRUE arm (5 OPEN rows but only 2 total) -> TRUE is Skipped;
    -- FALSE is seeded. Expected coverage: the reachable arm only.
    IF (SELECT COUNT(*) FROM pz.Orders) = 2 AND (SELECT COUNT(*) FROM pz.Orders WHERE Status = 'OPEN') = 5
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

CREATE OR ALTER PROCEDURE pz.LoopLocalGate
AS
BEGIN
    -- @x is accumulated in a LOOP - its value at the gate is not a static
    -- expression over seedable sources and not a clean IF/ELSE either, so it
    -- cannot be inlined deterministically -> UNRECOGNISED / Skip (honest).
    DECLARE @x INT = 0;
    DECLARE @i INT = 0;
    WHILE @i < (SELECT COUNT(*) FROM pz.Orders)
    BEGIN
        SET @x = @x + 1;
        SET @i = @i + 1;
    END;
    IF @x > 3
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

------------------------------------------------- HARD LOOP (search-based, v0.11)
-- The minimal deterministic repro of the usp_ReconcileTradedPositions G5a mechanism:
-- conditional accumulation into a NON-MONOTONE band. Only Status='SHIP' rows add to
-- @sum (inner equality literal -> candidate value); the gate is a BETWEEN band, so
-- extremes BOTH miss (0 rows undershoots, many/large overshoots). Covering IN_BAND
-- needs the numeric oracle (measure @sum) + interpolate, not probe-the-extremes.
GO
CREATE OR ALTER PROCEDURE pz.HardLoopGate @Lo DECIMAL(10,2), @Hi DECIMAL(10,2)
AS
BEGIN
    DECLARE @sum DECIMAL(10,2) = 0, @amt DECIMAL(10,2), @status NVARCHAR(20);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Amount, Status FROM pz.Orders;
    OPEN c; FETCH NEXT FROM c INTO @amt, @status;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @status = N'SHIP' SET @sum = @sum + @amt;   -- only SHIP rows accumulate
        FETCH NEXT FROM c INTO @amt, @status;
    END
    CLOSE c; DEALLOCATE c;
    IF @sum BETWEEN @Lo AND @Hi                         -- non-monotone band
        SELECT 'IN_BAND' AS Arm;
    ELSE
        SELECT 'OUT_OF_BAND' AS Arm;
END;
GO

-- Honest-boundary twin: accumulation driven by UNSEEDABLE state (GETDATE). The
-- oracle can measure @sum but no seedable axis moves it -> after budget B the engine
-- must emit NOT_TESTABLE naming the gate (proves the no-ghost guarantee at the hard end).
GO
CREATE OR ALTER PROCEDURE pz.UnseedableLoopGate
AS
BEGIN
    DECLARE @sum INT = 0, @i INT = 0;
    WHILE @i < (SELECT COUNT(*) FROM pz.Orders)
    BEGIN
        SET @sum = @sum + DATEPART(MILLISECOND, SYSDATETIME());  -- unseedable
        SET @i = @i + 1;
    END
    IF @sum > 100000
        SELECT 'A' AS Arm;
    ELSE
        SELECT 'B' AS Arm;
END;
GO

PRINT 'PredicateZoo procedures installed.';
GO
