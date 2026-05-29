@{
    ModuleVersion     = '0.9.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell wrapper for UnitAutogen CI/CD integration. Exports Cobertura XML, JUnit XML and HTML coverage reports from a tSQLt auto-gen run for Azure DevOps, GitHub Actions, Jenkins, GitLab CI and SonarQube.'
    PowerShellVersion = '5.1'
    RootModule        = 'UnitAutogen.psm1'

    FunctionsToExport = @(
        'Invoke-UnitAutogen',
        'Export-CoverageCoberturaXml',
        'Export-TestResultsJunitXml',
        'Export-CoverageHtmlReport'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags        = @('SQL', 'SQLServer', 'tSQLt', 'Coverage', 'CI-CD',
                            'Cobertura', 'JUnit', 'AzureDevOps', 'Testing', 'UnitTest')
            LicenseUri  = 'https://github.com/unitautogen/unitautogen-public-repo/blob/main/LICENSE.md'
            ProjectUri  = 'https://github.com/unitautogen/unitautogen-public-repo'
            ReleaseNotes = 'v0.9.0-beta: Initial CI/CD output — Cobertura XML, JUnit XML, HTML report.'
        }
    }
}
