@{
    ModuleVersion     = '0.10.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen — auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework AND the in-database (SQLCLR) predicate parser, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube. The single C# predicate parser runs inside SQL Server (no PowerShell-side parser); installation registers it and requires sysadmin once plus ''clr enabled''=1.'
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
## v0.10.0 (beta) — 2026-06-05

Major capability + honesty release. New capabilities:

- DML EFFECT ASSERTIONS. A modifying procedure's per-table write effect is now asserted
  with EXACT row counts, measured at generation time by running the procedure under its
  own reverse-predicate seed (rolled back). Covers INSERT (VALUES and SELECT), UPDATE and
  DELETE; when the seed drives no write, the test is skipped and names the untouched table.
- DELETE and INSERT...SELECT branch coverage. The snapshot-and-replay branch assertions
  now handle a single-target DELETE and INSERT...SELECT, not just UPDATE / INSERT...VALUES.
- TABLE-VALUED PARAMETERS. A procedure with a TVP is now auto-tested: the generator builds
  and seeds a table variable of the type and passes it (such procedures were previously
  NOT_TESTABLE). The coverage instrumenter emits table parameters schema-qualified + READONLY.
- ROW-LEVEL SECURITY. SafeFakeTable now drops a SECURITY POLICY (and its predicate-function
  chain) before faking, so RLS-protected tables can be faked instead of dooming the test
  with "participates in enforced dependencies".

Honesty fixes (no false failures — every non-pass is a pass, a labelled skip, or a clear
NOT_TESTABLE):

- Error-expectation tests are no longer over-generated. A CATCH-block re-throw is no longer
  mistaken for input validation, and a parenthesis-less THROW (THROW n,'msg',state;) is now
  detected — so "must reject" / "raises error" tests fire only for genuine validation guards.
- When the generated happy / boundary / NULL inputs cannot satisfy a procedure's own
  validation, the affected tests are SkipTest-annotated with a clear reason instead of
  failing by construction.
- A FOR JSON / FOR XML result set no longer errors the row-baseline test (it cannot be
  captured via INSERT...EXEC); that single test is skipped for such procedures.

## v0.9.14 (beta) — 2026-06-04

- CATCH-with-ROLLBACK error paths skip with an exact reason; inline TVFs report a clean
  NOT_TESTABLE; SkipTest reasons containing apostrophes are quote-escaped.

## v0.9.12 (beta) — 2026-06-04

- Result-row baseline quotes JSON keys (result columns with spaces now work); functions
  declared WITH EXECUTE AS OWNER build their coverage shadow correctly.

## Earlier releases

Full release history (v0.9.11 back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
