@{
    ModuleVersion     = '0.16.1'
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

## v0.15.9 (beta) - 2026-06-15

A correctness fix to derived-arithmetic seeding, plus several seeding bug fixes.

- FIX: a witness for a derived-arithmetic branch could PASS without actually COVERING
  its arm when the value was derived through an aggregate over another table - the
  test's baseline seed row for that table shifted the aggregate, so the computed value
  missed the threshold. The generator now clears such aggregate-source tables after the
  baseline seeding, so the witness's own seed controls the aggregate. On a trade-
  reconciliation procedure this lifted branch coverage from 62.5% to 93.8%.
- More gate shapes are now seeded: an aggregate-band gate over a date-windowed table (a
  previous illegal EXEC-argument expression is fixed), an operand assigned from a loop
  #temp, and an OR of column comparisons.
- Validated; full regression on AdventureWorks2025 (PredicateZoo), a JSON/MERGE/
  transaction procedure, and a multi-procedure analytics DB all unchanged. No C#/CLR change.

## v0.15.8 (beta) - 2026-06-15

Reverse seeding for derived arithmetic locals now also handles compound conditions
and sum / multi-step expressions.

- A compound branch like "IF @AdjustedValue > 100000 AND @WavePatternPhase = 'C'",
  where the second test depends on a different source (a flag set from an aggregate
  over another table), is now seeded by coordinating BOTH sources: the arithmetic
  driver as before, plus a synthesised seed for the aggregate that sets the flag (one
  row past the threshold, with any date-window filter satisfied). A compound gate
  whose extra condition cannot be satisfied still stays honestly NOT_TESTABLE.
- Derived locals built with addition (a + b) are now handled alongside products, and
  the driver is traced through intermediate locals (a = b; b = c * Col) - multi-hop -
  to its source column.
- Validated: a trade-reconciliation proc's compound risk-limit branch went from
  skipped to covered, and a synthetic loop proc's sum and multi-hop branches reached
  100%. Full regression on AdventureWorks2025 (PredicateZoo), a JSON/MERGE/transaction
  proc, and a multi-procedure analytics DB all unchanged. No C#/CLR change.

## v0.15.7 (beta) - 2026-06-15

Reverse seeding now covers a branch whose condition compares a DERIVED arithmetic
local to a literal - e.g. "IF @AdjustedValue > 50000" where
@AdjustedValue = @Volume * @Price * @RiskMultiplier is computed from per-row loop
columns and other locals.

- Such a gate was previously skipped NOT_TESTABLE ("comparison does not involve an
  aggregate/scalar subquery"). The seeder now traces the operand through its arithmetic
  to the source columns, neutralises the co-factor columns (so the product reduces to a
  single driving column), pins non-row factors via the existing FakeTable of every
  referenced table, and sets the driving column deterministically just past the literal -
  covering the arm without a search (which also avoids the per-gate sweep timeout on loop
  procedures).
- Restricted to a simple single comparison; a compound gate (e.g. "@v > 100000 AND
  @phase = 'C'") with a conjunct the path cannot satisfy stays honestly NOT_TESTABLE.
- Validated on a trade-reconciliation loop procedure (two derived-local arms skip ->
  covered, with verified seeds + an OUTPUT assertion); full regression on
  AdventureWorks2025 (PredicateZoo), a JSON/MERGE/transaction procedure, and a
  multi-procedure analytics database all unchanged. No C#/CLR change.

## v0.15.6 (beta) - 2026-06-15

Statement-aware coverage instrumentation - dense one-liner procedures now report
honest branch coverage instead of a false 0%.

- A procedure written with an IF, its THEN body, and its ELSE all on one physical
  line (or several statements separated by ; on one line) previously defeated the
  line-based coverage walker: the branch arms shared the predicate's line, so none
  could be measured (0% branch) even though the generated tests exercised them all.
- A new normalization pass (run before instrumentation) reformats such lines onto
  canonical one-statement-per-line form so every arm is measured. It is quote /
  comment / bracket / paren / CASE aware (a CASE expression's WHEN/THEN/ELSE/END is
  never mistaken for control flow), idempotent, and a no-op on already-well-formatted
  procedures - so it changes nothing for procedures that already measured correctly.
- Validated: a dense IF/ELSE procedure went from a false 0% branch to a true 100%
  (6/6) with no source change; full regression on AdventureWorks2025 (PredicateZoo),
  a JSON/MERGE/transaction procedure, and a multi-procedure analytics database all
  unchanged. No C#/CLR change.

## v0.15.5 (beta) - 2026-06-14

Auto-generation now drives JSON-shredding, transaction-managing procedures to full
coverage - deterministic "deep-gate" witnesses for the branch shapes the iterative
search could not reach.

- A new derivation (TestGen.DeriveDeepGateWitnesses) reads the procedure's own structure -
  the key-lookup SELECT (table, key column/param, the local-to-column map), and the
  OPENJSON(@param) WITH(...) shred + catalog JOIN + filter - and synthesises a valid JSON
  parameter literal plus coordinated real-table seeds. It then emits verified witness tests for:
  parameter NULL-guards, @@ROWCOUNT "not found" checks, key-lookup status scalars
  (e.g. an "is active" flag), and aggregate gates over a table VARIABLE populated by the JSON
  shred (e.g. total-due vs a credit-limit column, or a shortage count) - pivoting the seed to
  the comparand's real source column instead of the un-seedable table variable - plus a
  happy-path scenario that falls through every gate.
- These run BEFORE the iterative search, which now skips any gate already witnessed - so this
  whole class of procedure is covered deterministically and fast (no per-candidate sweep).
- Self-contained witnesses (which provide their own arguments + seeds) no longer get a
  spurious ExpectException when the procedure catches its own RAISERROR internally.
- The generic base tests are also more robust on this proc shape: a parameter consumed by
  OPENJSON gets valid JSON in the smoke tests (not arbitrary text that breaks parsing); the
  "raises"/"rejects" error-expectation tests are skipped when the procedure swallows its own
  errors in a non-rethrowing CATCH; and the OUTPUT constant-skeleton no longer mashes a literal
  that is a substring of a longer one (e.g. ''SUCCESS'' inside ''FULL_SUCCESS'').
- Validated: a complex order-processing proc (OPENJSON shred + window CTEs + MERGE + a
  self-managed transaction with several rejection paths) goes from a partial result to
  100% line (35/35) and 100% branch (6/6), with the whole generated suite green
  (11 passed / 0 failed / 0 errored / 8 honest skips).
  PredicateZoo regression on AdventureWorks2025 green (deep-gate derivation is a no-op on
  procedures without that shape). No C#/CLR change.
- The generic boundary "accepts" tests are no longer falsely skipped on a procedure that manages
  its own transaction: the generation-time probe now recognises that a "mismatching BEGIN and
  COMMIT" error (266) is the procedure's own transaction control, not a rejected input.
- NEW TestGen.RunTests @SchemaName, @ProcName runs a procedure's generated tests and returns
  pass/fail. It handles a procedure that manages its OWN transactions - which a direct tSQLt.Run
  cannot, because the procedure's ROLLBACK collapses tSQLt's per-test transaction and FakeTable
  setup - by running those tests against the transaction-neutralized shadow (reusing the coverage
  swap; no coverage permission required, it degrades gracefully). Plain procedures run directly.

## Earlier releases

Full release history (v0.12.0 back to v0.9.0) is in CHANGES.md and on the GitHub
Releases page: https://github.com/unitautogen/unitautogen-public-repo/releases

'@
        }
    }
}
