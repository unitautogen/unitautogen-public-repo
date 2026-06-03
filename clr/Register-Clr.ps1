<#
.SYNOPSIS
  (dev) Register the CLR parser into a database from the loose lib/*.dll files,
  computing the SHA-512 trust hashes for you. An alternative to running the
  self-contained Install-UnitAutogenClr.SSMS.sql in SSMS.

.PARAMETER ServerInstance
  e.g. 'localhost' or 'SRV\INST'.

.PARAMETER Database
  Target database (must already have the TestGen framework + 'clr enabled').

.NOTES
  Requires sysadmin / CONTROL SERVER (sp_add_trusted_assembly). Uses
  CREATE ASSEMBLY FROM <path>, so the SQL Server service account must be able to
  read lib/ — grant it read, or use Install-UnitAutogenClr.SSMS.sql (embedded bytes)
  instead. Uses Integrated Security.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ServerInstance,
    [Parameter(Mandatory=$true)][string]$Database
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path $here 'lib'
$sdDll  = Join-Path $lib 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
$clrDll = Join-Path $lib 'UnitAutogenClr.dll'
foreach ($f in @($sdDll,$clrDll)) { if (-not (Test-Path $f)) { throw "Missing $f (run Build-Clr.ps1 first)." } }
$h1 = (Get-FileHash -Algorithm SHA512 $sdDll).Hash
$h2 = (Get-FileHash -Algorithm SHA512 $clrDll).Hash

$sql = @"
SET NOCOUNT ON;
DECLARE @h1 VARBINARY(64)=0x$h1;
DECLARE @h2 VARBINARY(64)=0x$h2;
IF NOT EXISTS(SELECT 1 FROM sys.trusted_assemblies WHERE [hash]=@h1) EXEC sys.sp_add_trusted_assembly @h1, N'UnitAutogen: Microsoft ScriptDom (net472)';
IF NOT EXISTS(SELECT 1 FROM sys.trusted_assemblies WHERE [hash]=@h2) EXEC sys.sp_add_trusted_assembly @h2, N'UnitAutogen: UnitAutogenClr 0.13';
IF OBJECT_ID('TestGen.ParseDatabasePredicates') IS NOT NULL DROP PROCEDURE TestGen.ParseDatabasePredicates;
IF OBJECT_ID('TestGen.ParseProcedurePredicates') IS NOT NULL DROP PROCEDURE TestGen.ParseProcedurePredicates;
IF EXISTS(SELECT 1 FROM sys.assemblies WHERE name='UnitAutogenClr') DROP ASSEMBLY [UnitAutogenClr];
IF EXISTS(SELECT 1 FROM sys.assemblies WHERE name='Microsoft.SqlServer.TransactSql.ScriptDom') DROP ASSEMBLY [Microsoft.SqlServer.TransactSql.ScriptDom];
CREATE ASSEMBLY [Microsoft.SqlServer.TransactSql.ScriptDom] FROM '$sdDll' WITH PERMISSION_SET=UNSAFE;
CREATE ASSEMBLY [UnitAutogenClr] FROM '$clrDll' WITH PERMISSION_SET=UNSAFE;
GO
CREATE PROCEDURE TestGen.ParseDatabasePredicates @SchemaFilter NVARCHAR(128) = NULL
AS EXTERNAL NAME [UnitAutogenClr].[UnitAutogenClr].[ParseDatabasePredicates];
GO
CREATE PROCEDURE TestGen.ParseProcedurePredicates @Schema NVARCHAR(128), @ProcName NVARCHAR(128)
AS EXTERNAL NAME [UnitAutogenClr].[UnitAutogenClr].[ParseProcedurePredicates];
GO
"@

# Execute via .NET SqlClient (batch on GO) — avoids sqlcmd quirks and needs no PATH.
$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$ServerInstance;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True")
$cn.Open()
try {
    $batches = [regex]::Split($sql, '(?im)^\s*GO\s*$') | Where-Object { $_.Trim() -ne '' }
    foreach ($b in $batches) { $cmd = $cn.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = 120; [void]$cmd.ExecuteNonQuery() }
    Write-Host "Registered UnitAutogenClr into $Database on $ServerInstance."
    Write-Host "Try:  EXEC TestGen.ParseDatabasePredicates @SchemaFilter=N'dbo';"
} finally { $cn.Close() }
