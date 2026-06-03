# UnitAutogen CLR predicate parser (v0.13) — SSMS-native, zero PowerShell

This folder hosts the predicate parser **inside SQL Server** via SQLCLR, so the
whole UnitAutogen workflow — parse, generate, cover, run — is callable from T-SQL
in SSMS with **no PowerShell**. It is a faithful C# port of
`powershell/UnitAutogen/Get-ParsedPredicates.ps1`; it emits the identical
`TestGen.PredicateInbox` JSON the T-SQL seeder already consumes, so the rest of the
framework (modules 31–34, the generator and coverage) is unchanged.

See `design/DESIGN_v0_13_SqlClrParser.md` for the rationale and architecture.

## What's here

| File | Purpose |
| --- | --- |
| `UnitAutogenClr.cs` | The C# parser + the CLR procedures. |
| `lib/UnitAutogenClr.dll` | Compiled assembly (net472). |
| `lib/Microsoft.SqlServer.TransactSql.ScriptDom.dll` | Microsoft's MIT-licensed ScriptDom (TSql170Parser = SQL 2025 grammar). Bundled — see `THIRD-PARTY-NOTICES.txt`. |
| `Install-UnitAutogenClr.SSMS.sql` | **Self-contained installer.** Embeds both assemblies as `0x` bytes; just open it in SSMS and run. No file paths, no PowerShell. |
| `Build-Clr.ps1` | (dev) Recompile `UnitAutogenClr.dll` from source. |
| `Register-Clr.ps1` | (dev) Register from the loose DLL files via `sqlcmd` (computes the SHA-512 trust hashes for you). |

## Install (SSMS only)

1. Ensure CLR is enabled (one-time, instance-level):

   ```sql
   EXEC sp_configure 'clr enabled', 1; RECONFIGURE;
   ```

   `clr strict security` can stay **ON** and the database can stay
   `TRUSTWORTHY OFF` — registration authorises each assembly by SHA-512 hash via
   `sys.sp_add_trusted_assembly` (this requires `CONTROL SERVER`, i.e. a sysadmin
   runs the install once).

2. Open **`Install-UnitAutogenClr.SSMS.sql`** in SSMS against your target database
   (the one with the TestGen framework) and execute. It trusts + creates both
   assemblies and the two procedures. (~10–15 s; the file is ~12 MB because it
   carries the assembly bytes. Run it in SSMS, not `sqlcmd` — `sqlcmd` is slow on
   the single very long binary literal.)

## Use

```sql
-- Parse predicates for a schema (or NULL / '*' for every user schema):
EXEC TestGen.ParseDatabasePredicates @SchemaFilter = N'dbo';

-- ...or one procedure:
EXEC TestGen.ParseProcedurePredicates @Schema = N'dbo', @ProcName = N'AssessCustomer';

-- Then generate + cover exactly as before (pure T-SQL):
EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = N'dbo';
```

That is the entire pipeline in SSMS — the ScriptDom cold start the PowerShell
parser paid is gone (the CLR host is warm in-process).

## Coexistence

The PowerShell parser still works and writes the same inbox; use it on servers
where UNSAFE CLR is disallowed. Both are interchangeable producers of
`TestGen.PredicateInbox`.

## Rebuild from source (dev)

```powershell
./Build-Clr.ps1            # -> lib/UnitAutogenClr.dll
# then regenerate Install-UnitAutogenClr.SSMS.sql (see Build-Clr.ps1 -Emit)
```
