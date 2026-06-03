# UnitAutogen

> **Built on tSQLt — auto-generated unit tests with real branch coverage.**

![UnitAutogen coverage report: 94.9% line, 94.4% branch, 100% autonomous on a full AdventureWorks2025 sweep](assets/hero-coverage.png)

UnitAutogen is a framework for SQL Server that **reads a stored procedure, generates a complete tSQLt unit-test class for it, and reports real line *and* branch coverage** of the test run. Point it at a procedure; minutes later you have a runnable test class that exercises every IF / CASE / EXISTS path and a coverage report that tells you what was actually hit.

It is built on top of the open-source [tSQLt](https://tsqlt.org) framework. The tests it generates run under tSQLt and produce tSQLt-native results.

---

**Status: Beta — v0.9.0**
Validated end-to-end against AdventureWorks, Northwind, and WideWorldImporters. Expect rough edges on production schemas it hasn't seen. See [docs/what-works.md](docs/what-works.md) for the honest scope.

---

## See it in action

One command generates the tests, runs them, measures coverage, and emits the CI-standard artifacts your pipeline already understands — Cobertura (coverage), JUnit (test results), and a human-readable HTML report:

![End to end: one PowerShell command to coverage report to Cobertura and JUnit](assets/end-to-end.png)

---

## Why it exists

The SQL Server testing ecosystem already has unit-testing frameworks (tSQLt, Redgate SQL Test, Devart dbForge Unit Test) and coverage tools (SQLCover, SQLServerCoverage). Every one of them assumes a human has already written the tests. **UnitAutogen is the missing front half.** It writes the tests, runs them, and measures real branch coverage — converting "we should write tests for these 200 legacy procs" from a person-months task into an afternoon's curation.

![Branch coverage: 50% with line-only tools versus 94.4% with UnitAutogen on the same tests](assets/branch-before-after.png)

## Requirements

- SQL Server 2017 (MSSQL14) or later
- tSQLt **v1.0.7597.5637 (Oct 2020) or later** installed in the target database (`SELECT tSQLt.Info();` to check)
- Permissions: `CREATE PROCEDURE`, `CREATE FUNCTION`, `CREATE SCHEMA` on the target database

## Quick start

Run these in SSMS with **SQLCMD Mode** on (Query → SQLCMD Mode) so the `:r`
includes resolve, from the repo root.

```sql
-- 1. Install the framework into your database (idempotent; safe to re-run)
USE YourDatabase;
GO
:r Install_UnitAutogen.sql

-- 1b. Register the single in-database (SQLCLR) predicate parser.
--     Needs sysadmin once + 'clr enabled' = 1. (Run clr\Install-UnitAutogenClr.SSMS.sql
--     directly in SSMS if you're not in SQLCMD mode.)
:r clr\Install-UnitAutogenClr.SSMS.sql

-- 2. Parse predicates (fills TestGen.PredicateInbox for data-shape branch seeding)
EXEC TestGen.ParseDatabasePredicates @SchemaFilter = N'dbo';   -- or NULL/'*' = all schemas

-- 3. Generate, run, and report coverage for ONE procedure - one call
EXEC TestGen.GenerateAndRunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'YourProcedure',
     @OutputMode = N'HTML';     -- or N'TEXT'

-- 4. Or do it for the WHOLE database in one call (CI/CD entry point)
EXEC TestGen.GenerateAndCoverDatabase
     @OutputMode = N'HTML';
```

That's the entire happy path. The two procedures above generate the test
classes, run them, and print a coverage report - line and branch percentages
plus a list of any uncovered lines.

## CI/CD Integration

UnitAutogen emits **Cobertura XML** (coverage) and **JUnit XML** (test results)
natively consumed by Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube —
no custom plugins required.

**PowerShell wrapper — one call exports all three output files:**

```powershell
Import-Module './powershell/UnitAutogen.psm1'   # auto-installs SqlServer module

Invoke-UnitAutogen `
    -ServerInstance 'sql01' `
    -Database       'YourDatabase' `
    -OutputPath     './artifacts'

# Writes:
#   artifacts/coverage.xml          ← Cobertura XML for coverage tools
#   artifacts/test-results.xml      ← JUnit XML for test result dashboards
#   artifacts/coverage-report.html  ← Human-readable HTML report
```

Or call the SQL procs directly from SSMS:

```sql
EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'COBERTURA';  -- Cobertura XML
EXEC TestGen.GetCoverageCoberturaXml;   -- re-export without re-running
EXEC TestGen.GetTestResultsJunitXml;    -- JUnit XML
EXEC TestGen.GetCoverageHtmlReport;     -- HTML report
```

Ready-to-use pipeline files are in the [`ci/`](ci/) folder:
[`ci/azure-pipelines.yml`](ci/azure-pipelines.yml) and
[`ci/github-actions.yml`](ci/github-actions.yml).

Full usage guide: [`powershell/USAGE.md`](powershell/USAGE.md).

## Documentation

| Document                                          | When to read it                                                                                |
|---------------------------------------------------|------------------------------------------------------------------------------------------------|
| [docs/quickstart.md](docs/quickstart.md)          | First 15 minutes - install, generate, see a coverage report.                                   |
| [docs/EASY_USAGE.md](docs/EASY_USAGE.md)          | The four commands that cover 80% of normal usage. Start here after the quickstart.             |
| [docs/ADVANCED_USAGE.md](docs/ADVANCED_USAGE.md)  | Every user-facing method, every switch, the custom-test-class pattern.                         |
| [docs/REFERENCE_GUIDE.md](docs/REFERENCE_GUIDE.md)| Complete reference - every method, the coverage architecture, troubleshooting, feature history.|
| [docs/what-works.md](docs/what-works.md)          | Honest scope - what UnitAutogen handles well, partially, or not yet.                           |
| [docs/architecture.md](docs/architecture.md)      | How coverage instrumentation works under the hood.                                             |
| [docs/strong-assertions.md](docs/strong-assertions.md) | The snapshot-and-replay assertion mechanism for branch tests.                             |
| [docs/advanced-snippets.sql](docs/advanced-snippets.sql) | Paste-ready SQL for the advanced workflows above.                                        |
| [INSTALL.md](INSTALL.md)                          | Full installation options, upgrade paths, modular install.                                     |
| [powershell/USAGE.md](powershell/USAGE.md)        | PowerShell wrapper — CI/CD usage, Windows/SQL auth, Azure DevOps and GitHub Actions YAML.     |

## What works, what doesn't

Honest scope is in [docs/what-works.md](docs/what-works.md). Short version: UnitAutogen shines on procedural T-SQL with `IF` / `CASE` / `EXISTS` branching. Set-based / heavy CTE / dynamic-SQL procedures fall back to statement-level smoke coverage. NOT-TESTABLE procedures are detected and labelled rather than producing misleading 0% reports.

## How it works

In one paragraph: UnitAutogen parses your procedure body, builds a path table of every IF / CASE / EXISTS branch, generates a test per path with appropriate seed data, instruments a copy of the procedure with Extended Events line probes, runs the test class, captures hit lines from the XEvent file, and produces a line/branch coverage report. v9.4 added snapshot-and-replay assertions so each branch's table effect is verified, not just executed. v10 added universal generation, NOT-TESTABLE detection, and in-place test preservation across regenerations.

Full architecture: [docs/architecture.md](docs/architecture.md).

## Status and roadmap

This is the **first public release** of UnitAutogen, labelled Beta because real-world testing only happens at scale once strangers run it on their own schemas. The engineering has been validated on three reference databases at high coverage, but you will surface things on production schemas that nobody has tried. Bug reports are the most valuable thing you can give us right now.

**Shipped in this release:**

- Cobertura XML + JUnit XML output — natively consumed by Azure DevOps, GitHub Actions, Jenkins, GitLab CI, SonarQube
- HTML coverage report re-export without re-running tests
- PowerShell wrapper module (`UnitAutogen.psm1`) with Windows and SQL auth support
- Ready-to-use Azure DevOps and GitHub Actions pipeline YAML samples

**What's coming next (your input shapes the order):**

- Broader stored procedure pattern support (dynamic SQL, OUTPUT parameters, CLR)
- SonarQube quality gate integration guide
- NuGet package for easier pipeline consumption

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). External *code* contributions are not being accepted in Beta — but bug reports, feature suggestions, and feedback are essential and very welcome.

## Licence

UnitAutogen is licensed under the **GNU Affero General Public License v3.0** (see [`LICENSE`](LICENSE) and [`COPYRIGHT`](COPYRIGHT)).

A separate **commercial licence**, without the AGPL's copyleft obligations, is available for organisations that prefer it. Contact **licensing@unitautogen.com**.

## Support

- **Bug reports & feature requests:** [open an Issue](../../issues/new/choose) on this repository.
- **Questions / general:** open a Discussion, or email **hello@unitautogen.com**.
- **Security / vulnerability reports:** see [SECURITY.md](SECURITY.md) or email **security@unitautogen.com** privately.
- **Commercial licensing:** **licensing@unitautogen.com**.

## Acknowledgements

UnitAutogen builds on the excellent [tSQLt](https://tsqlt.org) framework by Sebastian Meine and the tSQLt project — without it, none of this works. The framework is developed and tested against Microsoft's [AdventureWorks](https://github.com/microsoft/sql-server-samples), [Northwind](https://github.com/microsoft/sql-server-samples), and [WideWorldImporters](https://github.com/microsoft/sql-server-samples) sample databases; gratitude to Microsoft for keeping those public.
