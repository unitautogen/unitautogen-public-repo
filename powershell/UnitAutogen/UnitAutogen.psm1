#Requires -Version 5.1

# Auto-install SqlServer module if not present
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "[UnitAutogen] SqlServer module not found. Installing from PSGallery..."
    Install-Module SqlServer -Scope CurrentUser -AllowClobber -Force
    Write-Host "[UnitAutogen] SqlServer module installed."
}
Import-Module SqlServer -ErrorAction Stop

<#
.SYNOPSIS
    UnitAutogen CI/CD PowerShell module.

.DESCRIPTION
    Installs the UnitAutogen SQL framework and exports Cobertura XML (coverage)
    and JUnit XML (test results) for Azure DevOps, GitHub Actions, Jenkins,
    GitLab CI, and SonarQube.

.NOTES
    Prerequisites
    -------------
    SqlServer PowerShell module (includes Invoke-Sqlcmd):
        Install-Module SqlServer -Scope CurrentUser -AllowClobber

    Authentication
    --------------
    Windows authentication is used by default — the identity running the
    CI/CD agent is passed transparently.  No credential parameter is needed
    in most on-premises environments.

    For SQL Server authentication (Azure SQL, Docker, cross-domain agents),
    supply a PSCredential.  NEVER pass a plain-text password.  Source
    credentials from the pipeline secret store:

        # Azure DevOps — map secret variables to env vars, then:
        $cred = New-Object PSCredential(
            $env:SQL_USER,
            (ConvertTo-SecureString $env:SQL_PASS -AsPlainText -Force)
        )
        Install-UnitAutogenDatabase -ServerInstance $srv -Database $db -Credential $cred

    Note: Invoke-Sqlcmd (SqlServer module) requires the password as a plain
    string internally.  This module extracts it from the SecureString only at
    the point of the SQL call and holds it no longer than the duration of that
    call.  It is never written to disk, logged, or returned.

    Exported functions
    ------------------
    Install-UnitAutogenDatabase Deploy the UnitAutogen SQL framework to a database.
    Invoke-UnitAutogen          Full pipeline: generate + cover + export output files.
    Export-CoverageCoberturaXml Export Cobertura XML from the last run (no re-run).
    Export-TestResultsJunitXml  Export JUnit XML from the last run (no re-run).
    Export-CoverageHtmlReport   Export HTML coverage report from the last run (no re-run).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Private helpers
# =============================================================================

function script:Build-ConnParams {
    <#
    Builds the parameter hashtable for Invoke-Sqlcmd.
    Password is extracted from the SecureString only here, momentarily.
    #>
    param(
        [string]       $ServerInstance,
        [string]       $Database,
        [PSCredential] $Credential    = $null,
        [int]          $QueryTimeout  = 300
    )

    $p = @{
        ServerInstance         = $ServerInstance
        Database               = $Database
        QueryTimeout           = $QueryTimeout
        OutputSqlErrors        = $true
        TrustServerCertificate = $true
        ErrorAction            = 'Stop'
    }

    if ($Credential) {
        $p['Username'] = $Credential.UserName
        # GetNetworkCredential().Password momentarily decrypts — unavoidable
        # with Invoke-Sqlcmd's string-based -Password parameter.
        $p['Password'] = $Credential.GetNetworkCredential().Password
    }

    return $p
}

function script:Save-XmlFile {
    param([string] $Path, [string] $Content)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fullPath, $Content, $utf8NoBom)
    $bytes = (Get-Item -LiteralPath $fullPath).Length
    return $fullPath, $bytes
}

function script:Build-SchemaArg {
    param([string] $SchemaFilter)
    if ($SchemaFilter) { return "@SchemaFilter = N'$SchemaFilter'" }
    return ''
}

# =============================================================================
# Public functions
# =============================================================================

function Install-UnitAutogenDatabase {
    <#
    .SYNOPSIS
        Deploys the UnitAutogen SQL framework to a SQL Server database.

    .DESCRIPTION
        Runs the bundled Install_UnitAutogen.sql installer against the target
        database.  The installer is idempotent — safe to run multiple times and
        safe to re-run after an upgrade.

        After installation, the database will have the TestGen schema with all
        UnitAutogen stored procedures.  tSQLt must already be installed in the
        target database before calling this function.

        Typical first-time setup:
            1. Install tSQLt into the database (see https://tsqlt.org).
            2. Call Install-UnitAutogenDatabase.
            3. Call Invoke-UnitAutogen to generate tests and measure coverage.

    .PARAMETER ServerInstance
        SQL Server instance name.
        Examples: 'localhost', '.\SQLEXPRESS', 'sql01\PROD', 'sql01,1433'

    .PARAMETER Database
        Target database name.

    .PARAMETER InstallTimeout
        Query timeout in seconds for the install script.
        Default: 600 (10 minutes).  Increase for slow servers.

    .PARAMETER Credential
        PSCredential for SQL Server authentication.
        Omit to use Windows authentication (recommended).

    .EXAMPLE
        # Windows auth
        Install-UnitAutogenDatabase -ServerInstance 'localhost' -Database 'Northwind'

    .EXAMPLE
        # SQL auth
        $cred = New-Object PSCredential(
            $env:SQL_USER,
            (ConvertTo-SecureString $env:SQL_PASS -AsPlainText -Force)
        )
        Install-UnitAutogenDatabase `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -Credential     $cred

    .EXAMPLE
        # CI/CD pipeline (Azure DevOps / GitHub Actions)
        Install-UnitAutogenDatabase `
            -ServerInstance $env:SQL_SERVER `
            -Database       $env:SQL_DATABASE `
            -Credential     $cred
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [int]                  $InstallTimeout = 600,
        [PSCredential]         $Credential     = $null
    )

    $sqlFile = Join-Path $PSScriptRoot 'sql\Install_UnitAutogen.sql'

    if (-not (Test-Path -LiteralPath $sqlFile)) {
        throw "[UnitAutogen] Cannot locate installer: $sqlFile"
    }

    $auth = if ($Credential) { "SQL auth ($($Credential.UserName))" } else { 'Windows auth' }
    Write-Host "[UnitAutogen] Installing UnitAutogen framework"
    Write-Host "[UnitAutogen] Server  : $ServerInstance"
    Write-Host "[UnitAutogen] Database: $Database"
    Write-Host "[UnitAutogen] Auth    : $auth"
    Write-Host "[UnitAutogen] Script  : $sqlFile"
    Write-Host ''

    $connParams = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                      -Credential $Credential -QueryTimeout $InstallTimeout

    Invoke-Sqlcmd @connParams -InputFile $sqlFile -Verbose 4>&1 |
        ForEach-Object { Write-Host $_ }

    Write-Host ''
    Write-Host "[UnitAutogen] Framework installed successfully."

    # Register the in-database C# (SQLCLR) predicate parser. This is the SINGLE
    # parser used everywhere (the old PowerShell parser is retired). It populates
    # TestGen.PredicateInbox so data-shape branches (EXISTS / COUNT / scalar-subquery
    # gates) get real seeded tests. Idempotent. Needs CONTROL SERVER (sysadmin) once
    # + 'clr enabled' = 1; it trusts the assemblies by SHA-512 hash via
    # sys.sp_add_trusted_assembly (no TRUSTWORTHY required).
    $clrFile = Join-Path $PSScriptRoot 'sql\Install-UnitAutogenClr.SSMS.sql'
    if (Test-Path -LiteralPath $clrFile) {
        Write-Host ''
        Write-Host "[UnitAutogen] Registering the in-database predicate parser (SQLCLR)..."
        try {
            Invoke-Sqlcmd @connParams -InputFile $clrFile -Verbose 4>&1 |
                ForEach-Object { Write-Host $_ }
            Write-Host "[UnitAutogen] Predicate parser registered (EXEC TestGen.ParseDatabasePredicates)."
        }
        catch {
            Write-Warning "[UnitAutogen] CLR parser registration failed: $_"
            Write-Warning "[UnitAutogen] This step needs sysadmin (CONTROL SERVER) and 'clr enabled' = 1."
            Write-Warning "[UnitAutogen] Register it later by running clr/Install-UnitAutogenClr.SSMS.sql in SSMS."
        }
    }
    else {
        Write-Warning "[UnitAutogen] CLR parser installer not bundled beside the module ($clrFile)."
        Write-Warning "[UnitAutogen] Register it from clr/Install-UnitAutogenClr.SSMS.sql, or data-shape seeding is disabled."
    }

    Write-Host ''
    Write-Host "[UnitAutogen] Next step: run Invoke-UnitAutogen to generate tests and measure coverage."
}


function Invoke-UnitAutogen {
    <#
    .SYNOPSIS
        Full CI/CD pipeline run: generates tests, measures coverage, and
        exports Cobertura XML, JUnit XML, and HTML coverage report.

    .DESCRIPTION
        1. Runs TestGen.GenerateAndCoverDatabase on the target database.
        2. Calls Export-CoverageCoberturaXml  -> writes CoverageFileName.
        3. Calls Export-TestResultsJunitXml   -> writes TestResultsFileName.
        4. Calls Export-CoverageHtmlReport    -> writes HtmlReportFileName.

        All three output files are written to OutputPath and are ready to be
        consumed by the pipeline's "Publish Code Coverage Results" and
        "Publish Test Results" tasks.

    .PARAMETER ServerInstance
        SQL Server instance name.
        Examples: 'localhost', '.\SQLEXPRESS', 'sql01\PROD', 'sql01,1433'

    .PARAMETER Database
        Target database name.

    .PARAMETER OutputPath
        Directory to write output files. Created if it does not exist.
        In Azure DevOps use $env:BUILD_ARTIFACTSTAGINGDIRECTORY.
        Default: current directory.

    .PARAMETER SchemaFilter
        Restrict generation and reporting to one schema (e.g. 'dbo').
        Default: all user schemas.

    .PARAMETER CoverageFileName
        Filename for the Cobertura XML file. Default: coverage.xml

    .PARAMETER TestResultsFileName
        Filename for the JUnit XML file. Default: test-results.xml

    .PARAMETER HtmlReportFileName
        Filename for the HTML report file. Default: coverage-report.html

    .PARAMETER GenerationTimeout
        Query timeout in seconds for GenerateAndCoverDatabase.
        Default: 3600 (1 hour). Increase for very large databases.

    .PARAMETER Credential
        PSCredential for SQL Server authentication.
        Omit to use Windows authentication (recommended).

    .EXAMPLE
        # Windows auth — typical on-prem Azure DevOps / Jenkins agent
        Invoke-UnitAutogen `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -OutputPath     $env:BUILD_ARTIFACTSTAGINGDIRECTORY

    .EXAMPLE
        # SQL auth — credentials from pipeline secret variables
        $cred = New-Object PSCredential(
            $env:SQL_USER,
            (ConvertTo-SecureString $env:SQL_PASS -AsPlainText -Force)
        )
        Invoke-UnitAutogen `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -Credential     $cred `
            -OutputPath     $env:BUILD_ARTIFACTSTAGINGDIRECTORY

    .EXAMPLE
        # Filter to one schema
        Invoke-UnitAutogen `
            -ServerInstance 'sql01' `
            -Database       'AdventureWorks' `
            -SchemaFilter   'HumanResources' `
            -OutputPath     './artifacts'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [string]               $OutputPath          = '.',
        [string]               $SchemaFilter        = $null,
        [string]               $CoverageFileName    = 'coverage.xml',
        [string]               $TestResultsFileName = 'test-results.xml',
        [string]               $HtmlReportFileName  = 'coverage-report.html',
        [int]                  $GenerationTimeout   = 3600,
        [PSCredential]         $Credential          = $null,
        [switch]               $SkipPredicateParse
    )

    # Ensure output directory exists
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $auth = if ($Credential) { "SQL auth ($($Credential.UserName))" } else { 'Windows auth' }
    Write-Host "[UnitAutogen] Server   : $ServerInstance"
    Write-Host "[UnitAutogen] Database : $Database"
    Write-Host "[UnitAutogen] Auth     : $auth"
    Write-Host "[UnitAutogen] Output   : $(Resolve-Path $OutputPath)"
    Write-Host ''

    # STEP 0: populate TestGen.PredicateInbox via the in-database C# (SQLCLR)
    # predicate parser - the single parser used everywhere. It is registered by
    # Install-UnitAutogenDatabase; here we just invoke it from T-SQL. One call
    # parses the whole target scope (a schema, or '*' = every user schema).
    if (-not $SkipPredicateParse) {
        $scopeArg = if ($SchemaFilter) { "N'$SchemaFilter'" } else { "N'*'" }
        Write-Host "[UnitAutogen] Parsing predicates (in-DB SQLCLR parser) over scope $scopeArg ..."
        $connParse = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                         -Credential $Credential -QueryTimeout $GenerationTimeout
        try {
            Invoke-Sqlcmd @connParse -Query "EXEC TestGen.ParseDatabasePredicates @SchemaFilter = $scopeArg;" -Verbose 4>&1 |
                ForEach-Object { Write-Host "  $_" }
        } catch {
            Write-Warning "[UnitAutogen] Predicate parse failed: $_"
            Write-Warning "[UnitAutogen] Is the CLR parser installed? Run Install-UnitAutogenDatabase (it registers TestGen.ParseDatabasePredicates)."
            Write-Warning "[UnitAutogen] Continuing - data-shape branches will fall back to NOT_TESTABLE / string-gen."
        }
        Write-Host ''
    }

    Write-Host "[UnitAutogen] Running GenerateAndCoverDatabase..."

    $connGen      = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                        -Credential $Credential -QueryTimeout $GenerationTimeout
    $schemaClause = if ($SchemaFilter) { "@SchemaFilter = N'$SchemaFilter', " } else { '' }
    $genQuery     = "EXEC TestGen.GenerateAndCoverDatabase ${schemaClause}@OutputMode = 'TEXT';"

    try {
        Invoke-Sqlcmd @connGen -Query $genQuery -Verbose 4>&1 |
            ForEach-Object { Write-Host $_ }
    }
    catch {
        Write-Warning "[UnitAutogen] GenerateAndCoverDatabase error: $_"
        Write-Warning "[UnitAutogen] Attempting to export any partial results..."
    }

    Write-Host ''
    $coveragePath    = Join-Path $OutputPath $CoverageFileName
    $testResultsPath = Join-Path $OutputPath $TestResultsFileName
    $htmlPath        = Join-Path $OutputPath $HtmlReportFileName

    Export-CoverageCoberturaXml `
        -ServerInstance $ServerInstance -Database $Database `
        -OutputFile     $coveragePath   -SchemaFilter $SchemaFilter `
        -Credential     $Credential

    Export-TestResultsJunitXml `
        -ServerInstance $ServerInstance -Database $Database `
        -OutputFile     $testResultsPath -SchemaFilter $SchemaFilter `
        -Credential     $Credential

    Export-CoverageHtmlReport `
        -ServerInstance $ServerInstance -Database $Database `
        -OutputFile     $htmlPath        -SchemaFilter $SchemaFilter `
        -Credential     $Credential

    Write-Host ''
    Write-Host "[UnitAutogen] Done."
    Write-Host "  Cobertura XML : $coveragePath"
    Write-Host "  JUnit XML     : $testResultsPath"
    Write-Host "  HTML Report   : $htmlPath"
}


function Export-CoverageCoberturaXml {
    <#
    .SYNOPSIS
        Exports Cobertura XML from the most recent UnitAutogen batch.

    .DESCRIPTION
        Calls TestGen.GetCoverageCoberturaXml and writes the result to a file.
        Does not re-run generation or tests — reads from the existing
        TestGen.CoverageResult and TestGen.CoverageLines data.

        Use this to re-export the Cobertura file without rerunning the full
        GenerateAndCoverDatabase pipeline.

    .PARAMETER ServerInstance
        SQL Server instance name.

    .PARAMETER Database
        Target database name.

    .PARAMETER OutputFile
        Path to write the Cobertura XML file. Default: coverage.xml

    .PARAMETER SchemaFilter
        Restrict output to one schema. Default: all schemas.

    .PARAMETER Credential
        PSCredential for SQL auth. Omit for Windows auth.

    .EXAMPLE
        Export-CoverageCoberturaXml `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -OutputFile     './artifacts/coverage.xml'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [string]               $OutputFile    = 'coverage.xml',
        [string]               $SchemaFilter  = $null,
        [PSCredential]         $Credential    = $null
    )

    $connParams = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                      -Credential $Credential
    $schemaArg  = Build-SchemaArg -SchemaFilter $SchemaFilter
    $query      = "EXEC TestGen.GetCoverageCoberturaXml $schemaArg;"

    Write-Host "[UnitAutogen] Fetching Cobertura XML from [$Database]..."

    # -MaxCharLength: Invoke-Sqlcmd silently truncates column values at 4000
    # chars by default; override so the full Cobertura XML reaches PowerShell.
    $result = Invoke-Sqlcmd @connParams -Query $query -MaxCharLength ([int]::MaxValue)
    $xml    = $result.CoberturaXml

    if (-not $xml) {
        throw "[UnitAutogen] GetCoverageCoberturaXml returned no data. " +
              "Run GenerateAndCoverDatabase first."
    }

    $fullPath, $bytes = Save-XmlFile -Path $OutputFile -Content $xml
    Write-Host "[UnitAutogen] Cobertura XML written -> $fullPath ($bytes bytes)"
}


function Export-TestResultsJunitXml {
    <#
    .SYNOPSIS
        Exports JUnit XML from the most recent UnitAutogen batch.

    .DESCRIPTION
        Calls TestGen.GetTestResultsJunitXml and writes the result to a file.
        Does not re-run generation or tests — reads from TestGen.CoverageResult.

        Use this to re-export the JUnit file without rerunning the full
        GenerateAndCoverDatabase pipeline.

    .PARAMETER ServerInstance
        SQL Server instance name.

    .PARAMETER Database
        Target database name.

    .PARAMETER OutputFile
        Path to write the JUnit XML file. Default: test-results.xml

    .PARAMETER SchemaFilter
        Restrict output to one schema. Default: all schemas.

    .PARAMETER Credential
        PSCredential for SQL auth. Omit for Windows auth.

    .EXAMPLE
        Export-TestResultsJunitXml `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -OutputFile     './artifacts/test-results.xml'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [string]               $OutputFile    = 'test-results.xml',
        [string]               $SchemaFilter  = $null,
        [PSCredential]         $Credential    = $null
    )

    $connParams = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                      -Credential $Credential
    $schemaArg  = Build-SchemaArg -SchemaFilter $SchemaFilter
    $query      = "EXEC TestGen.GetTestResultsJunitXml $schemaArg;"

    Write-Host "[UnitAutogen] Fetching JUnit XML from [$Database]..."

    # -MaxCharLength: Invoke-Sqlcmd silently truncates column values at 4000
    # chars by default; override so the full JUnit XML reaches PowerShell.
    $result = Invoke-Sqlcmd @connParams -Query $query -MaxCharLength ([int]::MaxValue)
    $xml    = $result.JUnitXml

    if (-not $xml) {
        throw "[UnitAutogen] GetTestResultsJunitXml returned no data. " +
              "Run GenerateAndCoverDatabase first."
    }

    $fullPath, $bytes = Save-XmlFile -Path $OutputFile -Content $xml
    Write-Host "[UnitAutogen] JUnit XML written -> $fullPath ($bytes bytes)"
}


function Export-CoverageHtmlReport {
    <#
    .SYNOPSIS
        Exports the UnitAutogen HTML coverage report from the most recent batch.

    .DESCRIPTION
        Calls TestGen.GetCoverageHtmlReport and writes a self-contained HTML
        file identical in layout to the report produced by
        GenerateAndCoverDatabase @OutputMode='HTML'.  Does not re-run tests.

        Open the output file in any browser for a human-readable coverage
        summary with colour-coded line/branch percentages, per-proc breakdown,
        and collapsible NOT_TESTABLE reasons.

    .PARAMETER ServerInstance
        SQL Server instance name.

    .PARAMETER Database
        Target database name.

    .PARAMETER OutputFile
        Path to write the HTML file. Default: coverage-report.html

    .PARAMETER SchemaFilter
        Restrict output to one schema. Default: all schemas.

    .PARAMETER Credential
        PSCredential for SQL auth. Omit for Windows auth.

    .EXAMPLE
        Export-CoverageHtmlReport `
            -ServerInstance 'sql01' `
            -Database       'Northwind' `
            -OutputFile     './artifacts/coverage-report.html'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [string]               $OutputFile    = 'coverage-report.html',
        [string]               $SchemaFilter  = $null,
        [PSCredential]         $Credential    = $null
    )

    $connParams = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                      -Credential $Credential
    $schemaArg  = Build-SchemaArg -SchemaFilter $SchemaFilter
    $query      = "EXEC TestGen.GetCoverageHtmlReport $schemaArg;"

    Write-Host "[UnitAutogen] Fetching HTML report from [$Database]..."

    # -MaxCharLength: Invoke-Sqlcmd silently truncates column values at 4000
    # chars by default; override so the full HTML report reaches PowerShell.
    $result = Invoke-Sqlcmd @connParams -Query $query -MaxCharLength ([int]::MaxValue)
    $html   = $result.CoverageReportHTML

    if (-not $html) {
        throw "[UnitAutogen] GetCoverageHtmlReport returned no data. " +
              "Run GenerateAndCoverDatabase first."
    }

    $fullPath, $bytes = Save-XmlFile -Path $OutputFile -Content $html
    Write-Host "[UnitAutogen] HTML report written -> $fullPath ($bytes bytes)"
}


function Export-UnitAutogenTests {
    <#
    .SYNOPSIS
        Exports the generated tSQLt test classes from a database into a single,
        deployable .sql script.

    .DESCRIPTION
        Calls TestGen.ExportTestClasses and writes the returned script to a file.
        Run that script against any OTHER database that already has tSQLt and
        UnitAutogen (TestGen) installed to recreate the tests there. The script is
        idempotent (drops + recreates each class) and starts with a pre-flight
        guard that aborts cleanly if tSQLt or TestGen is missing on the target.

    .PARAMETER ServerInstance
        SQL Server instance name.

    .PARAMETER Database
        Source database (where the tests were generated).

    .PARAMETER OutputFile
        Path to write the .sql script. Default: unitautogen-tests.sql

    .PARAMETER TestClass
        Export a single test class (e.g. 'test_MyProc'). Default: all classes.

    .PARAMETER Like
        LIKE filter on the test-class name (e.g. 'test\_usp%'). Default: all.

    .PARAMETER Credential
        PSCredential for SQL auth. Omit for Windows auth.

    .EXAMPLE
        Export-UnitAutogenTests `
            -ServerInstance 'sql01' `
            -Database       'DevDB' `
            -OutputFile     './tests/unitautogen-tests.sql'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]       $ServerInstance,
        [Parameter(Mandatory)] [string]       $Database,
        [string]               $OutputFile = 'unitautogen-tests.sql',
        [string]               $TestClass  = $null,
        [string]               $Like       = $null,
        [PSCredential]         $Credential = $null
    )

    $connParams = Build-ConnParams -ServerInstance $ServerInstance -Database $Database `
                      -Credential $Credential

    $argList = @()
    if ($TestClass) { $argList += "@TestClass = N'$($TestClass -replace "'","''")'" }
    if ($Like)      { $argList += "@Like = N'$($Like -replace "'","''")'" }
    $argList += "@OutputMode = 'RESULT'"
    $query = "EXEC TestGen.ExportTestClasses " + ($argList -join ', ') + ";"

    Write-Host "[UnitAutogen] Exporting test classes from [$Database]..."

    # -MaxCharLength: Invoke-Sqlcmd truncates column values at 4000 chars by
    # default; override so the full export script reaches PowerShell.
    $result = Invoke-Sqlcmd @connParams -Query $query -MaxCharLength ([int]::MaxValue)
    $script = $result.ExportScript

    if (-not $script) {
        throw "[UnitAutogen] ExportTestClasses returned no script - no matching " +
              "generated test classes were found in [$Database]."
    }

    $dir = Split-Path -Parent $OutputFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputFile, $script, (New-Object System.Text.UTF8Encoding($false)))
    $bytes = (Get-Item -LiteralPath $OutputFile).Length
    Write-Host "[UnitAutogen] Test classes exported -> $((Resolve-Path $OutputFile).Path) ($bytes bytes)"
}


# =============================================================================
Export-ModuleMember -Function Install-UnitAutogenDatabase,
                               Invoke-UnitAutogen,
                               Export-CoverageCoberturaXml,
                               Export-TestResultsJunitXml,
                               Export-CoverageHtmlReport,
                               Export-UnitAutogenTests
