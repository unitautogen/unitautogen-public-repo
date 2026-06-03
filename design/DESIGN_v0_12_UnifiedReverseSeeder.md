# DESIGN v0.12 — Unified reverse-predicate-seeder (predicate tree)

Status: IMPLEMENTED 2026-06-03 (phases 1–6). Validated live on AdventureWorks2025
+ PredicateZoo: every seedable gate 100% branch on the tree path; the only Skips
are genuine unsatisfiability (ContradictionGate) and runtime-dependent locals
(DynamicLocalGate). Flat inbox columns retained one release as a fallback (the
§7.1 cutover switch). Original draft below; decisions §9 are settled.
Supersedes the *engine shape* of [DESIGN_v0_10_PredicateSeeding.md](DESIGN_v0_10_PredicateSeeding.md)
(the ScriptDom-parser-in-PowerShell + T-SQL-seeder split is kept; the flat,
per-shape seeder is replaced).

---

## 1. Why

The v0.10–v0.11.x seeder is **piecemeal**. `TestGen.PredicateInbox` stores flat
fields (`Shape`, `Comparator`, `Comparand`, `AggregateColumn`, `TargetTablesJson`,
`JoinsJson`, `WhereAstJson`) and `TestGen.SatisfyPredicate` branches per `Shape`
with separate code paths: a single-table path, a bolted-on join block, a DNF
patch for OR, a comparand-resolution patch for `@param`. Every "UNRECOGNISED by
design" case we keep hitting —

- 3+-table joins, outer joins, non-equi `ON`,
- `OR` spanning a joined `WHERE`,
- aggregate-over-join,
- a branch gated on a **local variable**,

— lives in the **seam between two of those blocks**, not in any genuine
impossibility. A single general pass removes the seams: represent the branch
predicate as a **tree**, drive the tree to the target truth value by propagation,
and reverse-seed each leaf's tables with one recursive routine. Joins, OR,
params and locals stop being special cases and become ordinary nodes.

The guiding invariant is unchanged: **no ghost pass**. Every generated test
reconstructs the *actual* gate (params/locals resolved) and `AssertEquals` the
intended truth value before running the proc, so a seed that fails to drive the
branch fails **red**, never green. Anything we genuinely cannot seed stays
`[@tSQLt:SkipTest]` (amber), flagged for a human — never silently green.

---

## 2. The predicate as a tree

A branch predicate `P` is a boolean combination of **data-shape atoms**. Two
distinct leaf kinds:

- **atom** — a data-shape sub-predicate: `EXISTS(q)`, `agg(q) op comparand`,
  `scalar(q) IS [NOT] NULL`. Reading it requires *table data*.
- **colpred** — a column comparison *inside* a query's `WHERE`/`ON`:
  `col op literal | @param | col`. Reading it requires nothing — it constrains a
  row.

Boolean nodes (`and` / `or` / `not`) compose either kind. A query's `WHERE` is
itself a boolean tree of `colpred`s — the *same* propagation logic reused one
level down.

### 2.1 Node JSON

```jsonc
// boolean nodes (used at top level over atoms, and inside a query WHERE over colpreds)
{ "k": "and",  "items": [ <node>, ... ] }
{ "k": "or",   "items": [ <node>, ... ] }
{ "k": "not",  "item": <node> }

// data-shape atom (top-level leaf)
{ "k": "atom",
  "agg": "EXISTS|COUNT|SUM|MIN|MAX|AVG|SCALAR",
  "op":  "exists | = | <> | < | > | <= | >= | in | between | isnull | isnotnull",
  "comparand": "<t-sql literal> | @Param | [n0,n1] (between) | [v0,v1,..] (in) | null",
  "selectExpr": "<column for SUM/MIN/MAX/AVG/SCALAR, or * for COUNT/EXISTS>",
  "source": <query> }

// query: the FROM/JOIN/WHERE an atom reads
{ "k": "query",
  "tables": [ { "schema": "..", "table": "..", "alias": ".." }, ... ],   // ordered; [0] = base
  "joins":  [ { "type": "INNER|LEFT|RIGHT|FULL", "addAlias": "..",
                "on": [ { "lAlias":"..","lCol":"..","op":"=|<>|<|>|<=|>=","rAlias":"..","rCol":".." }, ... ] }, ... ],
  "where":  <boolean node over colpred> | null }

// column predicate (leaf inside query.where / used to derive overrides)
{ "k": "colpred", "tbl": "<alias|null>", "col": "..", "op": "=|<>|<|>|<=|>=",
  "val": "<literal> | @Param", "valKind": "literal|param" }
```

The old flat fields are all expressible here: `EXISTS over one table` is an
`atom{agg:EXISTS, source:{tables:[T], where:…}}`; `COUNT(*) … = 2` is
`atom{agg:COUNT, op:'=', comparand:'2', source:…}`; a join is just a `source`
with `joins[]`; OR is an `or` node.

---

## 3. Driving the tree to a direction (truth propagation)

To make `P` evaluate to `D ∈ {TRUE, FALSE}` we walk top-down assigning each node
a required truth, collecting a flat **seed plan**: a list of *(atom, requiredTruth)*
tasks, each annotated with the row-count/overrides needed.

| node | D = TRUE | D = FALSE |
|---|---|---|
| `and` | every child TRUE | pick the **first seedable** child → FALSE; rest = don't-care |
| `or`  | pick the **first seedable** child → TRUE; rest = don't-care | every child FALSE |
| `not` | child = FALSE | child = TRUE |
| `atom`| seed its source so the atom is TRUE | seed its source so the atom is FALSE |

**Don't-care** children are not seeded. Because every target table is
`tSQLt.FakeTable`d (empty) first, an unseeded atom reads empty tables →
`EXISTS`=false, `COUNT`=0, `scalar`=NULL. So a don't-care leaf defaults to the
"neutral/false" pole, which is exactly what `or`-TRUE and `and`-FALSE tolerate.

Propagation runs in the **parser** (PowerShell — recursion is free there), for
**both** directions, emitting `SeedPlanTrueJson` and `SeedPlanFalseJson`. The
T-SQL seeder just executes the chosen direction's flat plan. This is the central
architectural decision: **the hard recursion stays in PowerShell; the T-SQL side
stays flat** (the same reason ScriptDom lives in PowerShell today).

### 3.1 Seed plan — **per physical table** (the merge is the model)

Propagation does **not** emit rows per atom. Each atom it must drive contributes
*demands* to a **per-physical-table accumulator**; the plan is then keyed by
`schema.table`, and each table is solved **once** for all the demands on it
(§6). This makes shared-table coherence the default behaviour, not a special
case — two atoms over the same `Orders` table are simply two demands the table
solver reconciles.

```jsonc
// SeedPlan{True,False}Json  — grouped by physical table
[ { "schema": "..", "table": "..",
    "rowgroups": [                       // each group = a set of rows sharing constraints
      { "count": <K | ">=1" | "0">,      // how many rows this demand needs
        "preds": [ { "col":"..","op":"..","value": <vspec> }, ... ],  // each row satisfies these
        "fromAtom": <id> } , ... ],
    "joinval": { "<groupId>": <vspec>, ... }   // shared values for join-key groups touching this table
  }, ... ]
// <vspec> is symbolic, resolved by existing T-SQL helpers:
//   { "lit": "N'OPEN'" }                         -> use literal as-is
//   { "param": "@Threshold" }                    -> GetSampleValueLiteral(proc param)
//   { "satisfy": { "op": ">", "comparand": .. }} -> SatisfyingValue(op, comparand, 1)
//   { "joinval": <groupId> }                     -> shared join-key value for a group
//   { "sample": true }                           -> GetSampleValueLiteral(column type)
```

The T-SQL seeder walks each table's reconciled row-groups and emits the
`INSERT`s, resolving `<vspec>` via the **existing** `GetSampleValueLiteral` /
`SatisfyingValue` / `BuildSeedInsert`. No new value logic in T-SQL — it iterates
an already-reconciled plan. The reconciliation (§6) happens in the parser, where
recursion and set logic are easy.

---

## 4. Reverse-seeding one atom (where joins/OR/aggregates unify)

Given *(atom, requiredTruth)* with `source = {tables, joins, where}`:

1. **Row count K** from the atom's comparator (the existing case analysis):
   EXISTS→1/0, COUNT `op` N → K, SUM/MIN/MAX/AVG/SCALAR→1 (+ a column override),
   IS NULL→0/1.
2. **WHERE driver** — `source.where` is a boolean tree of `colpred`s. Drive it
   TRUE for a matching row by the *same* propagation (§3): for `or` pick one
   disjunct, for `and` take all, each `colpred` → a column override
   `(col → satisfy(op,val))`, params reverse-resolved. (This is today's DNF
   driver, generalised to arbitrary nesting and done in the parser.)
3. **Join coordination** — for every column that appears in an `ON` predicate:
   - **equi** (`=`): join-compatible columns share a type, so each gets its
     type's deterministic sample (`GetSampleValueLiteral(type,0)`); linked
     columns therefore get the **same** literal and the equality holds — no
     union-find needed. A `WHERE col = lit` on a join column pins that group to
     `lit` instead.
   - **non-equi** (`>` etc., numeric): set the right column to a sample `S`, the
     left to `S±1` to satisfy the operator.
   - **outer** (`LEFT/RIGHT/FULL`): seed a fully-matching row exactly as for
     INNER — a matching row is present in an outer join too; the join *type*
     only changes the reconstructed assertion text. (Anti-join intent —
     `WHERE b.x IS NULL` — is out of grammar anyway; column `IS NULL` isn't a
     supported `colpred`.)
4. **Emit K coordinated rows**: `K` rows in the base table (all sharing the join
   values) + 1 row in each other table → the join yields `K` rows, each passing
   the `WHERE`. (`EXISTS`/scalar use K∈{0,1}; `COUNT=N` uses K=N.)
5. **FALSE pole**: leave the source's tables empty (no rows → atom false).

Everything an atom needs — joins of any arity, outer/non-equi, OR in the WHERE,
param comparands — is handled in this one routine. There is no separate "join
block."

### 4.1 Strong assertion (unchanged guarantee)

The parser also renders `P` back to SQL from the tree (`PredicateText`,
params/locals **kept symbolic**); the seeder substitutes resolved param values
(longest-name-first string replace) and emits
`AssertEquals(<rendered P> , D)` before the proc `EXEC`. Tree → SQL is a trivial
recursive render (no DNF expansion ⇒ the old 16-term cap disappears).

---

## 5. Local-variable substitution (pre-pass, parser)

Per your point: a local gated branch is an **indirection**, not a dead end.
Before classifying, the parser inlines locals:

1. Collect assignments reaching the branch: `DECLARE @x T = <expr>` and
   `SET @x = <expr>`, in source order, on the straight-line path to the `IF`.
2. For each variable referenced in the predicate, substitute its **defining
   expression fragment** (a `ScalarSubquery`, `(SELECT COUNT(*) …)`, arithmetic,
   a literal, or another `@param`). Recurse if the expression references further
   locals (bounded depth, cycle guard).
3. Re-classify the **substituted** predicate. `IF @cnt > @Threshold` with
   `@cnt = (SELECT COUNT(*) FROM T)` becomes `IF (SELECT COUNT(*) FROM T) >
   @Threshold` — an ordinary atom we already seed.

**Residue (honest NOT_TESTABLE):** a local whose value is *not* a static
expression over seedable sources — reassigned inside a loop/branch on the path,
or fed by an `EXEC`/OUTPUT param/dynamic SQL/`@@`-function/external state. We
cannot deterministically seed it, so forcing a test would be a guaranteed red;
we Skip and flag it. This is the only class that stays UNRECOGNISED, and it is
genuinely irreducible (it is data we do not control), consistent with the
no-ghost rule.

---

## 6. Per-table constraint merge (core, not deferred — decided)

**Decision:** the per-table merge is part of the engine from day one; there is no
shared-table Skip. Seeding is **table-centric**, not atom-centric, so two atoms
over the same table are reconciled by construction.

After propagation has chosen which atoms must be TRUE/FALSE, each atom emits its
demands into a per-`schema.table` accumulator:

- a **count demand** — `= N`, `>= 1`, or `0` rows (from the atom's comparator), and
- a **row predicate set** — the `colpred`s a qualifying row must satisfy (the
  atom's `source.where`, plus join-key values for that table).

The table solver then produces one coherent row set:

1. Partition the table's demands into **row-groups** by their predicate set
   (rows asking for `Status='OPEN'` vs rows asking for `Status='CLOSED'` are
   different groups; a bare `COUNT(*)=N` with no predicate is the "any-row" group).
2. Reconcile counts. A subset demand (`COUNT WHERE Status='OPEN' = 5`) and a
   superset demand (`COUNT(*) = 6`) are compatible iff `subset ≤ superset`; the
   solver seeds `5` OPEN rows + `1` filler that satisfies the superset but not the
   subset predicate. **Genuine contradictions** (`COUNT(*)=2` ∧
   `COUNT WHERE OPEN=5`) are detected as `5 > 2` → **Skip** — honest, because the
   predicate is *unsatisfiable*, not because the engine is weak.
3. Emit the union of row-groups as the table's `INSERT`s; the count for the
   "any-row" / superset group is back-filled so totals match.

Worked example —
`(SELECT COUNT(*) FROM Orders) = 6 AND EXISTS(SELECT 1 FROM Orders WHERE Status='OPEN')`
drive TRUE: demands on `Orders` = {count `=6` any-row} ∪ {count `>=1` where
`Status='OPEN'`}. Solver: 1 OPEN row (satisfies the EXISTS) + 5 filler rows
(non-OPEN) = 6 total. Both atoms hold; one coherent seed.

The predicate tree makes this tractable: every atom's `source.where` is already a
structured `colpred` set, so grouping by `schema.table` and reconciling is set
arithmetic, done in the parser. Joined atoms that share a table contribute their
join-coordinated demands to the same accumulator; the solver treats the join-key
value as just another fixed `colpred` on the row-group.

The only residue remains the genuinely irreducible: **unsatisfiable** predicates
(Skip, correctly) and **undeterminable locals** (§5). Everything seedable is
seeded.

---

## 7. Inbox schema & module impact

`TestGen.PredicateInbox` (module 31): **add**
`PredicateTreeJson NVARCHAR(MAX) NULL`, `SeedPlanTrueJson NVARCHAR(MAX) NULL`,
`SeedPlanFalseJson NVARCHAR(MAX) NULL`. Keep `PredicateText`, `BranchId`,
`StartLine`, `Context`, `Schema/Proc/RunId`, `UnsupportedReason`. The flat
`Shape/Comparator/Comparand/AggregateColumn/TargetTablesJson/JoinsJson/
WhereAstJson` columns stay (nullable) for one release for rollback, then drop.

- **Parser** `Get-ParsedPredicates.ps1`: build the tree; run local substitution;
  run truth-propagation for both directions; emit tree + two seed plans +
  `PredicateText`. (The bulk of new code; PowerShell, well-suited.)
- **Module 32** `SatisfyPredicate`: shrinks — read the chosen `SeedPlan`,
  resolve `<vspec>`s via existing helpers, `BuildSeedInsert` per table-row spec,
  concatenate; render the assertion from `PredicateText` + resolved params. The
  per-shape/join/DNF branches are deleted.
- **Modules 33/34**: largely unchanged — they already call `SatisfyPredicate`
  and fake every `source` table; module 34 fakes from the union of all
  `tables` across the plan.

### 7.1 Migration / de-risking

- Build behind a switch: `SatisfyPredicate` reads `PredicateTreeJson` when
  present, else falls back to the current flat path. Land the parser + new seeder,
  keep the old as fallback until PredicateZoo is 100% on the tree path, then
  remove the flat path.
- **PredicateZoo is the safety net.** Every existing gate must stay green on the
  tree engine, and we add one gate per new capability:
  `ThreeTableJoinGate`, `LeftJoinGate`, `NonEquiJoinGate`, `JoinOrWhereGate`,
  `CountOverJoinGate`, `LocalVarGate` (literal), `LocalSubqueryGate`
  (`@cnt = (SELECT COUNT(*) …)`), `SharedTableGate` (per-table merge → seeded),
  and `ContradictionGate` (unsatisfiable → expected Skip, proves honest residue).
- Coverage gate: the whole `pz` schema must reach the same 100% line+branch it
  has today, with 0 UNRECOGNISED except genuine unsatisfiability (ContradictionGate)
  and undeterminable locals.

---

## 8. Build phases

1. **Schema + scaffolding** — inbox columns; `SatisfyPredicate` switch + flat
   fallback; tree renderer (assertion) only.
2. **Parser: tree + propagation + per-table seed plans** for the shapes we
   already support (no new grammar) → prove the tree engine reproduces today's
   100% on PredicateZoo. *Gate: parity.*
3. **Per-table merge** (§6) — the table-centric solver, with a shared-table
   PredicateZoo gate (`SharedTableGate`) and an unsatisfiable gate
   (`ContradictionGate`, expected Skip). Built here, not deferred.
4. **Joins, general** — N tables, outer, non-equi, OR-in-WHERE, aggregate-over
   -join, folded into the atom-seeder + table accumulator. Add the join gates.
5. **Local substitution** — literals, then static-expression/subquery inlining.
   Add the local gates.
6. Drop the flat columns/paths; refold installer; docs/memory.

Each phase keeps PredicateZoo green; nothing ships until parity (phase 2) holds.

---

## 9. Open questions for review

1. **Seed-plan-in-parser vs tree-walk-in-T-SQL.** This doc puts truth
   propagation + plan generation in the parser (two flat plans per branch).
   Alternative: store only the tree, walk it in T-SQL at seed time (recursive
   CTE / iterative stack). Parser-side is far simpler to write and test; the cost
   is the inbox carries two plans. Agree parser-side?
2. **Shared-table residue (§6).** ✅ **DECIDED** — per-table constraint-merge is
   core; no shared-table Skip. Only genuine unsatisfiability and undeterminable
   locals Skip. "Merge everything together," one build.
3. **Drop vs keep the flat columns.** Keep them one release as rollback (my
   default), or cut over hard once parity holds?
4. **Aggregate-over-join scope.** COUNT-over-join is straightforward (K matching
   rows). SUM/MIN/MAX/AVG-over-join needs the aggregated column controlled across
   joined rows — include in v0.12.0 or defer one point release?
5. **Versioning.** Call this v0.12 (engine redesign) — agreed? It changes the
   inbox contract, so a minor bump rather than a patch.
