# v0.10 ScriptDom Feasibility Spike

This folder is the validation gate for the v0.10 architectural
decision in [`DECISION_v0_10_Parser_Choice.md`](../DECISION_v0_10_Parser_Choice.md).
It exists so we can confirm Microsoft's ScriptDom parser exposes the
T-SQL AST nodes we need for predicate-aware data-shape seeding before
committing the v0.10 build to that path.

## Files

| File | Purpose |
| --- | --- |
| `TestProcedure.sql` | A stored procedure containing one branch per predicate shape in `DESIGN_v0_10_PredicateSeeding.md` §3.2 |
| `Run-Spike.ps1` | Loads ScriptDom, parses `TestProcedure.sql`, walks the AST, classifies each predicate, prints a verdict |
| `Expected-Output.md` | What the spike should produce on a passing run |

## How to run (Windows)

```powershell
cd <repo-root>\design\spike
.\Run-Spike.ps1
```

The script will:
1. Locate `Microsoft.SqlServer.TransactSql.ScriptDom.dll` via SSMS,
   dotnet-tool, or NuGet cache; failing that, install the package
   into `%TEMP%\uag-spike-scriptdom` and use it from there
2. Parse `TestProcedure.sql` via `TSql160Parser`
3. Walk the AST, extract one `ParsedPredicate` row per IF / WHILE /
   CASE-WHEN
4. Print rows and a pass/fail verdict

Exit code `0` is pass. Exit code `1` is fail and reopens the
DECISION doc.

## Time budget

Per `DECISION_v0_10_Parser_Choice.md`: 2 hours. If you spend more than
that fighting the spike script, the issue is in the spike, not in
ScriptDom — flag it and we adjust the script rather than questioning
the architecture.

## After the spike

- Pass: update `DECISION_v0_10_Parser_Choice.md` Status to `CONFIRMED`,
  unblock tasks #54 (parser wrapper) and #60 (PredicateInbox table).
- Fail: capture details in `Expected-Output.md` under a new
  `## Observed (failed)` section, reopen the DECISION doc, decide
  next step.

## Why this gate exists

The v0.10 build is ~3.5 weeks at 4h/day if ScriptDom works (Option B
in the DECISION doc), and ~5 weeks if we have to hand-roll the parser
(Option A). The cost of finding out which path we're on is 2 hours.
That asymmetry justifies a hard gate before any other v0.10 work.
