# UnitAutogen v0.11.0-beta

**Search-based gate seeding** — UnitAutogen now covers branch gates that no prior version (and
no static reverse-seeder) could reach, automatically, as part of the normal sweep.

## What's new

Some branch gates aren't decidable from the predicate text alone — the value that drives them is
produced by code the static seeder can't invert: a loop accumulator, a per-row product, an
aggregate band, or a condition coupled to an earlier gate. v0.11 covers these with a **numeric
oracle**: it instruments the procedure, drives candidate seeds, reads the controlling local's
live value through an XEvent probe (rollback-immune, fires on every loop iteration), and
**measure-and-interpolates** the seed that lands each arm. A verified seed becomes a real tSQLt
test; a genuinely unreachable or environmental gate is an honest `NOT_TESTABLE` — never a faked
pass.

**Archetypes auto-derived** (no configuration):

| Archetype | Example gate |
|---|---|
| Aggregate-over-table | `@x = AVG(col) FROM t … IF @x > 80` |
| Scalar-from-table | `@x = col FROM t … IF @x = 0` |
| Null-check | `IF @x IS [NOT] NULL` |
| Bare parameter | `IF @IsDryRun = 0` |
| Per-row value / categorical | `IF @CurrentVolume <= 0`, `IF @Direction = 'S'` |
| **Coupled cross-gate** | `IF @AdjustedValue > 100000 AND @Phase = 'C'` (recursive prefix reuses the ancestor gate's witness) |
| **Loop-count** | `IF @x > 3` where `@x` is a loop trip-count accumulator |

## Measured impact (real procedures, full sweep)

- A coupled / per-row reconciliation procedure: **1 of 13 → 13 of 13** branch gates handled
  (36.7% → 83.3% line, 18.8% → 87.5% branch).
- A loop-accumulator gate: **0% → 100%** line and branch.
- Database totals moved up with **no regressions** on already-covered procedures.

## Notes

- Runs automatically inside `Invoke-UnitAutogen` / the database sweep — no new step.
- Pure T-SQL; **no CLR rebuild** required. Re-run the installer and sweep.
- The search layer is **collation-safe** (works on databases whose collation differs from the
  server default).
- Honest residue is still labelled, not hidden: error-handler (`CATCH`) branches gated on
  `@@TRANCOUNT`, full-text procedures, and unsatisfiable arms are reported as `NOT_TESTABLE` /
  by-design partial coverage.

## Install

Re-run `Install_UnitAutogen.sql` (or install the module from the PowerShell Gallery), then run
your normal sweep. Full history in `CHANGES.md`.
