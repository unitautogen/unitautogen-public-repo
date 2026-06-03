# DESIGN v0.13 — SSMS-native predicate parser (ScriptDom in SQLCLR)

Status: **IMPLEMENTED + VALIDATED 2026-06-03** (built per this design; see CHANGES
v0.13 and `clr/`). Feasibility spike PASSED (§3); the C# port is a faithful replica
of the PowerShell parser — verified by zero-diff structural parity over all 28
PredicateZoo gates and a zero-PowerShell AssessCustomer 6/6 (100% line + branch)
end-to-end on HighValueCustomer. The bundled-ScriptDom (MIT) distribution was
confirmed with the user.

---

## 1. Why

UnitAutogen's predicate seeding has exactly **one** dependency that cannot run
from T-SQL: the ScriptDom parser (`Get-ParsedPredicates.ps1`, PowerShell). It
populates `TestGen.PredicateInbox`; everything else — install, generate, cover,
run — is T-SQL and runs in SSMS. For an **SSMS-only** shop, that single PowerShell
step is an adoption blocker: without it the inbox is empty and the data-shape
branch seeding silently degrades to string-gen / NOT_TESTABLE.

This design removes the blocker by hosting ScriptDom **inside SQL Server** via
SQLCLR, exposed as a T-SQL stored procedure:

```sql
EXEC TestGen.ParseDatabasePredicates @SchemaFilter = N'dbo';   -- pure T-SQL, from SSMS
EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter = N'dbo';
```

No PowerShell anywhere. The PowerShell parser stays as an alternative (e.g. for
locked-down servers where CLR/UNSAFE is disallowed).

---

## 2. The one hard constraint, and why CLR is the answer

ScriptDom is a managed .NET assembly. T-SQL cannot call it; PowerShell can, and so
can **SQLCLR** (the same .NET host tSQLt already requires). The only alternatives
were a hand-rolled T-SQL parser (fragile on real SQL — nesting, quotes, comments,
join grammar; the approach we deliberately abandoned) and a SQL-Agent/xp_cmdshell
wrapper (still server-side PowerShell). SQLCLR is the one that genuinely removes
PowerShell.

---

## 3. Feasibility spike (PASSED on the live SQL 2025 instance)

Confirmed end-to-end on `HighValueCustomer` (SQL major 17 / compat 170,
**clr strict security = ON, TRUSTWORTHY = OFF**):

- The **net472** ScriptDom `17.0.0.0` (exposes **TSql170Parser** = SQL 2025
  grammar) shipped with SSMS loads as a SQLCLR **UNSAFE** assembly. It references
  only `System.Core` + `System.Xml` (both SQLCLR-supported) — **no third-party
  deps**.
- With clr-strict ON and TRUSTWORTHY OFF, `sys.sp_add_trusted_assembly @hash`
  (SHA2_512) authorises both the ScriptDom DLL and our wrapper — **no TRUSTWORTHY
  required**.
- A CLR scalar function using ScriptDom's **`TSqlFragmentVisitor`** parsed a real
  proc, counted its `IF`s and extracted the first predicate text, returned to
  T-SQL: `ok; ifStatements=2; parseErrors=0; firstPredicate=[(SELECT 1 FROM
  dbo.Orders o JOIN dbo.Discounts d ON … WHERE o.CustomerID=@id AND
  o.Status='COMPLETED')]`.

So the risky unknowns (loadability, strict-security trust, grammar version,
in-engine AST walk) are all answered. The remaining work is engineering: port the
parser logic from PowerShell to C# and ship the registration.

---

## 4. Architecture

Two assemblies registered in the target DB:

1. **`UagScriptDom`** — the redistributed net472 ScriptDom DLL.
2. **`UnitAutogenClr`** — our C# assembly: the parser logic + a CLR procedure
   `TestGen.ParseDatabasePredicates` (and `ParseProcedurePredicates` for one proc).

The CLR proc, given a schema (or `'*'`), reads `sys.sql_modules` over the **context
connection**, parses each procedure with `TSql170Parser`, builds the predicate
**tree** + per-direction **seed plans** (the exact JSON the T-SQL seeder already
consumes), and writes rows to `TestGen.PredicateInbox` via `AddParsedPredicate`.

```
SSMS ──EXEC TestGen.ParseDatabasePredicates──► [UnitAutogenClr]
        (CLR proc)                                  │ uses
        reads sys.sql_modules (context conn)         ▼
        parses each proc ───────────────────► [UagScriptDom] (TSql170Parser, visitor)
        builds tree + seed plans (C#)
        EXEC TestGen.AddParsedPredicate ────► TestGen.PredicateInbox
                                                  │
GenerateAndCoverDatabase (unchanged T-SQL) ◄──────┘  reads the inbox
```

**The inbox contract is unchanged.** The CLR parser emits the identical
`PredicateTreeJson` / `SeedPlanTrueJson` / `SeedPlanFalseJson` (and back-compat flat
fields) the PowerShell parser does, so modules 31–34 and the whole generate/cover
pipeline are untouched. The CLR parser is a drop-in replacement for the parser's
inbox-population role.

---

## 5. What ports from PowerShell to C#

A faithful port of `Get-ParsedPredicates.ps1` — same algorithms, JSON output
byte-compatible with what the seeder expects:

- Predicate **tree** build (boolean nodes over data-shape atoms; query nodes with
  general joins; column-predicate WHERE trees) — via `TSqlFragmentVisitor` /
  direct AST typing (no reflection; inherently faster than the PS walk).
- **Truth propagation** + **per-table merge** seed-plan generation (both
  directions), and the **constant folding** for inlined values.
- **Local-variable substitution** (single + conditional IF/ELSE inlining) — the
  control-flow walk is cleaner in C# with typed visitors.
- Tree → SQL **render** for the strong assertion.
- Schema defaulting (unqualified → `dbo`), param-comparand handling, etc.

C# advantages: typed AST (no `GetType().GetProperties()` reflection), the visitor
pattern, and one warm in-proc CLR host (no per-invocation cold start).

### 5.1 JSON in SQLCLR
The SQLCLR framework allow-list excludes `System.Web.Extensions`
(`JavaScriptSerializer`) and `Newtonsoft`. The tree/plan shapes are simple, so the
port includes a **tiny hand-rolled JSON writer** (string building with proper
escaping) — no extra assembly to register. (The seeder reads it back with the
built-in T-SQL `OPENJSON`.)

---

## 6. Distribution & registration (installer)

- **Ship the net472 ScriptDom DLL** with UnitAutogen (it is the redistributable
  Microsoft NuGet `Microsoft.SqlServer.TransactSql.ScriptDom`; confirm licence note
  — MIT-style, redistribution permitted). Pin one version (170 grammar).
- The installer registers both assemblies **without TRUSTWORTHY** (works under
  clr-strict): for each DLL it computes the SHA2_512 hash and runs
  `sys.sp_add_trusted_assembly @hash, @desc`, then `CREATE ASSEMBLY … WITH
  PERMISSION_SET = UNSAFE`. The hashes are emitted into the installer at build time
  (or computed at install from the shipped DLL bytes via `OPENROWSET(BULK…SINGLE_BLOB)`
  / a deploy step). Idempotent: drop+recreate on reinstall, re-trust as needed.
- Fallback path: if a server forbids UNSAFE CLR entirely, the installer prints a
  notice and the user uses the PowerShell parser instead. Both populate the inbox.

---

## 7. T-SQL surface

- `TestGen.ParseDatabasePredicates @SchemaFilter = NULL` — parse every user proc
  (NULL/'*' = all user schemas; a value = that schema). Clears + repopulates the
  inbox for the scope.
- `TestGen.ParseProcedurePredicates @Schema, @ProcName` — one proc.
- Optionally fold a `@Parse BIT = 1` flag into `GenerateAndCoverDatabase` so a
  single `EXEC TestGen.GenerateAndCoverDatabase` parses-then-covers in one call
  (mirrors what `Invoke-UnitAutogen` now does in PowerShell).

---

## 8. Coexistence & versioning

- v0.13 adds the CLR parser **alongside** the PowerShell one; both write the same
  inbox. No change to the seeder/generator. `Invoke-UnitAutogen` keeps working;
  SSMS users get the CLR path.
- Minor version bump to **v0.13** (adds CLR assemblies + a parse surface; no inbox
  contract change).

---

## 9. Build phases

1. **C# project + JSON writer + AST→tree** (port build/render). Unit-check the
   emitted JSON equals the PowerShell parser's for the PredicateZoo procs.
2. **Propagation + per-table merge + local substitution** (port the planner).
3. **CLR proc** `ParseDatabasePredicates` writing the inbox via the context
   connection; installer registration (trusted-assembly + CREATE ASSEMBLY).
4. **Validate**: on HighValueCustomer (SSMS-only), `EXEC ParseDatabasePredicates`
   then `EXEC GenerateAndCoverDatabase` → AssessCustomer 6/6 = 100%, matching the
   PowerShell path, with **zero PowerShell**. Re-run PredicateZoo for parity.
5. Docs (README/runbook: "SSMS-only install"), CHANGES, fold into the installer.

---

## 10. Open questions / risks

1. **ScriptDom redistribution.** Confirm the licence permits shipping the DLL in
   the installer. (NuGet package is Microsoft, MIT-style — needs a one-line note in
   COPYRIGHT/THIRD-PARTY.) If not redistributable, the installer can register from
   a user-pointed path (SSMS/VS install) instead of shipping bytes.
2. **Grammar version.** Ship the 170 parser (SQL 2025). On older servers the same
   net472 170 DLL still loads and parses ≤2025 syntax; selecting the parser by DB
   compat (as the PS parser does) is a nicety, not required.
3. **Port fidelity.** The seed JSON must match exactly so the seeder behaves
   identically. Mitigation: a differential test (CLR JSON vs PS JSON per pz proc)
   in phase 1–2.
4. **UNSAFE permission.** Some hardened servers disable UNSAFE CLR outright; those
   keep the PowerShell parser. Document clearly.
5. **Effort.** ~1500 lines PS → C#; the largest single piece of v0.13, but the
   algorithms are settled and the spike proves the host works.
