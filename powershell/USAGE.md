# UnitAutogen PowerShell Module — Usage Guide

The `UnitAutogen` PowerShell module connects to your SQL Server database,
runs test generation and coverage measurement, and exports three output files
ready for CI/CD pipeline consumption.

---

## Prerequisites

- PowerShell 5.1 or later
- SQL Server with UnitAutogen framework installed (`Install_UnitAutogen.sql`)
- The `SqlServer` PowerShell module — **auto-installed on first use**

---

## Import the Module

```powershell
Import-Module './powershell/UnitAutogen.psm1'
```

The first import installs the `SqlServer` module from PSGallery if it is not
already present. Subsequent imports skip straight to loading.

---

## Functions

| Function | Purpose |
|---|---|
| `Invoke-UnitAutogen` | Full pipeline: generate tests → measure coverage → export all 3 files |
| `Export-CoverageCoberturaXml` | Re-export Cobertura XML from last run (no re-run) |
| `Export-TestResultsJunitXml` | Re-export JUnit XML from last run (no re-run) |
| `Export-CoverageHtmlReport` | Re-export HTML report from last run (no re-run) |

---

## Output Files

| File | Format | Consumed by |
|---|---|---|
| `coverage.xml` | Cobertura XML | Azure DevOps "Publish Code Coverage Results", SonarQube, Jenkins Cobertura Plugin, GitLab CI |
| `test-results.xml` | JUnit XML | Azure DevOps "Publish Test Results", GitHub Actions, Jenkins JUnit Plugin, SonarQube |
| `coverage-report.html` | HTML | Browser — human-readable summary with colour-coded coverage percentages |

---

## Examples

### 1. Full pipeline run — Windows authentication

The simplest case. The identity running PowerShell is passed to SQL Server
transparently — no credentials needed.

```powershell
Import-Module './powershell/UnitAutogen.psm1'

Invoke-UnitAutogen `
    -ServerInstance 'localhost\SQLEXPRESS' `
    -Database       'Northwind' `
    -OutputPath     'C:\artifacts'
```

Output:
```
C:\artifacts\coverage.xml
C:\artifacts\test-results.xml
C:\artifacts\coverage-report.html
```

---

### 2. Full pipeline run — SQL Server authentication

Supply a `PSCredential`. Source credentials from environment variables or a
secret store — **never hardcode passwords**.

```powershell
Import-Module './powershell/UnitAutogen.psm1'

$cred = New-Object PSCredential(
    $env:SQL_USER,
    (ConvertTo-SecureString $env:SQL_PASS -AsPlainText -Force)
)

Invoke-UnitAutogen `
    -ServerInstance 'sql01' `
    -Database       'Northwind' `
    -Credential     $cred `
    -OutputPath     'C:\artifacts'
```

---

### 3. Filter to one schema

```powershell
Invoke-UnitAutogen `
    -ServerInstance 'localhost\SQLEXPRESS' `
    -Database       'AdventureWorks' `
    -SchemaFilter   'HumanResources' `
    -OutputPath     'C:\artifacts'
```

---

### 4. Custom output filenames

```powershell
Invoke-UnitAutogen `
    -ServerInstance      'localhost\SQLEXPRESS' `
    -Database            'Northwind' `
    -OutputPath          'C:\artifacts' `
    -CoverageFileName    'cobertura.xml' `
    -TestResultsFileName 'junit.xml' `
    -HtmlReportFileName  'report.html'
```

---

### 5. Re-export files without re-running tests

Useful when you want to regenerate output files from the last run without
paying the cost of re-running `GenerateAndCoverDatabase`.

```powershell
Import-Module './powershell/UnitAutogen.psm1'

# Re-export all three independently
Export-CoverageCoberturaXml `
    -ServerInstance 'localhost\SQLEXPRESS' `
    -Database       'Northwind' `
    -OutputFile     'C:\artifacts\coverage.xml'

Export-TestResultsJunitXml `
    -ServerInstance 'localhost\SQLEXPRESS' `
    -Database       'Northwind' `
    -OutputFile     'C:\artifacts\test-results.xml'

Export-CoverageHtmlReport `
    -ServerInstance 'localhost\SQLEXPRESS' `
    -Database       'Northwind' `
    -OutputFile     'C:\artifacts\coverage-report.html'
```

---

### 6. Increase timeout for large databases

`GenerateAndCoverDatabase` can run for several minutes on large databases.
The default timeout is 3600 seconds (1 hour). Increase if needed.

```powershell
Invoke-UnitAutogen `
    -ServerInstance    'sql01' `
    -Database          'LargeDatabase' `
    -OutputPath        'C:\artifacts' `
    -GenerationTimeout 7200
```

---

## CI/CD Pipeline Samples

Ready-to-use pipeline files are in the `ci/` folder of this repository:

| File | Platform |
|---|---|
| [`ci/azure-pipelines.yml`](../ci/azure-pipelines.yml) | Azure DevOps |
| [`ci/github-actions.yml`](../ci/github-actions.yml) | GitHub Actions |

Each file is fully commented and covers SQL auth, secret variable wiring,
coverage publishing, and test result publishing. Read the setup notes at the
top of each file before use.

---

## Authentication Notes

Windows authentication (no `-Credential` parameter) is recommended for
on-premises environments where the CI/CD agent runs as a domain service
account with access to SQL Server.

SQL Server authentication is needed for:
- Azure SQL Database
- Docker-hosted SQL Server
- Cross-domain environments

In all cases, source credentials from the pipeline's secret store
(`$(SQL_PASS)` in Azure DevOps, `${{ secrets.SQL_PASS }}` in GitHub Actions)
and pass them as `PSCredential`. Never hardcode passwords in scripts or YAML.
