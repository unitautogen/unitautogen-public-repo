@{
    ModuleVersion     = '0.13.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen — auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework AND the in-database (SQLCLR) predicate parser, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube. The single C# predicate parser runs inside SQL Server (no PowerShell-side parser); installation registers it and requires sysadmin once plus ''clr enabled''=1.'
    PowerShellVersion = '5.1'
    RootModule        = 'UnitAutogen.psm1'

    FunctionsToExport = @(
        'Install-UnitAutogenDatabase',
        'Invoke-UnitAutogen',
        'Export-CoverageCoberturaXml',
        'Export-TestResultsJunitXml',
        'Export-CoverageHtmlReport'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # All files that must be present for the module to work
    FileList = @(
        'UnitAutogen.psd1',
        'UnitAutogen.psm1',
        'sql\Install_UnitAutogen.sql',
        'sql\Install-UnitAutogenClr.SSMS.sql'
    )

    PrivateData = @{
        PSData = @{
            ExternalModuleDependencies = @('SqlServer')
            Tags        = @('SQL', 'SQLServer', 'tSQLt', 'Coverage', 'CI-CD',
                            'Cobertura', 'JUnit', 'AzureDevOps', 'Testing',
                            'UnitTest', 'CodeCoverage', 'BranchCoverage',
                            'DatabaseTesting', 'AutomatedTesting')
            LicenseUri  = 'https://github.com/unitautogen/unitautogen-public-repo/blob/main/LICENSE'
            ProjectUri  = 'https://github.com/unitautogen/unitautogen-public-repo'
            IconUri     = 'https://raw.githubusercontent.com/unitautogen/unitautogen-public-repo/main/docs/logo.png'
            ReleaseNotes = @'
## v0.13.0 (beta) — 2026-06-11

CORRECTNESS FIXES (independent core-engine review) + NULL tests now OFF by default.

- @EmitNullChecks now DEFAULTS TO 0. The per-parameter "accepts NULL" smoke tests are no longer
  forced; genuine NULL handling in a procedure is covered as a normal branch/line. Pass
  @EmitNullChecks = 1 to restore the previous per-parameter NULL tests.
- Alias / user-defined scalar types (e.g. dbo.Flag, dbo.Name) now resolve to their base type when
  sampling values, so alias-typed parameters and columns get real seeds and arguments instead of
  NULL -- fixes weakened WHERE lookups and seed inserts on alias-heavy schemas.
- Equality seeding now skips (rather than emitting `col = NULL`) when a comparand is NULL, so a
  branch over an unknown-typed value no longer self-fails its own assertion.
- The in-database SQLCLR predicate parser is now detected correctly by GenerateAndRunCoverage (the
  guard tested for a T-SQL proc type and silently skipped the CLR parser), so single-proc runs
  parse predicates and emit data-shape branch tests when the parser is installed.
- NOT_TESTABLE skip annotations now escape apostrophes in the reason ("unmatched quote" fixed).
- The interrupted-run self-heal now also recovers a procedure left missing after a crash between
  the rename and the synonym create (previously only the synonym-present state was detected).

Regression-clean on AdventureWorks2025, HighValueCustomer and WideWorldImporters (0 fail / 0 err).

## v0.12.0 (beta) — 2026-06-07

WHERE-AWARE BOUNDARY SEEDING. The in-database SQLCLR parser now lifts a guarded UPDATE/DELETE''s
WHERE equalities (col = literal, col IN (...), AND-chained) into seed overrides, so the boundary
test pre-seeds rows that actually satisfy the filter. A selective UPDATE/DELETE behind a loosened
comparison operator (e.g. count > N silently changed to count >= N) is now caught even when the
filter uses specific literal values -- not just unfiltered or sample-matching DML. Strictly
additive and conservative: anything the parser cannot lift cleanly (OR, ranges, functions,
subqueries, INSERT, multi-gate) seeds exactly as v0.11.1 -- never an error, never a false failure.
Validated on AdventureWorks2025 including a 3-conjunct WHERE (Region = ''US'' AND Status IN (3,4)
AND Priority = 9). NOTE: this release rebuilds the SQLCLR assembly (new trust hash) and adds a
PredicateInbox column -- install BOTH Install_UnitAutogen.sql AND Install-UnitAutogenClr.SSMS.sql.

## v0.11.1 (beta) — 2026-06-07

BOUNDARY-VALUE MUTATION DETECTION. Predicate-branch tests now catch comparison-operator
loosening (e.g. count > N silently changed to count >= N). Two parts: (1) a COUNT_CMP ''>'' gate''s
non-satisfy case now seeds the boundary (N rows) instead of 0, so the discriminating value is
actually exercised; (2) the FALSE/boundary test pre-seeds the guarded write target and compares its
full content before/after the procedure runs — a row-count check catches INSERT/DELETE and
AssertEqualsTable catches UPDATE. On correct code the gate is false and the target is unchanged
(pass); loosen the operator and at the boundary the write fires, the content differs, and the test
fails with a clear message. Strictly conservative: emitted only for single-gate / single-fakeable-
target procedures, so every other shape generates exactly as before. Regression-clean on
AdventureWorks2025, HighValueCustomer and WideWorldImporters (0 fail / 0 err).

## v0.11.0 (beta) — 2026-06-06

SEARCH-BASED GATE SEEDING — the headline feature. Branch gates whose controlling value the
static reverse-seeder cannot invert (loop accumulators, per-row products, coupled cross-gate
conditions, aggregate bands) are now covered by a numeric oracle: the generator instruments the
procedure, drives candidate seeds, reads the operand''s live value through an XEvent probe
(rollback-immune, fires per loop iteration), and measure-and-interpolates the seed that lands
each arm. A verified witness becomes a real tSQLt test; an unreachable / environmental gate is
an honest NOT_TESTABLE. It runs automatically as part of the normal sweep.

Archetypes auto-derived: aggregate-over-table, scalar-from-table, IS [NOT] NULL, bare parameter,
per-row value, per-row categorical, COUPLED cross-gate (with a recursive prefix that reuses an
ancestor gate''s witness to establish the flag), and LOOP-COUNT (a loop accumulator driven by
the trip count over a seedable table — both arms seeded).

Measured impact on real procedures: a coupled/per-row reconciliation procedure went from 1 of 13
to 13 of 13 branch gates handled (36.7% -> 83.3% line); a loop-accumulator gate went 0% -> 100%.
No regressions on already-covered procedures. The whole search layer is collation-safe (works on
databases whose collation differs from the server default).

## v0.10.0 (beta) — 2026-06-05

Major capability + honesty release. New capabilities:

- DML EFFECT ASSERTIONS. A modifying procedure's per-table write effect is now asserted
  with EXACT row counts, measured at generation time by running the procedure under its
  own reverse-predicate seed (rolled back). Covers INSERT (VALUES and SELECT), UPDATE and
  DELETE; when the seed drives no write, the test is skipped and names the untouched table.
- DELETE and INSERT...SELECT branch coverage. The snapshot-and-replay branch assertions
  now handle a single-target DELETE and INSERT...SELECT, not just UPDATE / INSERT...VALUES.
- TABLE-VALUED PARAMETERS. A procedure with a TVP is now auto-tested: the generator builds
  and seeds a table variable of the type and passes it (such procedures were previously
  NOT_TESTABLE). The coverage instrumenter emits table parameters schema-qualified + READONLY.
- ROW-LEVEL SECURITY. SafeFakeTable now drops a SECURITY POLICY (and its predicate-function
  chain) before faking, so RLS-protected tables can be faked instead of dooming the test
  with "participates in enforced dependencies".

Honesty fixes (no false failures — every non-pass is a pass, a labelled skip, or a clear
NOT_TESTABLE):

- Error-expectation tests are no longer over-generated. A CATCH-block re-throw is no longer
  mistaken for input validation, and a parenthesis-less THROW (THROW n,'msg',state;) is now
  detected — so "must reject" / "raises error" tests fire only for genuine validation guards.
- When the generated happy / boundary / NULL inputs cannot satisfy a procedure's own
  validation, the affected tests are SkipTest-annotated with a clear reason instead of
  failing by construction.
- A FOR JSON / FOR XML result set no longer errors the row-baseline test (it cannot be
  captured via INSERT...EXEC); that single test is skipped for such procedures.

## Earlier releases

Full release history (v0.9.14 back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
