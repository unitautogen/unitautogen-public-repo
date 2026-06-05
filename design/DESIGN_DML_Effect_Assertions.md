# DESIGN — DML / side-effect effect assertions (per-table count, reverse-seeded)

Status: **design locked, build in progress.** Phase 1 (interim) built + content-aware.
**Phase 2 capture-based exact per-table counts BUILT + validated** on
HighValueCustomer (GetVIPCustomerAnalyticsReport: the audit insert now asserts
AuditExecutionLog = 6 exactly, read-only tables held at 5, test passes; AssessCustomer
count-stable still 6/6 — no regression). New proc `TestGen.CaptureExpectedCounts`;
skip-and-highlight + side-effect guards in. **Leaf parser + branch replay extended to
DELETE and INSERT…SELECT** (`TestGen.ExtractLeafDml` + the v9.4 snapshot-and-replay):
unit-verified (DELETE/INSERT…SELECT parse with correct {{TARGET}} rewrite; DELETE…JOIN
and two-DML bodies rejected; UPDATE/INSERT VALUES regressions intact), compiles + runs
with no regression. The replay only engages for branches `AnalyzeBranchPaths` emits a
REPLAY path for (table/column/EXISTS-gated — the reverse-seeding cases); a pure
`IF @param = <literal>` gate produces no REPLAY path (pre-existing, same for UPDATE),
so end-to-end DELETE/INSERT…SELECT branch assertions land on real column-gated procs in
the broad sweep. Phase 3 = MERGE. **Pending:** broad AdventureWorks + WideWorldImporters
sweep. Will ship all phases under a single version bump (no mid-work releases).

---

## 1. Problem

A procedure that returns a result set **and** writes data (a "mixed" proc) had its
write side-effect go **unasserted**. Concrete case found on
`HighValueCustomer.GetVIPCustomerAnalyticsReport`: it ends its TRY block with
`INSERT INTO AuditExecutionLog (...) VALUES (...)` — one audit row per run — but the
generated `test ... touches only mocked tables` test only **PRINTed** the per-table
before/after row counts. No assertion. So a regression that removes/breaks the audit
write, or a seed that never drives it, **passed silently** — the exact false-confidence
failure the tool exists to expose.

Root cause: the generator had two row-count strategies — "counts HELD" (count-stable /
UPDATE-only procs) and "print only" (INSERT/DELETE/MERGE procs, because a held
assertion would false-fail). It stopped at "counts change → don't assert" instead of
"counts change → assert the EXPECTED change."

---

## 2. Core principle

**Every modifying procedure must assert its per-table effect, and the assertion must
be driven by data that actually exercises the write.** A test with only an isolation
(TRY/CATCH) check is barely a test.

Two truths shape the whole design:
1. To assert a count you must know **what it should equal** — so the generator must
   *determine* the expected per-table count.
2. The DML only fires when the seed **satisfies the procedure's predicates** — so the
   data must come from **reverse-predicate seeding**, the tool's core capability, not a
   generic sample seed.

---

## 3. Where each case lives (seed locality)

The assertion belongs wherever the seed that drives the DML lives:

| DML shape | Seed source | Test family |
|---|---|---|
| **Unconditional** write (e.g. the audit insert) | any seed fires it — generic happy-path seed is fine | the `touches only mocked tables` isolation test |
| **Predicate-gated** write (`IF <cond> INSERT…`, `WHERE`-filtered `INSERT…SELECT`, conditional `DELETE`) | must be **reverse-predicate-seeded** so the gate is satisfied and the write fires | the **branch tests** (module 34 / v9.4 strong assertions), which already reverse-seed each branch |

Why this split matters: the generic isolation seed sets e.g. `Status='SampleText_1'`,
but `GetVIPCustomerAnalyticsReport`'s report path is gated on `Status='COMPLETED'` — so
the generic seed matches zero rows and the gated write never fires. Only reverse
seeding constructs data that satisfies the gate. The audit insert is unconditional, so
the generic isolation seed captured it fine in the spike.

---

## 4. The capture mechanism (SPIKE PASSED)

To know the expected per-table count, **capture it at generation time** by running the
proc once under the seed and measuring — deterministic because we own the seed.

Spike result on `GetVIPCustomerAnalyticsReport` (HighValueCustomer): captured
`AuditExecutionLog` 3→4 (the +1), read-only tables held, `@@TRANCOUNT` unwound to 1,
no error, real tables restored after rollback.

**Mechanism (validated):**
1. Generator assembles the test's **exact** setup block — same `SafeFakeTable` calls,
   same seeds, same `SpyProcedure` calls, same happy args (fidelity is automatic: it's
   literally the test's setup).
2. Run that block inside the **generator's own `BEGIN TRAN`**, capturing each faked
   table's resulting `COUNT(*)` into a **table variable**.
3. `ROLLBACK`. The table variable **survives** the rollback (rollback doesn't touch
   table variables); the fakes/seed/writes are all undone; real tables restored.
4. Use the captured numbers to emit the per-table assertions.

**Do NOT capture via `tSQLt.Run`.** tSQLt's rollback puts the counts behind the
transaction; recovering them would need to scrape `PRINT` output via an external
PowerShell orchestrator — reintroducing the PowerShell dependency the project removed.
The generator-owned transaction keeps it pure-T-SQL / SSMS-native and lets the
generator read the counts directly.

**Result-set noise:** wrap the proc's `EXEC` in `INSERT #sink EXEC …` so the proc's
returned result set is discarded (the generator already knows the result-set shape to
build `#sink`).

---

## 5. The emitted test

For each faked table the proc writes to, emit a plain per-table assertion:

```sql
EXEC tSQLt.AssertEquals @Expected = <captured count>, @Actual = (SELECT COUNT(*) FROM <table>);
```

Read-only tables (never written) → assert **held** (count == seeded count). This also
catches stray writes.

No content hashes, no "at least one changed", no `ISNULL` sentinels in the final form —
just per-table counts compared to known numbers. (Phase 1's content-aware heuristic is
the interim; phases 2–3 replace it.)

---

## 6. Skip-and-highlight (when a write didn't fire)

If the capture run shows a **zero delta on a table the proc writes to**, the seed did
not drive that write (reverse seeder couldn't satisfy the gate, or the branch wasn't
reached). The generator KNOWS this at generation time. Then:

- **Generate the COMPLETE test anyway** — write out the per-table assertions for all
  involved tables, so the developer sees exactly what was expected.
- **Mark the whole test `Skipped`**, with a reason that **names the specific untouched
  table(s)**:
  > "UnitAutogen could not determine a seed that exercises the INSERT/DELETE into
  > `dbo.AuditExecutionLog` — its row count did not change during generation. Adjust the
  > seed so it drives that write, or correct the procedure if it should; then remove
  > this annotation."

This is the honest NOT_TESTABLE pattern: don't bake a misleading "unchanged" assertion
(false pass) and don't FAIL (blames the proc for our seeding gap). The user reads the
complete-but-skipped test, sees which table was missed, and acts: **fix the seed** or
**fix the procedure**.

(Remember to quote-escape the SkipTest reason — apostrophes break the annotation; see
the v0.9.12 fix.)

---

## 7. Side-effect guards (safety of the capture run)

The capture runs the real proc, so:
1. **Replicate the test's spies** in the capture (it already does — same setup block),
   so called procs don't execute for real and the counts match what the test reproduces.
2. **Non-transactional operations are NOT undone by rollback**: `sp_send_dbmail`,
   `SEQUENCE` consumption (`NEXT VALUE FOR`), linked-server / `xp_cmdshell` / external
   calls, global `##temp`. Detect these in the proc body and **skip the capture** for
   such procs (generate the test marked "could not safely capture") rather than perform
   a real-world action at generation time.
3. **Error path:** if the proc errors during capture, its own CATCH→ROLLBACK unwinds the
   generator's transaction. Guard with an outer `TRY/CATCH` + `@@TRANCOUNT` check; on a
   capture error, bake no numbers → the test is skipped with the "couldn't determine
   seed" reason. Graceful, never corrupting.

---

## 8. Phasing (single release at the end)

- **Phase 1 (built, interim, unreleased):** `touches only mocked tables` for a
  count-changing proc asserts at least one faked table changed by **row count OR
  content** (content via `CHECKSUM_AGG`, to avoid the net-zero false-fail). Catches
  "proc did nothing"; cannot catch a partial regression. Placeholder until phase 2.
- **Phase 2:** capture-based **exact per-table count** assertions; reverse-seeded;
  skip-and-highlight on zero deltas; side-effect guards. Covers INSERT (VALUES and
  SELECT) and DELETE. Replaces the phase-1 heuristic.
- **Phase 3:** `MERGE`.

Each phase validated on AdventureWorks + WideWorldImporters + HighValueCustomer before
the others. **No version bump or PSGallery publish until all phases are done and
validated — one bump, one release-notes entry, one bundle.**

---

## 9. Code locations

- `TestGen.GenerateTestsForProcedure` (Install_UnitAutogen.sql):
  - the `touches only mocked tables` test: shared count/hash capture (~5527–5610), the
    count-stable IF branch (~5614), the count-changing ELSE branch (phase-1 assertion).
  - existing branch-DML machinery (snapshot-and-replay) at ~6822–6929 — extend this for
    reverse-seeded conditional DML (DELETE, INSERT…SELECT gaps).
- DML leaf parser ~2565–2686 — currently recognizes UPDATE and INSERT…VALUES only;
  rejects INSERT…SELECT; no DELETE/MERGE. Extending it is part of phases 2–3.

---

## 10. Residual / known limits

- Content-hash (phase 1) can collide (rare false-negative) and skips LOB-only tables.
- Exotic non-transactional side effects → capture skipped by design (section 7.2).
- `MERGE` deferred to phase 3.
