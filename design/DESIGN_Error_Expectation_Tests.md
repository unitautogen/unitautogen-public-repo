# DESIGN — Error-expectation test generation (derive, don't assume)

Status: **design locked, build not started.** Separate from the DML-effect work
(`DESIGN_DML_Effect_Assertions.md`). No version bump until built + validated; folds
into the same single release discipline.

---

## 1. Problem

The generator emits "this proc must raise an exception" tests **speculatively** —
without verifying that a reachable code path actually raises for the input it chose.
Result: guaranteed-red tests on whole classes of procedures that are behaving
correctly.

Concrete case: `HighValueCustomer.GetVIPCustomerAnalyticsReport` — a read/report proc
with **no input validation**, whose only `RAISERROR` is a `CATCH`-block rethrow. It got
three failing tests, all "Expected an error to be raised":

| Test | What it did | Why it false-fails |
|---|---|---|
| `rejects high boundary values` | `ExpectException` + call with `@MinNetSpend=99999.99, @StartDate='9999-12-31'` | comment literally asserts *"Proc has input validation; boundary values are expected to be rejected"* — but the proc has **no guard**, so extreme values just return no rows |
| `rejects low boundary values` | `ExpectException` + call with `@MinNetSpend=0, @StartDate='1900-01-01'` | same — no validation exists to reject anything |
| `raises error path 001` | `ExpectException` + call with `@MinNetSpend=NULL` | detected the `RAISERROR` text, but it's a **catch-and-rethrow**; only a genuine runtime error in the TRY triggers it, and `NULL` doesn't error the query → `CATCH` never entered |

---

## 2. Root cause — two flawed heuristics, one mistake

Both heuristics treat weak textual signals as licence to assert an exception:

1. **"rejects boundary values"** is generated on the **assumption** that the proc
   validates its parameters and rejects extremes. The assumption is never checked
   against the body. For any proc without an input guard (most reports, reads, simple
   CRUD), boundary inputs don't raise → false fail.

2. **"raises error path NNN"** is generated whenever a `RAISERROR`/`THROW` appears
   anywhere in the source. It does **not** distinguish:
   - a **catch-block rethrow** (`BEGIN CATCH … RAISERROR(ERROR_MESSAGE()…)`) — fires
     only on a real runtime error inside the TRY, **not triggerable by choosing an
     input**; from
   - a **genuine input guard** (`IF @param <cond> THROW/RAISERROR` in the main flow) —
     triggerable by an input that violates the condition.
   For the rethrow it guesses an input (`NULL`) and hopes; when that input doesn't
   error the TRY, the test false-fails.

The single mistake: **asserting an error without a specific, reachable, input-triggered
raise.** This contradicts the tool's own honesty principle (only assert what you can
prove) and false-fails the *most common* proc shapes — anything with a standard
`TRY…CATCH…RAISERROR` rethrow, and anything without input validation.

---

## 3. Core principle

**Only emit an exception-expectation test when the generator can point to a reachable
path that raises for the chosen input** — either *derived* (reverse-seed a parameter to
violate a real guard) or *forced* (make a faked dependency throw to enter the CATCH).
Otherwise emit no error test (or an honest NOT_TESTABLE). Never a speculative "it
probably validates."

### 3a. Relationship to the DML skip-and-highlight rule (no conflict)

This shares one rule with `DESIGN_DML_Effect_Assertions.md` §6, applied to the same
distinction:

- **Behavior provably EXISTS in the proc but the generator couldn't drive it** →
  *keep the complete test, mark it Skipped, name what was missed.* The developer has an
  actionable lever (fix the seed / the proc). This is the DML skip-and-highlight pattern,
  and it ALSO applies here: a real input guard exists but the reverse-seeder couldn't
  derive a violating input (see §4a, "guard found but unseedable").
- **Behavior does NOT exist** (no input guard at all; only a CATCH rethrow that rolls
  back) → *emit nothing.* There is nothing to assert; a skipped stub here would invent a
  requirement the proc was never designed to meet, implying a deficiency that isn't real.

So the two designs are consistent: skip-and-highlight is for *"exists but undriven,"*
emit-nothing is for *"doesn't exist."* The over-generation bug is precisely emitting
guaranteed-red tests for the *doesn't-exist* case.

---

## 4. The fix

### 4a. "rejects" tests — require a real guard, then reverse-seed the parameter
- Scan the body for an **input-validation guard**: `IF <condition over @param>` (or
  `IF @param IS NULL`, range/type checks) whose THEN reaches a `RAISERROR`/`THROW`,
  located in the **main flow, not inside a `CATCH`**.
- If found: **reverse-seed the parameter** to violate the guard (the predicate seeder
  already derives parameter values to satisfy/violate conditions — this is the same
  capability, applied to the parameter instead of a table column), so the `RAISERROR`
  genuinely fires. Then `ExpectException` is honest.
- If **no guard** exists: **do not generate** a "rejects"/boundary test. (Boundary
  *value* coverage of a non-validating proc belongs in normal result-set tests, not an
  exception test.)

### 4b. "raises error path" — separate rethrow from guard
- **Genuine guard RAISERROR** (main flow, param-gated): treat as 4a — reverse-seed the
  param to hit it.
- **Catch-block rethrow**: an input can't trigger it; only a runtime failure in the TRY
  can. Use the **existing forced-error mechanism** (`@v943ForceErrOK` — make a faked
  dependency throw so the CATCH runs), *not* a guessed parameter. And honor its existing
  guard: when the CATCH does its own `ROLLBACK` (as this proc does), the forced-error
  test is correctly **suppressed** (the rollback would unwind tSQLt's transaction) — so
  the right outcome for `GetVIPCustomerAnalyticsReport` is **no auto error-path test**,
  not a guessed `NULL`.

### 4c. Otherwise — silence, or honest NOT_TESTABLE
No reachable, triggerable raise → emit nothing, or a NOT_TESTABLE-skipped stub naming
the reason ("no input-validation guard detected; only error path is a CATCH rethrow that
rolls back"). Never a guaranteed-red speculative test.

---

## 5. Why it matters

The current behavior false-fails the two **most common** procedure shapes in any real
database: procs with a standard `TRY…CATCH…RAISERROR` rethrow, and procs with no input
validation (reports, reads, CRUD). A developer running the tool on a clean report proc
sees red tests demanding errors the proc was never meant to throw — which erodes trust
faster than a missing feature and directly undercuts the "tests that actually test the
logic" positioning.

---

## 6. Code locations (to confirm at build)

- Error-expectation test emitters in `TestGen.GenerateTestsForProcedure`
  (`Install_UnitAutogen.sql`): the `rejects … boundary values` generator and the
  `raises error path NNN` generator (search the proc text the tests carry:
  `Proc has input validation; boundary values are expected to be rejected` and
  `Detected RAISERROR in source`).
- The RAISERROR/THROW scan that currently fires on *any* occurrence — needs the
  in-CATCH vs in-main-flow classification (reuse the block-structure the instrumenter
  already walks).
- `@v943ForceErrOK` forced-error path + its CATCH-ROLLBACK suppression guard — reuse,
  don't duplicate.
- Parameter reverse-seeding — same engine as table-column seeding
  (`TestGen.ParseDatabasePredicates` / planner), applied to the parameter that the guard
  compares.

---

## 7. Residual / known limits

- Guard detection is syntactic; an input-validation pattern hidden behind dynamic SQL or
  a called sub-proc won't be recognized → no rejects test (acceptable: silence, not a
  false fail).
- Multi-condition guards (`IF @a<0 OR @b>@c`) need the DNF/OR seeding path already built
  for predicates — verify it covers parameter comparands.
