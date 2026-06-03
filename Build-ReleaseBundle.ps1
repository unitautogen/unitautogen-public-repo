<#
.SYNOPSIS
  Assemble the end-user install bundle: a single .zip a newcomer can download and
  run in SSMS. Output: dist/UnitAutogen-<version>-install.zip

.DESCRIPTION
  Stages the two installers (framework + in-database parser), a numbered install
  README, and the licence/notices, then zips them. The version is read from the
  PowerShell module manifest so the bundle name tracks the module.

.EXAMPLE
  ./Build-ReleaseBundle.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

$framework = Join-Path $repo 'Install_UnitAutogen.sql'
$clr       = Join-Path $repo 'clr\Install-UnitAutogenClr.SSMS.sql'
$notices   = Join-Path $repo 'clr\THIRD-PARTY-NOTICES.txt'
$license   = Join-Path $repo 'LICENSE'
$copyright = Join-Path $repo 'COPYRIGHT'
foreach ($f in @($framework,$clr,$notices,$license,$copyright)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f" }
}

$manifest = Test-ModuleManifest -Path (Join-Path $repo 'powershell\UnitAutogen\UnitAutogen.psd1')
$version  = $manifest.Version.ToString()

$dist  = Join-Path $repo 'dist'
$stage = Join-Path $dist "UnitAutogen-$version-install"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $framework (Join-Path $stage '1_Install_UnitAutogen.sql')         -Force
Copy-Item $clr       (Join-Path $stage '2_Install-UnitAutogenClr.SSMS.sql') -Force
Copy-Item $notices   $stage -Force
Copy-Item $license   $stage -Force
Copy-Item $copyright $stage -Force

$readme = @"
# UnitAutogen $version - Install

Auto-generated tSQLt unit tests with real branch coverage for SQL Server.

## Prerequisites
- SQL Server 2017+ with 'clr enabled' = 1   (EXEC sp_configure 'clr enabled',1; RECONFIGURE;)
- tSQLt installed in your database           (https://tsqlt.org ; check: SELECT tSQLt.Info();)
- Sysadmin (CONTROL SERVER) for step 2 (registers the parser via sp_add_trusted_assembly;
  no TRUSTWORTHY needed, clr strict security can stay ON)

## Install (run both in SSMS, in your target database)
1. Open and run  1_Install_UnitAutogen.sql          -- the framework
2. Open and run  2_Install-UnitAutogenClr.SSMS.sql  -- the single in-database predicate parser
   (~12 MB; run in SSMS, not sqlcmd)

## Use
    EXEC TestGen.ParseDatabasePredicates  @SchemaFilter = N'dbo';   -- or NULL/'*' = all schemas
    EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = N'dbo';   -- generate + cover

Per procedure:
    EXEC TestGen.ParseProcedurePredicates  @Schema = N'dbo', @ProcName = N'YourProc';
    EXEC TestGen.GenerateTestsForProcedure @SchemaName = N'dbo', @ProcName = N'YourProc', @ExecuteScript = 1;
    EXEC TestGen.RunCoverage               @SchemaName = N'dbo', @ProcName = N'YourProc', @OutputMode = N'TEXT';

## CI/CD
    Install-Module UnitAutogen
    Install-UnitAutogenDatabase -ServerInstance <srv> -Database <db>   # installs framework + parser
    Invoke-UnitAutogen          -ServerInstance <srv> -Database <db> -OutputPath ./artifacts

## Notes
- One parser only: the C# parser runs INSIDE SQL Server. There is no PowerShell parser.
- A server that forbids UNSAFE CLR cannot register the parser; data-shape branches then
  fall back to NOT_TESTABLE / string-gen.
- THIRD-PARTY-NOTICES.txt covers the bundled Microsoft ScriptDom (MIT).
- Full docs: https://github.com/unitautogen/unitautogen-public-repo
"@
Set-Content -Path (Join-Path $stage 'README-INSTALL.md') -Value $readme -Encoding UTF8

$zip = Join-Path $dist "UnitAutogen-$version-install.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item -Recurse -Force $stage

Write-Host "Built $zip ($([math]::Round((Get-Item $zip).Length/1MB,2)) MB)."
