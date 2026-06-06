# DESIGN — Search-based seeding for loop-local & coupled branch gates

Status: **design — build not started.** Targets 0.11 (new capability, not a 0.10.x patch).
Reuses the gen-time-execution harness (`CaptureExpectedCounts` / `ProbeHappyPath`) and the
coverage instrumenter (`InstrumentProcedure` + branch-hit registry). Mostly T-SQL
orchestration; the C# ScriptDom parser gains a small "unresolved gate + operand locals +
candidate literals" signal.

**Design driven HARDEST-CASE-FIRST** (per user direction 2026-06-05): rather than validate on
the trivial monotone counter (`pz.LoopLocalGate`), the engine is designed against the nastiest
real gate available — `HighValueCustomer.dbo.usp_ReconcileTradedPositions` — so the architecture
is proven where it actually strains. The easy cases then fall out as degenerate specialisations.

---

## 1. The benchmark: usp_ReconcileTradedPositions

A ~150-line reconciliation proc: account-validity gate, a 3-way AVG-over-a-date-window risk
gate that sets a phase flag, a row-by-row WHILE loop over a `#temp` built from a faked source,
per-row dirty-data and direction/value gates, a dry-run vs real-execution split, OUTPUT param,
RETURN codes, RAISERROR, and real DML side-effects.

NOTE: in HighValueCustomer the proc references **7 tables that do not exist** (created via
deferred name resolution). It is parse-only until `examples/HardCase/00_..._tables.sql` is
installed; only then can it be FakeTable'd / instrumented / run.

### Gate inventory (what each arm demands)

| # | Gate | Hard arm requires | Class |
|---|------|-------------------|-------|
| G1 | `@IsActiveAccount IS NULL` / `=0` / else | `TradingAccounts` row absent / IsActive=0 / =1 | local <- **SELECT-assignment** of a scalar col (not `DECLARE =`; current seeder gap) + RAISERROR/RETURN arm |
| G2 | `@MFI_Score >80` / `<20` / else | seed `MarketIndicators` so **AVG** over `MetricDate >= @CutoffDate-14` lands in each band | 3-way aggregate via SELECT-assignment, **coupled to a param date window** |
| G3 | `WHILE @LoopCounter <= @MaxRows` | seed `RawPositionIngest` rows matching `@AccountID AND SettleDate<=@CutoffDate AND IsReconciled=0` so the `#temp` count >= 1 | **loop entry; count from a `#temp` built from a faked source under a 3-predicate param-coupled WHERE** |
| G4 | `@CurrentVolume<=0 OR @CurrentPrice<=0` | seed current row Volume/Price either side | per-row value gate on loop-locals (OR) |
| **G5a** | `@AdjustedValue>100000 AND @WavePatternPhase='C'` | **simultaneously**: G2 AVG>80 (sets Phase='C') **and** a row with `Volume*Price*1.50 > 100000` | **CROSS-GATE COUPLING across 2 tables; the multiplier is set by the earlier gate** |
| G5b/c | S `>50000` -> MANUAL_REVIEW; B `>250000` -> FLAG_LARGE_CAP; else REJECT | seed row direction ('S'/'B'/other) + value | nested per-row value gates, **categorical literal** from inner equality |
| G6 | `@IsDryRun = 0` vs else | pass the param both ways (real arm does UPDATE+INSERT) | trivial param + DML side-effects |

### Measured baseline (live parse on HighValueCustomer, 2026-06-05, after HardCase tables)

`EXEC TestGen.ParseProcedurePredicates 'dbo','usp_ReconcileTradedPositions'` -> 13 branch gates;
**only 1 resolves** (a seed plan). The other 12 are UNRECOGNISED with NULL seed plans:

| Line | Gate | Label | Status / UnsupportedReason |
|------|------|-------|----------------------------|
| L77 | `@LoopCounter <= @MaxRows` | G3 | **RESOLVED** (PREDTREE; @MaxRows inlined to count subquery) |
| L127 | `@IsDryRun = 0` | G6 | unrec: "comparison does not involve aggregate/scalar subquery" -> **bare-param gap, cheap win** |
| L27 | `@IsActiveAccount IS NULL` | G1a | unrec: "IS NULL not over a scalar subquery" (SELECT-assignment not traced) |
| L32 | `@IsActiveAccount = 0` | G1b | unrec: no subquery |
| L44 | `@MFI_Score > 80` | G2hi | unrec: no subquery -> numeric oracle (AVG band) |
| L49 | `@MFI_Score < 20` | G2lo | unrec -> numeric oracle |
| L88 | `@CurrentVolume<=0 OR @CurrentPrice<=0` | G4 | unrec: "not in v0.10 grammar" -> per-row value |
| L103 | `@CurrentDirection = 'S'` | G5dS | unrec -> categorical literal |
| L105 | `@AdjustedValue>100000 AND @WavePatternPhase='C'` | **G5a** | unrec: "not in grammar" -> **coupled numeric-oracle + path-prefix** |
| L109 | `@AdjustedValue > 50000` | G5b | unrec -> per-row value |
| L114 | `@CurrentDirection = 'B'` | G5dB | unrec -> categorical literal |
| L116 | `@AdjustedValue > 250000` | G5c | unrec -> per-row value |
| L62 | `OBJECT_ID('tempdb..#PendingTrades') IS NOT NULL` | — | unrec -> **genuine NOT_TESTABLE** (environmental temp-guard, no seedable axis) |

Headline: **today's coverage on a real production proc is 1/13 branch gates.** That is the gap
this subsystem closes, with a concrete before/after. Two non-search wins land first (G6 bare
param; G1 SELECT-assignment tracing); L62 is a natural honest-residue case beside the synthetic
`pz.UnseedableLoopGate`.

## 2. What the benchmark forces (and the easy case hid)

`pz.LoopLocalGate` is monotone, 1-D, single-table, no ancestor coupling — it flips at the row
extremes. Designing to it yields a boolean-arm + probe-extremes seeder that **dies on G5a**.
The benchmark forces four requirements:

1. **Numeric oracle, not boolean.** G2/G5a hinge on *values* (`@MFI_Score`, `@AdjustedValue`),
   not just which arm fired. Observe the value, not only the branch. (Capture mechanism chosen:
   **instrument a dedicated capture point** that writes the gate's operand locals to the
   rolled-back capture channel — most accurate, sees in-scope loop locals.)
2. **Path-prefix fixing.** G5a sits under a chain: account active -> AVG>80 (Phase='C') -> loop
   enters -> direction='S'. Cover a deep arm by first constructing the seed **prefix** that
   routes execution past every ancestor gate, *then* searching the remaining free dimension.
3. **Arm-observation via branch hits composes the prefix.** After each candidate run, read the
   branch registry to confirm the prefix actually held (Phase='C' fired? loop entered?
   direction='S' fired?) before trusting the inner measurement.
4. **Aggressive measure-and-interpolate (B≈24, 2-D coordinate descent — chosen budget).** G5a is
   non-separable: qualifying-MFI-rows count × per-row product. 1-D extremes can't crack it;
   coordinate descent over (count, value) with the numeric oracle can.

## 2b. Capture mechanism (resolved 2026-06-05 — "most accurate", reuses the broker)

The existing coverage broker injects `EXEC TestGen.RecordCoverageHit '<tag>'` into `<proc>_cov`
and harvests the **statement TEXT** from an XEvent session (`TestGenCoverage` on
`sp_statement_completed`, read from the XEL file). That captures *which line ran*, not runtime
*values* — so it already gives the **boolean arm-observation** for free, but NOT the numeric
oracle (sp_statement_completed records the statement text, not substituted variable values).

For VALUES, the channel is `error_reported`:
- Inject at each gate's operand-evaluation point:
  `DECLARE @__p NVARCHAR(120)=CONCAT(N'__PROBE|',<gateId>,N'|',CAST(<operandLocal> AS NVARCHAR(40))); RAISERROR(@__p,0,1) WITH NOWAIT;`
- Add `ADD EVENT sqlserver.error_reported (WHERE message LIKE '__PROBE%')` to the `TestGenCoverage`
  session; parse `<gateId>` + value from the message text.
Why it is correct: messages emit IMMEDIATELY and are **not unwound by ROLLBACK** (rollback-immune),
fire **once per loop iteration** (needed for G5a per-row @AdjustedValue), and **cross the proc
boundary**. Severity 0 -> not an error, no control-flow impact. Reuses the broker; no loopback
connection, no ##temp, no OUTPUT-param surgery (which would only hold the LAST iteration's value).

So: arm-observation = existing line-hit capture; value-observation = error_reported probe.

## 3. Engine

For each UNRESOLVED target arm `A` (parser-marked, with operand locals + candidate literals):

1. **Build the path prefix to A.** Walk the ancestor gate chain (already in the per-proc line
   map / branch tree). For each ancestor gate use the *existing* static reverse-seeder where it
   can (G1 row, G3 qualifying rows, G6 param, G5 categorical direction literal); where it can't
   (G2 aggregate band), recurse into search. Result: a seed context that routes to A's guard.
2. **Identify A's free dimension(s)** from the parser signal: faked-table row COUNT, comparable
   column VALUES (type min/low/mid/high/max), in-scope PARAMS. Up to 2 coupled dims for descent.
3. **Search under the fixed prefix (budget B≈24):**
   - Arrange (SafeFakeTable + prefix seed + candidate) and run the instrumented proc in a
     ROLLED-BACK tran (reuse `CaptureExpectedCounts`/`ProbeHappyPath`).
   - Read the **operand-local value** at A's gate AND the branch hits.
   - If the prefix broke (an ancestor arm didn't fire), repair the prefix first.
   - With >=2 value samples, **interpolate** the (count,value) that lands A's predicate
     (linear solve for thresholds; midpoint for BETWEEN bands); then **coordinate-descent**
     refine if the first solve misses. Early-exit when A's arm fires.
4. **Emit.** Witness found -> a branch test carrying the exact prefix+witness seed. Else ->
   `NOT_TESTABLE` naming A: "search exhausted B seeds; arm unreachable by varying seedable
   inputs (non-monotone / unseedable state)."

## 4. Honest boundary (proven, not assumed)

The fixture set must include arms the engine *correctly refuses*: accumulation driven by
unseedable state (`GETDATE`, `@@SPID`, external rowsets) — the oracle measures the local but no
seedable axis moves it, so after B it emits `NOT_TESTABLE`. This proves the no-ghost guarantee
holds at the hard end. Also out of scope by design: chaotic/non-monotone-beyond-2-D coupling.

Cost: up to B instrumented runs per unresolved arm at GEN time only; witnesses are baked into
emitted tests, so the tests stay deterministic. Gate behind a flag; resolved gates pay nothing.

## 5. Reuse vs new

- Reuse: `CaptureExpectedCounts`/`ProbeHappyPath` (rolled-back execute), `InstrumentProcedure` +
  branch registry (arm + value capture point), `SafeFakeTable`, `BuildSeedInsertForTable`
  (+ row-count & value knobs), the static reverse-seeder (prefix construction for resolved
  ancestors).
- New: `TestGen.SearchSeedForGate` (prefix build + candidate loop + oracle read + interpolate +
  descent) and a parser signal: for each UNRESOLVED gate emit its operand locals and the
  candidate literals/tables/params it references.

## 6. Fixtures

- **Synthetic minimal:** `pz.HardLoopGate` (examples/PredicateZoo) — conditional accumulation
  (only `Status='SHIP'` rows) into a non-monotone `BETWEEN @Lo AND @Hi` band: the smallest
  deterministic repro of the numeric-oracle + interpolate mechanism. Plus an unseedable twin for
  the honest-boundary assertion.
- **Real benchmark:** `dbo.usp_ReconcileTradedPositions` (HighValueCustomer, after the HardCase
  tables) — the full G1-G6 inventory above, especially G5a cross-gate coupling.

## 7. Phasing (hardest-first)

- **Phase A — numeric oracle + path-prefix on G2 & G5a.** The hard core: capture operand-local
  values, build prefixes, interpolate a band, coordinate-descend a coupled gate. VALIDATE on
  `usp_ReconcileTradedPositions` G2 (3-way AVG band) and G5a (coupled). If this works, the rest
  is downhill.
- **Phase B — loop-entry & per-row value gates** (G3/G4/G5b/c): row-count search for `#temp`
  trip count, per-row value search. VALIDATE `pz.LoopLocalGate` 0% -> covered and the loop-body
  arms.
- **Phase C — parser signal hardening + honest-residue** (unseedable twin) + broad sweep.

No version bump until a phase is validated. All full-DB validation runs LOCALLY by the user
(remote sweeps are unreliable from the sandbox — 240s cap vs multi-minute XEvent coverage).

## 8. Why this is the right "any loop" answer

It does not enumerate idioms. It covers any arm reachable by routing a seed prefix past the
ancestor gates and then moving a measurable seedable axis to the boundary — the vast majority of
real production gates, including coupled cross-gate ones like G5a — and honestly skips the rest.
It is concolic-lite (execute + observe + interpolate) built almost entirely from machinery this
codebase already has.
