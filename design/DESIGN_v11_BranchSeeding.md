# Design — Accurate, hang-proof branch seeding for function coverage

Status: **proposed**. Extends v11 function support. Target: close the residual
"un-driven branch" gap (the ~5%) — reach every *reachable* branch on purpose,
guarantee the coverage run can never hang or break, and report the genuinely
unreachable residue honestly.

## 1. The gap, and why the obvious fix was wrong

The v11 coverage driver calls a function's shadow procedure with two inputs: the
"happy" sample value and NULL. That covers whatever branches those two values
land on. Branches gated on a *parameter value* are missed:

```sql
IF @status = 5            -- happy @status isn't 5  -> arm never runs
ELSE IF @amount > 1000    -- happy @amount is small -> arm never runs
```

The first instinct — feed each parameter a set of "boundary" values (low / high /
max) — is **wrong on two counts**:

1. *Inaccurate.* A generic high/low value rarely satisfies a *specific* predicate.
   To enter `IF @n < 0` you need a negative; a max-int "boundary" gives the
   opposite. You pay the cost and still miss the branch.
2. *Dangerous.* A "high" value handed to a parameter that bounds a loop —
   `WHILE @i <= @n` — turns a probe into millions of iterations. This is the hang
   that pulled multi-variant seeding from v11.

The fix is to separate two concerns that the boundary approach tangled together:
**how seed values are chosen** (accuracy) and **whether the run can run away**
(safety). Solve each independently and both problems vanish.

## 2. Two independent layers

### Layer A — the self-capping shadow (makes hanging *impossible*)

The shadow procedure is already built mechanically from the function body (v11).
Extend the transform: **inject a per-loop iteration guard into every loop of the
shadow.** Each `WHILE <cond>` becomes

```sql
SET @__loopK = 0;
WHILE (<cond>)
BEGIN
    SET @__loopK += 1; IF @__loopK > @__LoopCap BREAK;   -- injected
    <original body>
END
```

with `@__LoopCap` a small constant (e.g. 1000). The same treatment covers
`DECLARE CURSOR` / `FETCH` loops (cap the fetch count) and self-recursion (a depth
parameter, capped).

Consequences:

- **The coverage run can no longer hang for any input**, period. Worst case is
  `@__LoopCap` iterations. Termination is a *property of the shadow*, not of the
  seed values — so seeding is free to be aggressive without risk.
- **Correctness is untouched.** The shadow exists *only* to measure coverage. All
  value/row assertions run against the *real* function (v11 already does this), so
  capping the shadow's loops changes nothing a user sees — it only bounds the
  probe.
- **Coverage is preserved.** A loop body that is entered is still executed (≥1
  iteration), so its lines/branches are recorded; post-loop code still runs after
  the `BREAK`. Capping a loop at 1000 does not lose coverage — one iteration
  already covers the body.

This single mechanism is the headline reliability claim: *the coverage harness is
provably non-hanging.* That is exactly the property a DevOps buyer wants to hear,
and most coverage tooling cannot state it.

### Layer B — predicate-inversion seeding (makes branch targeting *accurate*)

With hanging off the table, choose seed values that *deliberately* reach each
branch, by inverting the branch predicate instead of guessing.

For each branch the analyzer finds (reusing the existing `AnalyzeBranchPaths`,
which already enumerates predicates and extracts their literals — the shadow is a
procedure, so it feeds that analyzer directly), derive a concrete argument set
that makes the predicate **true**, and one that makes it **false**:

| Predicate over parameter `@p` | Seed that makes it true |
| --- | --- |
| `@p = K` | `@p := K` |
| `@p <> K` | `@p := K + 1` |
| `@p < K` | `@p := K - 1` |
| `@p <= K` | `@p := K` |
| `@p > K` | `@p := K + 1` |
| `@p >= K` | `@p := K` |
| `@p IS NULL` | `@p := NULL` |
| `@p IS NOT NULL` | `@p := <happy>` |
| `@p IN (a,b,c)` | `@p := a` |
| `@p BETWEEN a AND b` | `@p := a` |
| `@p LIKE 'x%'` | `@p := 'x' + filler` |
| `YEAR(@p) = 2025` | `@p := '2025-06-01'` |

Boolean composition recurses the predicate tree: for `AND` satisfy every child,
for `OR` satisfy one, a negation flips the goal — bottoming out at the leaf rules
above. To reach a *nested* branch, also satisfy every enclosing predicate by
walking the parent chain the AST provides (the ancestor-chain rule from
DESIGN_v10 §6). Each branch yields one driver call; total cost is bounded by the
branch count (cap it, e.g. ≤ 32 calls).

The decisive property: **every value comes from a literal the author wrote in the
code.** If the code says `> 1000`, inversion uses `1001` — bounded by the
program's own constant, not by `INT` max. So even without Layer A, inversion is
already far safer than boundary seeding; *with* Layer A it is unconditionally
safe.

## 3. Loop-bound parameters — handled twice over

A parameter that bounds a loop (`WHILE @i <= @n`) is the danger case. It is now
defused on both layers:

- **Layer A** caps the loop, so a large `@n` cannot hang regardless.
- **Layer B** still only ever assigns `@n` a value derived from a predicate
  literal; if some *other* branch needs `@n > 1000`, inversion proposes `1001`,
  and Layer A guarantees the loop it feeds stops at the cap anyway.

The AST also lets us *detect* that `@n` controls a loop and prefer the smallest
satisfying value, keeping iteration counts minimal even when uncapped behaviour
would be fine.

## 4. Never lie — the honest residue

When inversion cannot produce a value, the branch is **not** faked. It is emitted
and marked *"branch not reached — manual seed required"* and excluded from the
covered count, exactly as the rest of the framework does. The genuinely
unsolvable cases are a computability ceiling, not an effort one (same result as
DESIGN_v10 §6):

- a predicate wrapping an arbitrary scalar function (`dbo.Risk(@x) > 80`) —
  inverting it is undecidable in general;
- a branch gated on a value the function *accumulates in a loop* — reachable only
  at some iteration, which is the halting problem for that loop;
- non-linear / mixed-domain constraints (multiplying unknowns, arithmetic tangled
  with string ops);
- clock / environment leaves (`GETDATE()`, `@@SPID`, sequences) that cannot be
  seeded to a chosen value.

Surfacing this residue truthfully is the product's credibility: coverage numbers
that are *real*, never inflated by a value thrown at the wall. For a buyer
evaluating the tool for release gating, "honest 92% with the 8% itemised" beats
"99% you can't trust" every time.

## 5. What ships, in order

Each step is independently valuable and leaves a working framework.

- **Step 1 — Layer A (self-capping shadow).** Inject the loop guard in
  `BuildShadowProcForFunction`. Standalone win: *no coverage run can ever hang.*
  This alone makes even naive seeding safe and is the strongest marketing claim.
- **Step 2 — Layer B leaf inversion.** Feed the shadow's branch predicates
  (via `AnalyzeBranchPaths`) through the inversion table; emit one driver call per
  branch with the satisfying argument set; ancestor-chain for nesting. Gate:
  branch coverage on a sample with value-gated `IF` chains goes from partial to
  full, with the run still bounded.
- **Step 3 — residue marking.** Any branch whose predicate can't be inverted is
  emitted as the honest "manual seed required" marker, excluded from the covered
  count. Gate: no phantom green; the report's gaps are all genuinely unreachable
  by automated means.
- **Step 4 — hardening.** Cursor/recursion caps; smallest-satisfying-value
  preference for loop bounds; per-driver `TRY/CATCH` already isolates a predicate
  whose satisfying value happens to raise (divide-by-zero etc.) — that branch
  becomes residue rather than a break.

## 6. Why this is the right investment

- It converts the "~5%" from *luck* (did the happy value happen to hit it?) into
  *intent* (we derived a value that reaches it).
- It removes the failure mode that killed the first attempt — hanging — by
  construction, not by hoping the values stay small.
- It reuses what already exists (the shadow transform, `AnalyzeBranchPaths`, the
  never-lie marking), so it is an extension, not a rebuild.
- The non-hanging guarantee and the honest residue are themselves *features* — the
  exact reliability and trustworthiness properties that make the tool defensible
  as a release-gate in a DevOps pipeline.

## 7. Limits, stated plainly

This raises automated branch coverage toward its theoretical maximum; it does not
reach 100% on every function, and no tool can (Step-4 residue, §4). It does not
decompose set-based statement internals (which `CASE` arm of one `SELECT` ran) —
that remains atomic, as for procedures. And the loop cap means a branch reachable
only after, say, the 5000th iteration is reported as residue rather than driven —
the correct, honest outcome for a probe that must terminate.
