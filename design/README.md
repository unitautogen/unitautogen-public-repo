# UnitAutogen Design Documents

Internal design rationale and architecture specs for major features.
These complement — they don't replace — user docs (`docs/`), the
changelog (`CHANGES.md`), or in-code comments.

| Doc | Scope | Status |
| --- | --- | --- |
| [DESIGN_v11_Functions.md](DESIGN_v11_Functions.md) | Scalar / inline TVF / multi-statement TVF test generation + coverage via the shadow-procedure transform | Shipped in v11 |
| [DESIGN_v11_BranchSeeding.md](DESIGN_v11_BranchSeeding.md) | Hang-proof shadow loops (Layer A) + predicate-inversion branch seeding for value-gated branches (Layer B) | Shipped in v11 |
| [DESIGN_v11_AncestorChaining.md](DESIGN_v11_AncestorChaining.md) | Reach branches nested inside another parameter's predicate by chaining ancestor-branch seeds | Shipped in v11 |
| [DESIGN_v0_10_PredicateSeeding.md](DESIGN_v0_10_PredicateSeeding.md) | ScriptDom predicate parser (PowerShell) + single case-analysis seeder (T-SQL) for data-shape branches (EXISTS, COUNT, scalar, SUM/MIN/MAX/AVG, multi-join) | DRAFT — open for review |
| [DECISION_v0_10_Parser_Choice.md](DECISION_v0_10_Parser_Choice.md) | ADR: adopt Microsoft ScriptDom for v0.10 predicate parsing rather than hand-rolling in T-SQL | CONFIRMED 2026-06-02 (spike passed 11/11 shapes) |
| [DESIGN_v0_12_UnifiedReverseSeeder.md](DESIGN_v0_12_UnifiedReverseSeeder.md) | Redesign: predicate-**tree** + one recursive reverse-seed pass (truth propagation, parser-side seed plans, per-table constraint merge) + local-variable substitution; dissolves the piecemeal join/OR/param/local seams | IMPLEMENTED 2026-06-03 (phases 1–6) |
| [DESIGN_v0_13_SqlClrParser.md](DESIGN_v0_13_SqlClrParser.md) | SSMS-native parser: host ScriptDom in **SQLCLR** so the predicate parser is callable from T-SQL (`EXEC TestGen.ParseDatabasePredicates`), removing the one PowerShell dependency | IMPLEMENTED + VALIDATED 2026-06-03 (see `clr/`, CHANGES v0.13) |

## Conventions

- One file per feature. Cross-link with relative paths.
- Code comments and user docs reference design docs by relative path
  (e.g. `design/DESIGN_v11_Functions.md`) so paths stay stable.
- Historical entries in `CHANGES.md` may reference design docs by bare
  filename — that is intentional, those entries record the state at
  the time the change was made.
