@{
    ModuleVersion     = '0.9.14'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen — auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework AND the in-database (SQLCLR) predicate parser, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube. As of v0.13 the single C# predicate parser runs inside SQL Server (no PowerShell-side parser); installation registers it and requires sysadmin once plus ''clr enabled''=1.'
    PowerShellVersion = '5.1'
    RootModule        = 'UnitAutogen.psm1'

    FunctionsToExport = @(
        'Install-UnitAutogenDatabase',
        'Invoke-UnitAutogen',
        'Export-CoverageCoberturaXml',
        'Export-TestResultsJunitXml',
        'Export-CoverageHtmlReport'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # All files that must be present for the module to work
    FileList = @(
        'UnitAutogen.psd1',
        'UnitAutogen.psm1',
        'sql\Install_UnitAutogen.sql',
        'sql\Install-UnitAutogenClr.SSMS.sql'
    )

    PrivateData = @{
        PSData = @{
            ExternalModuleDependencies = @('SqlServer')
            Tags        = @('SQL', 'SQLServer', 'tSQLt', 'Coverage', 'CI-CD',
                            'Cobertura', 'JUnit', 'AzureDevOps', 'Testing',
                            'UnitTest', 'CodeCoverage', 'BranchCoverage',
                            'DatabaseTesting', 'AutomatedTesting')
            LicenseUri  = 'https://github.com/unitautogen/unitautogen-public-repo/blob/main/LICENSE'
            ProjectUri  = 'https://github.com/unitautogen/unitautogen-public-repo'
            IconUri     = 'https://raw.githubusercontent.com/unitautogen/unitautogen-public-repo/main/docs/logo.png'
            ReleaseNotes = @'
## v0.9.14 (beta) — 2026-06-04

Reporting-quality refinements (no coverage-number change - all are genuinely
not-auto-coverable cases, now reported honestly):

- A procedure whose error-handling CATCH runs its own ROLLBACK TRANSACTION now skips
  its error path with an exact reason (the ROLLBACK would unwind tSQLt's per-test
  transaction - Msg 266) instead of a generic "no analysable branches" message.
- Inline table-valued functions (RETURNS TABLE AS RETURN ...) are now reported as a
  clean NOT_TESTABLE ("a single set query - no statements or branches to instrument;
  coverage does not apply") rather than a generic instrumenter "deferred".
- Fix: a SkipTest reason containing an apostrophe (e.g. "tSQLt's") no longer errors
  the test with "Annotation has unmatched quote" - the reason text is now
  quote-escaped at both emit sites.

## v0.9.12 (beta) — 2026-06-04

Two fixes from broad-database validation on WideWorldImporters (both v0.9.11 fixes
held there - 0 failures, no doomed transactions):

- Result-row baseline now quotes JSON keys, so result columns with spaces or special
  characters in their names (e.g. "Quantity On Hand") work. Previously an unquoted
  OPENJSON path raised "JSON path is not properly formatted" (Msg 13607) and the test
  errored. Common in real-world schemas; AdventureWorks' tight names never hit it.
- Functions/procedures declared WITH EXECUTE AS OWNER (or CALLER/SELF/'user') now
  build their coverage shadow correctly. The header splitter was matching the AS
  inside "EXECUTE AS OWNER" and failing with "Incorrect syntax near 'OWNER'". A
  self-contained EXECUTE AS OWNER function now reaches 100% line / 100% branch.

## v0.9.11 (beta) — 2026-06-04

Fix: the v0.9.10 schema-bound cleanup could doom the test transaction, turning
whole groups of procedures into all-errors (0% coverage) on real databases.

- Cause: the schema-bound dependent walk in SafeFakeTable used a recursive query
  with no cycle guard. A table with a persisted computed column built on a
  WITH SCHEMABINDING function references ITSELF as schema-bound (e.g. AdventureWorks
  Sales.Customer.AccountNumber), so the walk hit the recursion limit and errored.
  tSQLt runs tests with XACT_ABORT ON, under which that error dooms the transaction,
  so every later table-fake then failed with "the current transaction cannot be
  committed".
- Fix: the cleanup now runs under SET XACT_ABORT OFF (auto-restored on exit) so it
  can never doom the test, and the walk ignores the self-edge and guards against
  cycles. Validated on a clean AdventureWorks2025: 0 errors across the testable
  procedures and functions.

Also: result-set shape characterization no longer compares IsNullable. SQL Server's
nullability inference for literal/computed result columns is unstable (flips across
recompiles/builds), which produced false-positive "shape drift" failures. Column
count, order, names, types and sizes are still asserted in full.

## Earlier releases

Full release history (v0.9.10 back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
