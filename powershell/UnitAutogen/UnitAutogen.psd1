@{
    ModuleVersion     = '0.9.6'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Munaf Ibrahim Khatri'
    CompanyName       = 'UnitAutogen'
    Copyright         = '(C) 2026 Munaf Ibrahim Khatri. Licensed under AGPL-3.0.'
    Description       = 'PowerShell module for UnitAutogen — auto-generated tSQLt unit tests with real branch coverage for SQL Server. Installs the framework AND the in-database (SQLCLR) predicate parser, runs generation and coverage, and exports Cobertura XML, JUnit XML, and HTML reports for Azure DevOps, GitHub Actions, Jenkins, GitLab CI, and SonarQube. As of v0.13 the single C# predicate parser runs inside SQL Server (no PowerShell-side parser); installation registers it and requires sysadmin once plus ''clr enabled''=1.'
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
## v0.9.6 (beta) — 2026-06-03  (ships the "v0.13" in-database parser)

SSMS-native predicate parser — ONE parser everywhere (the PowerShell ScriptDom
parser is retired):

- The predicate parser now runs INSIDE SQL Server as a SQLCLR assembly (a C# port
  of the old PowerShell parser, hosting Microsoft's ScriptDom). It is exposed as
  EXEC TestGen.ParseDatabasePredicates and is the single parser used by every entry
  point — SSMS, this module, and CI/CD. No more two-parsers-to-keep-in-sync.
- Install-UnitAutogenDatabase now also registers the parser (bundled
  sql\Install-UnitAutogenClr.SSMS.sql). This needs sysadmin (CONTROL SERVER) ONCE
  and 'clr enabled'=1; it trusts the assemblies by SHA-512 hash via
  sys.sp_add_trusted_assembly (no TRUSTWORTHY required).
- Invoke-UnitAutogen calls EXEC TestGen.ParseDatabasePredicates (was: a PowerShell
  step). -SkipPredicateParse still skips it. No ScriptDom cold start anymore.
- Servers that forbid UNSAFE CLR entirely have no parser; data-shape branches then
  fall back to NOT_TESTABLE / string-gen (tSQLt itself already requires CLR).
- Validated: PredicateZoo parity (CLR == old PowerShell parser on all 28 gates) and
  AssessCustomer 100% line + 100% branch end-to-end with zero PowerShell parsing.

## v0.9.5 (beta) — 2026-06-02

Production-safety release.  Two operational fixes:

1. Recovery from interrupted coverage runs (production-critical):
   When a coverage run is killed mid-flight (test cancelled, agent
   crashed, connection dropped), the procedure being instrumented was
   left in a broken state - the base name became a synonym pointing
   at a stale _cov copy, and any application that called the procedure
   would hit the wrong target.  Two new public procedures:

   - TestGen.CleanupInterruptedRunForProc - single-procedure recovery
   - TestGen.CleanupInterruptedRuns       - database-wide sweep with
                                            optional @SchemaFilter and
                                            @WhatIf preview mode

   GenerateAndCoverDatabase now calls CleanupInterruptedRuns at the
   start as a database-wide sweep, so the framework self-heals
   automatically on the next coverage run.  No user action required
   in the normal path.  Recovery is safe and reversible:  _orig is
   renamed back to the original name via sp_rename; the original
   procedure body is preserved (never DROPped).

2. Compatibility-level pre-flight check:
   Installer now detects databases with compatibility_level < 130 and
   aborts with a clear actionable message (instead of cascading errors
   from STRING_SPLIT).  The required ALTER DATABASE statement is
   included verbatim in the error so the user can copy-paste to fix.

## v0.9.3 (beta) — 2026-06-01

Critical fix (affects ALL prior versions — please upgrade):
- Export functions silently truncated their output at 4000 characters
  in v0.9.0, v0.9.1, and v0.9.2 because Invoke-Sqlcmd's default
  -MaxCharLength was not overridden. Export-CoverageCoberturaXml,
  Export-TestResultsJunitXml, and Export-CoverageHtmlReport all now
  pass -MaxCharLength ([int]::MaxValue), so the full content reaches
  disk. Any user who ran Invoke-UnitAutogen against a non-trivial
  database was affected.

Other improvements:
- Validation on AdventureWorks 2025 now reports 94.9% line coverage
  and 94.4% branch coverage (up from 93.9% line / 50% branch on the
  same database under v0.9.1). Branch detection in scalar functions
  with multi-arm CASE expressions is per-arm, and seeding reaches
  each arm. Three AdventureWorks status-text functions now hit
  100% / 100%.

## v0.9.2 (beta) — 2026-06-01

- TVF shadow teardown: defensively drops the synonym/_cov/_orig objects
  before rebuild, eliminating the "already an object named _covfn" failure
  on rerun when a previous coverage run was interrupted.
- Bundled SQL installer updated with v11 function coverage and seeding
  extensions (30_Function_Support_v1.sql, Patch_v11_SeedExtensions.sql,
  Verify_SeedExtensions.sql, Verify_ShadowTeardown.sql).
- New examples/Demo_Schema.sql for an end-to-end walkthrough.
- PowerShell cmdlets unchanged from v0.9.1.

## v0.9.1 (beta)

Bundled SQL framework updated — user-defined function support + branch coverage:
- Test generation + line/branch coverage for scalar (FN), inline (IF) and
  multi-statement (TF) functions, via a shadow-procedure transform.
- GenerateAndCoverDatabase now reports procedures AND functions in one run.
- Hang-proof coverage probe: every shadow loop is capped, so a runaway loop can
  never stall a coverage run.
- Predicate-inversion branch seeding: value-gated branches (e.g. IF @x = 5) are
  reached on purpose by deriving a satisfying parameter value from the code.
- One-line compound function bodies now instrument correctly.

PowerShell cmdlets are unchanged from v0.9.0.

## v0.9.0 (beta)

New in this release:
- Install-UnitAutogenDatabase: deploy the SQL framework from PowerShell in one command
- Invoke-UnitAutogen: full pipeline — generate tests, measure coverage, export all three output files
- Export-CoverageCoberturaXml: Cobertura XML for Azure DevOps / SonarQube
- Export-TestResultsJunitXml: JUnit XML for all major CI systems
- Export-CoverageHtmlReport: self-contained HTML report

Requirements:
- SQL Server 2017 or later
- tSQLt v1.0.7597.5637 or later installed in the target database
'@
        }
    }
}
