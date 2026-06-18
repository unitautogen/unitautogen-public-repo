# UnitAutogen — Installation

UnitAutogen has two installable pieces:

1. **The framework** — the `TestGen` schema and all its stored procedures
   (generation, coverage, reporting).
2. **The predicate parser** — a single C# parser hosted **inside SQL Server**
   (SQLCLR) that reads your procedures and populates `TestGen.PredicateInbox`, so
   data-shape branches (EXISTS / COUNT / SUM / scalar-subquery gates) get real
   seeded tests. As of v0.13 this is the **only** parser; it runs from T-SQL as
   `EXEC TestGen.ParseDatabasePredicates`. (The old PowerShell parser is retired —
   see `powershell/legacy/`.)

## Prerequisites

- **SQL Server 2017 (MSSQL14) or later.**
- **tSQLt** v1.0.7597.5637 (Oct 2020) or later in the target database
  (`SELECT tSQLt.Info();`). Get it from <https://tsqlt.org>.
- **`clr enabled` = 1** at the instance (tSQLt already needs CLR):

      EXEC sp_configure 'clr enabled', 1; RECONFIGURE;

- **Sysadmin (CONTROL SERVER) once**, only for step 2 — registering the parser
  authorises its assemblies with `sys.sp_add_trusted_assembly` (so `clr strict
  security` can stay ON and the database can stay `TRUSTWORTHY OFF`).
- Database permissions for step 1: `CREATE PROCEDURE`, `CREATE FUNCTION`,
  `CREATE SCHEMA`.
- An **Extended Events directory** the SQL Server service account can write to
  (coverage uses it). Default is the instance `MSSQL\DATA\` path — change it in the
  installer if your instance differs.

---

## Option A — Release download (.zip) — easiest, no clone

Every release ships a ready-to-run bundle on the
[Releases page](https://github.com/unitautogen/unitautogen-public-repo/releases):
**`UnitAutogen-<version>-install.zip`**. You don't need to clone the repository.

1. Download `UnitAutogen-<version>-install.zip` from the latest release and extract it.
2. In SSMS, connect to your target database (`USE YourDatabase;`), then open and execute
   **`1_Install_UnitAutogen.sql`** — the framework. You should see
   `Framework installed successfully.`
3. In the **same** database, open and execute **`2_Install-UnitAutogenClr.SSMS.sql`** —
   the in-database predicate parser (needs sysadmin once). Run it in **SSMS**, not
   `sqlcmd` — it is ~12 MB because it carries the assembly bytes (~10–15 s).

Both files are pure T-SQL and idempotent (safe to re-run / upgrade). The bundle also
contains `README-INSTALL.md` with these same steps, plus `LICENSE`, `COPYRIGHT`, and
`THIRD-PARTY-NOTICES.txt`. After installing, jump to [Quick start](#quick-start-after-install).

## Option B — SSMS from a repo clone

**Step 1 — install the framework.** Open `Install_UnitAutogen.sql` in SSMS,
`USE YourDatabase;`, and execute the whole file. It is idempotent (safe to re-run
/ upgrade). You should see `Framework installed successfully.`

**Step 2 — register the parser.** Open `clr/Install-UnitAutogenClr.SSMS.sql` in
SSMS (same database) and execute it. It trusts + creates the two assemblies and the
`TestGen.ParseDatabasePredicates` / `ParseProcedurePredicates` procedures. (~10–15 s;
the file is ~12 MB because it carries the assembly bytes. Run it in **SSMS**, not
`sqlcmd` — `sqlcmd` is slow on the single long binary literal.)

That's it — both steps are pure T-SQL.

## Option C — PowerShell (one command, e.g. CI/CD)

    Install-Module UnitAutogen          # from the PowerShell Gallery
    Install-UnitAutogenDatabase -ServerInstance 'localhost' -Database 'YourDb'

`Install-UnitAutogenDatabase` runs **both** steps — framework + parser — against the
target database (it needs sysadmin once, as above). Then:

    Invoke-UnitAutogen -ServerInstance 'localhost' -Database 'YourDb' -OutputPath './artifacts'

`Invoke-UnitAutogen` calls the in-database parser, generates tests, measures
coverage, and writes Cobertura XML, JUnit XML, and an HTML report.

---

## Quick start (after install)

    -- Parse predicates for a schema (or NULL / '*' for every user schema):
    EXEC TestGen.ParseDatabasePredicates @SchemaFilter = N'dbo';

    -- Generate + cover a whole schema:
    EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = N'dbo';

    -- ...or work one procedure at a time:
    EXEC TestGen.ParseProcedurePredicates @Schema = N'dbo', @ProcName = N'YourProc';
    EXEC TestGen.GenerateTestsForProcedure @SchemaName = N'dbo', @ProcName = N'YourProc', @ExecuteScript = 1;
    EXEC TestGen.RunCoverage               @SchemaName = N'dbo', @ProcName = N'YourProc', @OutputMode = N'TEXT';

See [`docs/quickstart.md`](docs/quickstart.md) for a fuller walkthrough and
[`clr/README.md`](clr/README.md) for parser details.

---

## Notes & limitations

- **No-UNSAFE-CLR servers.** Registering the parser needs `UNSAFE` CLR. tSQLt
  itself already requires CLR, so most servers qualify; but on a server that
  forbids `UNSAFE` outright the parser cannot be installed, and data-shape branches
  fall back to NOT_TESTABLE / string-gen. A retired PowerShell parser remains in
  `powershell/legacy/` for that edge case (unmaintained).
- **Re-running.** Both installers are idempotent. Re-run `Install_UnitAutogen.sql`
  to upgrade the framework; re-run `clr/Install-UnitAutogenClr.SSMS.sql` to
  re-register the parser (e.g. after rebuilding it).
- **Verify.** `scripts/Verify_Coverage.sql` regenerates the sample tests and runs
  coverage.
