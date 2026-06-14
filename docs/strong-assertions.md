# Branch-test and OUTPUT-value assertions

How UnitAutogen makes a generated test verify *behaviour*, not just *coverage* —
and where it deliberately stops. This reflects the current engine (v0.14.x). For
the earlier row-count tautology and the v9.4 snapshot-and-replay design that
preceded it, see [CHANGES.md](../CHANGES.md).

## The contract: Arrange-Act-Assert

Every generated test is **Arrange → Act → Assert**, in that order:

1. **Arrange** — fake the dependencies (`TestGen.SafeFakeTable`), seed the rows
   that drive the branch (reverse predicate seeding), set the inputs.
2. **Act** — run the procedure under test, once.
3. **Assert** — check what the procedure *did*.

The assertion comes *after* the Act and is about the procedure's effect. (An
earlier version asserted that the seed satisfied the predicate *before* the Act
— that only tested the test's own setup and let a broken branch pass; it was
removed. A CI guard, [`scripts/Check_Invariants.sql`](../scripts/Check_Invariants.sql),
now fails any generated test that asserts before it runs the procedure.)

## Branch tests — the measured effect

For a predicate branch (the TRUE and FALSE arm of an `IF` / `EXISTS` / aggregate
gate), the generator does **not** guess the branch's effect from the source — it
**measures** it. At generation time it runs that arm's Arrange + the procedure
in a rolled-back transaction and observes the target table's row count and a
content checksum, before and after, then classifies the delta:

| Observed | Classified as | The generated test asserts |
|---|---|---|
| row count grew | INSERT | the procedure adds exactly *N* rows |
| row count shrank | DELETE | the procedure removes exactly *N* rows |
| count held, content changed | UPDATE | content changes with the row count held |
| count held, content unchanged | no observable write | smoke (ran without error) |

The emitted assertion captures its own before/after at run time, so a
`GETDATE()`-style value inside a row cannot make it false-fail. If the arm has
no single determinable write target, or the measurement can't run cleanly, the
test falls back to a clearly-labelled smoke assertion — never a false failure.

## OUTPUT parameters — the value (v0.14.1)

Each scalar `OUTPUT` parameter's *value* is asserted, both on the happy path and
on each branch path:

- **Deterministic output** → the exact value (`tSQLt.AssertEqualsString`),
  measured under the test's own faked + seeded inputs.
- **Non-deterministic output** (mixes string constants with a runtime-volatile
  part such as `GETDATE` / `NEWID`) → a **constant `LIKE` skeleton**: the
  procedure's own string literals, in order, with `%` for the volatile spans
  (e.g. `'%Receipt for % at %'`). The deterministic structure is verified
  without false-failing on the volatile part.
- **No usable literal** (a purely volatile value) → assert the parameter was
  assigned (non-NULL).

Determinism is **confirmed by measurement**, not assumed. A source scan only
sees volatile functions written in the procedure itself, so the value is
measured **twice** in independent rolled-back runs, separated past a system-clock
tick. The exact value is asserted only when the scan is clean *and* the two runs
agree; otherwise it falls back to the skeleton. This catches non-determinism
hidden in a called function/procedure (a UDF that calls `GETDATE`), a
`SCOPE_IDENTITY` / sequence read, or order-sensitive aggregation — cases a text
scan alone would miss.

## Honest properties — what this buys, and what it doesn't

This is a **characterization / consistency oracle**, not an independent
correctness oracle: the "expected" comes from the procedure's own observed
behaviour at generation time.

It **does** catch:

- a branch body's write not running at all (or writing the wrong row count);
- collateral changes — the procedure touching rows the branch should not (a
  wrong or missing `WHERE`);
- **regressions** — once generated, the test pins current behaviour; a later
  edit that changes the effect makes the test fail and forces review.

It **does not** independently judge "is the procedure's intent correct?" — that
needs a human-written spec; no auto-generated assertion can supply it. When a
branch direction genuinely can't be reached (a contradiction, an unreachable
arm, or an error path the data-seeder can't trigger), it is reported as
`NOT_TESTABLE` with the reason — never faked into a pass.
