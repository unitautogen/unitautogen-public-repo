# PredicateZoo — expected parse results

What `Get-ParsedPredicates.ps1` should write to `TestGen.PredicateInbox` for
each procedure (schema `pz`). One branch per procedure; `BranchId = 1`.

## Recognised shapes

| Procedure | Shape | Comparator | Comparand | Target table | WHERE conjuncts |
| --- | --- | --- | --- | --- | --- |
| `ExistsGate` | `EXISTS` | — | — | `pz.Orders` | `CustomerId = @CustomerId` *(param, not literal)* → see note |
| `NotExistsGate` | `NOT_EXISTS` | — | — | `pz.Students` | `Active = 1` |
| `CountEqGate` | `COUNT_CMP` | `=` | `2` | `pz.Students` | `Active = 1` |
| `CountGtGate` | `COUNT_CMP` | `>` | `5` | `pz.Orders` | *(none)* |
| `CountInGate` | `COUNT_IN` | `IN` | `1, 3, 5` | `pz.Students` | *(none)* |
| `CountBetweenGate` | `COUNT_BETWEEN` | `BETWEEN` | `2 AND 4` | `pz.Orders` | *(none)* |
| `SumGate` | `SUM_CMP` | `>` | `1000` | `pz.Orders` | *(none)* |
| `MinGate` | `MIN_CMP` | `<` | `50` | `pz.Students` | *(none)* |
| `MaxGate` | `MAX_CMP` | `>=` | `90` | `pz.Students` | *(none)* |
| `AvgGate` | `AVG_CMP` | `>` | `100` | `pz.Orders` | *(none)* |
| `ScalarCmpGate` | `SCALAR_CMP` | `=` | `N'OPEN'` | `pz.Orders` | `OrderId = @OrderId` *(param)* → see note |
| `ScalarNullGate` | `SCALAR_NULL` | `IS_NULL` | — | `pz.Orders` | `OrderId = @OrderId` *(param)* → see note |
| `JoinFromGate` | `EXISTS` | — | — | `pz.Orders` ⋈ `pz.Students` | `s.Active = 1` *(v0.11 join seeding: 2-table INNER equi-join, ON `s.StudentId = o.CustomerId`)* |
| `OrCompositionGate` | `COUNT_CMP` | `=` | `2` | `pz.Students` | `Active = 1 OR Score > 50` *(v0.11.1 DNF: seed one disjunct, assert the full OR)* |
| `ParamComparandGate` | `COUNT_CMP` | `>` | `@Threshold` | `pz.Orders` | — *(v0.11.1: parameter comparand, reverse-resolved to the proc-param sample value)* |

**Note on parameter WHERE conjuncts.** `ExistsGate`, `ScalarCmpGate` and
`ScalarNullGate` filter on `<col> = @param` (and `ParamComparandGate` compares to
a `@param`). The value is a *parameter*, not a literal. The seeder reverse-seeds:
it resolves `@param` to the same proc-parameter sample value the generated test
passes as the EXEC arg, so the seeded row/count and the runtime gate agree. This
landed in v0.10.1 for WHERE conjuncts and v0.11.1 for the comparand; these gates
are fully seedable, not NOT_TESTABLE. (A parameter that is *not* a procedure
parameter — e.g. a local variable — still degrades to NOT_TESTABLE, honestly.)

## UNRECOGNISED (must become NOT_TESTABLE)

*(none — as of v0.11.1 every PredicateZoo gate is recognised and coverable.)*

History: `JoinFromGate` (2-table INNER join) became recognised in v0.11;
`OrCompositionGate` (OR/DNF WHERE) and `ParamComparandGate` (parameter comparand)
in v0.11.1.

**v0.12 unified engine** (design/DESIGN_v0_12_UnifiedReverseSeeder.md). The
predicate is now a TREE (`Shape='PREDTREE'`, `PredicateTreeJson` + per-direction
`SeedPlan{True,False}Json`); the former bounds are gone. Added gates:
`LeftJoinGate` (outer), `NonEquiJoinGate` (non-equi ON), `CountOverJoinGate` /
`SumOverJoinGate` (aggregate over a join), `SelfJoinGate` (per-table merge of a
self-join), `SharedTableGate` (two atoms over one table → merge),
`LocalSubqueryGate` / `LocalChainGate` (a local variable inlined to its defining
expression). The only Skips left are **genuinely irreducible**, and PredicateZoo
ships a demonstrator of each: `ContradictionGate` (an *unsatisfiable* TRUE arm —
5 OPEN rows but 2 total — so TRUE is honestly Skipped) and `DynamicLocalGate` (a
runtime-dependent local that cannot be inlined deterministically). These prove
the no-ghost guarantee: an unseedable arm is Skipped (amber), never silently
green.

## How to validate

```powershell
# 1. Install corpus (run 00 then 01 against your target DB).
# 2. Parse:
.\powershell\UnitAutogen\Get-ParsedPredicates.ps1 `
    -ServerInstance '(local)' -Database AdventureWorks2025 -Schema pz -Clear

# 3. Inspect what was classified:
#    SELECT ProcName, Shape, Comparator, Comparand, TargetTablesJson,
#           WhereAstJson, UnsupportedReason
#    FROM TestGen.PredicateInbox WHERE SchemaName='pz' ORDER BY ProcName;

# 4. See the seed plan per branch/direction:
#    EXEC TestGen.GeneratePredicateBranchPlan @SchemaName='pz', @ProcName='CountEqGate';
```

Pass criterion: every recognised proc gets its row with the Shape in the table
above and zero parser errors; every UNRECOGNISED proc gets `Shape =
UNRECOGNISED` with the listed reason.
