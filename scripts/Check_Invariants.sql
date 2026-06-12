/*============================================================================
  Check_Invariants.sql  -  UnitAutogen generated-test invariant guard
  ----------------------------------------------------------------------------
  Enforces INV-1 (Arrange - Act - Assert) from BUGS.md.

  Scans every generated tSQLt test in the CURRENT database and FAILS
  (RAISERROR severity 16, so a CI step returns non-zero) if any test makes an
  assertion BEFORE it executes the procedure under test - the Arrange-Assert-Act
  ordering that was BUG-001. Run it after a generation sweep, e.g. as a CI gate:

      sqlcmd -S server -d YourDb -b -i scripts\Check_Invariants.sql

  How it decides:
    * Act marker    = the first 'EXEC [' in the body. The procedure under test is
                      always called  EXEC [schema].[proc] ; the tSQLt / TestGen
                      helpers are EXEC tSQLt.* / EXEC TestGen.* and never 'EXEC ['.
    * Assert marker = the first 'tSQLt.Assert' or 'TestGen.Assert'.
    * A behavioural assertion positioned before the Act => INV-1 violation.
      (tSQLt.ExpectException is registered before the Act by design and is NOT an
       assertion, so it is correctly ignored.)
============================================================================*/
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#uag_inv1') IS NOT NULL DROP TABLE #uag_inv1;

;WITH tests AS (
    SELECT  s.name AS TestClass, o.name AS TestCase, m.definition AS Body
    FROM    sys.procedures  o
    JOIN    sys.schemas     s ON s.schema_id = o.schema_id
    JOIN    sys.sql_modules  m ON m.object_id = o.object_id
    WHERE   EXISTS (SELECT 1 FROM sys.extended_properties ep
                    WHERE ep.class = 3 AND ep.major_id = o.schema_id
                      AND ep.name  = 'tSQLt.TestClass')
),
marked AS (
    SELECT  TestClass, TestCase,
            NULLIF(CHARINDEX('EXEC [', Body), 0) AS ActPos,
            (SELECT MIN(p) FROM (VALUES
                (NULLIF(CHARINDEX('tSQLt.Assert',   Body), 0)),
                (NULLIF(CHARINDEX('TestGen.Assert', Body), 0))
             ) v(p)) AS AssertPos
    FROM    tests
)
SELECT TestClass, TestCase
INTO   #uag_inv1
FROM   marked
WHERE  AssertPos IS NOT NULL AND ActPos IS NOT NULL AND AssertPos < ActPos;

DECLARE @viol INT = (SELECT COUNT(*) FROM #uag_inv1);
IF @viol > 0
BEGIN
    DECLARE @msg NVARCHAR(MAX) = N'';
    SELECT @msg = @msg + CHAR(10) + N'   ' + TestClass + N'.' + TestCase
    FROM   #uag_inv1 ORDER BY TestClass, TestCase;
    RAISERROR(N'INV-1 (Arrange-Act-Assert) VIOLATION: %d generated test(s) assert before executing the proc under test (see BUGS.md / BUG-001):%s',
              16, 1, @viol, @msg);
END
ELSE
    PRINT 'INV-1 OK: every generated test executes the proc under test before any assertion.';
GO
