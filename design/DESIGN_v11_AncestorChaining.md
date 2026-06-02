# Design — Ancestor-chaining for branch seeding (v11 Step 2.1)

Status: **proposed**. Extends Step 2 (predicate-inversion seeding). Closes the
top residue item: a branch gated on a *different* parameter's predicate is only
reached if the happy value happens to satisfy the enclosing gate.

## 1. The gap

Step 2 derives a value that satisfies one branch's *own* leaf predicate, setting
every other parameter to its happy value. That fails when the branch is **nested
inside another parameter's predicate**:

```sql
IF @kind = 'A'              -- outer gate on @kind
BEGIN
    IF @amount > 1000      -- inner branch on @amount
        ...                -- reached only when BOTH hold
END
```

Step 2 seeds `@amount = 1001` but leaves `@kind` at its happy value. If happy
`@kind <> 'A'`, the outer `IF` is false and the inner branch never runs — the
seed is wasted and the branch stays uncovered.

## 2. The fix — carry the enclosing predicates down

To reach a branch, satisfy its own predicate **and every predicate of the
blocks that enclose it**. Walk the body maintaining a stack of the
currently-active enclosing gates; each branch's seed is its own leaves combined
with everything on that stack.

### Walk state

- `@depth` — BEGIN/END nesting depth.
- `@anc` (stack, as a table var) — one frame per open `BEGIN`. A frame opened as
  an **IF/WHILE/ELSE IF body** carries that predicate's satisfying assignments
  `{param := value}`; any other block (the proc's outer BEGIN, an ELSE body, a
  bare BEGIN) carries an **empty** frame (depth bookkeeping only).

### Events

- **`IF` / `WHILE` / `ELSE IF <pred>`** — capture the predicate text (up to the
  body's `BEGIN`, or the statement for a single-line body; paren/string/comment
  aware). Extract its invertible leaves (reusing the Step-2 leaf rules). Emit a
  **branch seed** = those leaves ∪ all assignments currently on `@anc`. If the
  body is a `BEGIN` block, remember these leaves as *pending* so the block frame
  carries them.
- **`BEGIN`** — `@depth++`; push a frame at `@depth` carrying the pending leaves
  (if this BEGIN is an IF/WHILE body) else empty; clear pending.
- **`END`** — pop the frame at `@depth`; `@depth--`.

### Output

`ExtractBranchSeeds` returns `(BranchId, ParamName, SeedLiteral)` — multiple rows
per branch (own leaves + ancestors). `RunCoverageForFunction` groups by
`BranchId` and emits **one** shadow EXEC per branch, overriding every assigned
parameter (others happy). A top-level branch with no ancestors collapses to
exactly the Step-2 single-override call, so verified fixtures are unchanged.

## 3. Conflicts and feasibility

- **Same param, multiple constraints** (e.g. `@n > 0` ancestor + `@n < 10`
  leaf): pick one value per (branch, param). The leaf's own value is preferred;
  if it also satisfies the ancestors the branch is reached, otherwise the
  constraint set is contradictory and the branch is genuinely unreachable
  (residue) — never faked.
- **Conjunction** (`@a=1 AND @b=2`): take all leaves — the union satisfies it.
- **Disjunction** (`@a=1 OR @b=2`): taking all leaves over-constrains but still
  *reaches* the branch (an OR is true if any clause is). Conflicting OR on one
  param → residue.

## 4. ELSE bodies — honest gap (unchanged)

An `ELSE BEGIN … END` body is gated by the **negation** of its `IF` predicate.
Negation satisfaction isn't attempted here; the ELSE block pushes an *empty*
frame, so branches inside it get their grandparents' ancestors but not the
ELSE's negation. They may not be reached → reported as residue, not faked.
(Reversed/negated predicate work is a separate backlog item.)

## 5. Safety — still non-regressing

The three Step-2 safety layers are unchanged: every seed EXEC is `TRY/CATCH`'d,
the whole seed-building block is `TRY/CATCH`'d (any extractor error falls back to
happy+NULL), and all values come from the code's own literals. The Step-1 loop
cap keeps every seed call hang-proof. So ancestor-chaining can only *add* reach;
a bug degrades to "no extra coverage", never a break.

## 6. Limits, stated plainly

Single linear ancestor chain via lexical block nesting (the common shape). Not
addressed here: ELSE-negation ancestors (§4), predicates whose satisfaction
depends on a value computed earlier in the same block (data-flow, not lexical),
and the existing Step-2 residue (function-wrapped / non-literal / clock leaves).
