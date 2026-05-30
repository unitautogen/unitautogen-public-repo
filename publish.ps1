<#
.SYNOPSIS
    Publishes the UnitAutogen PowerShell module to the PowerShell Gallery.

.DESCRIPTION
    Validates the module manifest, then calls Publish-Module to push to
    PSGallery.  Use -WhatIf to do a dry run without actually publishing.

.PARAMETER ApiKey
    Your PSGallery API key.  Defaults to the PSGALLERY_API_KEY environment
    variable.  Generate one at https://www.powershellgallery.com/account/apikeys

.PARAMETER WhatIf
    Validate and report what would be published without actually publishing.

.EXAMPLE
    # Dry run
    .\publish.ps1 -WhatIf

.EXAMPLE
    # Publish (API key from environment)
    $env:PSGALLERY_API_KEY = '<your-key>'
    .\publish.ps1

.EXAMPLE
    # Publish (API key inline — CI/CD usage)
    .\publish.ps1 -ApiKey $env:PSGALLERY_API_KEY

.NOTES
    Requirements:
    - PowerShellGet 2.x  (ships with PowerShell 5.1+; update with
      Install-Module PowerShellGet -Force if needed)
    - Run from the repository root (the folder that contains this script).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ApiKey = $env:PSGALLERY_API_KEY
)

$ErrorActionPreference = 'Stop'

# PowerShellGet 1.x defaults to TLS 1.0; PSGallery requires TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot   = $PSScriptRoot
$modulePath = Join-Path $repoRoot 'powershell\UnitAutogen'
$manifestPath = Join-Path $modulePath 'UnitAutogen.psd1'

# ── 1. Verify files exist ────────────────────────────────────────────────────
Write-Host "Module path : $modulePath"
Write-Host "Manifest    : $manifestPath"
Write-Host ""

if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Module directory not found: $modulePath"
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Manifest not found: $manifestPath"
}

$sqlInstaller = Join-Path $modulePath 'sql\Install_UnitAutogen.sql'
if (-not (Test-Path -LiteralPath $sqlInstaller)) {
    throw "Bundled SQL installer not found: $sqlInstaller`nRun from the repo root after ensuring sql\ is populated."
}

# ── 2. Validate the manifest ─────────────────────────────────────────────────
Write-Host "Validating manifest..."
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Write-Host "  Name    : $($manifest.Name)"
Write-Host "  Version : $($manifest.Version)"
Write-Host "  Author  : $($manifest.Author)"
Write-Host "  Exports : $($manifest.ExportedFunctions.Keys -join ', ')"
Write-Host ""

# ── 3. Confirm API key ───────────────────────────────────────────────────────
if (-not $WhatIfPreference) {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "No API key supplied. Pass -ApiKey or set `$env:PSGALLERY_API_KEY.`n" +
              "Generate one at: https://www.powershellgallery.com/account/apikeys"
    }
    Write-Host "API key     : ****** (set)"
} else {
    Write-Host "API key     : (skipped - WhatIf mode)"
}
Write-Host ""

# ── 4. Publish ───────────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess("PSGallery", "Publish-Module UnitAutogen v$($manifest.Version)")) {
    Write-Host "Publishing UnitAutogen v$($manifest.Version) to PSGallery..."
    Publish-Module -Path $modulePath -NuGetApiKey $ApiKey -Repository PSGallery -Verbose
    Write-Host ""
    Write-Host "Published successfully."
    Write-Host "View at: https://www.powershellgallery.com/packages/UnitAutogen"
} else {
    Write-Host "[WhatIf] Would publish: UnitAutogen v$($manifest.Version) -> PSGallery"
    Write-Host "[WhatIf] Module path  : $modulePath"
}
