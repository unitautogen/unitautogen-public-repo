# Clean-room install + full sweep (v0.10)

Goal: restore a clean AdventureWorks2025, install tSQLt + UnitAutogen (v0.10 is
now folded into the single installer), run one full `Invoke-UnitAutogen` sweep,
and produce the HTML coverage report. The v0.10 objects are inert with respect
to the generator, so the sweep numbers are the true baseline (target ~94.9%
line / 94.4% branch) AND this confirms the v0.10 objects deploy cleanly.

Run each step against the **restored** AdventureWorks2025.

## 0. Restore (you)
Restore the clean AdventureWorks2025 backup. Confirm:
```sql
SELECT name, compatibility_level FROM sys.databases WHERE name = 'AdventureWorks2025';
-- compat should be >= 130 (170 on SQL 2025). The UnitAutogen installer aborts below 130.
```

## 1. Install tSQLt
Use your tSQLt distribution against the restored DB:
```sql
-- one-time server prep for tSQLt CLR (skip if already done on this instance)
EXEC sp_configure 'clr strict security', 0; RECONFIGURE;   -- SQL 2017+
EXEC sp_configure 'clr enabled', 1; RECONFIGURE;
ALTER DATABASE AdventureWorks2025 SET TRUSTWORTHY ON;
```
Then run tSQLt's `tSQLt.class.sql` against AdventureWorks2025 (SSMS or sqlcmd).
Verify: `SELECT tSQLt.Info();`

## 2. Install UnitAutogen (single installer — v0.10 included)
In SSMS: `USE AdventureWorks2025;` then execute the whole single-file installer:
```
Install_UnitAutogen.sql
```
Idempotent. v0.10 (modules 31/32/33) is folded in near the end; you will see
`== Installing v0.10 predicate-seeding (modules 31/32/33) ==` then
`UnitAutogen framework installed successfully.` as the final banner. (There is
no longer a separate add-on file.)

## 3. Full sweep + HTML report (PowerShell)
Run in a normal PowerShell window (not through any 60s-limited tool):
```powershell
Import-Module SqlServer
Import-Module "D:\Working Files\ai\tsqlt Automation\tsqltAutoGen\unitautogen-public-repo\unitautogen-public-repo\powershell\UnitAutogen\UnitAutogen.psd1" -Force

$out = "D:\Working Files\ai\tsqlt Automation\tsqltAutoGen\sweep_out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

Invoke-UnitAutogen `
    -ServerInstance localhost `
    -Database AdventureWorks2025 `
    -OutputPath $out `
    -GenerationTimeout 7200
```
This runs `TestGen.GenerateAndCoverDatabase` over the whole DB, then writes:
- `coverage-report.html`  <- the file to share
- `coverage.xml` (Cobertura), `test-results.xml` (JUnit)

A full AdventureWorks sweep takes a while (hundreds of objects); the default
generation timeout is bumped to 2h above to be safe.

### Optional: scope the sweep
To sweep a single schema first (faster smoke), add `-SchemaFilter dbo`.

## 5. Share
Send `coverage-report.html`. Compare line/branch % and the
testable-vs-NOT_TESTABLE breakdown against the README baseline.

## Notes / what to watch
- **Do NOT install examples/PredicateZoo for this run** - it is a synthetic
  corpus and would add `pz.*` rows to the report. The baseline sweep should be
  AdventureWorks objects only.
- Known pre-existing generator issue to watch for in the report (NOT v0.10):
  a NOT_TESTABLE `[@tSQLt:SkipTest]('...')` annotation does not escape
  apostrophes, so a reason text containing `'` (e.g. "another procedure's CATCH
  block" on `uspLogError`) errors that one test. Flag if you want it fixed in
  module 04/30 - module 33's v0.10 equivalent already escapes correctly.
- If a prior interrupted run left objects renamed, `GenerateAndCoverDatabase`
  self-heals via `CleanupInterruptedRuns` at the start (v0.9.5).
