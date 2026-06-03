#Requires -Version 5.1
# =============================================================================
# UnitAutogen - convenience shim for direct import from a repo clone:
#
#     Import-Module ./powershell/UnitAutogen.psm1
#
# This is NOT a second implementation. It auto-installs the SqlServer module if
# missing, then loads the REAL module in ./UnitAutogen/ - the exact same code
# published to the PowerShell Gallery. There is one module; maintain it only in
# powershell/UnitAutogen/. (Prior to v0.13 this file held a separate, older copy
# of the cmdlets - that duplication is gone, and with it the v0.13 single-parser
# behaviour now applies no matter how the module is loaded.)
# =============================================================================

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "[UnitAutogen] SqlServer module not found. Installing from PSGallery (CurrentUser)..."
    Install-Module SqlServer -Scope CurrentUser -AllowClobber -Force
}

$realModule = Join-Path $PSScriptRoot 'UnitAutogen\UnitAutogen.psd1'
if (-not (Test-Path -LiteralPath $realModule)) {
    throw "[UnitAutogen] Canonical module not found at $realModule"
}

# -Global so the cmdlets land in the caller's session, exactly as if the
# published module had been imported directly.
Import-Module $realModule -Global -Force -DisableNameChecking
