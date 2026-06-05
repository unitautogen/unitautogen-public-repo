# UnitAutogen v0.10.0 (beta)

Auto-generated tSQLt unit tests with **real branch coverage** for SQL Server — now with side-effect (DML) assertions, table-valued-parameter support, and a database-wide honesty pass that removes false failures.

This is the largest release since the public launch: it asserts what your procedures *write*, not just what they *return*, and it tests whole classes of procedures that were previously skipped — while making sure every result is either a genuine pass or a clearly-labelled, actionable skip.

---

## ✨ New capabilities

**DML effect assertions — test what the procedure changes.**
A modifying procedure's per-table write effect is now asserted with **exact row counts**, measured at generation time by running the procedure under its own reverse-predicate seed (inside a rolled-back transaction). Covers `INSERT` (both `VALUES` and `SELECT`), `UPDATE`, and `DELETE`. If the generated seed doesn't drive a write, the test is **skipped and names the untouched table**, so you know to fix the seed or the procedure — never a silent pass on an unasserted side effect.

**`DELETE` and `INSERT … SELECT` branch coverage.**
The snapshot-and-replay branch assertions now handle a single-target `DELETE` and `INSERT … SELECT`, not just `UPDATE` / `INSERT … VALUES`.

**Table-valued parameters are auto-tested.**
A procedure that takes a TVP used to be `NOT_TESTABLE` ("Operand type clash"). UnitAutogen now **constructs and seeds a table variable** of the parameter's type and passes it, and the coverage instrumenter emits table parameters schema-qualified and `READONLY` so the instrumented copy compiles.

**Row-level security (RLS) tables can be faked.**
`SafeFakeTable` now drops a `SECURITY POLICY` (and its predicate-function chain) before faking, so RLS-protected tables no longer doom the test with *"participates in enforced dependencies."*

---

## 🎯 Honesty pass — no false red

Every non-pass is now a genuine pass, a labelled skip, or a clear `NOT_TESTABLE` — never a failure caused by the framework rather than your code.

- **Error-expectation tests are no longer over-generated.** A `CATCH`-block re-throw is no longer mistaken for input validation, and a parenthesis-less `THROW n, 'msg', state;` is now detected — so "must reject" / "raises error" tests fire only for genuine validation guards.
- **Unsatisfiable inputs skip honestly.** When the generated happy / boundary / `NULL` inputs can't satisfy a procedure's own validation, the affected tests carry a `SkipTest` annotation with a clear reason instead of failing by construction.
- **`FOR JSON` / `FOR XML`** result sets no longer error the row-baseline test (they can't be captured via `INSERT … EXEC`); that single test is skipped for such procedures.

---

## ✅ Validation

Full `GenerateAndCoverDatabase` sweeps across three real databases — **zero false failures**:

| Database | Tests | Pass | Fail | Error | Line | Branch |
|---|---|---|---|---|---|---|
| HighValueCustomer | 20 | 19 | **0** | **0** | 89.5% | 85.7% |
| AdventureWorks2025 | 91 | 81 | **0** | **0** | 94.9% | 94.4% |
| WideWorldImporters | 71 | 57 | **0** | **0** | 91.2% | 66.7% |

Every remaining non-pass is a transparent skip, `NOT_TESTABLE`, or coverage deferral with a reason in the report.

---

## ⚠️ Known, honest limitations (reported transparently, not failures)

- **Multi-statement scalar functions `WITH EXECUTE AS OWNER`** can hit a coverage deferral ("instrumenter could not produce a compiling `_cov`") — the shadow-transform for that specific shape is a future enhancement. Reported as `gen=N`, not a failure.
- **Temporal / memory-optimized / full-text** procedures remain `NOT_TESTABLE` by nature (tSQLt can't fake those tables); turn `SYSTEM_VERSIONING OFF` on temporal tables to make those procedures testable.
- A few **unseeded single branches** show as honest 0%-branch coverage (reverse-seed-the-branch territory) rather than red.

---

## 📦 Install

```powershell
Install-Module UnitAutogen
```

Or update an existing install:

```powershell
Update-Module UnitAutogen
```

Requires SQL Server with tSQLt; the in-database (SQLCLR) predicate parser is registered at install (`sysadmin` once + `clr enabled = 1`). See the README and `docs/` for the quickstart and CI/CD report exporters (Cobertura, JUnit, HTML).

---

**Full changelog:** see [`CHANGES.md`](https://github.com/unitautogen/unitautogen-public-repo/blob/main/CHANGES.md).
**Website:** [unitautogen.com](https://unitautogen.com)
