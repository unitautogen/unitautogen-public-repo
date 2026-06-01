@{
    ModuleVersion     = '0.9.2'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen — auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube.'
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
        'sql\Install_UnitAutogen.sql'
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
## v0.9.2 (beta) — 2026-06-01

Fixes:
- TVF shadow teardown: defensively drops the synonym/_cov/_orig objects
  before rebuild, eliminating the "already an object named _covfn" failure
  on rerun when a previous coverage run was interrupted.

v11 work-in-progress (bundled SQL installer updates):
- 30_Function_Support_v1.sql — scalar function + TVF coverage groundwork.
- Patch_v11_SeedExtensions.sql + Verify_SeedExtensions.sql — seed
  extension patches for branch-condition seeding.
- Verify_ShadowTeardown.sql — verification script for the teardown fix.

Examples:
- New examples/Demo_Schema.sql for an end-to-end walkthrough.

PowerShell cmdlets are unchanged from v0.9.1.

## v0.9.1 (beta)

Bundled SQL framework updated — user-defined function support + branch coverage:
- Test generation + line/branch coverage for scalar (FN), inline (IF) and
  multi-statement (TF) functions, via a shadow-procedure transform.
- GenerateAndCoverDatabase now reports procedures AND functions in one run.
- Hang-proof coverage probe: every shadow loop is capped, so a runaway loop can
  never stall a coverage run.
- Predicate-inversion branch seeding: value-gated branches (e.g. IF @x = 5) are
  reached on purpose by deriving a satisfying parameter value from the code.
- One-line compound function bodies now instrument correctly.

PowerShell cmdlets are unchanged from v0.9.0.

## v0.9.0 (beta)

New in this release:
- Install-UnitAutogenDatabase: deploy the SQL framework from PowerShell in one command
- Invoke-UnitAutogen: full pipeline — generate tests, measure coverage, export all three output files
- Export-CoverageCoberturaXml: Cobertura XML for Azure DevOps / SonarQube
- Export-TestResultsJunitXml: JUnit XML for all major CI systems
- Export-CoverageHtmlReport: self-contained HTML report

Requirements:
- SQL Server 2017 or later
- tSQLt v1.0.7597.5637 or later installed in the target database
'@
        }
    }
}
