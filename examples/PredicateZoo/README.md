# PredicateZoo

A tiny, deterministic regression corpus for v0.10 **predicate-aware seeding**.
One procedure per recognised data-shape predicate, plus a handful the parser
must mark `NOT_TESTABLE`. Used to validate the whole v0.10 pipeline end to end:

```
Get-ParsedPredicates.ps1  ->  TestGen.PredicateInbox  ->  TestGen.SatisfyPredicate
                                                      ->  TestGen.GeneratePredicateBranchPlan
```

## Files

| File | Purpose |
| --- | --- |
| `00_Schema.sql` | `pz` schema + `Students` / `Orders` tables. |
| `01_Procedures.sql` | 12 recognised-shape procs + 3 UNRECOGNISED procs. |
| `02_Expected_Shapes.md` | The expected `PredicateInbox` classification per proc (the assertion target). |

## Install + run

```cmd
sqlcmd -S "(local)" -d AdventureWorks2025 -i examples\PredicateZoo\00_Schema.sql
sqlcmd -S "(local)" -d AdventureWorks2025 -i examples\PredicateZoo\01_Procedures.sql
```

```powershell
.\powershell\UnitAutogen\Get-ParsedPredicates.ps1 -ServerInstance "(local)" `
    -Database AdventureWorks2025 -Schema pz -Clear
```

Then compare `TestGen.PredicateInbox` (schema `pz`) against
`02_Expected_Shapes.md`, and inspect seeds via
`EXEC TestGen.GeneratePredicateBranchPlan @SchemaName='pz', @ProcName='CountEqGate';`.

## What each shape exercises

`EXISTS`, `NOT_EXISTS`, `COUNT_CMP` (`=`, `>`), `COUNT_IN`, `COUNT_BETWEEN`,
`SUM_CMP`, `MIN_CMP`, `MAX_CMP`, `AVG_CMP`, `SCALAR_CMP`, `SCALAR_NULL`; and the
three NOT_TESTABLE gates (OR composition, multi-table FROM, parameter comparand).

This corpus is intentionally minimal and side-effect free so it runs fast in CI
and is safe to (re)install on any database.
