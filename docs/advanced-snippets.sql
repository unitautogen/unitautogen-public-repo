/*============================================================================
  advanced-snippets.sql   --   UnitAutogen
  ----------------------------------------------------------------------------
  Paste-ready snippets for the ADVANCED workflows: the generation switches,
  the "separate developer class" pattern, schema-wide generation, and the
  full coverage / CI-CD lifecycle. Run in the database where UnitAutogen
  and tSQLt are both installed.

  If you are NEW to UnitAutogen, read docs/EASY_USAGE.md first - it covers
  the four commands that handle most workflows. Come back here when you
  need more control.

  TestGen.GenerateTestsForProcedure parameters used below:
     @SchemaName       the schema of the procedure under test
     @ProcName         the procedure under test
     @ExecuteScript    1 = create the tests now; 0 = just return the script
     @CaptureRows      1 = also emit the golden-row baseline test
     @EmitNullChecks   1 = emit NULL-rejection tests        (default 1)
     @EmitScaffold     1 = emit the set-based CTE scaffold   (default 1)
============================================================================*/

/*--- 1. Generate tests - default (everything on) ----------------------------*/
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName    = 'dbo',
     @ProcName      = 'uspGetBillOfMaterials',
     @ExecuteScript = 1;
GO

/*--- 2. Generate WITHOUT the NULL-rejection tests ---------------------------
  Use when the procedure deliberately does not validate NULL inputs and you
  do not want the NULL-rejection tests in the class.                          */
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName     = 'dbo',
     @ProcName       = 'uspV9ValidationTest',
     @EmitNullChecks = 0,
     @ExecuteScript  = 1;
GO

/*--- 3. Generate WITHOUT the CTE / set-based characterization scaffold -------
  Use when you do not want the skipped "...matches a hand-built expectation"
  scaffold test for this procedure.                                           */
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName    = 'dbo',
     @ProcName      = 'uspGetBillOfMaterials',
     @EmitScaffold  = 0,
     @ExecuteScript = 1;
GO

/*--- 4. Minimal generation - both families off ------------------------------*/
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName     = 'dbo',
     @ProcName       = 'uspGetBillOfMaterials',
     @EmitNullChecks = 0,
     @EmitScaffold   = 0,
     @ExecuteScript  = 1;
GO

/*--- 5. Set-based / CTE procedure - scaffold ON + golden-row baseline --------
  Recommended for a pure SELECT / recursive-CTE procedure: the scaffold gives
  you the value-level test to complete, @CaptureRows adds the baseline.        */
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName    = 'dbo',
     @ProcName      = 'uspGetBillOfMaterials',
     @EmitScaffold  = 1,
     @CaptureRows   = 1,
     @ExecuteScript = 1;
GO

/*--- 6. Whole schema - switches pass through --------------------------------
  e.g. generate for every dbo procedure, NULL tests on, scaffold off.          */
EXEC TestGen.GenerateTestsForSchema
     @SchemaName     = 'dbo',
     @EmitNullChecks = 1,
     @EmitScaffold   = 0,
     @ExecuteScript  = 1;
GO


/*============================================================================
  THE CUSTOM DEVELOPER CLASS  -  tests the framework never deletes
  ----------------------------------------------------------------------------
  GenerateTestsForProcedure OWNS  test_<proc>  and drops/recreates it on every
  run.  It NEVER creates, drops, or edits  test_<proc>_custom  - that class is
  yours.  RunCoverage runs both classes; coverage counts your tests too.
============================================================================*/

/*--- 7. Create your protected class - ONCE per procedure --------------------
  TestGen.EnsureCustomTestClass hides the tSQLt naming convention and the fact
  that tSQLt.NewTestClass DROPS an existing class.  Safe + idempotent: if the
  class already exists it is left intact.                                      */
EXEC TestGen.EnsureCustomTestClass @SchemaName = 'dbo', @ProcName = 'uspGetBillOfMaterials';
GO
-- A procedure may have several developer classes - pass @Variant for extras.
-- Any class named test_<proc>_custom... is run by RunCoverage and deduped on
-- regeneration.  (One class holds many tests, so this is only for organising.)
EXEC TestGen.EnsureCustomTestClass
     @SchemaName = 'dbo', @ProcName = 'uspGetBillOfMaterials', @Variant = 'edge';
GO

/*--- 8. Adopt / complete a test in the protected class ----------------------
  Copy a generated test into test_<proc>_custom keeping the SAME NAME, then
  finish it.  Below: the CTE scaffold completed - a designed seed in, a
  hand-built expected result out.  Because the name matches, the next
  regeneration drops the framework's copy from test_uspGetBillOfMaterials,
  so the two never duplicate.                                                  */
CREATE OR ALTER PROCEDURE
    test_uspGetBillOfMaterials_custom.[test uspGetBillOfMaterials result set matches a hand-built expectation]
AS
BEGIN
    -- isolate
    EXEC tSQLt.FakeTable 'Production.Product';
    EXEC tSQLt.FakeTable 'Production.BillOfMaterials';

    -- DESIGNED seed: a small 2-level bill of materials
    --   assembly 100  ->  component 200 (qty 2),  component 300 (qty 3)
    --   assembly 200  ->  component 400 (qty 5)
    INSERT Production.Product (ProductID, [Name], StandardCost, ListPrice)
    VALUES (100, N'FrameKit', 0, 0), (200, N'Tube', 4, 9),
           (300, N'Bolt', 1, 2),     (400, N'Steel', 7, 12);

    INSERT Production.BillOfMaterials
           (BillOfMaterialsID, ProductAssemblyID, ComponentID, StartDate, EndDate, PerAssemblyQty, BOMLevel)
    VALUES (1, 100, 200, '2010-01-01', NULL, 2, 1),
           (2, 100, 300, '2010-01-01', NULL, 3, 1),
           (3, 200, 400, '2010-01-01', NULL, 5, 2);

    -- EXPECTED: the rows you expect for that seed (hand-computed).
    CREATE TABLE #Expected
        (ProductAssemblyID INT, ComponentID INT, ComponentDesc NVARCHAR(50),
         TotalQuantity DECIMAL(8,2), StandardCost MONEY, ListPrice MONEY,
         BOMLevel INT, RecursionLevel INT);
    INSERT #Expected VALUES
        (100, 200, N'Tube',  2, 4, 9,  1, 0),
        (100, 300, N'Bolt',  3, 1, 2,  1, 0),
        (200, 400, N'Steel', 5, 7, 12, 2, 1);

    -- ACTUAL: capture the procedure's real output for the same seed
    CREATE TABLE #Actual
        (ProductAssemblyID INT, ComponentID INT, ComponentDesc NVARCHAR(50),
         TotalQuantity DECIMAL(8,2), StandardCost MONEY, ListPrice MONEY,
         BOMLevel INT, RecursionLevel INT);
    INSERT #Actual
    EXEC dbo.uspGetBillOfMaterials @StartProductID = 100, @CheckDate = '2020-01-01';

    EXEC tSQLt.AssertEqualsTable '#Expected', '#Actual';
END;
GO

/*--- 8b. ONE-CALL generate + coverage ---------------------------------------
  TestGen.GenerateAndRunCoverage = GenerateTestsForProcedure (always executes)
  followed by RunCoverage.  Same generation switches; @OutputMode picks the
  coverage report format ('TEXT' or 'HTML').                                   */
EXEC TestGen.GenerateAndRunCoverage
     @SchemaName     = 'dbo',
     @ProcName       = 'uspGetBillOfMaterials',
     @EmitScaffold   = 1,
     @CaptureRows    = 1,
     @OutputMode     = 'TEXT';
GO

/*--- 9. Regenerate freely, then measure coverage ----------------------------
  Regeneration rebuilds test_uspGetBillOfMaterials and (because the test above
  now exists in _custom) drops its own copy of that test.  RunCoverage then
  exercises BOTH classes.                                                      */
EXEC TestGen.GenerateTestsForProcedure
     @SchemaName = 'dbo', @ProcName = 'uspGetBillOfMaterials', @ExecuteScript = 1;
GO
EXEC TestGen.RunCoverage
     @SchemaName = 'dbo', @ProcName = 'uspGetBillOfMaterials', @OutputMode = 'TEXT';
GO

/*--- 10. DATABASE-WIDE coverage report (CI/CD) ------------------------------
  Generate + run + measure coverage for every user procedure, and emit one
  HTML report: per-procedure line/branch coverage + a TOTAL, plus aggregate
  test outcomes (passed/failed/errored/skipped) with percentages.  Each row
  is also kept in TestGen.CoverageResult (keyed by BatchId) for trending.     */
EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';   -- all user schemas
GO
-- one schema only, TEXT report:
EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = 'dbo', @OutputMode = 'TEXT';
GO

/*--- 11. RunCoverage returns the test outcomes (single instrumented run) ----
  RunCoverage measures coverage AND hands back pass / failed / errored /
  skipped counts via OUTPUT parameters - one run does both, so a CI script
  need not run the tests again just to count them.  The parameters are
  optional, so existing RunCoverage calls are unaffected.                     */
DECLARE @run INT, @pass INT, @fail INT, @err INT, @skip INT;
EXEC TestGen.RunCoverage
     @SchemaName   = 'dbo',
     @ProcName     = 'uspGetBillOfMaterials',
     @OutputMode   = 'TEXT',
     @TestsRun     = @run  OUTPUT,
     @TestsPassed  = @pass OUTPUT,
     @TestsFailed  = @fail OUTPUT,
     @TestsErrored = @err  OUTPUT,
     @TestsSkipped = @skip OUTPUT;
SELECT @run AS TestsRun, @pass AS Passed, @fail AS Failed,
       @err AS Errored, @skip AS Skipped;
GO

/*--- 12. TEAR DOWN - return the database to just its business procedures ----
  DropGeneratedTestClasses removes the classes the framework generated (read
  from TestGenLog.GenerationRun, so ONLY framework test_<proc> classes).  Your
  test_<proc>_custom... classes are kept unless @IncludeCustom = 1.            */
EXEC TestGen.DropGeneratedTestClasses @WhatIf = 1;          -- preview: list, drop nothing
GO
EXEC TestGen.DropGeneratedTestClasses;                      -- drop the generated classes
GO
-- one schema only / full wipe incl. developer-owned classes:
EXEC TestGen.DropGeneratedTestClasses @SchemaFilter = 'dbo';
EXEC TestGen.DropGeneratedTestClasses @IncludeCustom = 1;
GO
