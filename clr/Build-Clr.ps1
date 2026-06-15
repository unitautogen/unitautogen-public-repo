<#
.SYNOPSIS
  Compile UnitAutogenClr.dll (net472) and, optionally, regenerate the
  self-contained SSMS installer (Install-UnitAutogenClr.SSMS.sql) with the
  assembly bytes + SHA-512 trust hashes embedded.

.PARAMETER ScriptDomPath
  Path to Microsoft.SqlServer.TransactSql.ScriptDom.dll. Defaults to the bundled
  lib copy; falls back to an SSMS install probe.

.PARAMETER Emit
  After compiling, regenerate Install-UnitAutogenClr.SSMS.sql.

.EXAMPLE
  ./Build-Clr.ps1 -Emit
#>
[CmdletBinding()]
param(
    [string]$ScriptDomPath,
    [switch]$Emit
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path $here 'lib'
New-Item -ItemType Directory -Force -Path $lib | Out-Null

if (-not $ScriptDomPath) {
    $bundled = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
    if (Test-Path $bundled) { $ScriptDomPath = $bundled }
    else {
        $ScriptDomPath = Get-ChildItem `
            "${env:ProgramFiles}\Microsoft SQL Server Management Studio*\*\Common7\IDE\Extensions\Application\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
            "${env:ProgramFiles}\Microsoft SQL Server Management Studio*\Common7\IDE\Microsoft.SqlServer.TransactSql.ScriptDom.dll" `
            -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $ScriptDomPath -or -not (Test-Path $ScriptDomPath)) { throw "ScriptDom DLL not found; pass -ScriptDomPath." }
# Keep a copy in lib so the bundle is self-contained (skip if it already IS the lib copy).
$libSd  = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
$srcFull = (Resolve-Path $ScriptDomPath).Path
$dstFull = if (Test-Path $libSd) { (Resolve-Path $libSd).Path } else { $libSd }
if ($srcFull -ne $dstFull) { Copy-Item $ScriptDomPath $libSd -Force }

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
$cs  = Join-Path $here 'UnitAutogenClr.cs'
$out = Join-Path $lib 'UnitAutogenClr.dll'
$sdRef = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'

# Invoke via the call operator so paths containing spaces are quoted correctly.
$cscOutput = & $csc /nologo /target:library "/out:$out" "/reference:$sdRef" /reference:System.Data.dll "$cs" 2>&1
$cscOutput | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)." }
Write-Host "Built $out ($((Get-Item $out).Length) bytes)."

if ($Emit) {
    & (Join-Path $here 'Emit-InstallerSql.ps1')
}
