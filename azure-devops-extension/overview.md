# UnitAutogen — tSQLt Test Generation & Coverage

Auto-generate **tSQLt unit tests with real branch coverage** for your SQL Server
stored procedures — as a step in your Azure Pipeline. UnitAutogen parses each
procedure, generates seeded tests that reach every `IF` / `CASE` / `EXISTS` branch,
runs them, and emits the formats your pipeline already understands.

## What the task does

In one step it runs `Invoke-UnitAutogen` against your database and produces, in the
output folder:

- `coverage.xml` — **Cobertura** (line + branch coverage)
- `test-results.xml` — **JUnit** (test outcomes)
- `coverage-report.html` — a human-readable report

Then your existing **Publish Code Coverage Results** and **Publish Test Results**
tasks surface them — no custom plumbing.

## Example pipeline

```yaml
# Windows agent that can reach your SQL Server; tSQLt installed in the target DB.
- task: UnitAutogenCoverage@0
  inputs:
    serverInstance: 'sql01'
    database: 'YourDatabase'
    schemaFilter: 'dbo'          # optional; blank = all user schemas
    installFramework: true       # first run only; needs sysadmin + 'clr enabled'=1
    outputPath: '$(Build.ArtifactStagingDirectory)'
    # SQL auth (optional) — map a SECRET variable to sqlPassword:
    # sqlAuth: true
    # sqlUser: '$(SqlUser)'
    # sqlPassword: '$(SqlPassword)'

- task: PublishTestResults@2
  inputs:
    testResultsFormat: 'JUnit'
    testResultsFiles: '$(Build.ArtifactStagingDirectory)/test-results.xml'

- task: PublishCodeCoverageResults@2
  inputs:
    summaryFileLocation: '$(Build.ArtifactStagingDirectory)/coverage.xml'
```

## Requirements

- A **Windows** pipeline agent that can reach your SQL Server instance.
- **tSQLt** installed in the target database.
- `clr enabled = 1` and (for the first `installFramework` run) sysadmin — the
  in-database predicate parser is registered via `sp_add_trusted_assembly`
  (no TRUSTWORTHY required).

## Notes

- The task installs the `UnitAutogen` PowerShell module from the PowerShell Gallery
  automatically if it isn't already present on the agent.
- UnitAutogen is open source (AGPL-3.0; a commercial licence is available). Beta —
  feedback welcome.

Project & docs: https://github.com/unitautogen/unitautogen-public-repo
