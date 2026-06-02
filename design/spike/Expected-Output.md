# v0.10 ScriptDom Spike — Expected Output

When you run `Run-Spike.ps1` on a Windows machine with the
ScriptDom DLL discoverable, this is what the output should look like
for the spike to pass.

The spike script counts how many of 11 target predicate shapes
(consolidated from the 16-shape design table — `COUNT_EQ_SINGLE`,
`COUNT_CMP_SINGLE`, `COUNT_<>` etc. all classify as `COUNT_CMP`) are
correctly extracted from `TestProcedure.sql`. Pass threshold: 9 of 11.

## Expected ParsedPredicate rows

`TestProcedure.sql` has 17 branch headers total:

- 14 `IfStatement`s (numbered 1-14 in the file's comments — note that
  branches 15 and 16 are an IF and a CASE)
- 2 `WhenClause`s inside the `SearchedCaseExpression` (branch 16)
- 1 `WhileStatement` (sanity check)

Total expected rows: **17**.

## Expected shape distribution

| Source branch | Expected `Shape` | Expected `Aggregate` | Expected `Comparator` |
| ---: | --- | --- | --- |
| 1 (EXISTS) | `EXISTS` | (null) | (null) |
| 2 (NOT EXISTS) | `NOT_EXISTS` | (null) | (null) |
| 3 (COUNT = 2) | `COUNT_CMP` | `COUNT` | `Equals` |
| 4 (COUNT > 3) | `COUNT_CMP` | `COUNT` | `GreaterThan` |
| 5 (COUNT <= 5) | `COUNT_CMP` | `COUNT` | `LessThanOrEqualTo` |
| 6 (COUNT <> 0) | `COUNT_CMP` | `COUNT` | `NotEqualToBrackets` or `NotEqualToExclamation` |
| 7 (COUNT IN (1,2,3)) | `COUNT_IN` | `COUNT` | `IN` |
| 8 (COUNT BETWEEN) | `COUNT_BETWEEN` | `COUNT` | `Between` |
| 9 (SUM > 1000) | `SUM_CMP` | `SUM` | `GreaterThan` |
| 10 (MIN > 50) | `MIN_CMP` | `MIN` | `GreaterThan` |
| 11 (MAX >= 100) | `MAX_CMP` | `MAX` | `GreaterThanOrEqualTo` |
| 12 (AVG > 5.0) | `AVG_CMP` | `AVG` | `GreaterThan` |
| 13 (scalar = @pName) | `SCALAR_CMP` | `SCALAR` | `Equals` |
| 14 (scalar IS NULL) | `SCALAR_NULL` | `SCALAR` | `IS_NULL` |
| 15 (EXISTS multi-join) | `EXISTS` | (null) | (null) |
| 16a (CASE WHEN EXISTS) | `EXISTS` | (null) | (null) |
| 16b (CASE WHEN COUNT > 0) | `COUNT_CMP` | `COUNT` | `GreaterThan` |
| WHILE (COUNT > 0) | `COUNT_CMP` | `COUNT` | `GreaterThan` |

Distinct shapes seen: **`EXISTS`, `NOT_EXISTS`, `COUNT_CMP`, `COUNT_IN`,
`COUNT_BETWEEN`, `SUM_CMP`, `MIN_CMP`, `MAX_CMP`, `AVG_CMP`,
`SCALAR_CMP`, `SCALAR_NULL`** — 11 distinct shapes.

## Pass / fail decision

Pass: `Run-Spike.ps1` exits 0 with at least 9 of 11 distinct shapes
correctly classified, and 0 (or close to 0) `UNRECOGNISED` rows.

Soft warning: a small number of `UNRECOGNISED` rows is acceptable in
the spike if they correspond to genuine edge cases I haven't covered
in the test procedure. Look at the `PredicateText` column to see what
the spike couldn't classify and decide whether it's a v0.10 scope gap
or a spike-script gap.

Hard fail: fewer than 9 shapes classified, OR ScriptDom raises parser
errors on `TestProcedure.sql`, OR a critical AST class (e.g.
`ScalarSubquery`, `BooleanComparisonExpression`) is not where the
script expects it.

## What to do after the spike

If the spike passes: update `DECISION_v0_10_Parser_Choice.md` status
to `CONFIRMED`, then unblock tasks #54, #60 and proceed with Phase 1.

If the spike fails: capture the failure detail (which classes were
missing, which shapes UNRECOGNISED, what parser errors occurred),
reopen the DECISION doc, and decide whether to:

- Adjust the spike's classification logic (most likely - minor wrapper
  bug, not a ScriptDom limitation)
- Fall back to hand-rolled Option A (only if a genuine ScriptDom
  capability gap)

## Observed (2026-06-02) - PASS

Run-Spike.ps1 ran clean after fixing a UTF-8 / em-dash encoding issue
in the script itself.

| Metric | Expected | Observed |
| --- | --- | --- |
| Distinct shapes classified | >= 9 of 11 | **11 of 11** |
| Total predicate rows extracted | ~17 | 18 (15 IFs + 2 CASE arms + 1 WHILE) |
| UNRECOGNISED rows | low | **0** |
| Parser errors | 0 | **0** |

Per-row classification matched the expected table above 1:1 for all
18 branches. No bugs in the classification logic. ScriptDom API
behaviour matched assumptions exactly:

- `ExistsPredicate.Subquery.QueryExpression` walks correctly
- `BooleanComparisonExpression.ComparisonType` yields the expected
  enum values (`Equals`, `GreaterThan`, `NotEqualToBrackets`, etc.)
- `InPredicate.Values` is iterable
- `BooleanTernaryExpression` with `Between` ternary type classifies
  as expected
- `BooleanIsNullExpression.IsNot` distinguishes `IS NULL` vs `IS NOT NULL`
- `ScalarSubquery.QueryExpression` exposes `QuerySpecification`
  with walkable `SelectElements`, `FromClause.TableReferences`
- `SearchedCaseExpression.WhenClauses[].WhenExpression` walkable as
  recursive predicate
- `WhileStatement.Predicate` walks identically to `IfStatement.Predicate`

ScriptDom is confirmed feasible for v0.10. Tasks #54 and #60 unblock.
