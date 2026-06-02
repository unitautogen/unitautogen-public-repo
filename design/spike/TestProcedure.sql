-- =========================================================================
-- Test procedure for the v0.10 ScriptDom feasibility spike.
-- Contains one branch per predicate shape from DESIGN_v0_10_PredicateSeeding
-- section 3.2.  The spike script (Run-Spike.ps1) parses this body, walks the
-- AST, and emits one row per recognised branch.  Pass criterion: 12 of 16
-- shapes parsed and classified correctly.
-- =========================================================================
CREATE OR ALTER PROCEDURE TestGen.SpikeProcedure
    @p          INT,
    @pName      NVARCHAR(50),
    @pAmount    DECIMAL(18,2)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @y INT = 0;

    -- 1. EXISTS
    IF EXISTS (SELECT 1 FROM dbo.Students WHERE Active = @p)
        SET @y = 1;

    -- 2. NOT EXISTS
    IF NOT EXISTS (SELECT 1 FROM dbo.Students WHERE Active = @p)
        SET @y = 2;

    -- 3. COUNT(*) = N
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) = 2
        SET @y = 3;

    -- 4. COUNT(*) > N
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) > 3
        SET @y = 4;

    -- 5. COUNT(*) <= N
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) <= 5
        SET @y = 5;

    -- 6. COUNT(*) <> N
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) <> 0
        SET @y = 6;

    -- 7. COUNT(*) IN (...)
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) IN (1, 2, 3)
        SET @y = 7;

    -- 8. COUNT(*) BETWEEN A AND B
    IF (SELECT COUNT(*) FROM dbo.Students WHERE GradeId = 1) BETWEEN 1 AND 5
        SET @y = 8;

    -- 9. SUM(col) op N
    IF (SELECT SUM(Amount) FROM dbo.Payments WHERE StudentId = @p) > 1000
        SET @y = 9;

    -- 10. MIN(col) op N
    IF (SELECT MIN(Score) FROM dbo.Tests WHERE StudentId = @p) > 50
        SET @y = 10;

    -- 11. MAX(col) op N
    IF (SELECT MAX(Score) FROM dbo.Tests WHERE StudentId = @p) >= 100
        SET @y = 11;

    -- 12. AVG(col) op N
    IF (SELECT AVG(Rate) FROM dbo.Payments WHERE StudentId = @p) > 5.0
        SET @y = 12;

    -- 13. Scalar = v
    IF (SELECT TOP 1 Name FROM dbo.Students WHERE Id = @p) = @pName
        SET @y = 13;

    -- 14. Scalar IS NULL
    IF (SELECT TOP 1 Name FROM dbo.Students WHERE Id = @p) IS NULL
        SET @y = 14;

    -- 15. Multi-join inside subquery
    IF EXISTS (SELECT 1
               FROM dbo.Students s
                    INNER JOIN dbo.Enrollments e ON s.Id = e.StudentId
               WHERE s.Active = 1 AND e.Term = @p)
        SET @y = 15;

    -- 16. CASE arm (search-form) -- two arms, two predicates
    SET @y = CASE
                 WHEN EXISTS (SELECT 1 FROM dbo.Students WHERE Active = @p) THEN 1
                 WHEN (SELECT COUNT(*) FROM dbo.Students) > 0 THEN 2
                 ELSE 0
             END;

    -- Sanity: WHILE with a count predicate
    WHILE (SELECT COUNT(*) FROM dbo.Queue WHERE Status = 'PENDING') > 0
    BEGIN
        SET @y = @y + 1;
        BREAK; -- spike only, never loop
    END;

    SELECT @y AS Result;
END;
GO
