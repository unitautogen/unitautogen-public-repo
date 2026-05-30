@{
    ModuleVersion     = '0.9.0'
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
            LicenseUri  = 'https://github.com/unitautogen/unitautogen/blob/main/LICENSE'
            ProjectUri  = 'https://github.com/unitautogen/unitautogen'
            IconUri     = 'https://raw.githubusercontent.com/unitautogen/unitautogen/main/docs/logo.png'
            ReleaseNotes = @'
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
