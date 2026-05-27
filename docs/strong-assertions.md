# Design — v9.4: Strong Branch-Test Assertions

Status: **proposed** (for review before implementation).
Builds on v9.3.

## 1. Problem

The branch/path tests the framework generates (`EXISTS_TRUE`, `EXISTS_FALSE`,
`IF_ELSE`, `CASE_WHEN`, `CASE_ELSE`) currently carry **tautological
assertions**:

- `EXISTS_TRUE` / `IF_ELSE`: `AssertEquals @Expected = 1, @Actual = @RowsGrew`,
  where `@RowsGrew = @RowsAfter > @RowsBefore`. `@RowsBefore` is captured
  *before* the seed block, and the seed block itself runs an `INSERT` — so the
  assertion is satisfied by the seed, not by the procedure.
- `EXISTS_FALSE` / `CASE_ELSE`: `AssertEquals @Expected = 1, @Actual = 1` — a
  no-op.

So today a branch test really verifies only **coverage** (the XEvent capture)
and **smoke** (the proc didn't throw — `BEGIN TRY … BEGIN CATCH tSQLt.Fail`).
A logic error in a branch body's `UPDATE`/`INSERT` would not be caught.

## 2. Goal

Turn the branch tests into proper **characterization tests**: each test
verifies that the branch body's table effect *actually happened* — to the
right rows, with no collateral change — using `tSQLt.AssertEqualsTable`
(whole-table comparison) rather than a row count.

## 3. Mechanism — snapshot-and-replay

For a branch whose body performs a determinable table mutation:

```sql
-- Arrange: ClearSchemaBoundReferences / FakeTable / FK-seed / EXISTS-seed   (unchanged)
...
-- v9.4: snapshot the seeded table, then replay the branch's own DML onto the
--       snapshot to form the expected post-state.
SELECT * INTO #Expected_SalesOrderHeader FROM [Sales].[SalesOrderHeader];
UPDATE #Expected_SalesOrderHeader SET Status = 4 WHERE CustomerID = 1;   -- branch DML, replayed

-- Act
EXEC [dbo].[uspLevel3ValidationTest] @CustomerID = 1, @OrderType = 'VIP', @Priority = '_ELSEPATH_';

-- Assert: the real table must match the replayed expectation exactly.
EXEC tSQLt.AssertEqualsTable '#Expected_SalesOrderHeader', '[Sales].[SalesOrderHeader]';
```

The expected state is **not** predicted from nothing — it is the seeded state
(whatever the seed produced) with the branch's *own* DML applied. The generator
already parses each branch body for the seeding work; here it re-emits that
parsed `UPDATE`/`INSERT` against `#Expected`, with two substitutions:

1. target table → the `#Expected` snapshot;
2. procedure parameters (`@CustomerID`, …) → the literal values the test passes
   (the generator already has these in `@ExecArgList`).

## 4. The leaf-DML principle

A branch body can be a nested tree (e.g. `pred-1`'s body in
`uspLevel3ValidationTest` contains `SET`, a nested `IF EXISTS`, and an
`IF/ELSE`). Which `UPDATE`/`INSERT` runs is then path-dependent, and predicting
the exact delta for that outer branch is unreliable.

Rule: **the strong assertion is attached only to the test whose branch body
*unconditionally* executes a single table-DML statement** — i.e. leaf
branches. For `uspLevel3ValidationTest`:

- `IF @Priority = 'High'` true-body → `UPDATE … Status = 6` — leaf → strong.
- its `ELSE` body (`IF_ELSE`) → `UPDATE … Status = 4` — leaf → strong.
- `pred-1`'s `EXISTS_TRUE` body → compound (nested) → **fallback** to smoke;
  its table effects are already characterized by the inner `@Priority` tests.

This keeps every `UPDATE`/`INSERT` characterized exactly once, by the
innermost test that owns it.

## 5. Analyzer changes (`AnalyzeBranchPaths`)

When the analyzer extracts a branch body, also record — *only* when the body
unconditionally contains exactly one table-DML statement:

- `BodyDmlKind`  — `UPDATE` or `INSERT`
- `BodyDmlTable` — the target table
- `BodyDmlText`  — the raw statement text, for replay

Stored as new `#Paths` columns (or a side temp table keyed by `PathID`).
This also replaces the current `AssertTable` detection — and fixes its
known bug (it matched the word `UPDATE` inside the comment
`-- Update based on priority`, yielding `AssertTable = 'based'`) by stripping
`--` comments before scanning.

## 6. Generator changes (`GenerateTestsForProcedure`)

Replace the assertion block. Per branch path:

- **Replayable** (a `BodyDmlText` was captured): emit the snapshot, the
  param-substituted replay onto `#Expected`, the `EXEC`, and
  `AssertEqualsTable`. Drop the `@RowsBefore`/`@RowsAfter` vars for this path.
- **Not replayable**: keep the current smoke assertion, but label it clearly
  (`-- coverage/smoke only — branch effect not asserted`).

## 7. Replayability boundary

| Body shape | Handling |
|---|---|
| Single `UPDATE`/`INSERT`, literal or proc-parameter values | **strong** (`AssertEqualsTable`) |
| `INSERT` with identity / computed / rowversion columns | strong, **with those columns projected out** before comparison (see §8) |
| Body DML references a procedure-**local** variable (`@Message`, …) | fallback — value not known at design time |
| `INSERT … SELECT`, `MERGE`, multi-statement bodies | fallback in Phase 1 (multi-statement is a Phase 3 candidate) |
| Body performs no table mutation (e.g. only `SELECT … RETURN`) | fallback — nothing to assert on a table |
| Compound / nested body | fallback (per §4) |

## 8. The `INSERT` wrinkle

`AssertEqualsTable` compares *all* columns. An `INSERT` branch's new row gets
identity / `rowversion` / `DEFAULT GETDATE()` values that the replay cannot
reproduce deterministically. The generator already classifies columns
(`@bpIsIdent`, `@bpIsComp`, `@bpIsRowVer` in `seedcur2`). For `INSERT`
branches, compare **projections** that exclude those columns:

```sql
SELECT <deterministic columns> INTO #Exp2 FROM #Expected_T;
SELECT <deterministic columns> INTO #Act2 FROM [Schema].[T];
EXEC tSQLt.AssertEqualsTable '#Exp2', '#Act2';
```

`UPDATE` branches need no projection (no new rows; identities unchanged).

## 9. Honest properties — what this does and does not buy

This is a **characterization / consistency oracle**, not an independent
correctness oracle. The "expected" is the procedure's *own* DML, replayed.

It **does** catch:

- the branch body's DML not running at all (actual ≠ `#Expected`);
- collateral changes — the proc touching rows or columns the branch DML did
  not (a wrong/missing `WHERE`, an unintended extra statement);
- **regressions** — once generated, the test pins current behaviour; a later
  edit to the proc's DML makes the test fail and forces review/regeneration.

It **does not** catch a logic error that is identical in the proc and in the
replayed statement (e.g. a wrong column name present in the source itself).
Independently judging "is the proc's intent correct?" needs a human-written
spec — no auto-generated assertion can supply that.

Even so, this is a large step up from the current row-count tautology, which
passes even if the branch body is gutted to do nothing.

## 10. Regression impact — read before approving

This strengthens the assertion of **every replayable branch test of every
procedure**, including `uspV9ValidationTest` (today 100 % coverage, all path
tests green on weak assertions).

Consequence: some currently-"passing" path tests **may now fail**. That is the
strengthened assertion doing its job — the weak assertion was masking a
seed/replay mismatch — but the "all green" picture will change. **Line and
branch coverage are unaffected** (the proc still runs; lines are still hit) —
only pass/fail becomes stricter. Each new failure must be triaged: a generator
bug to fix, or a genuine mismatch worth surfacing.

## 11. Files, version, phasing

- `modules/17_Branch_Path_Analyzer_v3_2.sql` + installer — body-DML capture.
- `modules/04_Test_Generator_v3.sql` + installer — assertion emission.
- New `scripts/Patch_TestGen_StrongAssertions.sql` — standalone DROP/CREATE patch.
- `CHANGES.md` — log; release becomes **v9.4**.

Suggested phasing:

- **Phase 1** — `UPDATE` leaf branches (the clean case; covers
  `uspLevel3ValidationTest`'s `IF_ELSE` tests).
- **Phase 2** — `INSERT` branches with column projection (§8).
- **Phase 3** — multi-statement bodies; fallback-label polish.

## 12. Verification

After each phase: regenerate and re-run coverage for
`uspLevel3ValidationTest`, `uspV9ValidationTest`, `uspGetBillOfMaterials`.
Expected: coverage holds at 100 % / 100 % / 100 %; triage every newly-failing
path test.

## 13. Decision needed

1. Phase 1 only first, or all three phases in one pass?
2. Confirm acceptance that `uspV9ValidationTest` may surface new path-test
   *failures* (coverage unchanged) — that is the intended effect of real
   assertions, not a regression.
