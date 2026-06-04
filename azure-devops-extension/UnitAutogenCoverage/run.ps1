# =============================================================================
# UnitAutogen Coverage - Azure DevOps pipeline task
#
# Installs the UnitAutogen PowerShell module (from PSGallery) if needed, then runs
# Invoke-UnitAutogen against the target database. It writes coverage.xml (Cobertura),
# test-results.xml (JUnit) and coverage-report.html to the output path. Add the
# native PublishTestResults@2 + PublishCodeCoverageResults@2 tasks AFTER this step
# to surface them in the pipeline (see the extension overview).
#
# Inputs arrive as INPUT_<NAME> environment variables (the PowerShell3 task handler
# convention) - no VstsTaskSdk vendoring required for this thin wrapper.
# =============================================================================
$ErrorActionPreference = 'Stop'

function Get-In([string]$name, [string]$default = '') {
    $v = [Environment]::GetEnvironmentVariable("INPUT_$($name.ToUpperInvariant())")
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v
}

$server           = Get-In 'serverInstance'
$database         = Get-In 'database'
$schemaFilter     = Get-In 'schemaFilter'
$installFramework = (Get-In 'installFramework' 'false') -eq 'true'
$outputPath       = Get-In 'outputPath' $env:BUILD_ARTIFACTSTAGINGDIRECTORY
$sqlAuth          = (Get-In 'sqlAuth' 'false') -eq 'true'
$sqlUser          = Get-In 'sqlUser'
$sqlPassword      = Get-In 'sqlPassword'
$generationTimeout= Get-In 'generationTimeout' '3600'
$failOnError      = (Get-In 'failOnError' 'true') -eq 'true'

try {
    if ([string]::IsNullOrWhiteSpace($server))   { throw "serverInstance is required." }
    if ([string]::IsNullOrWhiteSpace($database)) { throw "database is required." }
    if ([string]::IsNullOrWhiteSpace($outputPath)) { $outputPath = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $outputPath)) { New-Item -ItemType Directory -Path $outputPath -Force | Out-Null }

    # PSGallery requires TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Get-Module -ListAvailable -Name UnitAutogen)) {
        Write-Host "Installing UnitAutogen from the PowerShell Gallery..."
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        }
        Install-Module UnitAutogen -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module UnitAutogen -Force
    Write-Host "UnitAutogen $((Get-Module UnitAutogen).Version) loaded."

    $cred = $null
    if ($sqlAuth) {
        if ([string]::IsNullOrWhiteSpace($sqlUser) -or [string]::IsNullOrWhiteSpace($sqlPassword)) {
            throw "SQL authentication selected but the SQL login/password were not supplied (map a secret variable to sqlPassword)."
        }
        $sec  = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($sqlUser, $sec)
    }

    $conn = @{ ServerInstance = $server; Database = $database }
    if ($cred) { $conn.Credential = $cred }

    if ($installFramework) {
        Write-Host "##[group]Installing UnitAutogen framework + in-database parser into $database"
        Install-UnitAutogenDatabase @conn
        Write-Host "##[endgroup]"
    }

    $invoke = @{} + $conn
    $invoke.OutputPath = $outputPath
    if (-not [string]::IsNullOrWhiteSpace($schemaFilter)) { $invoke.SchemaFilter = $schemaFilter }
    $gt = 0; if ([int]::TryParse($generationTimeout, [ref]$gt) -and $gt -gt 0) { $invoke.GenerationTimeout = $gt }

    Write-Host "##[group]Running UnitAutogen (parse -> generate -> cover -> export)"
    Invoke-UnitAutogen @invoke
    Write-Host "##[endgroup]"

    foreach ($f in 'coverage.xml','test-results.xml','coverage-report.html') {
        $p = Join-Path $outputPath $f
        if (Test-Path -LiteralPath $p) { Write-Host "Produced: $p ($((Get-Item $p).Length) bytes)" }
        else { Write-Host "##vso[task.logissue type=warning]Expected output not found: $p" }
    }
    Write-Host "##vso[task.complete result=Succeeded;]UnitAutogen coverage complete. Add PublishTestResults@2 + PublishCodeCoverageResults@2 to surface the results."
}
catch {
    $msg = $_.Exception.Message
    Write-Host "##vso[task.logissue type=error]UnitAutogen task failed: $msg"
    if ($failOnError) { Write-Host "##vso[task.complete result=Failed;]$msg"; exit 1 }
    else { Write-Host "##vso[task.complete result=SucceededWithIssues;]$msg" }
}
