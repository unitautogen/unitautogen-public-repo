@{
    ModuleVersion     = '0.14.1'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen - auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework AND the in-database (SQLCLR) predicate parser, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube. The single C# predicate parser runs inside SQL Server (no PowerShell-side parser); installation registers it and requires sysadmin once plus ''clr enabled''=1.'
    PowerShellVersion = '5.1'
    RootModule        = 'UnitAutogen.psm1'

    FunctionsToExport = @(
        'Install-UnitAutogenDatabase',
        'Invoke-UnitAutogen',
        'Export-CoverageCoberturaXml',
        'Export-TestResultsJunitXml',
        'Export-CoverageHtmlReport',
        'Export-UnitAutogenTests'
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
## v0.14.1 (beta) - 2026-06-13

OUTPUT-value assertions get smarter, plus result-set test polish. All changes are additive
and conservative (no false failures); regenerate existing test classes to adopt them.

- Scalar OUTPUT parameters are now VALUE-asserted. The "assigns its OUTPUT parameters" test and
  the per-branch tests assert each output value -- exact (AssertEqualsString) for a deterministic
  output, or a constant LIKE skeleton (the string literals in the procedure body, with the
  runtime-varying spans wildcarded) when the output mixes constants with GETDATE / NEWID / RAND.
- Determinism is CONFIRMED BY MEASUREMENT, not just a source scan. Each output is measured twice
  in independent rolled-back runs separated past a clock tick; the exact value is asserted only
  when the source scan is clean AND both runs agree, otherwise it falls back to the skeleton -- so
  non-determinism hidden in a called function/procedure, a SCOPE_IDENTITY / sequence read, or
  order-sensitive aggregation cannot bake a value that later false-fails.
- The "executes with valid inputs" test is now a uniform smoke check for both read and write
  procedures, and the "returns rows matching baseline" test names its table explicitly
  (@ActualTable = N'#ActualResult'), matching the tSQLt table-name convention.
- NOT_TESTABLE and instrumentation messages reworded to neutral, professional guidance.

Regression-clean on AdventureWorks2025, HighValueCustomer and WideWorldImporters (0 fail / 0 err).

## v0.14.0 (beta) - 2026-06-12

BUG-001 FIX - generated branch tests restored to Arrange-Act-Assert with real effect
assertions; plus the new Export-UnitAutogenTests command.

- Seeded predicate-branch tests previously asserted the gate predicate on the seed BEFORE
  running the procedure (Arrange-Assert-Act) and never checked what the branch did -- a
  wrong-value / wrong-WHERE write passed the whole class green. They now run
  Arrange -> Act -> Assert and assert the arm's OBSERVED effect: INSERT adds rows, DELETE
  removes rows, UPDATE changes content with the row count held. The test captures its own
  before/after, so GETDATE()-style non-determinism cannot false-fail; anything the
  generator cannot resolve falls back to the previous smoke test (no false failures).
- New scripts/Check_Invariants.sql - a CI guard that fails if any generated test asserts
  before it executes the procedure under test. Regenerate existing test classes to adopt
  the new assertions.
- New Export-UnitAutogenTests scripts in-database test classes into a portable, idempotent
  .sql with a pre-flight guard requiring tSQLt + TestGen on the target.

## v0.13.0 (beta) - 2026-06-11

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

## Earlier releases

Full release history (v0.12.0 back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
