<#
.SYNOPSIS
  Generate clr/Install-UnitAutogenClr.SSMS.sql: a self-contained, PowerShell-free
  installer that embeds both assemblies (lib/*.dll) as 0x byte literals and the
  SHA-512 trust hashes. Run the produced .sql in SSMS against the target database.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path $here 'lib'
$sdDll  = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
$clrDll = Join-Path $lib 'UnitAutogenClr.dll'
foreach ($f in @($sdDll,$clrDll)) { if (-not (Test-Path $f)) { throw "Missing $f (run Build-Clr.ps1 first)." } }

function HexOf($path) { '0x' + [BitConverter]::ToString([IO.File]::ReadAllBytes($path)).Replace('-','') }
$h1 = (Get-FileHash -Algorithm SHA512 $sdDll).Hash
$h2 = (Get-FileHash -Algorithm SHA512 $clrDll).Hash

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("-- ============================================================================")
[void]$sb.AppendLine("-- Install-UnitAutogenClr.SSMS.sql  (v0.13)  -- AUTO-GENERATED, zero PowerShell")
[void]$sb.AppendLine("-- Registers the SSMS-native predicate parser: the net472 ScriptDom assembly")
[void]$sb.AppendLine("-- plus the UnitAutogen CLR parser, then the TestGen.Parse*Predicates procs.")
[void]$sb.AppendLine("-- Prereq: 'clr enabled'=1 (no TRUSTWORTHY needed; uses sp_add_trusted_assembly).")
[void]$sb.AppendLine("-- Run in the TARGET database (the one with the TestGen framework installed).")
[void]$sb.AppendLine("-- ScriptDom is Microsoft's MIT-licensed assembly; see clr/THIRD-PARTY-NOTICES.txt.")
[void]$sb.AppendLine("-- ============================================================================")
[void]$sb.AppendLine("SET NOCOUNT ON;")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("DECLARE @h1 VARBINARY(64)=0x$h1;")
[void]$sb.AppendLine("DECLARE @h2 VARBINARY(64)=0x$h2;")
[void]$sb.AppendLine("IF NOT EXISTS(SELECT 1 FROM sys.trusted_assemblies WHERE [hash]=@h1) EXEC sys.sp_add_trusted_assembly @h1, N'UnitAutogen: Microsoft ScriptDom (net472)';")
[void]$sb.AppendLine("IF NOT EXISTS(SELECT 1 FROM sys.trusted_assemblies WHERE [hash]=@h2) EXEC sys.sp_add_trusted_assembly @h2, N'UnitAutogen: UnitAutogenClr 0.13';")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("IF OBJECT_ID('TestGen.ParseDatabasePredicates') IS NOT NULL DROP PROCEDURE TestGen.ParseDatabasePredicates;")
[void]$sb.AppendLine("IF OBJECT_ID('TestGen.ParseProcedurePredicates') IS NOT NULL DROP PROCEDURE TestGen.ParseProcedurePredicates;")
[void]$sb.AppendLine("IF EXISTS(SELECT 1 FROM sys.assemblies WHERE name='UnitAutogenClr') DROP ASSEMBLY [UnitAutogenClr];")
[void]$sb.AppendLine("IF EXISTS(SELECT 1 FROM sys.assemblies WHERE name='Microsoft.SqlServer.TransactSql.ScriptDom') DROP ASSEMBLY [Microsoft.SqlServer.TransactSql.ScriptDom];")
[void]$sb.AppendLine("GO")
[void]$sb.Append("CREATE ASSEMBLY [Microsoft.SqlServer.TransactSql.ScriptDom] FROM "); [void]$sb.Append((HexOf $sdDll));  [void]$sb.AppendLine(" WITH PERMISSION_SET=UNSAFE;")
[void]$sb.AppendLine("GO")
[void]$sb.Append("CREATE ASSEMBLY [UnitAutogenClr] FROM "); [void]$sb.Append((HexOf $clrDll)); [void]$sb.AppendLine(" WITH PERMISSION_SET=UNSAFE;")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("CREATE PROCEDURE TestGen.ParseDatabasePredicates @SchemaFilter NVARCHAR(128) = NULL")
[void]$sb.AppendLine("AS EXTERNAL NAME [UnitAutogenClr].[UnitAutogenClr].[ParseDatabasePredicates];")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("CREATE PROCEDURE TestGen.ParseProcedurePredicates @Schema NVARCHAR(128), @ProcName NVARCHAR(128)")
[void]$sb.AppendLine("AS EXTERNAL NAME [UnitAutogenClr].[UnitAutogenClr].[ParseProcedurePredicates];")
[void]$sb.AppendLine("GO")
[void]$sb.AppendLine("PRINT 'UnitAutogenClr registered. Usage: EXEC TestGen.ParseDatabasePredicates @SchemaFilter=N''dbo'';';")
[void]$sb.AppendLine("GO")

$outPath = Join-Path $here 'Install-UnitAutogenClr.SSMS.sql'
[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "Wrote $outPath ($([math]::Round((Get-Item $outPath).Length/1MB,2)) MB)."
Write-Host "  ScriptDom SHA-512: 0x$h1"
Write-Host "  UnitAutogenClr SHA-512: 0x$h2"
