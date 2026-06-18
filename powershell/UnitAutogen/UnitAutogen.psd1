@{
    ModuleVersion     = '0.16.7'
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
## v0.16.7 (beta) - 2026-06-18

- **Nondeterministic-gate guard (no more runaway searches).** A branch whose operand is built from a
  runtime value the seeder cannot control - a clock (SYSDATETIME / GETDATE / CURRENT_TIMESTAMP / ...),
  NEWID, or RAND - is now detected up front and reported as an honest NOT_TESTABLE, instead of the
  search-seeding sweep grinding (in one pathological loop-accumulator fixture, 37+ minutes of CPU)
  before giving up. The detector scans the operand's own assignment lineage; @@ROWCOUNT-style globals
  are deliberately NOT treated as nondeterministic (they reflect seedable row state).
- **Search backstops.** A per-gate wall-clock budget (default 90s) abandons any non-converging search,
  and the loop-count row-count knob is capped at @MaxSeedRows (default 500) so a large comparand can't
  request 100k+ seeded rows per probe. Raise @MaxSeedRows to test a gate that genuinely needs more.
- Pure T-SQL; no CLR change. Validated on AdventureWorks2025 (the fixture now resolves in ~10s; pz
  loop/count/aggregate/scalar/OR gates unchanged) and HighValueCustomer (AssessCustomer 6/6, Reconcile
  15/16 with all witnesses intact) - all 0 fail / 0 err.

## v0.16.6 (beta) - 2026-06-17

- **IN / BETWEEN in a WHERE are now seeded** (in-database parser enhancement). A branch gated on
  EXISTS/COUNT over "... WHERE col IN (v1, v2, ...)" was previously NOT_TESTABLE; the parser now
  expands it to an OR of equalities, so coverage generates one TRUE test PER value (each seeding a row
  matching only that value). "col BETWEEN a AND b" expands to col >= a AND col <= b and is seeded.
  Requires the updated in-database CLR parser (re-run installer step 2).
- Validated on AdventureWorks2025 (IN gate -> per-value tests with distinct seeds; BETWEEN seeded);
  PredicateZoo regression unchanged.

## v0.16.5 (beta) - 2026-06-17

- **OR per-arm coverage.** A branch gated on a multi-condition OR over a table (e.g.
  EXISTS(... WHERE a = 1 OR b = 2 OR c = 3)) now generates one TRUE test PER disjunct - each seeding a
  row that satisfies only that arm - instead of a single TRUE test for the first arm, so every OR arm
  is exercised independently. (Branch coverage is unchanged; this adds condition-level thoroughness.)
- A column IN (...) / BETWEEN in a WHERE, and COUNT(col) NULL semantics, remain dependent on a future
  in-database parser enhancement.
- Validated on AdventureWorks2025 (synthetic OR gate: per-arm seeds verified distinct); PredicateZoo
  regression unchanged. No C#/CLR change.

## v0.16.4 (beta) - 2026-06-17

- **Temp-table tracing.** A branch gated on a #temp populated by SELECT ... INTO #t FROM <base>
  (e.g. a loop bounded by the temp's row count) is now covered: the seeder traces the #temp back to
  its base table and seeds that, since the procedure itself fills the #temp at run time. These gates
  were previously skipped ("target table not found").
- **Parenthesised derived locals - correctness guard.** A per-row arithmetic gate whose value groups
  an additive sub-expression in parentheses (e.g. value = qty * (price - fee)) is now left as an
  honest NOT_TESTABLE instead of being mis-flattened into a wrong witness. (Full distribution is
  future work; pure-product parens and paren-free expressions are unaffected.)
- Validated on AdventureWorks2025 synthetics; PredicateZoo regression unchanged. No C#/CLR change.

## v0.16.2 (beta) - 2026-06-17

Seeder-robustness batch (1 of 2 from an external code review). The deeper test-generator
and parser items follow in v0.16.3.

- A new per-run **@MaxSeedRows** parameter on GenerateAndRunCoverage / GenerateAndCoverDatabase
  makes the seed-row cap tunable (was hardcoded 500); a COUNT(*) gate needing more rows can now
  be covered by raising it. Default 500 - existing behaviour unchanged.
- **Date and string range predicates are now seeded.** A comparand using >, >=, <, <= on a
  date/datetime or string (reporting windows, alphabetical filters) was previously a silent skip;
  the seeder now produces a satisfying value (DATEADD past a date bound; a collation-safe boundary
  for strings). The aggregate-filter seeder reuses the same logic, so "... WHERE d <= '<date>'"
  no longer excludes the seeded row.
- A branch gated on a **single-column contradiction** (e.g. x > y AND x < y) is now reported as
  PROVABLY UNREACHABLE (dead code) instead of a generic skip, via a new constraint classifier.
- Validated on AdventureWorks2025 (configurable-cap and dead-branch synthetics; PredicateZoo
  count/scalar/sum gates unchanged at 100%). No C#/CLR change.

## v0.16.1 (beta) - 2026-06-15

Two narrower derived-value and aggregate shapes are now seeded to full branch coverage.

- A derived local that uses SUBTRACTION (e.g. value = qty * price - fee, or qty * price
  - 100) is now covered. A subtracted column is neutralised to 0 like any other term; a
  subtracted (or added) numeric constant is folded into the knob so the driving term
  still crosses the threshold exactly.
- An aggregate gate whose source has a NON-equality filter is now satisfied: numeric
  >, >=, <, <= seed a value just inside the bound; IN (...) seeds the first list value;
  BETWEEN seeds the low bound. (Equality and date ">=" windows were already handled.)
- Validated on a synthetic loop procedure (100% line + branch); full regression on
  AdventureWorks2025 (PredicateZoo aggregate/scalar gates), a JSON/MERGE/transaction
  procedure, and a multi-procedure analytics DB all unchanged. No C#/CLR change.

## v0.16.0 (beta) - 2026-06-15

Two more derived-value and aggregate shapes are now seeded to full branch coverage.

- A derived local that MIXES multiplication and addition (e.g. value = qty * price +
  fee) is now covered. The generator splits the expression into additive terms, drives
  the term holding the chosen column and neutralises the rest, so the computed value
  crosses the threshold exactly. Pure-product and pure-sum cases are unchanged.
- An aggregate gate whose source has a NON-date filter (e.g. AVG(Score) FROM Metrics
  WHERE Status='ACTIVE') now seeds a row that PASSES the filter instead of a placeholder
  the filter excluded (which left the aggregate NULL and the branch uncovered). This also
  fixes compound gates that reuse such an aggregate to set a flag.
- Validated on a synthetic loop procedure (100% line + branch); full regression on
  AdventureWorks2025 (PredicateZoo aggregate/scalar gates), a JSON/MERGE/transaction
  procedure, and a multi-procedure analytics DB all unchanged. No C#/CLR change.

## Earlier releases

Full release history (v0.15.x back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
