# What works, what doesn't — honest scope

UnitAutogen is in Beta. This document is the honest map of what the framework
handles well, what it handles partially, and what it does not handle yet.
We document limitations explicitly because *un*documented limitations are what
destroy trust on a first install. If you hit something here, you'll know it's
expected; if you hit something *not* here, please open a bug report.

## Validated against

Three reference databases at the time of this Beta release:

| Database              | Pass rate          | Coverage          | Autonomy |
| --------------------- | ------------------ | ----------------- | -------- |
| AdventureWorks 2025   | 167 / 167 pass     | 87.1% line / 79.7% branch | 100% |
| Northwind             | 42 / 42 pass       | 100% line / 100% branch   | 100% |
| WideWorldImporters    | 24 / 24 pass / 0 err | 94.2% line / 100% autonomy | 100% |

If you run UnitAutogen on a database in this list and see materially different
numbers, please open a bug report — that's a regression worth investigating.

## Works well

These are the patterns UnitAutogen was designed for and is most reliable at.

**Procedural T-SQL.** Procedures structured around `IF` / `CASE` / `EXISTS`
branches with `INSERT` / `UPDATE` / `DELETE` / `SELECT` statements inside the
branches. This is the core target — generation produces one test per branch
path, coverage probes fire reliably, and the v9.4 snapshot-and-replay
assertions verify each branch's table effect rather than just executing it.

**Multi-condition predicates.** `IF EXISTS (... AND ...)`, `CASE WHEN` value
assignments to locals then branched on, `IN (...)` lists with multiple values,
`LIKE '%pattern%'` predicates, JOIN-aliased columns in EXISTS subqueries.

**Branch coverage.** Real line *and* branch coverage, not just statement
coverage. The reporter distinguishes "branch taken" from "branch present but
never taken" so you can see where your tests don't actually reach.

**NOT-TESTABLE detection.** Procedures the framework cannot meaningfully
auto-test (e.g. single set-based statements with no branching, or procs that
require very specific runtime context) are *detected* and labelled rather
than producing misleading 0% coverage reports. They emit a
`--[@tSQLt:SkipTest]` annotation explaining why.

**In-place test preservation.** If you edit a generated test directly inside
`test_<proc>`, the next regeneration keeps your change. Hash-based detection,
no annotation marker required. See [REFERENCE_GUIDE.md](REFERENCE_GUIDE.md)
for the full mechanism.

## Works with caveats

**Set-based / heavy CTE procedures.** A procedure whose entire body is one
big set-based query (e.g. a recursive CTE) collapses to a single coverage unit
— the framework instruments at statement boundaries and cannot see inside one
statement. You'll get statement-level smoke coverage (the proc ran or it
didn't) but no per-branch breakdown, because there are no branches to
instrument. This is the framework's fundamental limit; documented and intentional.

**Result-set-only branches.** Branches whose only effect is changing the
returned result set (no `INSERT` / `UPDATE` / `DELETE`) get a smoke assertion
("the branch executed") rather than the v9.4 snapshot-and-replay table
assertion. Characterising result sets needs a separate feature (planned).

**Compound bodies.** Branches whose body is a nested IF tree rather than a
single leaf DML statement fall back to smoke assertions for the same reason —
the leaf-DML extractor is conservative.

## Not yet supported

**Dynamic SQL.** `EXEC sp_executesql` and `EXEC (@sql)` bodies are opaque to
the parser; the framework will not generate per-branch tests for them. The
procedure will likely be flagged NOT TESTABLE.

**Functions and triggers.** UnitAutogen targets stored procedures specifically.
Scalar functions, table-valued functions, and triggers are out of scope for
this release line.

**Multi-database / cross-server procedures.** Procedures that reference objects
in other databases or linked servers may parse but won't seed correctly.

**SQL Server versions before 2017.** Some Extended Events behaviour the
coverage instrumenter relies on changed in 2017; older versions are
unsupported.

**Databases other than Microsoft SQL Server.** UnitAutogen is SQL-Server-only.
Azure SQL Database (single database) and Azure SQL Managed Instance should
work but are not yet officially validated. PostgreSQL, MySQL, Oracle and
others are not targets — different testing frameworks would be needed.

## Reporting something not on this list

If you hit a failure mode that isn't documented here, please [open an
Issue](../../../issues/new/choose) and use the bug-report template. The list
above will grow based on what real users find — that's the whole point of the
Beta.
