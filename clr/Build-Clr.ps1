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
# Keep a copy in lib so the bundle is self-contained.
Copy-Item $ScriptDomPath (Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll') -Force

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found at $csc" }
$cs  = Join-Path $here 'UnitAutogenClr.cs'
$out = Join-Path $lib 'UnitAutogenClr.dll'
$sdRef = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'

$args = @('/nologo','/target:library',"/out:$out","/reference:$sdRef",'/reference:System.Data.dll',$cs)
$tmpOut = [IO.Path]::GetTempFileName(); $tmpErr = [IO.Path]::GetTempFileName()
$p = Start-Process -FilePath $csc -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
Get-Content $tmpOut, $tmpErr -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) { throw "csc failed (exit $($p.ExitCode))." }
Write-Host "Built $out ($((Get-Item $out).Length) bytes)."

if ($Emit) {
    & (Join-Path $here 'Emit-InstallerSql.ps1')
}
