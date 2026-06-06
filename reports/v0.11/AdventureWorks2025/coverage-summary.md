# UnitAutogen v0.11 — AdventureWorks2025 coverage baseline

**2026-06-06 06:16:41** · 45 objects (0 failed generation, 2 not testable)

| Metric | Value |
|---|---|
| Line coverage | **96.6%** (112/116) |
| Branch coverage | **97.3%** (71/73) |
| Tests | 270 — 233 pass, 0 fail, 0 err, 37 skip |
| Autonomy | 100% (270/270 framework-owned) |

## vs prior baseline (2026-06-05 05:23, pre-v0.11-search on this DB)

| | Before | Now |
|---|---|---|
| DB line | 93.1% (108/116) | 96.6% (112/116) |
| DB branch | 93.2% (68/73) | 97.3% (71/73) |
| pz.LoopLocalGate | 0% / 0% (0 pass / 3 skip) | 100% / 100% (3 pass / 2 skip) |

Driver: the v0.11 **LOOPCOUNT** archetype (row-count knob) closed `pz.LoopLocalGate` (loop
accumulator `IF @x>3`, `@x = COUNT(pz.Orders)`); seeds 12 rows for arm A and 1 row for arm B.
The collation hardening (DATABASE_DEFAULT on search temp columns) was required for the
search-seeding to run at all on this DB (collation Latin1_General_CI_AS <> server default).

## Honest residue (uncovered, by design / known)
- `HumanResources.uspUpdateEmployeeHireInfo` 66.7% line / 0% branch — known unseeded UPDATE branch.
- `dbo.ufnGetContactInformation` 83.3% — 1 uncovered line.
- `pz.ContradictionGate` 50% — unsatisfiable TRUE arm by design (no-ghost guarantee).
- `dbo.uspLogError`, `dbo.uspSearchCandidateResumes` — NOT_TESTABLE (CATCH-context helper / full-text).
