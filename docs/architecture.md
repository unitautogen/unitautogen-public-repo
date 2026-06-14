# Design - v10: Universal Test Generator

Status: **proposed** (for review before any implementation). Builds on v9.4.2.

## 1. Goal and non-goals

Goal: make TestGen generate tests and measure coverage for **any** stored
procedure - not just the procedural IF / CASE / EXISTS shape the v9.x line
handles.

Two decisions are fixed (chosen 2026-05-24):

- **Architecture** - the parser and generator run **in-database via SQLCLR**:
  a managed assembly hosting Microsoft's ScriptDom T-SQL parser, cataloged
  into SQL Server and exposed as TestGen CLR procedures. The install-into-the
  -database model is preserved.
- **Target** - **universal coverage + a universal regression net**. Every
  procedure shape gets accurate statement/branch coverage and generated tests
  that characterize current behaviour and catch regressions.

Non-goals, stated plainly. v10 makes the framework universal in
*comprehension* - it parses and understands any valid T-SQL procedure
correctly - and near-universal in *coverage measurement*; it is not, and no
tool is, universal in *test generation*. The known tradeoffs:

- **Correctness oracle.** Generated assertions stay characterization /
  consistency oracles - they confirm a procedure still behaves as it does
  today; they do not judge whether that behaviour is *correct*. Real
  correctness testing needs a human-written spec, and is out of scope for v10
  (the "coverage + regression" target was chosen deliberately over the
  spec-driven option).
- **Path reachability.** Seeing a branch is not the same as being able to seed
  data that reaches it. Satisfying an arbitrary predicate - correlated
  subqueries, computed columns, multi-table conditions - is a constraint-
  satisfaction problem with no general solution (section 6). v10's rule is
  "never lie": it emits the test but marks it "branch not reached - manual
  seed required" rather than faking a phantom green test.
- **Dynamic SQL.** ScriptDom parses the outer procedure and sees an
  EXEC(@sql) / sp_executesql call, but the dynamic string is built at runtime
  and its logic is opaque. v10 flags it; it cannot generate branch tests for
  the dynamic body, and coverage cannot see inside it.
- **Error / CATCH paths.** v10 sees every CATCH block, but executing one means
  making the TRY block actually raise the specific error. Some error paths are
  drivable (force a constraint violation, a conversion error); many are not
  easily, and fall to hand-written tests.
- **Set-based internals.** A recursive CTE or one large SELECT is a single
  statement. v10 reports honest statement and branch coverage, with set-based
  statements as atomic units; it does not decompose the logic *inside* a
  set-based query - which JOIN path, which CASE arm in the SELECT list, which
  UNION leg ran.
- **Environmental behaviour.** Triggers firing on the procedure's DML,
  transaction / rollback / XACT_ABORT paths, isolation-level- or concurrency-
  dependent behaviour, and cross-procedure interaction are only partially
  characterized, or not at all.

The residue these leave - hard-to-seed paths, dynamic SQL, some error paths,
set-based query internals, correctness - falls to hand-written tests. v10's
contribution there is to surface that residue honestly rather than hide it
behind a phantom passing test.

## 2. Why a rebuild - the current ceiling

TestGen.AnalyzeBranchPaths, ExtractLeafDml and InstrumentProcedure parse
procedure text with CHARINDEX / SUBSTRING. A string scanner cannot be made
correct: it cannot reliably tell a keyword from the same word inside a comment
or a string literal, it breaks on unanticipated formatting, and it has no
model of nesting, WHILE, TRY/CATCH, MERGE, CTEs or dynamic SQL. The whole
CHANGES.md history - and every procedure exercised in the v9.4.2 sessions - is
a stream of string-parsing edge cases. That is a structural ceiling, not a
backlog of bugs.

The fix is a real parser. **ScriptDom**
(Microsoft.SqlServer.TransactSql.ScriptDom) is Microsoft's own T-SQL parser -
the one SSDT, sqlpackage and SSMS use. It produces a complete, correct
abstract syntax tree (AST) for any valid T-SQL, and can regenerate T-SQL from
a modified tree. Everything v10 needs - branches, statements, predicates, DML,
dependencies - becomes a tree walk instead of a guess.

## 3. Architecture

Three layers.

**(a) CLR parse/model layer (new).** A managed assembly, TestGen.ScriptDom,
written in C#, referencing ScriptDom. It is cataloged into the target database
with CREATE ASSEMBLY and exposed as CLR procedures/functions in the TestGen
schema. Given a procedure's definition it parses to an AST, walks the AST, and
returns a **normalized model** - relational result sets the T-SQL layer
consumes:

- *Branches* - every IfStatement, searched/simple CASE, WhileStatement,
  TryCatchStatement, IF EXISTS; with kind, source span, nesting depth, parent
  branch, and the decomposed predicate.
- *Statements* - every executable statement with its line span (the unit of
  coverage).
- *DML* - INSERT / UPDATE / DELETE / MERGE, with target table, columns, value
  sources, and the enclosing branch.
- *Dependencies* - referenced tables, views, procedures, functions.

This layer replaces AnalyzeBranchPaths and ExtractLeafDml.

**(b) Generator, rebuilt to consume the model.** GenerateTestsForProcedure is
repointed at the normalized model. The *emission* logic - the FakeTable
scaffolding, the measured-effect branch assertions (Arrange-Act-Assert), the
OUTPUT-value assertions, the result-shape test, ancestor-chain seeding - is sound
and is **kept**; it simply consumes a reliable model instead of the fragile
#Paths. New work: branch bodies that are multi-statement or compound, WHILE
bodies, TRY/CATCH paths, MERGE.

**(c) Coverage instrumentation, rebuilt on the AST.** InstrumentProcedure
becomes: parse -> AST -> insert EXEC TestGen.RecordCoverageHit nodes at every
statement boundary (inside BEGIN/END, loop bodies, TRY and CATCH blocks,
before control-transfer statements) -> regenerate the _cov procedure with
ScriptDom's script generator. This removes the whole class of string-injection
bugs (bare branch bodies, control-transfer ordering) and yields correct
statement/branch coverage for any control flow.

**Kept unchanged** - the downstream pipeline is good and is reused as-is:
RunCoverage (the rename/synonym swap, the Extended Events capture, the XEL
parsing), GetCoverageReport, the CoverageLines / CoverageHits tables,
BlessBaseline, CaptureResultShape / AssertResultShape, the TestGen / TestGenLog
schemas and logging.

## 4. SQLCLR deployment - smaller than it looks

The framework already depends on tSQLt, and tSQLt ships its own CLR assembly,
so `sp_configure 'clr enabled', 1` is **already a prerequisite of every
database this framework runs in**. The SQLCLR architecture therefore asks for
no new infrastructure and no new security posture: any database that can run
the framework today already permits CLR. What is left is install mechanics,
not a fresh approval.

- `clr strict security` (default ON, SQL 2017+) requires each assembly to be
  trusted - signed, or hash-whitelisted with sp_add_trusted_assembly. tSQLt's
  own install already exercises this mechanism for its assembly; v10's
  installer registers TestGen.ScriptDom and the ScriptDom assembly the same
  way (sp_add_trusted_assembly, hash-based; no TRUSTWORTHY ON). That is two
  more assemblies through an already-open door, not a policy change.
- ScriptDom is pure managed code (no file / network / registry access), so it
  needs nothing beyond what tSQLt already needs - no UNSAFE, no EXTERNAL_ACCESS.
- Runtime pairing: SQLCLR hosts the .NET Framework 4.x CLR in-process, so a
  ScriptDom build compatible with that runtime is required (the .NET Standard
  2.0 ScriptDom NuGet is loadable by .NET Framework 4.7.2+; the SQL Server host
  also ships a ScriptDom DLL). This is the one genuine unknown - a technical
  compatibility check, settled in Phase 0.
- The assembly is cataloged from its DLL bytes, so the installer carries the
  assembly (inline hex literal, or a packaged DLL) - a change to how the
  framework is distributed.

Because CLR is a given - tSQLt requires it - the "what if SQLCLR is forbidden"
worry effectively disappears: a database that blocks CLR cannot run tSQLt, and
so cannot run this framework at all, today or under v10.

## 5. Phased roadmap

Each phase leaves a **working framework** - the old string analyzer stays in
place until its replacement is proven.

**Phase 0 - ScriptDom load spike.** CLR is already enabled (tSQLt requires
it), so this is purely a technical compatibility check: catalog the ScriptDom
assembly, whitelist it with sp_add_trusted_assembly, and run a trivial CLR
function that parses a procedure body and returns its AST node count -
confirming the chosen ScriptDom build runs on the target SQL Server's CLR
runtime. Small and decisive.

**Phase 1 - CLR parse/model layer.** Build TestGen.ScriptDom: parse -> AST
walk -> the normalized model (section 3a). Validate: its branch model must
agree with the current AnalyzeBranchPaths on uspV9ValidationTest and
uspLevel3ValidationTest, and must additionally model WHILE / TRY-CATCH / MERGE
and deep nesting correctly. The old analyzer is untouched - nothing regresses.

**Phase 2 - switch the generator.** Repoint GenerateTestsForProcedure at the
new model; reuse the v9.4.2 emission logic. Add multi-statement / WHILE /
TRY-CATCH branch handling. Gate: the three sample procedures still reach 100%
coverage and their tests pass.

**Phase 3 - coverage on the AST.** Rebuild InstrumentProcedure as parse ->
inject hit nodes -> regenerate. RunCoverage and reporting are unchanged. Gate:
coverage holds on the samples and is now correct for a WHILE / TRY-CATCH test
procedure the old instrumenter mishandled.

**Phase 4 - breadth and the recursive seeder.** Extend generation to the
remaining constructs, and build the recursive predicate solver of section 6
(structural recursion + leaf inversion, plus the pure-managed
linear-constraint handler). For a predicate the
solver cannot satisfy, emit the test but mark it "branch not reached - manual
seed required" rather than a phantom - structurally ending the path-#5 class
of bug.

**Phase 5 - cutover.** Retire the string-based AnalyzeBranchPaths /
ExtractLeafDml / old InstrumentProcedure. Release as **v10**.

## 6. Seeding - the recursive predicate solver

Reaching a branch means supplying data that makes its predicate true (or
false). With the ScriptDom AST this becomes a first-class component of the
generator, not the best-effort heuristic of v9.x: a **recursive predicate
solver** that walks the predicate tree.

**Recursion through structure.** The solver recurses two ways, both fully
general. Down the AND/OR tree: a predicate is a boolean tree, and the solver
recurses into each node - for AND satisfy every child, for OR satisfy one, a
negation flips the goal - bottoming out at leaf comparisons. Up the ancestor
chain: to reach a nested branch the solver must also satisfy every enclosing
branch predicate, so it walks the parent chain (the AST gives it exactly) and
solves each ancestor by the same recursion. That second recursion is the
principled fix for the path-#5 class of bug - an unseeded ancestor is no
longer possible by construction. A leaf comparison is satisfied by *inversion*
- turning `col = literal`, `col IN (...)`, `col BETWEEN a AND b`,
`col IS NULL`, `col LIKE 'lit%'`, `YEAR(col) = 2025` and FK-linked join
conditions into concrete seed rows. This covers the large majority of
predicates in real procedural T-SQL.

**The decidable zone, and why a full SMT solver is deferred.** Some leaves are
not single-column inversions but small constraint systems - cross-column
arithmetic, several conditions over the same rows. While they stay within
booleans, equality and linear integer arithmetic they are *decidable*. A full
SMT solver such as Z3 would settle them, but **Z3 is deferred to a future
release** - and not on a whim. Z3 is not pure managed code: its .NET API wraps
a native libz3 library, so hosting it in SQLCLR would require an UNSAFE
assembly and a native DLL inside SQL Server - precisely the elevated security
posture the SAFE-assembly SQLCLR choice (section 4) exists to avoid. ScriptDom
is pure managed and loads SAFE; Z3 is neither. A genuine SMT solver argues for
the external-tool architecture, not this one, so it is left to a later release.

**The in-architecture alternative.** The tier-3 constraint band is instead
handled by a pure-managed linear-constraint handler: a small in-assembly
solver for the common arithmetic shapes - a handful of columns, linear integer
relations. It stays SAFE, stays in-database, and captures the realistic
majority of tier-3 predicates without the native-code problem. Anything beyond
it falls to the residue below.

**The ceiling - where recursion provably stops.** The recursion through
structure is complete; the limit is at leaves that cannot be inverted, and it
is a *computability* limit, not an effort one:

- A leaf wrapping an arbitrary scalar function - `dbo.RiskScore(@x) > 80` -
  would require inverting that function, which may itself branch, loop and
  read data. Undecidable in general.
- A leaf depending on a loop-carried value - reachable only once a WHILE
  accumulates past a threshold. Which iteration satisfies it is the halting
  problem for that loop.
- Non-linear or mixed-domain constraints - multiplication of unknowns, or
  arithmetic tangled with string operations - exceed the decidable theories.
- A leaf testing the procedure's own earlier mutation, especially inside a
  loop - needs full symbolic execution of the procedure's data flow; the same
  wall.
- Clock / environment leaves - GETDATE(), @@SPID, sequence values - cannot be
  seeded to a chosen runtime value.

This is the settled result of symbolic-execution / concolic testing - Microsoft's
own Pex / IntelliTest used Z3 - high automatic coverage, never total; the hard
paths are abandoned or time out. Even inside the decidable zone SAT is NP-hard,
so a sufficiently gnarly predicate is still capped by a solver timeout.

**The rule for the residue - never lie.** When the solver (inversion, plus
optionally Z3) cannot satisfy a predicate, v10 still emits the test but marks
it "branch not reached - manual seed required" and excludes it from the
passing count. A coverage gap or an unreachable branch is always *visible*,
never hidden behind a phantom green test. That honesty is the break from v9.x,
where an unseeded branch could still report green off a tautological assertion.

## 7. Risks

- ScriptDom / CLR runtime version mismatch on the target SQL Server - the one
  real technical unknown; Phase 0 settles it. CLR being *enabled* is not a
  risk: tSQLt already requires it.
- Effort: v10 is a major rebuild across several phases, not a patch.
- A new build dependency: the framework gains a C# project / toolchain it did
  not have before.

## 8. Decisions needed before Phase 1

- The C# build toolchain, and where the TestGen.ScriptDom source lives in the
  repo.
- ScriptDom sourcing: the open-source NuGet package vs. the DLL shipped with
  the target SQL Server.
- Assembly trust: sp_add_trusted_assembly (recommended) vs. certificate
  signing.
- How the installer carries the assembly bytes (inline hex vs. a packaged DLL).

## 9. What stays true from v9.4.2

The assertion philosophy carries forward intact - Arrange-Act-Assert,
measured-effect branch assertions, OUTPUT-value checks, the result-set shape
test, the no-tautology rule. v10 changes how the framework *understands* a
procedure (a real AST instead of string scanning); it does not change what a
good generated test looks like.
