# UnitAutogen

> **Built on tSQLt — auto-generated unit tests with real branch coverage.**

UnitAutogen is a framework for SQL Server that **reads a stored procedure, generates a complete tSQLt unit-test class for it, and reports real line *and* branch coverage** of the test run. Point it at a procedure; minutes later you have a runnable test class that exercises every IF / CASE / EXISTS path and a coverage report that tells you what was actually hit.

It is built on top of the open-source [tSQLt](https://tsqlt.org) framework. The tests it generates run under tSQLt and produce tSQLt-native results.

---

**Status: Beta — v0.9.0**
Validated end-to-end against AdventureWorks, Northwind, and WideWorldImporters. Expect rough edges on production schemas it hasn't seen. See [docs/what-works.md](docs/what-works.md) for the honest scope.

---

## Why it exists

The SQL Server testing ecosystem already has unit-testing frameworks (tSQLt, Redgate SQL Test, Devart dbForge Unit Test) and coverage tools (SQLCover, SQLServerCoverage). Every one of them assumes a human has already written the tests. **UnitAutogen is the missing front half.** It writes the tests, runs them, and measures real branch coverage — converting "we should write tests for these 200 legacy procs" from a person-months task into an afternoon's curation.

## Requirements

- SQL Server 2017 (MSSQL14) or later
- tSQLt **v1.0.7597.5637 (Oct 2020) or later** installed in the target database (`SELECT tSQLt.Info();` to check)
- Permissions: `CREATE PROCEDURE`, `CREATE FUNCTION`, `CREATE SCHEMA` on the target database

## Quick start

```sql
-- 1. Install the framework into your database (idempotent; safe to re-run)
USE YourDatabase;
GO
:r Install_UnitAutogen.sql

-- 2. Generate, run, and report coverage for ONE procedure - one call
EXEC TestGen.GenerateAndRunCoverage
     @SchemaName = N'dbo',
     @ProcName   = N'YourProcedure',
     @OutputMode = N'HTML';     -- or N'TEXT'

-- 3. Or do it for the WHOLE database in one call (CI/CD entry point)
EXEC TestGen.GenerateAndCoverDatabase
     @OutputMode = N'HTML';
```

That's the entire happy path. The two procedures above generate the test
classes, run them, and print a coverage report - line and branch percentages
plus a list of any uncovered lines.

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

## What works, what doesn't

Honest scope is in [docs/what-works.md](docs/what-works.md). Short version: UnitAutogen shines on procedural T-SQL with `IF` / `CASE` / `EXISTS` branching. Set-based / heavy CTE / dynamic-SQL procedures fall back to statement-level smoke coverage. NOT-TESTABLE procedures are detected and labelled rather than producing misleading 0% reports.

## How it works

In one paragraph: UnitAutogen parses your procedure body, builds a path table of every IF / CASE / EXISTS branch, generates a test per path with appropriate seed data, instruments a copy of the procedure with Extended Events line probes, runs the test class, captures hit lines from the XEvent file, and produces a line/branch coverage report. v9.4 added snapshot-and-replay assertions so each branch's table effect is verified, not just executed. v10 added universal generation, NOT-TESTABLE detection, and in-place test preservation across regenerations.

Full architecture: [docs/architecture.md](docs/architecture.md).

## Status and roadmap

This is the **first public release** of UnitAutogen, labelled Beta because real-world testing only happens at scale once strangers run it on their own schemas. The engineering has been validated on three reference databases at high coverage, but you will surface things on production schemas that nobody has tried. Bug reports are the most valuable thing you can give us right now.

What's coming next (your input shapes the order):

- Polished CI/CD plug-ins for GitHub Actions and Azure DevOps Pipelines
- HTML coverage dashboards and SonarQube / Cobertura output
- A Pro tier with the above integrations for commercial users (open core stays free)

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
