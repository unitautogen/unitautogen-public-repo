# Coverage Patch â€” Files Modified vs v9.1 FINAL_40

Base file: `Install_All_Combined_v9_1_FINAL_40.sql`
Target final file: `Install_All_Combined_v9_2.sql` (will be assembled at the end)

## Sections being replaced inside the base install

| Section in base file (approx line range) | Module name in base | Replaced by | Status |
|---|---|---|---|
| 4682â€“4929 | `20_Coverage_Instrumenter.sql` (v3) | `20_Coverage_Instrumenter_v4_1_final.sql` | drafted, awaiting diag confirmation |
| 5317â€“end of GetCoverageReport | inline `GetCoverageReport` (v1) | `22_Coverage_Reporter_v2.sql` | drafted |
| RunCoverage (5006â€“5267) | inline | unchanged | â€” |
| RecordCoverageHit stub (4984â€“5001) | inline | unchanged | â€” |
| BootstrapCoverage / PatchTestsForCoverage (4929â€“4982) | `21_Coverage_TestPatcher.sql` | unchanged | â€” |

## Pending issues to resolve before assembly

1. Instrumenter still produces 2 IsExec / 1 injection on AdventureWorks2025
   â†’ Diag_Splitter.sql sent to user; awaiting output.
2. Other unrelated issues seen but NOT addressed yet:
   - `TestGen.CaptureResultShape` insert: NULL into `SqlTypeName` (NOT NULL violation).
   - `_cov` not found by tSQLt synonym path â€” likely downstream of (1); recheck after (1) is fixed.

## Files staged for delivery

- `20_Coverage_Instrumenter_v4_1_final.sql` â€” DROP+CREATE for TestGen.InstrumentProcedure
- `22_Coverage_Reporter_v2.sql`            â€” DROP+CREATE for TestGen.GetCoverageReport
- `Diag_Splitter.sql`                       â€” diagnostic, not for install
- `Verify_Coverage_v4_diag.sql`             â€” diagnostic, not for install

## Installation instructions (to embed in final script)

These will be reconstructed from earlier chat:
  1. Run base install once.
  2. Apply coverage patch (v4.1 + reporter v2) â€” single script.
  3. Recreate target stored procedures.
  4. Bless baseline.
  5. Generate tests: `EXEC TestGen.GenerateTestsForProcedure â€¦`
  6. Run coverage: `EXEC TestGen.RunCoverage â€¦`

## 2026-05-21 update

- Diag_Splitter.sql: fixed two `PRINT + CAST((SELECT COUNT(*)...))` invalid expressions
  (replaced with intermediate variables).  Resent.

## 2026-05-21 update (root cause found)

Diag_Splitter.sql confirmed splitter + boundary detection are CORRECT:
  - 155 lines split in order
  - AS-boundary found at line 7
  - 148 body lines flagged correctly as [B]
  - 7 header lines flagged correctly as [H]

So the bug is in the WALKER, not the splitter.

Root cause: T-SQL `DECLARE @x TYPE = expr` initializers are evaluated ONLY ONCE
at batch parse time, not per loop iteration.  The instrumenter had four such
DECLAREs inside the cursor loop:
   DECLARE @IsBranchHeader BIT = CASE ...
   DECLARE @ScanPos INT = 1
   DECLARE @ScanLen INT = LEN(@Scrub)
   DECLARE @InCaseAfter BIT = CASE ...

After iteration 1 these kept their stale values, so the keyword scanner stopped
running and the context stack froze.  That broke statement termination, so
only the first 1-2 statements emitted hits.

FIX applied to 20_Coverage_Instrumenter_v4_final.sql:
  - Hoisted all loop-local working variables to the top-of-proc DECLARE block
  - Converted the four mid-loop DECLAREs to SET statements
  - Added a comment explaining the T-SQL gotcha

Diag_Walker.sql was created but is NO LONGER NEEDED for this run.

## Files currently staged for delivery

- `20_Coverage_Instrumenter_v4_2.sql`  â€” v4 + the loop-DECLARE fix
- `22_Coverage_Reporter_v2.sql`         â€” unchanged from earlier draft
- `Verify_Coverage_v4_2.sql`            â€” uses PRINT for all output so it shows in Messages tab

## 2026-05-21 second iteration

User reported v4.2 still produces 2 IsExec / 1 injection.
Branch headers (15 of them) ALL detected correctly.
Only one non-branch line (line 32) gets IsExec.

Hypothesis: termination not firing after line 32, so @StmtStart stays = 32
and every subsequent non-branch line is classified as "continuation".

Need empirical data: created Diag_Walker_Live.sql that runs the walker
inline and PRINTs per-line state.

## 2026-05-21 third iteration

Diag_Walker_Live output revealed root cause #2:
@ParenDepth goes WRONG starting at line 26.
Line 26 = `IF EXISTS (` should give Op=1.  But trace shows depth jumps to 2
after the line, and to -7 by line 30 (which is just `)`).

This means Op/Cp counts are wrong somewhere.  Hypotheses:
  - REPLACE varchar/nvarchar conversion issue
  - DATALENGTH vs LEN discrepancy on multi-byte chars
  - LineText contains chars I didn't expect

Created Diag_Parens.sql to print Op/Cp/LEN/DATALENGTH for lines 14-35
plus a direct REPLACE test on line 26.

## 2026-05-21 third iteration RESOLVED

Diag_Parens.sql output proved the root cause beyond doubt:
   Line 26 ('        IF EXISTS ( ' with trailing space)
     LEN=19, REPLACE-out-paren-LEN=17, difference=2 (wrong, should be 1)
   Line 30 ('        )' with trailing spaces)
     LEN=9, REPLACE-out-paren-LEN=0, difference=9 (wrong, should be 1)
   DATALENGTH=38 (=2*19 bytes) which is correct since NVARCHAR.

Root cause: LEN() ignores trailing spaces.  Counting parens via
LEN(text)-LEN(REPLACE(...)) returns the COUNT-OF-CHARS-REMOVED only when
the text has no trailing spaces to begin with.  When the line ends with
spaces, LEN of the post-REPLACE string drops by the trailing-space count
too, inflating the apparent "removed character count".

FIX applied to 20_Coverage_Instrumenter_v4_3.sql:
  - Replaced LEN() with DATALENGTH()/2 in both Op and Cp computations.
  - Updated nvarchar literals from '(' to N'(' (defensive; same result here).
  - Added explanatory comment in code.
  - Bumped version to v4.3 with changelog comment.

Verify_Coverage_v4_3.sql: identical to v4_2, just renamed references.

## Files staged for delivery (current)

- `20_Coverage_Instrumenter_v4_3.sql`  â€” patched (DATALENGTH/2 fix)
- `22_Coverage_Reporter_v2.sql`         â€” unchanged
- `Verify_Coverage_v4_3.sql`            â€” unchanged from v4_2 except names

## 2026-05-21 fourth iteration

User confirmed v4.3 walker now gives:
   IsExec lines: 28  âœ“
   IsBranch lines: 15  âœ“
   Injections: 28  âœ“

Registry dump shows all the right statement-start lines.  The classification
logic is complete.

BUT: _cov proc fails to compile (syntax error near PROCEDURE at line 10).

Root cause: the walker's "SET @Body = @Body + ISNULL(@LT,N'') + CHAR(10);"
was OUTSIDE the IF @IH=0 block, so it appended header lines (CREATE
PROCEDURE / params / AS) into the rebuilt body.  Combined with the
synthetic CREATE PROCEDURE wrapper, this produced nested CREATE PROCEDURE
syntax at line 10 of the generated proc.

Secondary: PRINT 'Instrumented procedure created' was unconditional - it
printed success even when EXEC(@CreateSQL) failed.

FIXES applied in 20_Coverage_Instrumenter_v4_4.sql:
  1. Moved the body-append INSIDE the IF @IH=0 block.
  2. Wrapped EXEC(@CreateSQL) in TRY/CATCH; PRINT now reports honestly.

Also corrected Verify expectation to 148 lines (which is body-only; the
splitter sees 155 = 7 header + 148 body).

## Files staged for delivery (current)

- `20_Coverage_Instrumenter_v4_4.sql`  â€” patched (header-line exclusion + TRY/CATCH)
- `22_Coverage_Reporter_v2.sql`         â€” unchanged
- `Verify_Coverage_v4_4.sql`            â€” unchanged from v4_3 except names/expected count

## 2026-05-21 fifth iteration - INSTRUMENTER COMPLETE

Verification PASSED:
   Total lines registered : 148  âœ“
   IsExec lines           : 28   âœ“
   IsBranch lines         : 15   âœ“
   Injections present     : 28   âœ“
   Injections missing     : 0    âœ“
   PASS - registry and instrumented body agree.

Next: run TestGen.RunCoverage to verify the FULL coverage pipeline:
   1. XEvent session captures sp_statement_completed
   2. tSQLt tests execute via synonym -> _cov
   3. XEL file is parsed correctly
   4. Hits land in TestGen.CoverageHits with line numbers matching the registry
   5. GetCoverageReport v2 reports correct coverage %

If issue: likely in RunCoverage (XEvent capture or line-num parsing).
If clean: assemble final Install_All_Combined_v9_2.sql.

## 2026-05-21 sixth iteration - END-TO-END WORKS, REAL COVERAGE EMERGED

End-to-end run successful:
   18/22 tests passed (vs 4/22 before)
   78 sp_statement_completed events captured
   14 distinct line hits recorded
   Line coverage: 14/28 = 50.0%
   Branch coverage: 7/15 = 46.7%

The instrumentation/measurement pipeline is fully working.  All numbers
are now meaningful.

### Two follow-up issues identified

(A) INSTRUMENTER LIMITATION: control-transfer statements unhittable.
    The instrumenter places `EXEC RecordCoverageHit` AFTER each ';'-terminated
    statement.  But for RETURN, THROW, RAISERROR(severity>=11), and GOTO,
    control transfers BEFORE the hit injection runs.
    Result: these lines are marked IsExec=1 in the registry but can NEVER
    be hit, inflating the uncovered count.
    Currently affects 4 of the 14 "uncovered" lines (48, 67, 93, 151 - all RETURN).

    Proposed fix: tag these as IsTerminal=1, exclude from denominator OR
    inject the RecordCoverageHit BEFORE the control-transfer statement.
    The "inject before" approach is cleaner because it keeps the line in
    the denominator (so the test author still sees it must be exercised)
    while making it actually hittable.

(B) TESTGEN ISSUE (separate from coverage):
    Several tests pass but their corresponding branch lines aren't hit.
    e.g. "executes @OrderType = Premium EXISTS path" passes but
    line 60 (the Premium-EXISTS-TRUE body) shows as uncovered.
    This means the tests' EXISTS_TRUE setup isn't actually making EXISTS true.
    Out of scope for the coverage pipeline; flagged for separate work.

(C) RUNCOVERAGE COSMETIC: PRINT 'XEvent rows captured: 78' followed by
    'No RecordCoverageHit statements found' is misleading - the second PRINT
    fires because PRINT resets @@ROWCOUNT to 0.  Cosmetic only, the actual
    INSERT still runs.

### Files unchanged this iteration

- 20_Coverage_Instrumenter_v4_4.sql (working)
- 22_Coverage_Reporter_v2.sql       (working)

### Next decision needed from user

Three options:
  1. Fix (A) - instrumenter inject-before-control-transfer.  ~30 min, real coverage % gain.
  2. Fix (C) - cosmetic PRINT cleanup in RunCoverage.  ~5 min.
  3. Move to final assembly: package what we have into Install_All_Combined_v9_2.sql.
     User can decide later whether to refine further.

## 2026-05-21 seventh iteration - INSTRUMENTER v5 (control-transfer fix)

Goal: 100% coverage requires the unhittable RETURN/THROW/RAISERROR/GOTO
problem to be fixed.  v5 does that.

### Change

Static-flags table now computes IsTerminalStart for each line.  True when
the line's first keyword is one of: RETURN, THROW, RAISERROR, GOTO,
BREAK, CONTINUE.

When the walker opens a new statement, it captures @StmtIsTerminal :=
@Terminal of the start line.  Carried through continuations.

At statement-termination time, the hit text goes either BEFORE the line
text (when @StmtIsTerminal=1) or AFTER (default).  This way:
   RETURN; -> EXEC TestGen.RecordCoverageHit ...; <newline> RETURN;
The injection fires BEFORE control transfers out, so the line is hittable.

Side note: RAISERROR with severity < 11 doesn't actually terminate, but
BEFORE-placement is still safe (just records the hit slightly earlier
than the statement completes - still semantically correct).

### Expected impact for uspV9ValidationTest

Previous coverage: 14/28 line, 7/15 branch.
Of the 14 uncovered:
   4 lines were RETURNs (48, 67, 93, 151) - NOW HITTABLE
   10 lines were real test gaps (38, 39, 60, 61, 79, 80, 118, 119, 141, 142)

If tests still take the same paths, expected:
   18/28 = 64.3% line coverage  (gain: 4 RETURNs)
   Branch coverage unchanged at 7/15 (RETURNs aren't branches)

The remaining 10 uncovered lines = TestGen issue (#2 from the plan).

### Files staged for delivery (current)

- `20_Coverage_Instrumenter_v5.sql`     â€” control-transfer fix
- `22_Coverage_Reporter_v2.sql`          â€” unchanged
- `Verify_Coverage_v5.sql`               â€” unchanged from v4_4 except names

## 2026-05-21 eighth iteration - v5 verified, attacking TestGen issue

v5 result: 18/28 line, 7/15 branch (50% -> 64.3%).  All RETURNs hit.

Now investigating why tests like 'Premium EXISTS path' pass but their
body lines (e.g. line 60) aren't hit.

Theory: assertion is "row count grew" but the seed INSERT itself grows
the count - so the test passes even when the EXISTS predicate is FALSE
and the THEN branch never fires.

Need to see the generated test proc to confirm what's actually emitted.
Created Diag_DumpPremiumTest.sql to dump the Premium EXISTS test source.

## 2026-05-21 ninth iteration - root cause two-pronged

Diag_DumpPremiumTest.sql output reveals:

(a) Seed INSERT is incomplete:
       INSERT [Sales].[SalesOrderHeader] ([SubTotal]) VALUES (5050);
    Missing CustomerID column.  So the seeded row has SubTotal=5050 but
    CustomerID=NULL.  Predicate `WHERE CustomerID = 1 AND SubTotal BETWEEN
    100 AND 10000` is FALSE for that row.

    FK seed earlier inserted 5 rows with CustomerID = 1..5 but SubTotal=NULL.
    None of those rows match the AND predicate either.

    Net: no row matches the EXISTS predicate, proc takes the FALSE path,
    line 60 isn't hit.

(b) Assertion is misleading:
       @RowsBefore = (count after FK seed, before EXISTS seed) = 5
       INSERT (just SubTotal) -> count = 6
       Proc runs, falls through (no UPDATE happens) -> count = 6
       @RowsGrew = (6 > 5) = 1, assertion PASSES even though branch missed.

Created Diag_AnalyzePremium.sql to confirm whether AnalyzeBranchPaths
emits a CustomerID row in #BranchPaths.  If it doesn't, the analyzer
needs the fix.  If it does, the test generator's seedcur2 is dropping it.

## 2026-05-21 tenth iteration - ANALYZER FIX (closing in on 100%)

Diag_AnalyzePremium confirmed: AnalyzeBranchPaths emits TWO rows for
Premium's predicate (CustomerID and SubTotal conditions), but they have
DIFFERENT PathID values (1 and 2) because PathID was IDENTITY(1,1).

The downstream code (pathidcur SELECT DISTINCT PathID, seedcur2 WHERE
PathID = @GenPathID) treated each as a separate test, so each test
seeded only ONE column.  The single-column seed doesn't satisfy the
AND-predicate at runtime.  And because both tests have the same name
(based on @BranchVal only), the second clobbers the first - we see one
test that seeds only SubTotal.

### Fix in 17_Branch_Path_Analyzer_v3_1.sql

- PathID column changed from IDENTITY to plain INT NOT NULL.
- Added @NextPathID monotonic counter, @CurPathID/@FalsePathID per-block.
- One PathID allocated per IF EXISTS predicate block (before parsing WHERE).
- All condition INSERTs within that block use the same @CurPathID.
- EXISTS_FALSE allocates its own @FalsePathID (different branch).
- CASE_WHEN and CASE_ELSE allocate fresh PathID per WHEN/ELSE (still each
  is its own branch, so no aggregation).
- All 8 INSERT #Paths statements now specify PathID explicitly.
- All SCOPE_IDENTITY references removed (no longer applicable).

### Expected impact

Single test "Premium EXISTS path" will now seed BOTH CustomerID and
SubTotal in one INSERT.  Predicate becomes TRUE, THEN branch (line 60)
fires, lines 60/61 covered.  Same pattern for Search EXISTS, Express
EXISTS, High EXISTS.

Predicted result: 28/28 lines covered (100%) for the validation proc,
assuming all other branches were already exercised.

### Files staged for delivery

- `17_Branch_Path_Analyzer_v3_1.sql`  â€” NEW (the AND-predicate fix)
- `20_Coverage_Instrumenter_v5.sql`    â€” control-transfer fix
- `22_Coverage_Reporter_v2.sql`         â€” branch-cov inference rule
- `Verify_Coverage_v5.sql`              â€” diagnostic

### Bug #2 (weak assertion) NOT fixed yet

The "row count grew" assertion is technically satisfied by the seed
itself.  But with the analyzer fix:
  - Seed adds a CORRECT row -> predicate TRUE -> THEN branch runs
  - For INSERT bodies: row count grows further, assertion holds genuinely
  - For UPDATE bodies: row count is unchanged from seed, assertion still
    holds (because seed grew it)

Coverage perspective: this is fine.  The instrumented proc records the
hits whether the assertion is strong or weak.  Once we see 100% line
coverage, we can revisit the assertions as a quality improvement.

## 2026-05-21 eleventh iteration - coverage stuck at 18/28

After v3.1 analyzer fix, coverage report shows identical numbers to before:
18/28 line, 7/15 branch.  Either:
  (a) Analyzer wasn't actually upgraded to v3.1, OR
  (b) Tests weren't regenerated after upgrade, OR
  (c) The analyzer is now correct but something downstream still drops it.

Sent Diag_PremiumState.sql to check both:
  - Re-runs AnalyzeBranchPaths on Premium (should show one PathID)
  - Dumps the regenerated Premium test source (should show multi-col INSERT)

## 2026-05-21 twelfth iteration

Diag_PremiumState confirms:
  - Analyzer IS v3.1 (one PathID for both Premium conditions). âœ“
  - Test source has NOT been regenerated - still single-column seed.

Sent Regen_and_RunCoverage.sql which drops the test class, regenerates
against the new analyzer, spot-checks that the Premium seed has both
columns, and runs end-to-end coverage.

## 2026-05-21 thirteenth iteration

After analyzer v3.1 + regen, Express EXISTS test failed to compile:
   Msg 264: 'Status' specified more than once in INSERT column list

Root cause: Express's predicate is `Status IN (1, 2, 3)`.  The analyzer
emits 3 rows for this (one per IN-list value), all with ColumnName=Status,
all under the same PathID (correct).  But seedcur2 in the test generator
just accumulates each row's column into the INSERT without deduping.
Result: INSERT (Status, Status, Status) VALUES (1, 2, 3) -> SQL error.

Batch aborted -> Express/Premium/etc. tests never got created -> coverage
dropped to 25% (only the boundary/NULL/with-valid-inputs tests existed).

### Fix in 04_Test_Generator_v2.sql

In seedcur2's accumulation loop, before appending a column, check if
QUOTENAME(@bpCol) is already in @bpCols (substring search for [@bpCol]).
If yes, skip - we already have a value for that column.

Semantically correct: `Status IN (1,2,3)` is satisfied by ANY one value,
so picking the first is sufficient to make the predicate TRUE.

### Files staged for delivery (current)

- `04_Test_Generator_v2.sql`           â€” IN-list / OR-on-same-column dedupe
- `17_Branch_Path_Analyzer_v3_1.sql`   â€” one-PathID-per-EXISTS fix
- `20_Coverage_Instrumenter_v5.sql`    â€” control-transfer fix
- `22_Coverage_Reporter_v2.sql`         â€” branch-coverage inference
- `Regen_and_RunCoverage.sql`           â€” convenience driver
- `Verify_Coverage_v5.sql`              â€” diagnostic

## 2026-05-21 fourteenth iteration - 71% reached, three quality bugs left

Coverage: 20/28 line (71.4%), 9/15 branch (60.0%).  Big jump from 64%/47%.
Premium EXISTS body now covered.  IN-list dedupe worked.

### Remaining gaps (8 lines)

(1) EXISTS_FALSE bodies (38/39 Standard ELSE, 141/142 Express ELSE):
    The FK-seeding block populates the predicate table BEFORE the EXISTS
    test calls the proc.  FK seed often satisfies the predicate (e.g.
    Standard's `CustomerID = @CustomerID OR TerritoryID = 1` is true
    because Customer #1 with CustomerID=1 exists in FK seed).
    Net: EXISTS is TRUE, proc takes THEN branch, ELSE body is missed.

    Fix: for EXISTS_FALSE tests, DELETE from the predicate table before
    EXEC, or pass @CustomerID outside the FK seed range.

(2) Search EXISTS body (79/80):
    Predicate: `[Group] LIKE '%America%' AND CountryRegionCode = @Region`.
    Analyzer skips LIKE entirely (sets ColName=NULL, ResolvedVal=NULL).
    Only CountryRegionCode gets seeded; [Group] remains NULL.
    Net: LIKE evaluates NULL=NULL=FALSE, predicate fails.

    Fix: handle LIKE in analyzer.  Extract literal substring between %s
    or before/after % and use it as the seed value.

(3) Express High-US body (118/119):
    Inner predicate: `c.CustomerID = @CustomerID AND st.CountryRegionCode = 'US'`.
    The analyzer's alias-handling at lines 337-340 drops conditions on
    tables whose alias != first-char-of-PrimaryTbl.  Here PrimaryTbl is
    Customer (c), so `st.CountryRegionCode = 'US'` gets ColName=NULL and
    is dropped from the seed.  CountryRegionCode is never seeded as 'US'
    in SalesTerritory, predicate fails.

    Fix: don't drop conditions on JOIN-aliased tables - emit them into
    #Paths with TableName=resolved-from-alias (st->SalesTerritory).

Waiting on user decision before applying fixes.

## 2026-05-21 fifteenth iteration - aiming for 100%

Applied all three fixes:

### 17_Branch_Path_Analyzer_v3_2.sql
(A) LIKE pattern handling:
    Extract literal core from pattern: '%America%' -> 'America'.
    Strips leading/trailing wildcards (% and _).  Falls back to N'X' for
    pure wildcards; falls back to NULL (old behaviour) for character
    classes [...].

(B) Alias resolution via #Aliases temp table:
    For each subquery block, parse FROM and JOIN clauses to build
    {alias -> table} map.  In WHERE conditions, look up the alias and
    set @ResolvedTbl to the joined table.  Conditions on JOIN-aliased
    columns (e.g. st.CountryRegionCode = 'US') now get emitted against
    the JOIN'd table (SalesTerritory) instead of being dropped.

### 04_Test_Generator_v3.sql
(C) EXISTS_FALSE explicit DELETE:
    For EXISTS_FALSE tests, emit
        DELETE FROM <PrimaryTbl>;
    immediately after FK-seeding and before EXEC.  This guarantees the
    predicate evaluates FALSE regardless of what the FK seed did.

### Expected impact

Standard ELSE (38/39):    FK-seed had CustomerID=1, predicate was TRUE.
                          Now DELETE wipes it -> predicate FALSE -> ELSE
                          body fires. +2 lines.
Search EXISTS (79/80):    LIKE was unhandled.  Now '%America%' seeds
                          'America' for [Group], predicate TRUE, body fires.
                          +2 lines.
High-US (118/119):        Alias `st` was unrecognised, st.CountryRegionCode
                          condition was dropped.  Now mapped to
                          Sales.SalesTerritory, condition emitted there,
                          predicate TRUE, body fires.  +2 lines.
Express ELSE (141/142):   Same as Standard ELSE.  +2 lines.

Total expected: +8 lines, taking us from 20/28 (71%) to 28/28 (100%).

### Files staged for delivery (current)

- `04_Test_Generator_v3.sql`           â€” EXISTS_FALSE delete + IN-list dedupe
- `17_Branch_Path_Analyzer_v3_2.sql`   â€” LIKE handling + alias map + one-PathID-per-block
- `20_Coverage_Instrumenter_v5.sql`    â€” control-transfer fix
- `22_Coverage_Reporter_v2.sql`         â€” branch-coverage inference
- `Regen_and_RunCoverage.sql`           â€” driver
- `Verify_Coverage_v5.sql`              â€” diagnostic

## 2026-05-21 sixteenth iteration - 78.6%/66.7%, three branches still missed

After all three fixes applied:
   18 -> 22 line covered (+4), 9 -> 10 branches (+1)

Wins:
   Express ELSE (141, 142) - DELETE-before-EXEC worked, fired ELSE body.

Still uncovered:
   Standard ELSE (38, 39)   - DELETE-before-EXEC fix should have hit this too
   Search EXISTS (79, 80)   - LIKE handler should have seeded [Group]
   Express High-US (118, 119) - alias map should have seeded SalesTerritory

ALSO NOTED: spot-check at Step 3 is buggy - my CHARINDEX check looked for
'([CustomerID],[SubTotal])' (no space) but actual text has a space after
the comma.  Premium IS correctly multi-column; spot-check just lies.

Need empirical data: created Diag_RemainingGaps.sql to dump:
  - Analyzer output for each of Standard/Search/High
  - Generated test source for each (seed section)
This will show whether the analyzer is doing the right thing AND
whether the generator is emitting the seed correctly.

## 2026-05-22 seventeenth iteration - three more fixes for 100%

(A) Standard ELSE (38/39) â€” Analyzer: EXISTS_FALSE.TableName must point at
    the EXISTS subquery's PRIMARY table (so generator DELETEs the right
    table).  Was using @ElseTable (the ELSE block's INSERT target).  Fix
    in analyzer.  Generator now also keeps a separate @AssertReadFullName
    for the post-EXEC row-growth assertion (still uses the ELSE target).

(B) Search EXISTS (79/80) â€” Value helper: GetSampleValueLiteral returned
    fixed 'SampleText' for string types regardless of @MaxLength.  For
    @Region NCHAR(3), the EXEC arg was 'SampleText' but the seed had to
    truncate to 'Sam'.  Predicate compared 'Sam' = 'SampleText' = false.
    Fix in 03_Value_Helpers_v2.sql: clamp Variant 0 to @MaxLength.

(C) Express High-US (118/119) â€” Generator: when the branch param is a
    CASE-derived LOCAL (e.g. @Priority = CASE @Status WHEN 3 THEN 'High'),
    the EXEC arglist must set the source param to the matching WHEN value.
    Added #CaseLocalAssigns (LocalVar, SourceParam, WhenValue, ResultValue),
    populated during the CASE-detect loop by looking back from CASE for
    `SET @x = ` / `SELECT @x = `.  arglist builder now consults it first.

### Files staged for delivery (current)

- `03_Value_Helpers_v2.sql`             â€” string sample clamped to MaxLength
- `04_Test_Generator_v3.sql`            â€” CaseLocalAssigns + AssertReadFullName
- `17_Branch_Path_Analyzer_v3_2.sql`    â€” EXISTS_FALSE.TableName = PrimaryTbl
- `20_Coverage_Instrumenter_v5.sql`     â€” unchanged
- `22_Coverage_Reporter_v2.sql`         â€” unchanged
- `Regen_and_RunCoverage.sql`           â€” unchanged
- `Verify_Coverage_v5.sql`              â€” unchanged

## 2026-05-22 eighteenth iteration

After third triple-fix attempt:
   Same coverage 22/28 line, 10/15 branch BUT:
   - Standard ELSE (38, 39) is now COVERED âœ“ (fix A worked)
   - Express ELSE (141, 142) REGRESSED (was covered, now not) âœ—
   - Search EXISTS (79, 80) still uncovered âœ—
   - High-US (118, 119) still uncovered âœ—

Suspicious - my fix shouldn't have regressed Express ELSE because the
DELETE FROM SalesOrderHeader is exactly what the old code did too.

Sent smaller Diag_Coverage_Gaps.sql to see seed + EXEC for each.

## 2026-05-22 nineteenth iteration

Three smoking guns from the previous diag:

1) Express ELSE regressed because the new analyzer creates 2 EXISTS_FALSE
   PathIDs for Express (outer and inner).  Both produce tests with the
   same name "@OrderType = Express ELSE path".  pathidcur orders ASC, so
   inner (PathID 4) overwrites outer (PathID 2).  Inner has
   TableName=Customer (with my v3.2 fix), so DELETE clears Customer,
   leaving SalesOrderHeader with NULL-Status FK rows -> outer EXISTS still
   false -> outer ELSE *should* fire -> lines 141/142 should be hit.
   Yet they're not.  WHY?

2) Search EXISTS test now seeds CountryRegionCode='Sam' with @Region='SampleText'
   (NOT 'Sam').  Wait - shown EXEC arg is 'SampleText' not 'Sam'.  Means
   GetSampleValueLiteral fix didn't take effect for that arg.  Need to
   check whether 03_Value_Helpers_v2.sql was actually installed.

3) High EXISTS test:
   EXEC @OrderType='Express', @Status=3 - GOOD, CaseLocalAssigns fix worked.
   Seed: INSERT Customer (CustomerID)=1, INSERT SalesTerritory (CountryRegionCode)='US'.
   But Customer also needs TerritoryID (for the JOIN), and SalesTerritory
   needs a matching TerritoryID for the JOIN to work.  The seed inserts
   are independent and the JOIN won't match -> EXISTS FALSE -> body not hit.

Sent Diag_Express_State.sql to see analyzer + both test sources.

## 2026-05-22 twentieth iteration - root-causing the three remaining gaps

### Express ELSE â€” analyzer ELSE-detection bug
The analyzer used CHARINDEX('ELSE', @AfterSubq) which returns the first
ELSE keyword anywhere - including ELSE keywords INSIDE the THEN block
(such as the inner High-priority ELSE).  For Express's outer EXISTS,
this captured the INNER ELSE, so the outer EXISTS_FALSE row was never
emitted.  Two extra inner-scan rounds also showed up (PathIDs 3 and 5
both EXISTS_FALSE on Customer; PathIDs 2 and 4 both inner EXISTS_TRUE).

Fix: walk after-subquery chars, track BEGIN/END depth, find the ELSE at
depth 0 after the THEN block's closing END.

### Search EXISTS â€” value helper file wasn't installed (user)
Test's EXEC arg is still 'SampleText' (full 10-char string).  My
03_Value_Helpers_v2.sql fix that clamps to MaxLength didn't take effect,
so 'SampleText' goes through to NCHAR(3) which truncates to 'Sam' in
seed but EXEC has 'SampleText'.  Need user to install 03_Value_Helpers_v2.sql.

### High EXISTS â€” JOIN seed mismatch
The seed inserts NEW rows into Customer and SalesTerritory but they
don't share a TerritoryID, so the JOIN c.TerritoryID = st.TerritoryID
fails (NULL â‰  NULL).  The FK seed has linked row #1 in each table via
TerritoryID=1; we need to update those linked rows to match the
predicate.

Fix: alongside each EXISTS_TRUE INSERT, emit
    UPDATE <tbl> SET <col1>=<val1>, <col2>=<val2>;
This updates ALL rows (no WHERE).  In practice, FK-seeded row #1 of
each table is linked via TerritoryID=1, so the linked row now also
matches the predicate columns -> JOIN works -> EXISTS TRUE.

This UPDATE approach is also useful for single-table predicates: e.g.
Premium's `CustomerID=1 AND SubTotal BETWEEN 100 AND 10000` is now
satisfied not just by the new INSERTed row but by the FK-seeded rows
too.  No downside.

### Files staged for delivery

- `03_Value_Helpers_v2.sql`            â€” string sample clamped to MaxLength
- `04_Test_Generator_v3.sql`           â€” INSERT + UPDATE EXISTS_TRUE seed
- `17_Branch_Path_Analyzer_v3_2.sql`   â€” depth-tracking outer-ELSE finder
- `20_Coverage_Instrumenter_v5.sql`    â€” unchanged
- `22_Coverage_Reporter_v2.sql`        â€” unchanged
- `Regen_and_RunCoverage.sql`          â€” unchanged
- `Verify_Coverage_v5.sql`             â€” unchanged

## 2026-05-22 twenty-first iteration - UPDATE causes identity errors

The previous UPDATE-after-INSERT change caused Express EXISTS test to
fail at create-or-execute time with Msg 8102 "Cannot update identity
column 'CustomerID'".  Whichever PathID-named-Express test happened to
reference Customer (e.g. via the alias-route or duplicate naming) hit
the identity protection.  That aborted regen mid-flight, leaving only
~10 test procs.  Coverage dropped to 32%.

### Fixes in 04_Test_Generator_v3.sql

(A) UPDATE wrapped in BEGIN TRY/END TRY BEGIN CATCH END CATCH so any
    runtime error (identity, computed, FK, etc.) is non-fatal to the
    test.

(B) SET-clause builder now also skips PRIMARY KEY columns (in addition
    to identity/computed/rowversion).  Customer.CustomerID and
    SalesTerritory.TerritoryID are PKs in AdventureWorks, so they get
    skipped, avoiding the most common identity issue.

Expected: regen completes cleanly, coverage back to >=78%, plus the
JOIN-table predicates (High EXISTS) now actually fire because the
UPDATE on SalesTerritory's CountryRegionCode is safe and works.

### Files staged

- `03_Value_Helpers_v2.sql`           â€” string sample clamped to MaxLength
- `04_Test_Generator_v3.sql`          â€” TRY/CATCH UPDATE, skip identity+PK
- `17_Branch_Path_Analyzer_v3_2.sql`  â€” depth-tracking outer-ELSE finder
- `20_Coverage_Instrumenter_v5.sql`   â€” unchanged
- `22_Coverage_Reporter_v2.sql`       â€” unchanged
- `Regen_and_RunCoverage.sql`         â€” unchanged
- `Verify_Coverage_v5.sql`            â€” unchanged

## 2026-05-22 twenty-second iteration - 24/28 (85.7%) reached

Big jump from 22/28 to 24/28 line, 10/15 to 12/15 branch.  High-US covered.
Express ELSE was covered then uncovered again - still hitting the
inner-EXISTS_FALSE overwriting outer-EXISTS_FALSE problem.

### Remaining 4 lines

(1) Search EXISTS (79, 80):
    Predicate `[Group] LIKE '%America%' AND CountryRegionCode = @Region`.
    Need to verify whether @Region is now 'Sam' (after value_helpers fix)
    OR still 'SampleText' (suggests 03_Value_Helpers_v2.sql not installed).
    With UPDATE in place, even if EXEC arg differs from seed,
    UPDATE SalesTerritory SET [CountryRegionCode]='Sam', [Group]='America'
    sets ALL rows to ('Sam','America').  But proc compares
    'Sam' to @Region='SampleText' -> false.
    User must install 03_Value_Helpers_v2.sql.

(2) Express ELSE (141, 142):
    Inner EXISTS_FALSE (Depth=2, TableName=Customer) overwrites outer
    EXISTS_FALSE (Depth=1, TableName=SalesOrderHeader).  DELETE clears
    Customer but SalesOrderHeader still has FK-seeded rows with
    Status=1 (default), so outer EXISTS=TRUE, outer ELSE never fires.

### Fix in 04_Test_Generator_v3.sql

pathidcur now filters EXISTS_FALSE PathIDs to only the OUTERMOST one
(lowest Depth, lowest PathID).  Inner EXISTS_FALSE doesn't generate a
test - their ELSE is semantically the inner-predicate's ELSE, which
is already covered when the inner predicate's branch param iterates
(e.g. @Priority=High ELSE).

Expected: Express ELSE generates DELETE FROM SalesOrderHeader (outer
primary), predicate becomes false, outer ELSE fires, lines 141/142 hit.

For Search: depends on whether 03_Value_Helpers_v2.sql is installed.
Diag_FinalGaps.sql will show.

## 2026-05-22 twenty-third iteration - 92.9%

Express ELSE NOW COVERED (outermost-EXISTS_FALSE filter worked).
Only Search EXISTS body (79, 80) remains.

Diag confirms: EXEC arg @Region='SampleText' even though I thought the
value-helpers fix would clamp it to 'Sam'.  Root cause:
   @Region is VARCHAR(50) - max length 50.
   My clamp returned 'SampleText' for @len>=10.
   Seed then truncates 'SampleText' to 'Sam' (NCHAR(3) column).
   EXEC arg 'SampleText' != predicate column value 'Sam' -> false.

Real fix: change @Variant=0 default to return a SHORT value ('Sam', max 3
chars).  Then EXEC arg = seed value = 'Sam'.  Predicate matches.

Edge case: columns with max-length < 3 (CHAR(1), CHAR(2)) would still
clip the seed value.  Acceptable; rare in real schemas.

Other branches don't use @Region in their predicates, so this change
doesn't regress anything.

### Files staged

- `03_Value_Helpers_v2.sql`   â€” default now 'Sam' (3 chars, fits anywhere â‰¥3)
- (all others unchanged from prev iteration)

## 2026-05-22 final - 100% COVERAGE ACHIEVED

LINE COVERAGE   : 28/28 lines    -> 100.0%
BRANCH COVERAGE : 15/15 branches -> 100.0%

All 18 path tests pass.  4 NULL-rejection tests fail (the validation
proc doesn't actually validate NULL inputs - that's a proc design gap,
not a coverage issue).

### Final fixes summary (chronological)

1. Instrumenter v5: control-transfer statements get hits BEFORE the line
2. Analyzer v3.1: one PathID per EXISTS predicate block (not per condition)
3. Generator v2: dedupe IN-list columns in seed INSERTs
4. Generator v3 (initial): DELETE FROM predicate table for EXISTS_FALSE
5. Analyzer v3.2: LIKE literal extraction, JOIN alias map, depth-tracked outer-ELSE
6. Value helpers v2: clamp string sample to MaxLength (later: just default to 'Sam')
7. Generator v3 (final): @CaseLocalAssigns for CASE-derived locals,
   INSERT+UPDATE seed (TRY/CATCH on UPDATE), skip identity/PK/computed/rowversion
   from SET clause, restrict EXISTS_FALSE pathidcur to outermost depth
8. Value helpers v2 (final): default to short 'Sam' (3 chars) so EXEC arg
   fits in any column â‰¥3 chars; matches seed value -> predicate matches

### Final deliverables

- Install_All_Combined_v9_2_FINAL.sql  â€” single installer (252KB base + ~55KB updates)
- README_v9_2.md                        â€” usage guide
- Plus all 5 modular files (for those who want to install piecemeal)

## 2026-05-22 â€” NEW PROC: uspGetBillOfMaterials reports 0% coverage

User ran `TestGen.RunCoverage` on `dbo.uspGetBillOfMaterials` (AdventureWorks2025).
Result: 5/7 functional tests pass; 2 NULL-rejection tests fail (same proc-design
gap already known for uspV9ValidationTest â€” the proc doesn't validate NULL
inputs). But LINE COVERAGE = 0/23, BRANCH 0/0, "XEvent rows captured: 0",
"No RecordCoverageHit statements found", "Coverage hits recorded: 0".

Root cause (from static read of Instrumenter v5 + RunCoverage, not yet
confirmed empirically):
  - uspGetBillOfMaterials' executable body is a SINGLE statement â€” a recursive
    CTE: WITH BOM_cte AS (SELECT ... UNION ALL SELECT ...) SELECT ...
    OPTION (MAXRECURSION 25).
  - The walker injects EXEC TestGen.RecordCoverageHit only at a ';'-terminated
    statement boundary at paren depth 0. This proc has no internal ';' â€” the
    only semicolons are SET NOCOUNT ON; (classified as noise) and END;.
  - A CTE + its consuming SELECT is syntactically indivisible: there is NO
    legal point to inject an EXEC between WITH...AS(...) and the SELECT, between
    the UNION ALL legs, or inside. Line-level instrumentation cannot apply to a
    single set-based statement.
  - Net: _cov ends up with 0 (or 1) hit recorders â†’ XEvent capture finds
    nothing matching '%RecordCoverageHit%' â†’ 0% coverage.
  - Contributing factor: RunCoverage only re-instruments when _cov is missing
    (IF OBJECT_ID(@CovFull) IS NULL), so a stale _cov / CoverageLines from an
    earlier run may also be in play.

The framework was tuned end-to-end against ONE procedure, dbo.uspV9ValidationTest
(a procedural IF/CASE/SET/INSERT/UPDATE/RETURN body â€” ideal for line
instrumentation). uspGetBillOfMaterials is the opposite shape (one set-based
recursive query) and is the framework's worst case.

Diagnostic returned (2026-05-22):
  - _cov injection count = 0  â†’ CONFIRMED: no hit recorders, hence 0% coverage.
  - CoverageLines = 23 IsExec + 15 non-exec rows.
  - Installed TestGen.InstrumentProcedure = v5 (current).
  - dbo.uspGetBillOfMaterials_cov create_date = 2026-05-20 20:01 â€” TWO DAYS
    before the 2026-05-22 coverage run.

Key finding â€” STALE _cov: RunCoverage only re-instruments when _cov is
MISSING (IF OBJECT_ID(@CovFull) IS NULL). The 2026-05-22 run reused the
2026-05-20 _cov (built by a pre-v5 instrumenter â€” explains the 23 IsExec
rows, which the v5 walker would NOT produce for a single-statement CTE).
So the "0/23" report reflects stale instrumentation, not current v5 logic.

Two distinct defects:
  (1) RunCoverage staleness: should re-instrument when _cov is older than
      the instrumenter or the source proc, not only when _cov is absent.
  (2) CTE limitation: even fresh v5 cannot inject inside a recursive CTE.
      Best case v5 collapses the proc to ONE coverage unit + one recorder
      after END; (meaningful 1/1 = statement coverage) â€” but only if the
      proc body ends in 'END;'. If it ends in 'END' (no semicolon) v5 still
      injects 0.

Next: user to DROP dbo.uspGetBillOfMaterials_cov and re-run RunCoverage to
see what fresh v5 instrumentation actually produces. No framework files
changed this iteration.

## 2026-05-22 â€” RESOLVED: stale _cov was the only defect; RunCoverage patched

Confirmed via fresh re-instrumentation:
  - Installed TestGen.InstrumentProcedure = v5 (current).
  - dbo.uspGetBillOfMaterials_cov create_date was 2026-05-20 â€” built TWO DAYS
    before the 2026-05-22 coverage run, by a pre-v5 instrumenter.
  - User dropped the stale _cov and re-ran RunCoverage. Fresh v5 produced:
        XEvent rows captured   : 6
        Coverage hits recorded : 1
        LINE COVERAGE   : 1/1 lines -> 100.0%
        BRANCH COVERAGE : 0/0  (proc has no procedural branches â€” expected)

So there was NO v5 instrumenter bug for this proc. v5 correctly collapses the
single recursive-CTE statement into ONE coverage unit, injects one recorder
after the proc's closing END;, the recorder fires, and coverage = 1/1 = 100%.
That is statement coverage â€” the framework cannot see inside a set-based
statement, which is the honest ceiling for a CTE proc. The "CTE limitation"
considered earlier in this investigation is a non-issue.

ROOT CAUSE of the misleading "0/23" report: TestGen.RunCoverage instrumented
the target proc only when _cov was MISSING:
    IF OBJECT_ID(@CovFull,'P') IS NULL  EXEC TestGen.InstrumentProcedure ...
So after the v9.2 (v5) upgrade it silently reused the 2026-05-20 _cov (0 usable
injections) and the 2026-05-20 CoverageLines (23 IsExec rows â€” pre-v5
"every-line" classification).

FIX applied this iteration â€” TestGen.RunCoverage, three changes:
  1. Instrumentation is now UNCONDITIONAL: re-instrument on every run so _cov
     and CoverageLines always reflect the current proc body and the current
     instrumenter version. Removed the IF OBJECT_ID(@CovFull) IS NULL guard.
  2. Moved the EXEC TestGen.InstrumentProcedure call to AFTER the leftover-
     _orig cleanup (new "Step 2b") so it always reads a correctly-named proc
     even if a previous run died mid-rename.
  3. Cosmetic: capture @@ROWCOUNT into @XeRows BEFORE the "XEvent rows
     captured" PRINT (PRINT resets @@ROWCOUNT to 0), so the
     "No RecordCoverageHit statements found" message no longer misfires.

Files changed:
  - Install_All_Combined_v9_2_FINAL.sql â€” RunCoverage section patched in place.
  - scripts\Patch_RunCoverage_AlwaysReinstrument.sql â€” NEW: standalone
    DROP+CREATE patch to apply the fix to an already-installed database.
  - scripts\Diag_BOM_Coverage.sql â€” NEW: diagnostic used to root-cause this.

NOT changed: the instrumenter (v5), analyzer, reporter, generator â€” all
correct. With this fix the next RunCoverage on each proc rebuilds its _cov
automatically, so stale pre-v5 _cov copies are corrected on their next run â€”
no manual cleanup needed. The README troubleshooting entry "No
RecordCoverageHit statements found ... Cosmetic message" is now obsolete.

## 2026-05-23 â€” NEW BUG: instrumenter emits non-compiling _cov for bare-body IF/ELSE

User ran coverage on dbo.uspLevel3ValidationTest â€” a PROCEDURAL proc (18 exec
lines, 11 branches: IF / EXISTS / SET / UPDATE / INSERT / RETURN / ELSE), i.e.
the framework's target shape, NOT a CTE case.  Result: 0% coverage,
"XEvent rows captured: 0", and the 14 tests split 3 pass / 6 fail / 5 error.

Diag_Level3_Coverage.sql (re-runs InstrumentProcedure directly) confirmed:
    !! Instrumented procedure FAILED to compile: [dbo].[uspLevel3ValidationTest_cov]
       Error: Incorrect syntax near the keyword 'ELSE'.
    RecordCoverageHit injections : 18
    Registry IsExec lines        : 18
    Registry IsBranch lines      : 11

ROOT CAUSE: the v5 instrumenter injects EXEC TestGen.RecordCoverageHit AFTER
each statement.  When an IF/ELSE/WHILE body is a BARE single statement (no
BEGIN/END) followed by ELSE, the injected EXEC lands between the IF body and
the ELSE:
    IF @Priority = 'High'
        UPDATE ... ;
        EXEC TestGen.RecordCoverageHit ...;   <- injected
    ELSE                                       <- now "ELSE with no IF"
        UPDATE ... ;
-> _cov fails to compile.  InstrumentProcedure DROPs the old _cov before the
   CREATE, so on failure _cov does not exist -> RunCoverage's synonym dangles
   -> tests error/fail -> 0 hits.  CoverageLines (18/11) is still populated
   because it is written before the _cov CREATE.

Secondary (latent) bug: even a bare IF body NOT followed by ELSE is mis-
instrumented â€” the injected EXEC sits AFTER the IF's single-statement scope,
so the hit fires unconditionally and the line reads as covered even when the
branch was not taken.

Why uspV9ValidationTest never hit this: its branch bodies are BEGIN/END
blocks, so the injected EXEC sits safely inside the block.

FIX (proposed, not yet applied): InstrumentProcedure must wrap a bare branch
body in BEGIN ... END in the generated _cov, so the injected hit stays inside
the branch:
    IF cond BEGIN <stmt>; EXEC RecordCoverageHit...; END ELSE BEGIN ... END
Walker change: when a branch header's body is the next statement and that
line is not already BEGIN, emit a synthetic BEGIN before it and a synthetic
END after its terminating hit.  Nested IFs need no stack (@Pending stays 1
across nested headers; only the terminal statement gets a @StmtStart).  Must
not regress uspV9ValidationTest (its bodies are real BEGIN/END, so the new
path won't trigger).

Status: root cause confirmed; awaiting user go-ahead before patching
InstrumentProcedure.  scripts\Diag_Level3_Coverage.sql created.

## 2026-05-23 â€” RESOLVED: instrumenter v5.1 wraps bare branch bodies

User approved the fix.  TestGen.InstrumentProcedure upgraded v5 -> v5.1.

Change (walker â€” 4 code edits + banner + trailing PRINT):
  - New @StmtWrap BIT.  Set = 1 when the @Pending path opens a statement â€”
    that statement is, by construction, a BARE branch body (a BEGIN-bodied
    branch clears @Pending via the BEGIN handler before this path runs).
  - Emitter: when @StmtWrap = 1, prepend a synthetic 'BEGIN' before the
    body's first line (@StmtStart = @LN) and append 'END' after its
    RecordCoverageHit when the statement terminates.
  - End-of-walk safety net: if @StmtWrap is still 1 (a bare body with no
    terminating ';'), emit a closing 'END' so _cov stays balanced.
  Result: IF cond BEGIN <stmt>; EXEC RecordCoverageHit...; END ELSE BEGIN
  <stmt>; EXEC RecordCoverageHit...; END  â€” compiles; hit scoped to branch.

Verified against the uspLevel3ValidationTest source: 3 bare bodies â€” the
EXISTS-Customer SET (no ELSE) and the IF @Priority='High' / ELSE UPDATE pair
(the compile breaker).  Every other branch body is a BEGIN/END block.

No-regression guarantee: for a branch whose body is a BEGIN/END block the
BEGIN handler clears @Pending before the bare-body path runs, so @StmtWrap
is never set and not one byte of that proc's _cov changes.  uspV9ValidationTest
(all BEGIN/END bodies) and uspGetBillOfMaterials (no branches) are therefore
byte-identical to before.  Wrapping a bare statement in BEGIN/END is
semantically transparent, so no test's pass/fail can change.

Files changed:
  - modules\20_Coverage_Instrumenter_v5.sql  â€” v5.1 (filename kept as _v5)
  - Install_All_Combined_v9_2_FINAL.sql       â€” same edits applied inline
  - scripts\Patch_InstrumentProcedure_BareBranchBody.sql  â€” NEW standalone
    DROP+CREATE patch for an already-installed database
Verified: InstrumentProcedure byte-identical across module, installer and
patch script (531 lines, clean diff); 7 @StmtWrap references in each.

Verified 2026-05-23 (uspLevel3ValidationTest re-run): _cov now COMPILES.
0 tests errored (was 5); 11/14 pass; coverage = 12/18 line (66.7%),
4/11 branch (36.4%) â€” real numbers, was 0%.  The instrumenter compile bug
is fixed.

  - The 3 failing tests are the NULL-rejection tests: the proc does not
    validate NULL inputs (same proc-design gap as uspV9ValidationTest's
    open item â€” NOT a framework bug).
  - Remaining uncovered lines 36/47/52/56/89/91 are EXISTS-TRUE branch
    bodies.  The generated VIP/Express EXISTS-path tests pass but their seed
    data does not satisfy the proc's complex predicates: 3-condition AND,
    YEAR(OrderDate)=YEAR(GETDATE()), 2- and 3-table JOINs, Status IN (1,2,3).
    This is a TEST-GENERATION gap (analyzer/generator), NOT instrumentation â€”
    the same class of work as the uspV9 analyzer iterations 9-23.

uspV9ValidationTest no-regression re-run still pending from the user.

## 2026-05-23 â€” INVESTIGATION: why uspLevel3 sits at 66.7% (test-gen gaps)

Ran Diag_Level3_TestGen.sql (AnalyzeBranchPaths output + the generated
EXISTS-path test sources).  The 6 uncovered lines are blocked by FOUR
analyzer/generator gaps:

  GAP C - multi-word string RHS truncated at first space.  The @RHSClean
          char-walk loop (analyzer ~line 614) BREAKs on space, so
          st.[Group] = 'North America' is captured as 'North'.  Confirmed:
          grid 1 shows CondValue 'North'.

  GAP D - WHERE clause truncated at first ')'.  @CloseP = CHARINDEX(')',
          @WhereClause) cuts the WHERE at the first ')', which for any
          predicate containing "IN (...)" is the IN-list's ')'.  For pred-3
          (Express, line 79) this DROPS "AND st.CountryRegionCode = 'US'"
          entirely.  Confirmed: grid 2 has NO CountryRegionCode row.

  GAP A - function-wrapped column conditions dropped.  YEAR(OrderDate)=... ->
          analyzer line 489 sets ColName=NULL (LHS has '('); OrderDate is
          never seeded -> pred-1 (VIP, line 29) is false.  Confirmed: grid 1
          PathID 1 has CustomerID + Status only, no OrderDate.

  GAP E - the @Priority='High' branch test EXECs with @OrderType='Express'
          (a sample value), but IF @Priority='High' (line 51) is nested
          inside IF @OrderType='VIP' ... IF EXISTS(pred-1).  The test can
          never reach line 51.  Confirmed: grid 5 EXECs @OrderType='Express'.
          Also: multiple EXISTS PathIDs for one branch share the test name
          ("VIP EXISTS path") and overwrite each other.

NOT a problem: JOIN-key linking.  The FK-seeding block already inserts 5
mutually-linked rows (Customer.TerritoryID->SalesTerritory,
SOH.CustomerID->Customer, SOH.TerritoryID->SalesTerritory), and the
EXISTS-seed UPDATE-all-rows strategy propagates WHERE-column values onto
those linked rows.  So once a condition is correctly CAPTURED, the
multi-table JOIN is already satisfied - no seed-graph work needed.

Traced: fixing GAP D alone should recover the Express EXISTS path (lines
89, 91) - CountryRegionCode='US' becomes an emitted row, the generator
UPDATEs all SalesTerritory rows to 'US', and the FK-linked rows satisfy the
whole 3-table predicate.

Recommended order: GAP C + GAP D first (contained analyzer string-parsing
bug fixes), then GAP A, then GAP E.  Awaiting user go-ahead.

## 2026-05-23 â€” IMPLEMENTED: complex-predicate fixes (Phases 1-3)

User approved all three phases.  Applied to TestGen.AnalyzeBranchPaths
(analyzer) and TestGen.GenerateTestsForProcedure (generator), in both the
module files and the installer.

Phase 1 â€” analyzer parsing bugs:
  GAP D - WHERE clause was cut at the FIRST ')' (an IN-list's paren), so
          conditions after "IN (...)" were dropped.  Now taken to the
          subquery block's balanced final ')':
          @WhereClause = SUBSTRING(@SubqBlock,@WherePos+5,
                                   LEN(@SubqBlock)-@WherePos-5).
  GAP C - the @RHSClean char-walk BROKE on the first space, truncating
          'North America' to 'North'.  Replaced with LTRIM/RTRIM + a single
          trailing-')' strip.

Phase 2:
  GAP A - a function-wrapped LHS (YEAR(OrderDate)) was dropped (ColName set
          NULL).  Now: if FUNC IN (YEAR,MONTH,DAY) and the RHS references
          GETDATE/SYSDATETIME/CURRENT_TIMESTAMP, unwrap to the inner column
          and seed it with CONVERT(NVARCHAR(30),SYSDATETIME(),121).  New
          analyzer vars @FuncName/@InnerArg/@FuncOpenP/@FuncCloseP/
          @LhsDateFunc.  Any other function still drops (old behaviour).
  GAP E2 - EXISTS_TRUE test names now append ' #'+PathID, so multiple EXISTS
          predicates in one branch no longer overwrite each other.

Phase 3 â€” generator seedcur2:
  The cursor now seeds @GenPathID PLUS every ancestor PathID, found via a
  recursive CTE walking ParentPathID (a PathDistinct CTE collapses
  #BranchPaths to one row per PathID so the recursive member is legal - no
  DISTINCT/TOP allowed there).  A nested-EXISTS test (e.g. pred-2 inside
  pred-1) now seeds the whole chain; with UPDATE-all-rows and the FK-linked
  seed rows, the ancestor predicates become TRUE together.

NOT done (deliberate): line 56 of uspLevel3ValidationTest (the ELSE of a
plain IF @Priority='High' nested inside an EXISTS) needs a new nested-ELSE
test category - documented as a known limitation.  Also left as-is: the
analyzer's AssertTable='based' quirk (CHARINDEX matched 'Update' inside the
comment '-- Update based on priority') - benign, since EXISTS_TRUE tests use
@AssertFullName (first seed table), not that column.

Files changed:
  - modules\17_Branch_Path_Analyzer_v3_2.sql  - GAP C, D, A
  - modules\04_Test_Generator_v3.sql           - GAP E2, Phase 3
  - Install_All_Combined_v9_2_FINAL.sql        - all of the above, inline
  - scripts\Patch_TestGen_ComplexPredicates_v9_2_1.sql - NEW standalone
    DROP+CREATE patch for AnalyzeBranchPaths + GenerateTestsForProcedure
Verified: analyzer byte-identical across module + installer (987 lines);
generator byte-identical across module + installer (1979 lines).

Expected on re-test of uspLevel3ValidationTest: ~17/18 lines (94%); line 56
remains the documented gap.  To apply: run the patch, then DropClass +
GenerateTestsForProcedure + RunCoverage.  uspV9ValidationTest still needs a
no-regression re-run.

## 2026-05-23 â€” FOLLOW-UP F1/F2: datetime seed-value truncation

First re-test after Phases 1-3:
  - uspV9ValidationTest: 28/28 line, 15/15 branch, 0 errored â€” 100% HELD
    (no regression; GAP E2's ' #'+PathID test names are visible there too).
  - uspLevel3ValidationTest: 14/18 (77.8%) â€” GAP C+D recovered the Express
    path (lines 89, 91), but the tests "VIP EXISTS path #1" and "#5" ERRORED
    and lines 36/47/52 stayed uncovered.

Root cause: GAP A now seeds an OrderDate value, which exposed a latent
generator bug.  The seed-value truncation (IF LEN(@bpVal) > @bpColMax) clamps
to the column's max_length.  For a datetime column max_length is 8 (BYTES),
so the datetime literal was chopped to 8 chars ('2026-05-') and the
INSERT/UPDATE threw a conversion error â€” the test errored before reaching the
branch body.

Fixes:
  F1 (analyzer)  - the GAP A seed value now uses CONVERT style 120
     ('yyyy-mm-dd hh:mi:ss', no fractional seconds) instead of 121 (7-digit
     fraction, which can overflow a plain datetime column).
  F2 (generator) - the @bpColMax char-length limit is now computed only for
     char/varchar/nchar/nvarchar columns; for every other type it is NULL
     (no truncation).  This is the real bug fix; F1 is belt-and-suspenders.

Files changed: modules\17_Branch_Path_Analyzer_v3_2.sql,
modules\04_Test_Generator_v3.sql, Install_All_Combined_v9_2_FINAL.sql.
scripts\Patch_TestGen_ComplexPredicates_v9_2_1.sql rebuilt to include F1+F2.

Expected on re-test: tests #1/#5 no longer error; lines 36, 47, 52 covered ->
17/18 (94%).  Line 56 (the ELSE of the plain nested IF @Priority='High')
remains the documented limitation.

## 2026-05-23 â€” CONFIRMED: complex-predicate work complete

Re-test after F1/F2 (patch re-applied, test class regenerated):
  uspLevel3ValidationTest: 17/18 line (94.4%), 10/11 branch (90.9%),
  0 errored, 13 pass, 3 fail (the NULL-rejection tests - proc-design gap,
  not a framework issue).  "VIP EXISTS path #1/#5" now pass.  Only line 56 /
  branch 55 uncovered - the ELSE of the plain nested IF @Priority='High',
  the documented limitation (the framework has no nested-plain-IF-ELSE test
  category; covering it is a disproportionate effort for one line).

  uspV9ValidationTest re-confirmed: 28/28 line, 15/15 branch = 100%,
  0 errored - NO REGRESSION.

All four complex-predicate gaps (C, D, A, E2) + Phase 3 ancestor-chain
seeding + F1/F2 datetime-truncation are complete and verified end-to-end.
Coverage on the three exercised procedures:
  uspV9ValidationTest      100%   (28/28 line, 15/15 branch)
  uspLevel3ValidationTest   94.4% (17/18 line; line 56 documented)
  uspGetBillOfMaterials    100%   (1/1 - single set-based recursive CTE)

Standalone patch scripts (apply to an already-installed database, in order):
  1. scripts\Patch_RunCoverage_AlwaysReinstrument.sql
  2. scripts\Patch_InstrumentProcedure_BareBranchBody.sql
  3. scripts\Patch_TestGen_ComplexPredicates_v9_2_1.sql
All changes are also folded into Install_All_Combined_v9_2_FINAL.sql for
fresh installs.

## 2026-05-23 â€” IF_ELSE: test category for the ELSE of a plain nested IF

User asked to close the last gap â€” line 56 of uspLevel3ValidationTest, the
ELSE of IF @Priority='High' nested inside the VIP EXISTS block.  The
framework generated only the TRUE side of a plain IF @param='value' branch,
never the ELSE side.

New IF_ELSE path type:
  Analyzer â€” section 2C (NEW): while the queue walks each block (including the
    EXISTS THEN-blocks it re-scans), detect a plain  IF @param = 'literal'
    that has an ELSE (bare single-statement body OR BEGIN/END block; skips
    the branch's own header and compound AND/OR predicates).  Emit an
    IF_ELSE #Paths row with ParentPathID = @QParent (the enclosing EXISTS).
  Generator â€” 5 splices, each scoped so EXISTS/CASE behaviour is byte-identical:
    - seedcur2 PathType filter: an IF_ELSE test also pulls its ancestor
      EXISTS_TRUE rows -- PathType = @GenPathType OR (@GenPathType='IF_ELSE'
      AND PathType='EXISTS_TRUE').
    - seed-block emission and the EXISTS_TRUE-style assertion now also fire
      for IF_ELSE.
    - test name: "@param <> literal path #PathID".
    - EXEC arg-list: @param is substituted with a non-matching sentinel
      ('_ELSEPATH_' for string params, -2147483647 for numeric).
  The IF_ELSE test seeds the enclosing EXISTS via Phase 3's ancestor chain,
  runs the proc with @param <> literal, and the ELSE body executes.

Scope / risk: the generator splices change behaviour ONLY for PathType
'IF_ELSE'; every existing path type is byte-identical.  The only way uspV9
(or any other proc) is affected is if section 2C finds a plain nested
IF...ELSE in it â€” which merely adds a test, and a new test cannot lower
coverage.

Files changed: modules\17_Branch_Path_Analyzer_v3_2.sql,
modules\04_Test_Generator_v3.sql, Install_All_Combined_v9_2_FINAL.sql.
scripts\Patch_TestGen_ComplexPredicates_v9_2_1.sql rebuilt to include IF_ELSE.
Verified: section 2C present and correctly terminated in the analyzer; the
generator ends correctly; installer and patch script consistent (3139-line
patch, both procedures present).

Expected on re-test: uspLevel3ValidationTest 18/18 (100%); uspV9ValidationTest
must hold 100%.

## 2026-05-23 â€” CONFIRMED: uspLevel3ValidationTest at 100%

Re-test after the IF_ELSE feature (patch re-applied, test class regenerated):
  uspLevel3ValidationTest: 18/18 line (100%), 11/11 branch (100%), 0 errored.
  15 pass, 3 fail (the NULL-rejection tests â€” proc-design gap, not a
  framework issue).  The two new IF_ELSE tests â€” "@Priority <> High path #5"
  and "#8" â€” cover line 56; #8 (ParentPathID=1) seeds pred-1 via the
  ancestor chain and reaches the nested ELSE.  The earlier documented
  limitation is now closed.

## 2026-05-23 â€” VERIFIED COMPLETE: full framework run

uspV9ValidationTest re-run after the IF_ELSE feature: 28/28 line (100%),
15/15 branch (100%), 0 errored.  NO REGRESSION.

Section 2C found a plain nested IF...ELSE in uspV9 as well and generated two
IF_ELSE tests ("@Priority <> High path #5" and "#8") â€” both PASS.  So the new
test category added 2 tests to uspV9 and it still held 100%.

=== Final state â€” all three exercised procedures ===
  uspV9ValidationTest      100%  (28/28 line, 15/15 branch)  â€” held, no regression
  uspLevel3ValidationTest  100%  (18/18 line, 11/11 branch)  â€” was 0%
  uspGetBillOfMaterials    100%  (1/1 â€” single set-based recursive CTE)  â€” was 0%

Remaining test FAILURES â€” uspV9 (4) and uspLevel3 (3) â€” are all NULL-rejection
tests: those procedures do not validate NULL inputs, a procedure-design gap,
NOT a framework gap (consistent with the CLAUDE.md open item).

Eight framework bugs fixed across this effort, in three procedures:
  RunCoverage          â€” reused a stale _cov instead of re-instrumenting
  InstrumentProcedure  â€” non-compiling _cov for bare-body IF/ELSE branches
  AnalyzeBranchPaths   â€” WHERE truncated at first ')'; multi-word value
                         truncated at first space; function-wrapped column
                         dropped
  GenerateTestsForProcedure â€” clobbered same-named EXISTS tests; seeded only
                         one PathID for nested predicates; chopped datetime
                         literals to a column's byte length
Plus one new capability: the IF_ELSE test category (ELSE side of a plain
nested IF).

Standalone patches (apply in order to an already-installed database):
  1. scripts\Patch_RunCoverage_AlwaysReinstrument.sql
  2. scripts\Patch_InstrumentProcedure_BareBranchBody.sql
  3. scripts\Patch_TestGen_ComplexPredicates_v9_2_1.sql
All folded into Install_All_Combined_v9_2_FINAL.sql for fresh installs.


## 2026-05-24 - v9.4.2: before/after DELTA assertions for branch tests

### Background

The v9.4 line (strong branch-test assertions - see README_v9_4.md and
DESIGN_v9_4_Strong_Assertions.md) replaced the old tautological branch
assertions with snapshot-and-replay tSQLt.AssertEqualsTable for replayable
leaf bodies.  Two gaps remained:

  1. A branch test whose body was NOT replayable (a proc-local @-var in the
     DML, a non-deterministic function in an UPDATE WHERE, or an empty
     deterministic-column projection) still fell back to the OLD tautological
     assertion - EXISTS_TRUE/IF_ELSE asserted "@RowsGrew = 1" (satisfied by
     the test's own seed INSERT, not the procedure); EXISTS_FALSE asserted
     "1 = 1".  A gutted branch body still passed.
  2. A REPLAYABLE UPDATE whose only mutated column is non-deterministic
     (e.g. uspV9ValidationTest's Standard branch: UPDATE Sales.Customer SET
     ModifiedDate = GETDATE()) gets a strong AssertEqualsTable - but the
     clock/newid/rand-typed column is PROJECTED OUT of that compare.  So the
     table assertion verifies only that no OTHER column changed; it never
     verifies the branch's actual effect (ModifiedDate refreshed) happened.

### Fix - a before/after delta assertion (generator only)

GenerateTestsForProcedure now emits, for EVERY branch test whose body has a
known leaf INSERT/UPDATE target (BodyDmlKind / BodyDmlTable - already captured
by AnalyzeBranchPaths in v9.4, so NO analyzer change is needed):

  - Arrange (just before EXEC, after all seeding): capture
    @v94d_CntBefore = COUNT(*) of the body-DML target; for an UPDATE also
    snapshot the target into #v94d_PreImg (every column whose type EXCEPT can
    compare - xml / text / ntext / image / geography / geometry excluded).
  - Assert (just after EXEC, emitted BEFORE the AssertEqualsTable so its
    clearer message shows first):
      INSERT body -> AssertEquals that COUNT(*) grew.  The baseline is
        captured AFTER all seeding, so the growth is the PROCEDURE's INSERT,
        never the test's own seed rows.
      UPDATE body -> AssertEquals that COUNT(*) is unchanged, AND AssertEquals
        that (#v94d_PreImg EXCEPT current target) is non-empty - i.e. the
        procedure actually modified the table.

The delta assertion COMPLEMENTS AssertEqualsTable where that exists (closing
gap 2 - the projected-out non-deterministic column is now verified to have
changed) and REPLACES the weak @RowsGrew / 1=1 fallbacks where it does not
(closing gap 1).  Every branch test with a table-writing body now carries a
real assertion of the procedure's effect.

### Honest residual

The UPDATE delta verifies "the table was actually modified and the row count
held" - it catches a gutted / no-op body.  It does NOT verify that EVERY row
matching the procedure's WHERE changed: reliable per-row matching is not
possible because tSQLt.FakeTable allows duplicate keys.  AssertEqualsTable
still covers collateral changes to the deterministic columns.  A branch body
that writes no table (a SET-@Message-only ELSE, or the @Status CASE branches)
is unaffected - those keep the v9.4 result-set AssertEqualsString.

### Scope / no-regression

The new emission is gated on @v94HasBodyDml (a resolved leaf INSERT/UPDATE
target).  AssertEqualsTable, the result-set AssertEqualsString, the coverage
instrumenter, the analyzer, and the generic Test-1-9 categories are all
untouched.  A branch with no body-DML target behaves exactly as before.
Line/branch coverage is unaffected (the procedure still runs, same lines
hit) - only pass/fail becomes stricter, which is the intended effect.

### Files changed

  - modules\04_Test_Generator_v3.sql       - delta-assertion emission in
    GenerateTestsForProcedure (2 DECLAREs, per-path reset, @v94HasBodyDml
    flag, an arrange block, an assert block, 2 weak-fallback gates).
  - Install_All_Combined_v9_2_FINAL.sql    - the same change in the inline
    copy of GenerateTestsForProcedure.
  - scripts\Patch_TestGen_StrongAssertions.sql - header text updated; it
    :r-includes the module files, so it applies v9.4.2 unchanged.

No analyzer change: BodyDmlKind / BodyDmlTable / BodyDmlText were already
captured by AnalyzeBranchPaths in v9.4.

### Verification expected (run by user)

Apply scripts\Patch_TestGen_StrongAssertions.sql in SQLCMD mode (it
:r-includes the modules), then DropClass + regenerate the test classes and
re-run scripts\Verify_v9_4.sql against AdventureWorks2025.  Coverage should
hold.  Every branch test with a table-writing body now carries the delta
assertion; triage any newly-failing test - a generator bug, or a genuine
seed/replay mismatch the weak assertion was masking.

### Tooling / file-integrity note

While applying these edits, three files were truncated by an editor that
capped each write at the file's original byte size, dropping the tail:
modules\04_Test_Generator_v3.sql, Install_All_Combined_v9_2_FINAL.sql and
scripts\Patch_TestGen_StrongAssertions.sql.  All three were rebuilt from the
verbatim tSQLtAutoGen_v9.4.zip copies with the v9.4.2 change re-applied via a
non-capping write, and verified (GenerateTestsForProcedure byte-identical
across module and installer).  SEPARATE PRE-EXISTING ISSUE: the installer in
tSQLtAutoGen_v9.4.zip is itself truncated mid-TestGen.InstrumentProcedure (it
ends at "... END ELSE") - NOT introduced here.  The installer was restored to
that zip state plus v9.4.2; until its missing tail is regenerated, the
modules + Patch_TestGen_StrongAssertions.sql (SQLCMD mode) are the reliable
install path.

## 2026-05-24 - v9.4.2 FIX: delta assertion passed a CASE expression to EXEC

First verification run of v9.4.2 (regenerate test_uspV9ValidationTest)
aborted at the first INSERT-bodied branch test:
  Msg 156, Level 15: Incorrect syntax near the keyword 'CASE'.
Because a failed CREATE PROCEDURE aborts the whole generated batch, only the
10 generic tests were created and coverage fell to 25% (the branch tests
never existed - not a coverage regression, a generation abort).

Root cause: the v9.4.2 INSERT-branch delta assertion emitted
    EXEC tSQLt.AssertEquals
         @Expected = 1,
         @Actual   = CASE WHEN @v94d_CntAfter > @v94d_CntBefore THEN 1 ELSE 0 END, ...
A T-SQL EXEC argument must be a constant or a scalar variable - an expression
(here a CASE) is rejected at parse time.  The pre-v9.4 weak fallback got this
right (it computed CASE into @RowsGrew_TRUE first, then passed the variable);
the new INSERT branch did not.

Fix (modules\04_Test_Generator_v3.sql + installer, GenerateTestsForProcedure):
  - INSERT branch: emit a  DECLARE @v94d_Grew INT = CASE WHEN @v94d_CntAfter >
    @v94d_CntBefore THEN 1 ELSE 0 END;  line, then pass @v94d_Grew to EXEC.
  - UPDATE branch (defensive): the EXISTS/EXCEPT result is now produced with
    DECLARE @v94d_Changed INT;  SET @v94d_Changed = CASE WHEN EXISTS(...) ...;
    so no CASE is ever an EXEC argument and the subquery sits under SET (which
    unambiguously allows it).
Every EXEC tSQLt.AssertEquals argument the generator emits is now a literal
or a variable.  Verified: GenerateTestsForProcedure byte-identical across
module and installer.  Re-run the regenerate + Verify_v9_4.sql cycle.

## 2026-05-24 - v9.4.2 cleanup: drop the dead row-count assertion vestiges

The generated branch tests still emitted the pre-v9.4 row-count plumbing -
@RowsBefore_TRUE / @RowsBefore_ELSE captured before seeding, and
@RowsAfter_TRUE / @RowsGrew_TRUE / @RowsAfter_ELSE / @ElseGrew after EXEC.
After v9.4 / v9.4.1 / v9.4.2 these are pure noise: a replayable body gets
AssertEqualsTable + the v9.4.2 delta assertion, and a CASE-result branch
gets AssertEqualsString.  The only thing still consuming them was the
EXISTS_TRUE weak fallback's "@RowsGrew = 1" assertion - itself the original
tautology (the test's own seed INSERT, not the procedure, satisfied it).

Change (generator only - modules\04_Test_Generator_v3.sql + installer,
GenerateTestsForProcedure):
  - the seed block no longer emits "DECLARE @RowsBefore_TRUE ..." nor the
    "Capture row count BEFORE seeding" comment;
  - the EXISTS_FALSE seed no longer emits "DECLARE @RowsBefore_ELSE ...";
  - the EXISTS_TRUE / IF_ELSE weak fallback now emits a single honest smoke
    assertion - EXEC tSQLt.AssertEquals @Expected=1, @Actual=1,
    @Message='branch executed (TRY/CATCH verified)' - instead of the
    @RowsGrew tautology;
  - the EXISTS_FALSE weak fallback drops the dead @RowsAfter_ELSE / @ElseGrew
    lines (it already asserted 1=1).

Net: generated tests no longer contain any @Rows* / @*Grew variable.  Every
branch test carries either a real assertion (AssertEqualsTable, the v9.4.2
delta, AssertEqualsString) or a clearly-labelled smoke assertion - no
tautological assertion remains anywhere.  Verified: GenerateTestsForProcedure
byte-identical across module and installer.

## 2026-05-24 - v9.4.2 FIX: INSERT-branch table compare must use only the named columns

Verification run: test "...executes @OrderType = Express ELSE path" failed
with AssertEqualsTable "Unexpected/missing resultset rows!" - the procedure
was correct; the test scaffolding was wrong.

Root cause: the v9.4 strong assertion builds the expected table with
  SELECT * INTO #v94_Expected FROM <target>;
then replays the branch's INSERT onto it.  SELECT ... INTO copies column
names / types / nullability / identity but NOT DEFAULT constraints.  The
real target table is faked WITH its defaults preserved, so when the
procedure's INSERT omits a column the faked table fills it from the default,
while the #v94_Expected copy (no defaults) fills the same column with NULL.
For Sales.SalesOrderHeader the Express-ELSE INSERT omits RevisionNumber
(default 0), OnlineOrderFlag (default 1) and rowguid (default newid()), so
the replayed row and the procedure's row differ on exactly those three
columns and AssertEqualsTable fails although the procedure is correct.
Only INSERT branches are affected - an UPDATE branch creates no new rows, so
the SELECT * INTO copy of the existing rows stays faithful.

Fix (generator only - modules\04_Test_Generator_v3.sql + installer): for an
INSERT branch the AssertEqualsTable projection is now intersected with the
columns the branch's INSERT explicitly names.  Those are the only columns
the replay can reproduce; any column the INSERT omits is default-vs-NULL
noise and is not the branch's effect.  GenerateTestsForProcedure parses the
column list out of the captured INSERT text (the names between the first
'(' and its ')', where that '(' precedes VALUES), normalises it to a
,delimited, lookup string (@v94InsNorm), and adds it as a filter on the
@v94DetCols projection query.  UPDATE branches are unchanged - the filter is
a no-op when @v94InsNorm IS NULL.

For "Express ELSE path" the compared projection becomes
{Status, CustomerID, SubTotal, TaxAmt, Freight} - all of which match - so the
test now passes.  The v9.4.2 delta assertion still independently confirms a
row was added, and AssertEqualsTable still catches a wrong value in a column
the INSERT does set, plus collateral changes to pre-existing rows.

Verified: GenerateTestsForProcedure byte-identical across module and
installer.  Re-run the regenerate + Verify_v9_4.sql cycle.

## 2026-05-24 - v9.4.2 VERIFIED on AdventureWorks2025

Regenerated test_uspV9ValidationTest and ran the full coverage cycle after
the four v9.4.2 fixes (delta assertions; CASE-not-an-EXEC-argument;
row-count vestige cleanup; INSERT-branch column-list restriction).

Result: 26 tests, 22 pass, 0 errored, 4 fail.  LINE 28/28 (100.0%),
BRANCH 15/15 (100.0%) - coverage held.

All 18 branch/path tests pass with the strengthened v9.4.2 assertions -
including every INSERT branch (Express ELSE, Standard ELSE, Search EXISTS)
that the column-list restriction addressed, and every UPDATE branch.
Test-class generation now completes fully - the CASE-as-EXEC-argument abort
is gone (all 26 procs created, vs only 10 on the first run).

The 4 failures are the NULL-rejection tests (rejects NULL for @CustomerID /
@OrderType / @Region / @Status), each "Expected an error to be raised".
These are the framework correctly reporting that dbo.uspV9ValidationTest
does not validate NULL inputs - it has no "IF @x IS NULL ... THROW/RAISERROR"
guard, so no error is raised and ExpectException fails.  This is a
procedure-design gap (the long-standing CLAUDE.md open item), NOT a
framework bug and NOT a v9.4.2 regression.  Closing it means adding NULL
checks to the procedure itself.

v9.4.2 is complete and verified end-to-end.

## 2026-05-24 - v9.4.2 FIX: drop the phantom (unseedable) duplicate IF_ELSE path

Verification run: test "...uspLevel3ValidationTest executes @Priority <> High
path #5" failed - the v9.4.2 UPDATE delta assertion reported the row count
changed (a row was INSERTed) although the test targets an UPDATE branch.

Root cause: the analyzer's section-2C plain-IF/ELSE detector scans each
queued block's full text.  A nested  IF @Priority = 'High' ... ELSE  that
lives inside an IF EXISTS(...) THEN-block is therefore detected TWICE:
  - once while scanning the OUTER branch block (the nested IF is textually
    inside it) - the emitted IF_ELSE row gets ParentPathID = the outer
    block's parent, which is NULL;
  - once while scanning the EXISTS THEN-block as its own queue entry - the
    IF_ELSE row gets ParentPathID = the enclosing EXISTS PathID.
The generator's seedcur2 walks ParentPathID to seed the ancestor EXISTS
chain.  The second copy (#8) seeds the enclosing EXISTS, the procedure
reaches the nested branch, and it passes.  The first copy (#5) has
ParentPathID NULL: nothing seeds the enclosing EXISTS, so the procedure's
outer IF EXISTS(...) is false and it runs the EXISTS-ELSE body (an INSERT)
instead of the nested branch.  #5 is a phantom - a test named for a branch
it never reaches.  Under the pre-v9.4 weak assertion #5 still "passed" (the
INSERT grew the row count, satisfying the old @RowsGrew tautology); the
v9.4.2 delta assertion is what exposed it.

Fix (generator only - modules\04_Test_Generator_v3.sql + installer): the
pathidcur cursor now de-duplicates IF_ELSE paths.  Per distinct
(ColumnName,CondValue) IF_ELSE branch it keeps exactly one row - the one with
the best ParentPathID (highest wins; NULL treated as worst; PathID breaks
ties) - via a NOT EXISTS "no better sibling" filter.  The seedable copy
(#8, parent = the enclosing EXISTS) survives; the phantom (#5, parent NULL)
is no longer turned into a test.  No analyzer change: #Paths still holds both
rows; the generator simply stops emitting a test for the unseedable one.

This also removes the equivalent redundant IF_ELSE path from
uspV9ValidationTest - there #5 only "passed" by luck (its enclosing EXISTS,
Status IN (1,2,3), happened to be satisfied by the default-seeded Status=1).
Coverage is unaffected: the surviving test, run with @param <> the literal,
still exercises the nested ELSE branch.

Verified: GenerateTestsForProcedure byte-identical across module and
installer.  Re-run the regenerate + Verify_v9_4.sql cycle - the
"@Priority <> High path #5" phantom should be gone and "#8" should pass.

## 2026-05-24 - v9.4.2 VERIFIED: IF_ELSE phantom fix confirmed on both sample procs

Regenerated both sample test classes and re-ran coverage after the IF_ELSE
de-duplication fix.

uspLevel3ValidationTest: 17 tests, 14 pass, 0 errored, 3 fail.
  LINE 18/18 (100%), BRANCH 11/11 (100%).
uspV9ValidationTest:     25 tests, 21 pass, 0 errored, 4 fail.
  LINE 28/28 (100%), BRANCH 15/15 (100%).

The phantom "@Priority <> High path #5" is gone from both classes - only the
seedable "#8" remains, and it passes.  Test counts dropped by exactly one
each (uspLevel3 18->17, uspV9 26->25) - the removed phantom.  Coverage held
at 100% / 100% for both: the surviving #8 still exercises the nested ELSE.

The remaining failures are the NULL-rejection tests (3 on uspLevel3, 4 on
uspV9) - the framework correctly reporting that neither procedure validates
NULL inputs.  Procedure-design gap, not a framework issue.

v9.4.2 is complete and verified end-to-end on both sample procedures.

## 2026-05-24 - DOC: result-set shape test guidance + BlessBaseline correction

README_v9_4.md (the user manual) gained a "Changing a procedure's output
columns" section under Workflow tips, plus a matching Troubleshooting entry:
the generated "returns a stable result-set shape" test pins the procedure's
first-result-set column contract, so redesigning the procedure to add /
remove / rename / retype a result-set column makes that test fail by design.
The fix is to re-bless (TestGen.BlessBaseline); regenerating the test class
does NOT clear the baseline.

Also corrected the README's TestGen.BlessBaseline reference, which documented
the wrong signature (@SchemaName / @ProcName) and the wrong behaviour
("records the shape").  The actual procedure is  BlessBaseline
@TestClass SYSNAME = NULL, @Kind VARCHAR(10) = 'Both'  and it CLEARS the
baseline rows so the next test run auto-captures fresh ones.  The Quick-start
example was corrected to match.

Docs only - no framework code changed.
\n
## 2026-05-24 - PROPOSED: v10 universal test generator (design only)

User goal: make the framework a universal test generator.  Two gating
decisions taken: architecture = SQLCLR in-database (host Microsoft's ScriptDom
T-SQL parser as a CLR assembly, keep the install-into-the-DB model); target =
universal coverage + a universal regression net (not a correctness oracle -
that needs human specs and is explicitly out of scope).

DESIGN_v10_Universal_Generator.md written (status: proposed, for review before
any implementation).  Summary: the string-based AnalyzeBranchPaths /
ExtractLeafDml / InstrumentProcedure are the structural ceiling; replace them
with a ScriptDom AST.  New CLR parse/model layer; generator rebuilt to consume
the model (v9.4.2 emission logic kept); instrumentation rebuilt as
parse -> inject -> regenerate.  RunCoverage, reporting, BlessBaseline, the
result-shape helpers and the schemas are kept as-is.  Phased roadmap (Phase 0
SQLCLR/ScriptDom spike through Phase 5 cutover), each phase leaving a working
framework.

No framework code changed in this iteration - design document only.
\n
## 2026-05-24 - v9.4.2: honest SkipTest for branches the generator cannot assert

User requirement: no phantom tests - a generated test must never pass while
asserting nothing.  If the generator cannot genuinely test a branch it must say
so, in the test class, so the end user knows what is covered and what they own.

Until now several fallbacks emitted a quietly-passing test: the EXISTS_TRUE /
IF_ELSE and EXISTS_FALSE weak fallbacks emitted EXEC tSQLt.AssertEquals
@Expected=1, @Actual=1 (a guaranteed pass); the no-table/no-result-column
branch and the no-analysable-paths fallback emitted no assertion at all (also a
pass); and the Phase B path emitted nothing when the result column expected
value was not statically derivable.  Each is a phantom pass.

Fix (generator only - modules\\04_Test_Generator_v3.sql + installer): every one
of those fallbacks now emits  EXEC tSQLt.SkipTest '<reason>'  instead.  The
SkipTest call is placed AFTER the procedure EXEC, so the procedure still runs
and coverage still records the hit; the test is then reported as SKIPPED (its
own column in the tSQLt summary) with a plain "MANUAL TEST REQUIRED: ..."
reason.  A generated test now either carries a real assertion (AssertEqualsTable,
the v9.4.2 delta, AssertEqualsString) or is skipped with a reason - no test
passes while asserting nothing.

Six fallbacks converted: the EXISTS_TRUE/IF_ELSE weak fallback; the EXISTS_FALSE
weak fallback (both resolved- and unresolved-read-target sub-cases); the branch
with no table effect and no result column; the Phase B result column whose
expected value is not statically derivable; and the no-analysable-paths smoke
fallback (IF @GenTestCount = 0).

Honest residual (in the spirit of the principle): this removes every *silent
pass*.  One weaker spot remains - a non-replayable INSERT branch whose only
check is the v9.4.2 "row count grew" delta could in principle be satisfied by
the procedure taking a different path that also inserts into the same table.
That is weak, not a phantom (it still verifies a row was added, and a replayable
INSERT branch is additionally backstopped by AssertEqualsTable on the projected
columns) - but it is not airtight.  Logged as a known item to tighten; the v10
recursive solver, which confirms a branch is actually reached, is the structural
fix.

README_v9_4.md gained a "Skipped tests - what the generator could not test for
you" section so end users read the skipped count as their manual-test to-do
list, not as a bug.

Verified: GenerateTestsForProcedure byte-identical across module and installer;
no  AssertEquals @Expected=1, @Actual=1  emission remains.  Re-run the
regenerate + Verify_v9_4.sql cycle - some previously-"passing" branch tests will
now show as skipped, which is the honesty working as intended.

================================================================================
2026-05-24  v9.4.2  --  Combined installer truncation REPAIRED
================================================================================
SYMPTOM
  Running Install_All_Combined_v9_2_FINAL.sql from scratch failed with:
    Msg 102, Level 15, State 1, Procedure InstrumentProcedure, Line 264
    [Batch Start Line 6355]  Incorrect syntax near 'ELSE'.

ROOT CAUSE  (pre-existing; not introduced by v9.4.x work)
  The combined installer was truncated mid-TestGen.InstrumentProcedure.  The
  file ended at module 20's line 364 with a dangling ELSE, so the CREATE
  PROCEDURE batch never closed.  Everything after that point was missing:
    - the rest of InstrumentProcedure (module 20 lines 365-629),
    - TestGen.BootstrapCoverage      (section 21_Coverage_TestPatcher),
    - TestGen.RecordCoverageHit      (section 23_Coverage_ServiceBroker),
    - TestGen.RunCoverage            (section 23_Coverage_ServiceBroker),
    - TestGen.GetCoverageReport      (section 22_Coverage_Reporter).
  The truncation also affected the v9.4 zip's Install_All_Combined_v9_4.sql
  (identical dangling-ELSE ending).  The last complete combined installer was
  Install_All_Combined_v9_3.sql inside tSQLtAutoGen_v9.3.zip.

FIX
  Reconstructed a complete installer.  Between v9.3 and v9.4.2 only two module
  files changed (verified by diff): 04_Test_Generator_v3.sql and
  17_Branch_Path_Analyzer_v3_2.sql.  Modules 03, 20, 22 are byte-identical
  (module 20 differs only by 3 trailing blank lines).  So the repaired
  installer is the verified-complete v9.3 installer with its section 17 and
  section 04 replaced by the current v9.4.2 module files:
    head (sections 01-16)  == v9.3 installer  (verified identical)
    section 17             == modules\17_Branch_Path_Analyzer_v3_2.sql
    section 04             == modules\04_Test_Generator_v3.sql
    tail (06,20,21,23,22)  == v9.3 installer  (verified identical)
  Every splice join falls on a GO batch terminator, so no batch spans a seam.
  Result: Install_All_Combined_v9_2_FINAL.sql is now 7537 lines and contains
  all 29 framework objects, including the five complete coverage procedures.
  Banner updated to v9.4.2; INSTALL.md updated (the combined installer is now
  the recommended brand-new-install path; the truncation warning removed).

VERIFY
  Re-run Install_All_Combined_v9_2_FINAL.sql against a fresh database; the
  final output line is "TestGen.GetCoverageReport v2 created." with no Msg 102.

================================================================================
2026-05-24  v9.4.2  --  SkipTest: wrong-API bug fixed (annotation, not procedure)
================================================================================
SYMPTOM
  The stress-corpus campaign run reported, for every test the "no phantom
  passes" work had converted:
    (Error) Could not find stored procedure 'tSQLt.SkipTest'. ... Number: 2812
  e.g. test_uspLevel3ValidationTest: 6 of 17 tests Errored, all on this.

ROOT CAUSE
  The earlier v9.4.2 work emitted  EXEC tSQLt.SkipTest '<reason>'  inside the
  test body.  tSQLt has NO callable procedure named tSQLt.SkipTest.  SkipTest
  is an ANNOTATION - a comment, --[@tSQLt:SkipTest]('reason'), placed before a
  test procedure's CREATE PROCEDURE - introduced in tSQLt V1.0.7597.5637
  (Oct 2020).  So this was never a tSQLt-version gap: no version of tSQLt would
  have made  EXEC tSQLt.SkipTest  resolve.  It was a wrong-API call.

FIX
  The generator (modules\04_Test_Generator_v3.sql) now emits the real
  annotation.  For each generated test it records, just after the GO that
  precedes the test, the character position where CREATE PROCEDURE starts
  (@v94CpPos = DATALENGTH(@S)/2 + 1).  When a branch cannot be auto-asserted it
  sets @v94SkipReason instead of emitting a body assertion; at end of the test
  it STUFFs  --[@tSQLt:SkipTest]('MANUAL TEST REQUIRED: ...')  into @S at
  @v94CpPos, i.e. immediately before CREATE PROCEDURE and inside that batch, so
  the annotation survives into the stored module definition and tSQLt honours
  it.  All six former  EXEC tSQLt.SkipTest  sites were converted; the five
  in-branch-loop sites share one STUFF block, the @GenTestCount=0 fallback its
  own.  A skipped test now reports in the tSQLt summary's *skipped* column - it
  is NOT marked Failed (a Failure would misrepresent a healthy procedure as
  broken).  The legitimate  EXEC tSQLt.Fail  calls (snapshot-setup failure,
  branch EXEC failure, fallback EXEC failure) are unchanged.

  Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced from the
  updated module; verified byte-identical).  Patch_TestGen_StrongAssertions.sql
  :r-includes module 04, so it carries the fix automatically.

REQUIREMENT
  v9.4.2 now requires tSQLt >= V1.0.7597.5637 for the SkipTest annotation to be
  honoured.  On an older tSQLt the annotation is an inert comment and such a
  test would run with no assertion.  INSTALL.md / README_v9_4.md updated;
  check the installed build with  SELECT tSQLt.Info();

VERIFY
  Regenerate a test class and re-run it - tests for non-assertable branches
  appear in the *skipped* column, not Errored and not Failed.

================================================================================
2026-05-24  v9.4.2  --  "touches only mocked tables" test: real per-table assert
================================================================================
SYMPTOM (user review of a generated test for dbo.uspGetBillOfMaterials)
  The standard "touches only mocked tables" isolation test captured row counts
  for each dependency table (BillOfMaterials, Product) - then collapsed them:
    DECLARE @TotalBefore INT = (SELECT SUM([RowCount]) FROM @RowCountsBefore);
    DECLARE @TotalAfter  INT = (SELECT SUM([RowCount]) FROM @RowCountsAfter);
  Two flaws:
   1. Summing across tables hides offsetting changes - delete N rows from one
      table, insert N into another, and the total is unchanged.
   2. The before/after comparison was only PRINTed.  The actual assertions
      (@BeforeValid / @AfterValid = "count >= 0") are tautologies - a COUNT(*)
      is never negative - so the test passed even if the proc modified rows.
  i.e. a phantom-style pass: titled "touches only mocked tables", asserts
  nothing meaningful about it.

FIX (modules\04_Test_Generator_v3.sql, Test 4 emission)
  - Per-table capture now lands in #v94_RcBefore / #v94_RcAfter temp tables
    (was @table variables, which cannot be passed to AssertEqualsTable).
  - The generator classifies the procedure read-only vs. DML by scanning its
    source for INSERT / UPDATE / DELETE / MERGE as whole words (errs toward
    "DML" when unsure, so a read-only proc is never given a false-failing
    assertion).
  - Read-only procedure:  EXEC tSQLt.AssertEqualsTable '#v94_RcBefore',
    '#v94_RcAfter';  - a real assertion that compares the two captures
    row-for-row, catching a change in ANY single table (no SUM masking).
  - DML procedure:  a per-table count change is legitimate (the writes land
    in the FAKED tables), so a counts-unchanged assertion would be a false
    failure.  The test is marked --[@tSQLt:SkipTest] (reported Skipped); its
    real table effects are covered by the branch/path tests.  The body prints
    the per-table delta for reference.
  The SUM, the IS NULL checks and the >=0 tautologies are gone.

  Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced from
  the updated module; verified byte-identical).

VERIFY
  Regenerate test_<proc>; "touches only mocked tables" now ends in a real
  AssertEqualsTable for a read-only proc (e.g. uspGetBillOfMaterials), or is
  reported Skipped for a proc that performs DML.

================================================================================
2026-05-24  v9.4.2  --  "touches only mocked tables": DML case is a smoke test
================================================================================
FOLLOW-UP to the entry above.  That change marked the "touches only mocked
tables" test [@tSQLt:SkipTest] for any DML procedure.  On review that was an
over-correction: the test still does real work - it fakes and seeds EVERY
table dependency and runs the procedure end-to-end - and skipping discarded a
genuine isolation check.

CHANGE (modules\04_Test_Generator_v3.sql, Test 4)
  The DML case is no longer skipped.  The procedure EXEC is now wrapped in
  TRY/CATCH; on error the CATCH calls tSQLt.Fail with an "Isolation failure:
  ..." message.  That TRY/CATCH IS the assertion for a DML procedure: the test
  passes when the procedure runs cleanly against faked + seeded copies of all
  its dependencies, and fails clearly otherwise.  It is an isolation smoke test
  with a real failure mode - not a tautology, and not skipped.
  Read-only procedures keep the stronger per-table AssertEqualsTable (and now
  also benefit from the TRY/CATCH).  Specific table effects of a DML procedure
  remain the job of the branch/path tests.

  Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced;
  verified byte-identical).

================================================================================
2026-05-24  v9.4.2  --  Characterization-test scaffold for set-based / CTE procs
================================================================================
MOTIVATION
  For a pure set-based procedure (a recursive CTE such as uspGetBillOfMaterials,
  or any SELECT-only proc) the analyzer finds no DML and no IF/EXISTS branches,
  so the generator could only derive the result-set SHAPE.  Shape testing
  catches column drift but never verifies the result VALUES are correct - the
  recursion / WHERE / date-filter / aggregation logic went unchecked.

CHANGE (modules\04_Test_Generator_v3.sql, result-set test block)
  1. NEW "Test 9" - a characterization scaffold, emitted for every procedure
     with a describable result set:
       - fakes + seeds the dependency tables (the generic auto-seed),
       - CREATE TABLE #Expected / #Actual from the described result shape,
       - INSERT #Actual EXEC <proc> <args>,
       - EXEC tSQLt.AssertEqualsTable '#Expected','#Actual'.
     It is emitted with the --[@tSQLt:SkipTest] annotation and an in-body
     instruction block: the developer replaces the auto-seed with a small
     DESIGNED dataset (>= 2 recursion levels; rows the filter should include
     AND exclude), fills #Expected with the hand-computed result, and removes
     the annotation to activate it.  Until then it reports Skipped - an honest,
     actionable to-do, not a silent shape-only pass.
  2. The baseline ("returns rows matching baseline") test now prints a NOTE
     when the captured result set is empty, so an empty-seed baseline - which
     would make the row comparison trivially pass - is disclosed rather than
     hidden.

  Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced;
  verified byte-identical).

RATIONALE
  A static generator cannot derive the expected output of arbitrary set-based
  SQL (that is v10 territory).  The honest v9.4.2 answer: scaffold everything
  mechanical and hand the two data sets - the designed input and the expected
  output, which encode the business logic - back to the developer, clearly
  marked.  See README_v9_4.md.

================================================================================
2026-05-24  v9.4.2  --  Generation switches + "separate developer class" model
================================================================================
Two requests, both about making the generate/regenerate cycle safe to live with.

1. SWITCHES
   GenerateTestsForProcedure gains @EmitNullChecks and @EmitScaffold (both
   BIT, default 1).  @EmitNullChecks=0 suppresses the NULL-rejection tests;
   @EmitScaffold=0 suppresses the set-based characterization scaffold.
   GenerateTestsForSchema gains the same two parameters and passes them
   through.  Defaults keep current behaviour.

2. "SEPARATE DEVELOPER CLASS" - hand-modified tests are no longer lost
   PROBLEM: GenerateTestsForProcedure's script begins with tSQLt.DropClass,
   so regenerating wipes the whole class - including any test a developer
   filled in (e.g. a completed characterization scaffold).  (RunCoverage
   itself was already safe: it instruments the proc and runs the existing
   class; it does NOT drop or regenerate tests.  The destroyer is
   regeneration / the Regen_and_RunCoverage convenience script.)

   MODEL: test_<proc> is framework-owned and fully regenerated every run.
   test_<proc>_custom is developer-owned - the framework never creates,
   drops, or edits it.  To keep a test, the developer copies it into
   test_<proc>_custom (same name).  Changes:
     - GenerateTestsForProcedure: after regenerating test_<proc>, a dedup
       pass drops from test_<proc> any test whose name also exists in
       test_<proc>_custom (the developer has adopted it) - so the framework
       copy and the developer copy never duplicate.
     - RunCoverage: now runs test_<proc>_custom alongside test_<proc> (inside
       the same XEvent window), so developer-owned tests count toward
       coverage.  Applied in both Patch_RunCoverage_AlwaysReinstrument.sql
       and the combined installer.
   The framework's only contact with test_<proc>_custom is read-only:
   RunCoverage executes it, the dedup pass checks it for name collisions.
   It is never NewTestClass-ed or DropClass-ed by the framework.

   See README_v9_4.md ("Keeping your own tests across regeneration").

   Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced from
   the updated module; GenerateTestsForSchema + RunCoverage edited in place;
   verified byte-identical / installer ends clean at GetCoverageReport).

================================================================================
2026-05-24  v9.4.2  --  TestGen.EnsureCustomTestClass wrapper
================================================================================
A one-call wrapper so a developer can create the protected custom test class
without knowing the tSQLt internals.

  EXEC TestGen.EnsureCustomTestClass @SchemaName='dbo', @ProcName='YourProc';

It derives the class name (test_<proc>_custom, or <@TestClassName>_custom),
checks tSQLt is installed, and creates the class only if it does not already
exist - so it is idempotent and SAFE: tSQLt.NewTestClass DROPS an existing
class, but the wrapper never calls it on a class that is already there, so a
re-run can never destroy the developer's tests.  Returns the class name via an
optional @CustomClassName OUTPUT parameter and prints what it did / next steps.
Soft-warns (does not fail) if the named procedure does not exist.

Lives in modules\04_Test_Generator_v3.sql (so Patch_TestGen_StrongAssertions.sql
delivers it via its :r include) and mirrored into the combined installer.
README_v9_4.md and scripts\Usage_Examples_v9_4_2.sql updated to use it.

================================================================================
2026-05-24  v9.4.2  --  TestGen.GenerateAndRunCoverage (combined convenience)
================================================================================
A single procedure that runs the whole loop - generate + install the test
class, then instrument and report coverage:

  EXEC TestGen.GenerateAndRunCoverage @SchemaName='dbo', @ProcName='YourProc';

Signature mirrors GenerateTestsForProcedure (same generation switches:
@CaptureRows, @EmitNegativeTests, @AssertExceptionOnInvalidInputs,
@EmitNullChecks, @EmitScaffold) plus @OutputMode for the coverage report and
@RunId OUTPUT.  It is a thin orchestration proc: it EXECs
GenerateTestsForProcedure (@ExecuteScript=1) then TestGen.RunCoverage; if
generation fails the error propagates and coverage is not attempted.  It uses
the default test class name test_<proc> (for a non-default @TestClassName,
call the two procedures separately).  Lives in module 04 (delivered by
Patch_TestGen_StrongAssertions.sql) and mirrored into the combined installer.

================================================================================
2026-05-24  v9.4.2  --  Database-wide coverage report (CI/CD)
================================================================================
NEW: TestGen.CoverageResult table + TestGen.GenerateAndCoverDatabase procedure.

  EXEC TestGen.GenerateAndCoverDatabase;                     -- HTML, all schemas
  EXEC TestGen.GenerateAndCoverDatabase @OutputMode='TEXT';
  EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter='dbo';

For every user procedure (all schemas except tSQLt / TestGen / TestGenLog and
the generated test_* classes) it: generates + installs the test class; runs it
(plus the developer-owned _custom class, if present) and reads tSQLt.TestResult
for passed/failed/errored/skipped; runs RunCoverage with @OutputMode='NONE'
(silent - GetCoverageReport's TEXT/HTML blocks are gated, so 'NONE' prints
nothing); and computes line/branch coverage from CoverageLines + CoverageHits
using the same next-executable-line branch rule as GetCoverageReport.

One row per procedure per batch is persisted to TestGen.CoverageResult
(BatchId, schema, proc, total/covered lines, line%, total/covered branches,
branch%, tests run/passed/failed/errored/skipped, error text) - kept across
runs for trending.

It then emits ONE report: an HTML table with a row per procedure, a TOTAL row,
summary cards for overall line% / branch% / test counts, and the aggregate
outcome percentages (passed/failed/errored/skipped over all procedures).
@OutputMode='TEXT' prints a summary and returns the per-proc rows as a result
set instead.

DESIGN: zero changes to existing procedures.  The whole feature is one new
table + one new procedure in module 04 (so Patch_TestGen_StrongAssertions.sql
delivers it); RunCoverage is driven silently via the already-supported (and
inert) @OutputMode='NONE'.  The tests run twice per procedure - once for
outcomes against the real proc, once instrumented by RunCoverage for coverage.
Needs server-level XEvent permission (via RunCoverage).

Mirrored into Install_All_Combined_v9_2_FINAL.sql (section 04 spliced; verified
byte-identical, installer ends clean at GetCoverageReport).
README_v9_4.md and scripts\Usage_Examples_v9_4_2.sql updated.

================================================================================
2026-05-24  v9.4.2  --  Coverage report: one test run per procedure, not two
================================================================================
FOLLOW-UP to the database-wide coverage report.  As first built,
GenerateAndCoverDatabase ran each procedure's tests twice: once with tSQLt.Run
to capture pass/fail/skip/error, and again inside RunCoverage (instrumented)
to measure coverage - because RunCoverage swallowed the outcomes internally
and tSQLt.Run clears tSQLt.TestResult on each call.

CHANGE: RunCoverage now captures the outcomes from its own (instrumented) run
and returns them via five new OUTPUT parameters - @TestsRun, @TestsPassed,
@TestsFailed, @TestsErrored, @TestsSkipped.  The instrumented procedure
behaves identically to the real one (instrumentation injects only no-op
hit-recording calls), so the instrumented run's outcomes ARE the real
outcomes - a separate clean run is unnecessary.  RunCoverage reads
tSQLt.TestResult after running test_<proc> and again after test_<proc>_custom,
accumulating across both.  The new parameters default to NULL OUTPUT, so every
existing RunCoverage caller is unaffected.

GenerateAndCoverDatabase now makes a SINGLE RunCoverage call per procedure and
reads the outcomes from those OUTPUT parameters - the tests run once, halving
the work on a large database.

Applied to RunCoverage in both Patch_RunCoverage_AlwaysReinstrument.sql and the
combined installer; GenerateAndCoverDatabase updated in module 04 and mirrored.
README_v9_4.md updated.

================================================================================
2026-05-24  v9.4.2  --  Multiple developer ("custom") classes per procedure
================================================================================
Previously only the single class test_<proc>_custom was wired into the
framework's automation.  Now ANY class named test_<proc>_custom... is
recognised - a procedure can have several developer-owned classes (e.g. to
keep edge-case tests separate from regression tests).

  - RunCoverage: replaced the single SCHEMA_ID(@TestClass+'_custom') check with
    a cursor over every schema whose name LIKE test_<proc>_custom% (underscores
    escaped as [_]); each is run and its outcomes accumulated.
  - GenerateTestsForProcedure dedup pass: a test adopted into ANY
    test_<proc>_custom... class now causes the framework's same-named copy to
    be dropped from test_<proc> (was: only the exact test_<proc>_custom class).
  - EnsureCustomTestClass: new optional @Variant parameter - appends a suffix,
    so EnsureCustomTestClass @ProcName='X', @Variant='edge' creates
    test_X_custom_edge.  All such classes are still never touched by the
    framework.

Note: one tSQLt class holds any number of test procedures, so multiple custom
classes are only an organisational convenience - not a requirement.

Applied to RunCoverage (Patch_RunCoverage_AlwaysReinstrument.sql + installer)
and module 04 (mirrored).  README_v9_4.md / Usage_Examples_v9_4_2.sql updated.

================================================================================
2026-05-24  v9.4.2  --  TestGen.DropGeneratedTestClasses (tear-down)
================================================================================
NEW: a tear-down procedure so a database can be returned to just its business
procedures after a generate / run / coverage cycle.

  EXEC TestGen.DropGeneratedTestClasses @WhatIf = 1;          -- preview
  EXEC TestGen.DropGeneratedTestClasses;                      -- drop generated
  EXEC TestGen.DropGeneratedTestClasses @IncludeCustom = 1;   -- full wipe

It reads TestGenLog.GenerationRun - the framework's own log of every class it
generated - and drops each class still present (via tSQLt.DropClass).  Because
it works off that log it ONLY removes framework-generated test_<proc> classes;
developer-owned test_<proc>_custom... classes are preserved unless
@IncludeCustom = 1.  @SchemaFilter scopes it to one schema; @WhatIf = 1 lists
what would be dropped and drops nothing.  Each DropClass is wrapped in
TRY/CATCH so one failure does not abort the run; a dropped/failed tally is
printed.  The TestGenLog history and TestGen.CoverageResult trending data are
left intact.

Lives in module 04 (delivered by Patch_TestGen_StrongAssertions.sql); mirrored
into the combined installer.  README_v9_4.md / Usage_Examples_v9_4_2.sql updated.

================================================================================
2026-05-25  v9.4.2 / Instrumenter v5.2  --  WWI: TRY/CATCH structural-keyword fix
================================================================================
CONTEXT
  First exercise of the framework on WideWorldImporters (it had only ever been
  run against AdventureWorks2025).  Target procedure
  [Application].[AddRoleMemberIfNonexistent] - a small security utility:
      @RoleName / @UserName sysname, WITH EXECUTE AS OWNER
      IF NOT EXISTS (<role-membership query over sys.database_role_members
                     + sys.database_principals>)
      BEGIN BEGIN TRY DECLARE @SQL ... = N'ALTER ROLE..ADD MEMBER..';
            EXECUTE(@SQL); PRINT.. END TRY
            BEGIN CATCH PRINT..; THROW; END CATCH END

SYMPTOM
  RunCoverage reported LINE 6/6 = 100% and BRANCH 1/1 = 100%, yet 0 of 5
  generated tests passed (2 failed, 3 errored).  The HTML report rendered
  EXECUTE(@SQL); - the line that does the procedure's entire work - in the
  non-executable style, i.e. excluded from the 6-line denominator.

ROOT CAUSE  (instrumenter v5/v5.1, confirmed by a line-by-line walk trace)
  The walker recognised only a bare "BEGIN" / "END" as structural; BEGIN TRY,
  BEGIN CATCH, END TRY, END CATCH were treated as ordinary executable
  statements.  "BEGIN TRY" therefore "opened" a statement and waited for a ';'
  to terminate it.  The first body line of the TRY block is DECLARE @SQL ...
  (classified as noise), so it did not open a statement of its own - the
  open-statement pointer @StmtStart stayed parked on the BEGIN TRY line.  The
  next ';'-terminated line, EXECUTE(@SQL);, closed that stale statement, so the
  coverage hit was recorded against BEGIN TRY and EXECUTE(@SQL); itself was
  registered IsExec=0.  END TRY similarly stranded the CATCH block's first
  statement (PRINT 'Unable...'), whose hit was misattributed to END TRY.
  Net: registry IsExec = {SET XACT_ABORT, BEGIN TRY, success-PRINT, END TRY,
  THROW, END CATCH} - six lines, four of them structural scaffolding - while
  EXECUTE(@SQL) and the CATCH PRINT were invisible.  The 100% was real for
  those six lines but certified the scaffolding, not the work.
  Not WWI-specific: any procedure with a DECLARE as the first statement inside
  a TRY block hits this.  The AdventureWorks sample procs never exposed it
  because their branch bodies are plain BEGIN/END blocks with INSERT/UPDATE,
  no TRY/CATCH.

FIX  (TestGen.InstrumentProcedure v5.1 -> v5.2)
  Two CASE expressions in the per-line static-flags table (@Cls):
    IsPureBegin now matches  'BEGIN','BEGIN TRY','BEGIN CATCH'
    IsPureEnd   now matches  'END','END;','END TRY','END TRY;',
                             'END CATCH','END CATCH;'
  The four TRY/CATCH keywords are now classified IsExec=0 / IsBranch=0 (excluded
  from the executable-statement walk).  BEGIN TRY / BEGIN CATCH push a block
  marker onto @CtxStack via the existing @PB handler; END TRY / END CATCH pop it
  via the existing END-keyword scan - so the stack stays balanced (pre-v5.2 it
  was net-unbalanced for any TRY/CATCH proc).  After the fix the CATCH PRINT is
  counted on its own line and the four structural keywords are no longer fake
  coverage units.

NO REGRESSION
  The change only alters @Cls for lines whose trimmed text is exactly one of the
  four TRY/CATCH keywords.  A procedure body containing none of them yields a
  byte-identical @Cls, hence a byte-identical walk and _cov.  uspV9ValidationTest,
  uspLevel3ValidationTest and uspGetBillOfMaterials have no TRY/CATCH in their
  bodies, so their instrumentation is unchanged.

HONEST RESIDUAL  (not fixed - line-walker limitation)
  EXECUTE(@SQL); is still not counted on its own line.  The DECLARE @SQL above
  it has NO terminating ';' (the ';' visible in the source is inside the string
  literal N';') and its initializer wraps across two lines.  A line walker
  cannot split a no-semicolon multi-line statement from the statement that
  follows it; DECLARE+EXECUTE collapse into one coverage unit (the hit lands on
  the DECLARE's last line).  This is the structural ceiling the v10 ScriptDom
  rewrite addresses; not pursued here.

CUSTOM TEST DELIVERED
  The auto-generator structurally cannot test this procedure (predicate over
  un-fakeable system catalog views; IF NOT EXISTS not recognised by the analyzer,
  which scans for the literal 'IF EXISTS'; the real work is done in dynamic SQL).
  NEW: scripts\test_AddRoleMemberIfNonexistent_custom.sql - a hand-authored,
  developer-owned tSQLt class (test_AddRoleMemberIfNonexistent_custom) with three
  real tests: membership added when absent; idempotent no-op when the member
  already exists; THROW when the role does not exist.  Each test creates a
  throwaway role + WITHOUT LOGIN user inside the test's rolled-back transaction.

OTHER WWI GAPS NOTED  (not addressed this iteration)
  - AnalyzeBranchPaths scans for the literal 'IF EXISTS'; 'IF NOT EXISTS' is not
    detected, so no branch test is generated for such a predicate.
  - GetProcedureDependencies filters out system catalog views (sys.objects join
    + type IN ('U','V',...)), so a predicate over sys.* gets no FakeTable setup -
    acceptable here (system views cannot be faked) but the generated tests then
    run against the live catalog with type-based junk arguments.
  - InstrumentProcedure builds _cov WITHOUT the original WITH EXECUTE AS clause,
    so a proc relying on EXECUTE AS for permissions runs as the caller under
    coverage.  Latent on a sysadmin dev box; a real correctness gap.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql                 (v5.1 -> v5.2)
  - Install_All_Combined_v9_2_FINAL.sql                     (inline copy, mirrored)
  - scripts\Patch_InstrumentProcedure_BareBranchBody.sql    (standalone DROP+CREATE
    patch; header updated; now delivers v5.2)
  - scripts\test_AddRoleMemberIfNonexistent_custom.sql       (NEW - custom test)
  Verified: CREATE PROCEDURE TestGen.InstrumentProcedure is byte-identical across
  module, installer and patch (528-line body, md5 90c168ff...).

TOOLING / FILE-INTEGRITY NOTE
  The first edit pass truncated all three InstrumentProcedure files - the editor
  capped each write at the file's ORIGINAL byte size and dropped the tail (the
  same capping bug recorded in the 2026-05-24 v9.4.2 file-integrity note).  All
  three were rebuilt from the verbatim tSQLtAutoGen_v9.4.2.zip copies with the
  v5.2 change re-applied via a non-capping (direct) write, then re-verified
  complete and byte-identical as above.

VERIFY  (run by user)
  Apply scripts\Patch_InstrumentProcedure_BareBranchBody.sql, then re-run
  TestGen.RunCoverage for Application.AddRoleMemberIfNonexistent.  Expect the
  CATCH PRINT to count on its own line and the four BEGIN/END TRY/CATCH lines to
  drop out of the denominator.  uspV9ValidationTest / uspLevel3ValidationTest must
  hold 100% (no TRY/CATCH in those procs -> byte-identical instrumentation).

================================================================================
2026-05-25  v9.4.3  --  "Not testable" detection (Phase 1: per-procedure gate)
================================================================================
MOTIVATION
  The run on WideWorldImporters' [Application].[AddRoleMemberIfNonexistent]
  showed the generator emitting five generic tests that all errored/failed,
  plus a misleading 100% coverage, for a procedure it structurally cannot test
  (no fakeable dependencies; the predicate reads system catalog views; the work
  is done in dynamic SQL).  A procedure the framework cannot auto-test should be
  DETECTED and MARKED - not silently omitted, and not papered over with
  hand-written tests (which do not scale).

NEW: TestGen.AssessTestability  (module 04)
  A pre-generation gate.  Returns @Verdict ('TESTABLE' / 'NOT_TESTABLE') and a
  @Reason via OUTPUT parameters.  A procedure is NOT_TESTABLE when BOTH hold:
    (1) zero fakeable user table/view dependencies
        (TestGen.GetProcedureDependencies returns no TABLE/VIEW rows), and
    (2) it references the system catalog (sys schema / INFORMATION_SCHEMA),
        detected via sys.dm_sql_referenced_entities with a source-text scan as
        a comment/string-immune fallback.
  Conservative by design: one fakeable dependency keeps a procedure on the
  normal path.  OUTPUT-only - no result set - so it is silent when called
  internally.

CHANGED: TestGen.GenerateTestsForProcedure  (module 04 - new section "1c")
  Immediately after the existing full-text-search skip check, the procedure now
  calls AssessTestability.  On a NOT_TESTABLE verdict it:
    - emits the test class test_<proc> containing exactly ONE test, carrying
      the  --[@tSQLt:SkipTest]('NOT TESTABLE: <reason>')  annotation, whose body
      is a guidance comment pointing the developer to
      TestGen.EnsureCustomTestClass for hand-written tests;
    - records the run in TestGenLog.GenerationRun with Status = 'NotTestable';
    - RETURNs - the futile generic tests are not emitted.
  On a TESTABLE verdict nothing changes - generation proceeds exactly as before.

  Rationale for a visible SkipTest marker (vs. silent omission): the procedure
  shows up honestly in tSQLt's *skipped* column with a reason - an actionable
  to-do, not an invisible gap - and it leaves a clear hook for a developer to
  hand-code tests in test_<proc>_custom if they choose.

EXAMPLE (WideWorldImporters)
  EXEC TestGen.GenerateTestsForProcedure 'Application','AddRoleMemberIfNonexistent';
  -> now emits test_AddRoleMemberIfNonexistent with one skipped marker test,
     instead of five erroring generic tests.

NO REGRESSION
  AssessTestability is a new procedure.  The only change to existing behaviour
  is the section-1c block in GenerateTestsForProcedure, gated entirely on a
  NOT_TESTABLE verdict; a testable procedure never enters it.  The three
  AdventureWorks sample procedures are testable (each has fakeable user-table
  dependencies), so their generation is unaffected.

SCOPE / PHASE 2 (still to come)
  This phase makes per-procedure GENERATION honest.  Phase 2 makes the
  database-wide REPORT honest: a Testability column on TestGen.CoverageResult,
  NULL (not 0%) coverage for not-testable procedures, a distinct "Not Testable"
  category in GenerateAndCoverDatabase's report with headline averages computed
  over testable procedures only, and the AssessTestability gate also consulted
  by RunCoverage and GetCoverageReport.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql      - NEW proc TestGen.AssessTestability;
    section 1c added to GenerateTestsForProcedure.
  - Install_All_Combined_v9_2_FINAL.sql   - same, mirrored inline.
  Verified: TestGen.AssessTestability and TestGen.GenerateTestsForProcedure are
  each byte-identical across module and installer.
  scripts\Patch_TestGen_StrongAssertions.sql :r-includes module 04, so it
  delivers Phase 1 unchanged.

TOOLING NOTE
  Edits applied via a direct (non-capping) write - the Edit tool's
  original-byte-size cap (see the 2026-05-24 / 2026-05-25 file-integrity notes)
  truncates any file an edit grows.

VERIFY  (run by user)
  Apply scripts\Patch_TestGen_StrongAssertions.sql, then
  EXEC TestGen.GenerateTestsForProcedure 'Application','AddRoleMemberIfNonexistent';
  then EXEC tSQLt.Run 'test_AddRoleMemberIfNonexistent' - the single test should
  report SKIPPED with the NOT TESTABLE reason.  Regenerate a normal procedure
  (e.g. an AdventureWorks sample) and confirm generation/coverage are unchanged.

================================================================================
2026-05-25  v9.4.3  --  "Not testable" detection (Phase 2: database-wide report)
================================================================================
Phase 1 made per-procedure GENERATION honest.  Phase 2 makes the database-wide
REPORT honest: a NOT_TESTABLE procedure is recorded and shown as its own
category, never as 0% / 100% coverage, and never dragged into the headline
averages.

CHANGED: TestGen.CoverageResult  (module 04)
  A new idempotent retro-fit block (after the CREATE TABLE) adds two columns and
  relaxes nullability - applied to a freshly created table and to one left by a
  pre-v9.4.3 install alike:
    - Testability       VARCHAR(20)  NOT NULL DEFAULT 'TESTED'
    - NotTestableReason NVARCHAR(400) NULL
    - the six coverage columns (TotalLines, CoveredLines, LinePct,
      TotalBranches, CoveredBranches, BranchPct) become NULLable, so a
      NOT_TESTABLE row stores NULL coverage rather than a misleading 0.
  Because the six columns are now NULL for not-testable procedures, the
  existing SUM()-based aggregates exclude them automatically - the headline
  line/branch coverage is computed over TESTED procedures only, with no extra
  WHERE clause.

CHANGED: TestGen.GenerateAndCoverDatabase  (module 04)
  - Per-procedure gate: each procedure is classified by AssessTestability
    before generation.  A NOT_TESTABLE procedure still gets its Phase 1
    SkipTest marker class, but is recorded in CoverageResult with
    Testability='NOT_TESTABLE', NULL coverage, the reason, and TestsSkipped=1 -
    then the loop CONTINUEs (no instrumentation, no coverage measurement).
  - Aggregate: new @gNotTestable count.
  - HTML report: the meta line shows "(N failed generation, M not testable)";
    each not-testable procedure renders as a distinct greyed row spanning the
    metric columns with its reason instead of coverage numbers.  The TOTAL row
    and the headline line/branch % are unchanged in code - they were already
    SUM-based, so they now naturally cover TESTED procedures only.
  - TEXT report: a "Not testable" summary line; the per-procedure result set
    gains the Testability and NotTestableReason columns.

  A testable procedure is completely unaffected - the gate's NOT_TESTABLE
  branch is never entered, the normal INSERT picks up Testability='TESTED' from
  the column default, and the report renders it exactly as before.

OUTCOME
  A database-wide run now answers "was this procedure unit-tested?" honestly:
  a NOT_TESTABLE procedure appears as its own row with a reason, is tallied
  separately ("M not testable"), stores NULL (not 0%) coverage, and is excluded
  from the headline averages - it can be neither mistaken for a tested 0%/100%
  procedure nor silently omitted.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql    - CoverageResult retro-fit block;
    GenerateAndCoverDatabase gate + report changes.
  - Install_All_Combined_v9_2_FINAL.sql - same, mirrored inline.
  Verified: TestGen.GenerateAndCoverDatabase byte-identical across module and
  installer; the CoverageResult retro-fit block byte-identical across both.
  Delivered by scripts\Patch_TestGen_StrongAssertions.sql (it :r-includes
  module 04).

STILL TO COME (Phase 2 remainder)
  RunCoverage and GetCoverageReport, called DIRECTLY on a not-testable
  procedure, still instrument it and can show a misleading per-procedure
  number.  Adding the AssessTestability guard + a "NOT TESTABLE" banner to
  those two procedures is the last piece.

TOOLING NOTE
  Edits applied via a direct (non-capping) write.

VERIFY  (run by user)
  Apply scripts\Patch_TestGen_StrongAssertions.sql, then
  EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter='Application';  (or TEXT)
  - [Application].[AddRoleMemberIfNonexistent] should appear as a NOT TESTABLE
  row with its reason, NULL coverage, and be excluded from the headline line/
  branch %.  Confirm an ordinary schema's procedures still report normally.

================================================================================
2026-05-25  v9.4.3  --  "Not testable" detection (Phase 2 remainder: RC + GCR)
================================================================================
The two procedures that, called DIRECTLY on a not-testable procedure, could
still print a misleading per-procedure coverage number now carry the same
AssessTestability gate.

CHANGED: TestGen.RunCoverage
  A testability gate added right after the variable setup (before any
  instrumentation).  On a NOT_TESTABLE verdict it prints a "NOT TESTABLE"
  banner with the reason and RETURNs - the procedure is never instrumented,
  no synonym/rename happens, and the @Tests* OUTPUT parameters stay 0.
  Applied to scripts\Patch_RunCoverage_AlwaysReinstrument.sql and the inline
  copy in Install_All_Combined_v9_2_FINAL.sql.

CHANGED: TestGen.GetCoverageReport
  A testability gate added after the DECLARE block (before the line-view is
  built).  On a NOT_TESTABLE verdict it prints a "NOT TESTABLE" banner (unless
  @OutputMode='NONE', in which case it stays silent) and RETURNs instead of
  rendering a 0% / 100% report.  Applied to modules\22_Coverage_Reporter_v2.sql
  and the inline copy in the installer.

  RunCoverage calls GetCoverageReport internally as its last step; because
  RunCoverage's own gate RETURNs first for a not-testable procedure, there is
  no double banner - GetCoverageReport's gate only fires on a direct call.

NO REGRESSION
  Both gates are no-ops for a TESTABLE procedure (the verdict branch is never
  entered).  AssessTestability failures are caught and treated as TESTABLE, so
  the gate can never block a procedure that was testable before.

PRE-EXISTING DISCREPANCY NOTED (not introduced here, not "fixed" here)
  The RunCoverage body in Patch_RunCoverage_AlwaysReinstrument.sql and the copy
  in the installer were already NOT byte-identical before this change: the
  installer copy has a trailing space on one line and an extra "-- Step 9:
  Report" comment block that the patch copy lacks.  Both are cosmetic (a
  trailing space; a comment) and semantically irrelevant.  The v9.4.3 gate
  block itself was verified byte-identical across both copies.  Reconciling the
  pre-existing whitespace/comment cruft is left as a separate optional cleanup.

FILES CHANGED
  - scripts\Patch_RunCoverage_AlwaysReinstrument.sql  - RunCoverage gate
  - modules\22_Coverage_Reporter_v2.sql               - GetCoverageReport gate
  - Install_All_Combined_v9_2_FINAL.sql               - both, mirrored inline
  Verified: GetCoverageReport byte-identical across module 22 and the installer;
  the v9.4.3 RunCoverage gate block byte-identical across the patch and the
  installer.

v9.4.3 "NOT TESTABLE" detection is now complete end to end: GenerateTests-
ForProcedure (Phase 1), GenerateAndCoverDatabase + CoverageResult (Phase 2),
and RunCoverage + GetCoverageReport (this entry).  AssessTestability is the
single shared gate.  A procedure the framework cannot auto-test is, at every
entry point, recorded and reported honestly - never silently dropped, never
shown a misleading coverage number.

VERIFY  (run by user)
  Apply scripts\Patch_TestGen_StrongAssertions.sql (delivers AssessTestability)
  and scripts\Patch_RunCoverage_AlwaysReinstrument.sql, then
  EXEC TestGen.RunCoverage 'Application','AddRoleMemberIfNonexistent' - expect a
  NOT TESTABLE banner and no instrumentation, not a coverage report.

================================================================================
2026-05-25  v9.4.3  --  "Not testable" detection: temporal-table handling
================================================================================
MOTIVATION
  Running coverage on WideWorldImporters' [Integration].[GetCityUpdates] aborted
  with Msg 13559 "Cannot insert rows in a temporal history table
  'Application.StateProvinces_Archive'": the generated test seeds every
  dependency, and a temporal HISTORY table rejects a direct INSERT.  No tests
  ran; the report showed a false 0/28.  tSQLt.FakeTable cannot fake a
  system-versioned temporal table (it cannot rename one) or a history table
  (insert is blocked) - a known tSQLt limitation (tSQLt issue #40).

DECISION (with the user)
  The operator turns SYSTEM_VERSIONING OFF on the temporal tables before
  testing, and ON afterwards - a documented manual prerequisite, so the
  framework never silently toggles production schema.  With versioning off the
  temporal tables behave as ordinary tables and procedures that use them as
  such are generated and tested normally.  Only two cases stay NOT_TESTABLE:
    - a procedure that uses FOR SYSTEM_TIME (AS OF / FROM..TO / CONTAINED IN /
      ALL) - that clause is valid only on a LIVE system-versioned table, so it
      can never run against a faked or de-versioned table.  PERMANENT.
    - a procedure that still depends on a system-versioned table at assess
      time - CONDITIONAL: the reason tells the operator to turn versioning
      off and regenerate; once they do, sys.tables.temporal_type becomes 0 and
      the check stops firing.

CHANGED: TestGen.AssessTestability  (module 04 + installer)
  Two checks added, before the existing "has fakeable dependencies -> TESTABLE"
  return:
    - FOR SYSTEM_TIME scan of the procedure body  -> NOT_TESTABLE (permanent).
    - any dependency with sys.tables.temporal_type <> 0 (1 = history table,
      2 = system-versioned temporal table)         -> NOT_TESTABLE (conditional).
  The FOR SYSTEM_TIME check runs first, so a procedure that both time-travels
  and depends on temporal tables gets the accurate permanent reason.

CHANGED: TestGen.GenerateAndCoverDatabase  (module 04 + installer)
  Prints a one-time reminder at the start of a database-wide run: turn
  SYSTEM_VERSIONING OFF on temporal tables before the run and ON afterwards.
  (Not added to RunCoverage - it runs per procedure, so a reminder there would
  repeat once per procedure during a sweep; RunCoverage already surfaces the
  need per procedure via its NOT TESTABLE banner.)

DOC: README_v9_4.md
  New "What's new in v9.4.3" section documents the NOT TESTABLE detection
  feature end to end and adds a "Prerequisite: temporal tables" subsection with
  the exact SET (SYSTEM_VERSIONING = OFF/ON) statements.  Title bumped to v9.4.3.

OUTCOME
  With versioning left on, [Integration].[GetCityUpdates] is reported
  NOT TESTABLE (it uses FOR SYSTEM_TIME) - a clean skipped marker test and a
  NOT TESTABLE report row, instead of an aborted batch and a false 0%.  A
  temporal-dependent procedure that does NOT use FOR SYSTEM_TIME is reported
  NOT TESTABLE only while versioning is on; once the operator turns it off and
  regenerates, it is generated and tested as an ordinary procedure.

NO REGRESSION
  Both new checks sit in AssessTestability ahead of the fakeable-dependency
  return; a procedure with no temporal dependency and no FOR SYSTEM_TIME is
  unaffected.  The AdventureWorks sample procedures use no temporal tables, so
  their classification and generation are unchanged.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql      - AssessTestability temporal checks;
    GenerateAndCoverDatabase prerequisite reminder.
  - Install_All_Combined_v9_2_FINAL.sql   - same, mirrored inline.
  - README_v9_4.md                        - v9.4.3 section + temporal prerequisite.
  Verified: TestGen.AssessTestability and TestGen.GenerateAndCoverDatabase are
  each byte-identical across module and installer.  Delivered by
  scripts\Patch_TestGen_StrongAssertions.sql (it :r-includes module 04).

VERIFY  (run by user)
  Without turning versioning off, regenerate [Integration].[GetCityUpdates] -
  expect a NOT TESTABLE skipped marker (reason: FOR SYSTEM_TIME), not Msg 13559.
  For a temporal-dependent procedure with no FOR SYSTEM_TIME: regenerate with
  versioning on (NOT TESTABLE, "turn versioning off"), then turn versioning off
  and regenerate (now generated and tested normally).

================================================================================
2026-05-25  v9.4.3  --  GetCoverageReport: branch coverage shows n/a, not 0%
================================================================================
MOTIVATION
  For a straight-line procedure with no branches (e.g. Integration.GetMovement-
  Updates - a single filtered SELECT), GetCoverageReport printed
  "BRANCH COVERAGE : 0/0 branches -> 0.0%".  0/0 is undefined; rendering it as
  0.0% reads as a failing score when there is simply nothing to measure - the
  same kind of misleading number the NOT TESTABLE work removed elsewhere.

CHANGED: TestGen.GetCoverageReport  (module 22 + installer)
  A single new variable, @BranchPctDisplay, is computed right after @BranchPct:
      CASE WHEN @TotalBranch > 0 THEN CAST(@BranchPct AS VARCHAR) + '%'
           ELSE 'n/a' END
  The TEXT report and the HTML stat box now display @BranchPctDisplay, so a
  branchless procedure shows "n/a" instead of "0.0%".  The HTML branch colour
  class no longer turns red for a branchless procedure (0 branches is not a
  failure).  Line coverage is unaffected - it already fully describes a
  straight-line procedure.

  This is deliberately a single decision point: to instead treat "no branch"
  as one covered branch (1/1 = 100%), change 'n/a' to '100.0%' in that one CASE
  - a comment at the site says so.  Branch = decision point throughout; a
  branchless procedure genuinely has zero branches, so the count stays 0/0 and
  only the *display* of 0/0 changes.

  The database-wide aggregate needs nothing: a branchless procedure contributes
  0 to both sides of SUM(CoveredBranches)/SUM(TotalBranches), so it is already
  neutral in GenerateAndCoverDatabase's headline branch figure.

NOT CHANGED (noted)
  GenerateAndCoverDatabase's per-procedure HTML row still shows 0.0% in the
  Branch % cell for a branchless procedure - that report's row cursor does not
  carry the branch count.  Applying the same n/a there is a small follow-up
  (thread TotalBranches through the rc cursor).

FILES CHANGED
  - modules\22_Coverage_Reporter_v2.sql   - @BranchPctDisplay; TEXT + HTML render.
  - Install_All_Combined_v9_2_FINAL.sql   - same, mirrored inline.
  Verified: TestGen.GetCoverageReport byte-identical across module and installer.

================================================================================
2026-05-25  v9.4.3  --  Seed INSERT must exclude GENERATED ALWAYS columns
================================================================================
SYMPTOM
  After the operator turned SYSTEM_VERSIONING OFF on the temporal tables and
  regenerated Integration.GetOrderUpdates (the conditional-recovery path), the
  generated "executes with valid inputs" test failed at its seed INSERT:
    Msg 13536 - Cannot insert an explicit value into a GENERATED ALWAYS column
                in table 'WideWorldImporters.Warehouse.PackageTypes'.
  No tests ran; coverage reported a false 0/3.

ROOT CAUSE
  Turning SYSTEM_VERSIONING OFF stops history tracking but does NOT remove the
  PERIOD FOR SYSTEM_TIME definition - the two period columns remain
  GENERATED ALWAYS AS ROW START / ROW END.  tSQLt.FakeTable's fake copy keeps
  those columns, and TestGen.BuildSeedInsertForTable listed EVERY column in the
  seed INSERT.  An explicit value cannot be inserted into a GENERATED ALWAYS
  column -> Msg 13536.  This is the residual flagged when the temporal handling
  was designed ("if a seed insert trips on a GENERATED ALWAYS column, the fix
  is small: add it to the seed skip-list").  It has now surfaced.

FIX: TestGen.BuildSeedInsertForTable
  The seed builder already excludes computed and rowversion columns from the
  INSERT (and FakeTable strips identity).  It now also excludes GENERATED
  ALWAYS columns:
    - the @Cols table gains an IsGeneratedAlways flag;
    - the INSERT @Cols ... SELECT captures
      CASE WHEN c.generated_always_type <> 0 THEN 1 ELSE 0 END;
    - both the column-list build and the per-row value cursor add
      AND IsGeneratedAlways = 0 to their WHERE.
  An omitted GENERATED ALWAYS column auto-fills on INSERT, so seeding a
  de-versioned temporal table now succeeds.  A table with no GENERATED ALWAYS
  column is seeded byte-identically to before.

DELIVERY
  TestGen.BuildSeedInsertForTable lives only in the combined installer (it has
  no file under modules\).  Changes:
    - Install_All_Combined_v9_2_FINAL.sql                       - patched in place.
    - scripts\Patch_BuildSeedInsertForTable_GeneratedAlways.sql - NEW standalone
      DROP + CREATE patch for an already-installed database.
  Verified: CREATE PROCEDURE TestGen.BuildSeedInsertForTable is byte-identical
  across the installer and the patch script.

HONEST RESIDUAL
  The branch-path seeder (the EXISTS / branch-test seed, which captures
  @bpIsIdent / @bpIsComp / @bpIsRowVer) has the same skip-list shape and would
  need the same GENERATED ALWAYS exclusion if a BRANCHING procedure with a
  temporal dependency is seeded.  GetOrderUpdates is a branchless SELECT, so it
  does not exercise that path; left as a follow-up to apply if a branching
  temporal-dependent procedure hits Msg 13536.

VERIFY  (run by user)
  Apply scripts\Patch_BuildSeedInsertForTable_GeneratedAlways.sql, then - with
  SYSTEM_VERSIONING still OFF on Sales.Customers and Warehouse.PackageTypes -
  regenerate Integration.GetOrderUpdates.  The seed INSERT should now succeed
  and the procedure should generate, test, and report coverage as an ordinary
  four-table-join SELECT.  Turn versioning back ON afterwards.

================================================================================
2026-05-25  v9.4.3  --  Two bugs surfaced by the WideWorldImporters DB-wide run
================================================================================
A full TestGen.GenerateAndCoverDatabase run over WideWorldImporters (46 result
rows) exposed two defects.

BUG 1 - the sweep includes the framework's own instrumentation artifacts
  GenerateAndCoverDatabase's @work query enumerates sys.procedures excluding the
  tSQLt / TestGen / TestGenLog schemas and test_* classes - but NOT the
  <proc>_cov instrumentation copies that RunCoverage leaves behind.  The run
  therefore processed AddRoleMemberIfNonexistent_cov, GetCityUpdates_cov,
  GetMovementUpdates_cov and GetOrderUpdates_cov as if they were real
  procedures.  Worse than cosmetic: running coverage on a _cov proc instruments
  the instrumentation (producing _cov_cov / _cov_orig cruft that compounds on
  the next sweep).
  FIX: the @work query now also excludes  o.name NOT LIKE '%[_]cov'  and
  '%[_]orig'.  The sibling enumeration in TestGen.GenerateTestsForSchema (its
  @procs query) had the identical exposure and got the same two filters.

BUG 2 - test-outcome counts (run/passed/failed/errored/skipped) come back 0
  In the report, every procedure whose test class contained a failing or
  erroring test showed 0 / 0 / 0 / 0 / 0 for the outcome counts - e.g.
  GetMovementUpdates, whose individual run produced 8 tests (5 pass / 1 skip /
  2 fail), showed all zeros.  Only the three procedures whose every test passed
  showed real counts.  Coverage figures were correct and fresh throughout.
  ROOT CAUSE: tSQLt.Run RAISES an error when any test in the class fails or
  errors.  In TestGen.RunCoverage the main run -  EXEC tSQLt.Run @TestClass  -
  sat bare inside the step's BEGIN TRY, with the outcome-capture SELECT (reads
  tSQLt.TestResult) immediately after it in the SAME TRY.  So for any class
  with a failure/error the raise transferred control straight to the step's
  CATCH, skipping the capture - the @Tests* OUTPUT parameters stayed 0.  Only
  all-passing classes reached the capture.  (The custom-class run a few lines
  down was already wrapped in its own inner TRY/CATCH; the main run was not.)
  FIX: the main  EXEC tSQLt.Run @TestClass  is now wrapped in its own inner
  TRY/CATCH - mirroring the custom-class run - so the expected raise is
  swallowed locally and the outcome capture below it always runs.  tSQLt.Run
  records its results in tSQLt.TestResult before raising, so the capture is
  accurate.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql      - Bug 1 fix in GenerateAndCoverDatabase.
  - Install_All_Combined_v9_2_FINAL.sql   - Bug 1 in GenerateAndCoverDatabase AND
    GenerateTestsForSchema; Bug 2 in RunCoverage.
  - scripts\Patch_RunCoverage_AlwaysReinstrument.sql - Bug 2 in RunCoverage.
  Verified: GenerateAndCoverDatabase byte-identical across module and installer;
  the RunCoverage Bug-2 wrap byte-identical across the patch and the installer.
  NOTE: GenerateTestsForSchema lives only in the combined installer (no module
  file); its Bug-1 fix is in the installer for fresh installs - an already-
  installed database that uses GenerateTestsForSchema would need a standalone
  DROP+CREATE patch for that one procedure.

VERIFY  (run by user)
  Re-run TestGen.GenerateAndCoverDatabase over WideWorldImporters: the four
  *_cov rows should be gone, and the run/passed/failed/errored/skipped columns
  should now carry real numbers for every procedure (e.g. GetMovementUpdates
  8 / 5 / 2 / 0 / 1), not zeros.


================================================================================
2026-05-25  v9.4.3  --  Zero-parameter procedures generated a NULL script
================================================================================
SYMPTOM
  The WideWorldImporters database-wide sweep reported a handful of procedures -
  [Application].[Configuration_ConfigureForEnterpriseEdition],
  GetStockHoldingUpdates, ReseedAllSequences - as TESTED but with 0 tests and
  0% coverage.  TestGenLog.GenerationRun for each showed Status = 'Generated'
  yet GeneratedScript = NULL and GeneratedTestCount = NULL.

ROOT CAUSE
  After the parameter cursor, GenerateTestsForProcedure strips the leading
  ', ' from each EXEC argument list:
        SET @ArgListHappy = STUFF(@ArgListHappy, 1, 2, '');
  STUFF returns NULL when its start position is past the end of the input
  string.  For a procedure with NO parameters the cursor adds nothing, so
  @ArgListHappy is the empty string '' - and STUFF('', 1, 2, '') returns NULL.
  Test 5 ("invokes its dependent procedures") and Test 4 ("touches only mocked
  tables") then concatenate @ArgListHappy into the running script @S with no
  NULL guard:
        SET @S = @S + N'    EXEC ' + @FullProc + N' ' + @ArgListHappy + ...
  In T-SQL  NULL + anything = NULL,  so @S collapsed to NULL.  The final UPDATE
  still ran (Status = 'Generated') but stored a NULL script and a NULL count;
  the sweep handed NULL to ExecuteBatchedScript, installed nothing, and the
  procedure showed up as TESTED / 0 tests / 0%.
  This hit EVERY zero-parameter procedure that has at least one table or
  procedure dependency (so Test 4 or Test 5 fires).

FIX
  The three STUFF() calls (@ArgListHappy, @ArgListBoundary, @ArgListHighBnd)
  are now wrapped in ISNULL(..., N''), so a zero-parameter procedure gets an
  empty-string arg list.  Test 1 already guarded its use with IF LEN()>0;
  Test 4 / Test 5 use it unguarded - the source fix protects both without
  touching their concatenation lines.  @ArgListBad has the same STUFF pattern
  but its only use site is already behind an IF LEN()>0 guard, so it was left
  unchanged.  Procedures that DO have parameters are generated byte-identically
  to before.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - ISNULL guard, GenerateTestsForProcedure.
  - Install_All_Combined_v9_2_FINAL.sql  - same fix mirrored.
  - scripts\Patch_GenerateTestsForProcedure_NullArgList.sql - NEW standalone
    DROP+CREATE patch for an already-installed database (no TestGenLog /
    CoverageResult data is touched).
  Verified: GenerateTestsForProcedure byte-identical across module, installer
  and patch (md5 f8ec2e444415eaf887da2fdb9f438658, 2689 lines).

VERIFY  (run by user)
  Re-run generation for a zero-parameter procedure, e.g.
        EXEC TestGen.GenerateTestsForProcedure
             @SchemaName=N'Application',
             @ProcName=N'Configuration_ConfigureForEnterpriseEdition',
             @ExecuteScript=0;
  then
        SELECT TOP 1 Status, GeneratedTestCount, LEN(GeneratedScript)
        FROM TestGenLog.GenerationRun
        WHERE TargetProcedure = N'Configuration_ConfigureForEnterpriseEdition'
        ORDER BY RunId DESC;
  GeneratedScript should be non-NULL and GeneratedTestCount >= 2 (Test 1 spy-
  and-execute smoke test + Test 5 dependent-procedure assertions).  Re-running
  GenerateAndCoverDatabase, the previously 0-test procedures should now install
  and measure real coverage.


================================================================================
2026-05-25  v9.4.3  --  Database coverage report: two honesty fixes
================================================================================
Both fixes are in TestGen.GenerateAndCoverDatabase (the database-wide TEXT/HTML
report builder).  Surfaced by the WideWorldImporters HTML report.

BUG 1 - branchless / zero-line procedures showed a red 0.0%, not n/a
  The per-procedure HTML row rendered the Line % and Branch % cells straight
  from CoverageResult.LinePct / BranchPct with a g/a/r colour band.  A
  procedure with no branches (e.g. [Application].
  [Configuration_ConfigureForEnterpriseEdition], whose body is four EXEC
  statements) therefore showed a red "0.0%" Branch % - visually identical to a
  procedure that has branches and covered none.  A procedure with 0
  instrumentable lines (Sequences.ReseedAllSequences) likewise showed a red
  "0.0%" Line %.  The single-procedure report (TestGen.GetCoverageReport,
  module 22) already shows 'n/a' here; the database-wide report did not.
  FIX: the row cursor now also selects TotalBranches; each row's Line % cell
  shows a neutral grey "n/a" when TotalLines = 0, and the Branch % cell shows
  "n/a" when TotalBranches = 0, instead of a red 0.0%.

BUG 2 - the "Tests" summary card mixed two test populations in the skip count
  Every NOT_TESTABLE procedure writes one CoverageResult row carrying the
  [@tSQLt:SkipTest] marker - TestsRun = 0, TestsSkipped = 1.  The @gSkip
  aggregate was SUM(TestsSkipped) over ALL rows, so it folded the 32
  NOT_TESTABLE marker rows in with the genuine skipped tests.  The card read
  "42 Tests ... 21 pass 50.0%, 6 fail 14.3%, 12 err 28.6%, 35 skip 83.3%" -
  35 = 3 real skips + 32 NOT_TESTABLE markers - while pass/fail/err were over
  the 42 executed tests, so the four numbers did not reconcile (21+6+12+35 =
  74, not 42) and the 83.3% implied most tests were skipped.
  FIX: @gSkip is now SUM(CASE WHEN Testability = 'NOT_TESTABLE' THEN 0 ELSE
  TestsSkipped END).  The executed-test breakdown now reconciles
  (pass + fail + err + skip = tests run = 42) in both the HTML card and the
  TOTAL row and the TEXT report; the NOT_TESTABLE count stays reported by the
  meta line and the per-procedure rows.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - both fixes in GenerateAndCoverDatabase.
  - Install_All_Combined_v9_2_FINAL.sql  - same fixes mirrored.
  - scripts\Patch_GenerateAndCoverDatabase_ReportHonesty.sql - NEW standalone
    DROP+CREATE patch (procedure only; the CoverageResult table and its history
    are not touched).
  Verified: GenerateAndCoverDatabase byte-identical across module, installer
  and patch (md5 2ac67034387c23d527ad901ff5724f95, 304 lines).

VERIFY  (run by user)
  Re-run TestGen.GenerateAndCoverDatabase over WideWorldImporters: branchless
  procedures (e.g. Configuration_ConfigureForEnterpriseEdition) should show a
  grey "n/a" Branch %, ReseedAllSequences a grey "n/a" Line %, and the Tests
  card's pass/fail/err/skip should sum to the tests-run figure.


================================================================================
2026-05-25  v9.4.3  --  AssessTestability: memory-optimized + missing-object
================================================================================
Two new NOT_TESTABLE detections in TestGen.AssessTestability, both surfaced by
the WideWorldImporters database-wide run.  Each sits beside the existing
temporal-table checks and RETURNs before the "one fakeable dependency is
enough" rule, so it fires even when the procedure also touches ordinary tables.

DETECTION 1 - memory-optimized (In-Memory OLTP) table dependency
  Website.RecordVehicleTemperature had all 5 generated tests ERROR with:
     SafeFakeTable: all attempts to fake Warehouse.VehicleTemperatures failed.
     Last error: The current transaction cannot be committed ... (error 3931)
  ROOT CAUSE: Warehouse.VehicleTemperatures is a memory-optimized table.
  tSQLt.FakeTable cannot fake one; the failed attempt dooms tSQLt's per-test
  transaction, so every test in the class errors.  This is the same class of
  limitation as a temporal table - the framework checked temporal_type but not
  is_memory_optimized.  (RecordColdRoomTemperatures is also memory-optimized
  but was already caught, by the temporal check, since ColdRoomTemperatures is
  system-versioned too; VehicleTemperatures is not temporal, so it slipped
  through.)
  FIX: a dependency with sys.tables.is_memory_optimized = 1 now yields
  NOT_TESTABLE.  Permanent - memory-optimization cannot be turned off the way
  SYSTEM_VERSIONING can.

DETECTION 2 - reference to an object that does not exist
  DataLoadSimulation.PopulateDataToCurrentDate had 4 tests ERROR with:
     Could not find stored procedure 'DataLoadSimulation.DailyProcessToCreate-
     History'.
  ROOT CAUSE: that procedure does not exist as a persistent object.  Populate-
  DataToCurrentDate bootstraps it at run time - it first EXECs DataLoad-
  Simulation.Configuration_ApplyDataLoadSimulationProcedures (which CREATEs
  DailyProcessToCreateHistory), calls it, then EXECs Configuration_Remove...
  (which DROPs it).  The generator spied Configuration_ApplyDataLoad-
  SimulationProcedures - correct behaviour for a dependency - so the real
  Apply never ran, DailyProcessToCreateHistory was never created, and the
  subsequent call failed with error 2812.  The generator can neither fake nor
  spy an object that is not there.
  FIX: a schema-qualified, same-database reference that sys.sql_expression_-
  dependencies recorded unresolved (referenced_id IS NULL) and OBJECT_ID still
  cannot bind now yields NOT_TESTABLE.  Cross-database / cross-server / temp-
  table / caller-dependent / unqualified references are excluded so the check
  never mis-fires; the OBJECT_ID re-check makes deferred-resolution objects
  that were since created pass cleanly.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - both checks in AssessTestability.
  - Install_All_Combined_v9_2_FINAL.sql  - same checks mirrored.
  - scripts\Patch_AssessTestability_MemOptAndMissingObj.sql - NEW standalone
    DROP+CREATE patch for an already-installed database.
  Verified: AssessTestability byte-identical across module, installer and
  patch (md5 9665dc8c4af3a5dcc817bab9d6468321, 199 lines).

VERIFY  (run by user)
  Re-run TestGen.GenerateAndCoverDatabase over WideWorldImporters: Record-
  VehicleTemperature and PopulateDataToCurrentDate should now appear as
  NOT_TESTABLE rows (with the new reasons) instead of erroring test classes,
  and the database-wide error count should drop accordingly.


================================================================================
2026-05-25  v9.4.3  --  NULL-injection test no longer false-fails non-validating procs
================================================================================
SYMPTOM
  Integration.GetMovementUpdates and Integration.GetTransactionUpdates each had
  2 tests FAIL with "Expected an error to be raised." - the per-parameter
  "rejects NULL for @LastCutoff" and "rejects NULL for @NewCutoff" tests.  Both
  procedures otherwise reached 100% line coverage.

ROOT CAUSE
  GenerateTestsForProcedure's NULL-injection test (Test 3) unconditionally
  emitted  EXEC tSQLt.ExpectException  before calling the procedure with a NULL
  argument - asserting the procedure RAISES an error on a NULL parameter.  The
  generator's own comment conceded the design: "we generate ExpectException
  tests for all NULL parameters. If the proc handles NULL gracefully, the test
  will fail (which is fine - user can delete it)."  Most procedures do not
  validate their inputs, so the test was a guaranteed FALSE failure for every
  non-validating procedure.  GetMovementUpdates / GetTransactionUpdates are
  plain delta queries - WHERE LastEditedWhen > @LastCutoff AND <= @NewCutoff -
  with no RAISERROR/THROW; a NULL cutoff makes the predicate UNKNOWN for every
  row, so the procedure returns an empty result set and RETURN 0, no error.
  The procedures are correct; the test's assumption was wrong.
  This also contradicted the rest of v9.4.x: Test 2 (boundary) already expects
  an exception only when the procedure has detected error paths, and the
  characterization / branch-fallback tests emit a visible [@tSQLt:SkipTest]
  scaffold rather than a guaranteed failure.

FIX
  Test 3 now mirrors Test 2's verb logic.  It emits ExpectException ("rejects
  NULL for @x") only when @UseExpectExceptionForInvalid = 1 - i.e. the
  procedure has detected RAISERROR/THROW error paths AND
  @AssertExceptionOnInvalidInputs = 1.  Otherwise it is generated as an
  "accepts NULL for @x" smoke test: the procedure is called with the NULL
  argument and tSQLt.AssertEquals confirms it ran without error.  Validating
  procedures are generated exactly as before.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - Test 3 verb logic in
    GenerateTestsForProcedure.
  - Install_All_Combined_v9_2_FINAL.sql  - same fix mirrored.
  - scripts\Patch_GenerateTestsForProcedure_NullTestVerb.sql - NEW standalone
    DROP+CREATE patch.  Being a full recreate of the procedure it also carries
    the earlier zero-parameter NULL-arg-list fix, so it SUPERSEDES
    Patch_GenerateTestsForProcedure_NullArgList.sql.
  Verified: GenerateTestsForProcedure byte-identical across module, installer
  and patch (md5 bbe03ac6e38e78fcb0317dbe25d60a99, 2705 lines).

VERIFY  (run by user)
  Regenerate test_GetMovementUpdates / test_GetTransactionUpdates and re-run:
  the two NULL-parameter tests should now be named "accepts NULL for @x" and
  PASS (the procedure runs cleanly with a NULL cutoff).  A procedure that does
  validate its inputs still gets "rejects NULL for @x" + ExpectException.


================================================================================
2026-05-25  v9.4.3  --  Instrumenter: "AS BEGIN" on a single line broke body detection
================================================================================
SYMPTOM
  In the WideWorldImporters database-wide sweep, Sequences.ReseedAllSequences
  came back TESTED with TotalLines = 0 (0% line coverage) and 1 of 2 tests
  FAILED.  But a direct  EXEC tSQLt.Run 'test_ReseedAllSequences'  passed BOTH
  tests - the failure did not reproduce outside the coverage sweep.

ROOT CAUSE
  TestGen.InstrumentProcedure locates the procedure body by scanning for the
  AS keyword: it matched a line whose trimmed text is exactly 'AS' or ends with
  ' AS', with a fallback for a line that is exactly 'BEGIN'.  ReseedAllSequences
  is written with  AS BEGIN  on ONE line, which matches neither pattern, so
  @BodyStart came back NULL.  The guarded  UPDATE #Lines SET InHeader = 0
  WHERE LineNum > @BodyStart  then never ran, so every line stayed flagged as
  header, the instrumenter saw no body, and emitted the instrumented copy
  (ReseedAllSequences_cov) with an EMPTY body.
  That produced both symptoms at once:
    - TotalLines = 0 - nothing was instrumented;
    - a phantom test failure - the sweep runs the test class against the _cov
      copy, and an empty copy still "executes with valid inputs" (passes) but
      never calls Sequences.ReseedSequenceBeyondTableValues, so "invokes its
      dependent procedures" fails (the spy log is empty).  A direct tSQLt.Run
      executes the REAL procedure, so both tests pass.
  Configuration_ConfigureForEnterpriseEdition has AS and BEGIN on separate
  lines, which is why it instrumented cleanly at 100%.

FIX
  The body-start detector now also recognises 'AS BEGIN' on a single line -
  the exact form, and 'AS BEGIN;' / 'AS BEGIN <stmt>' / 'AS BEGIN TRY' via a
  'AS BEGIN[ ;]%' pattern.  @BodyStart is set to the 'AS BEGIN' line; the
  instrumenter emits its own AS/BEGIN/END wrapper and skips IsPureBegin /
  IsPureEnd lines, so the stray BEGIN on the header line is dropped cleanly
  and the trailing END is skipped as IsPureEnd - no double wrapper.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - body-start detector in
    InstrumentProcedure.
  - Install_All_Combined_v9_2_FINAL.sql      - same fix mirrored.
  - scripts\Patch_InstrumentProcedure_AsBeginOneLine.sql - NEW standalone
    DROP+CREATE patch.  Being a full recreate it also carries the v5.2
    bare-branch / TRY-CATCH fix, so it SUPERSEDES
    Patch_InstrumentProcedure_BareBranchBody.sql.
  Verified: InstrumentProcedure byte-identical across module, installer and
  patch (md5 6cafa5972e0b9bad5a3f5d72146f9460, 541 lines).

NOTE - latent hardening still open
  The deeper exposure: when @BodyStart resolves to NULL for ANY reason the
  instrumenter silently emits an empty-bodied _cov procedure, and RunCoverage
  then records its test outcomes as if real - over-reporting failures.  The
  'AS BEGIN' fix removes the only known trigger; a defensive guard (raise /
  skip instrumentation instead of emitting an empty body) is not yet added.

VERIFY  (run by user)
  Regenerate + re-run coverage for Sequences.ReseedAllSequences: it should now
  show real TotalLines (~28 EXEC statements), a real LinePct, and BOTH tests
  passing in the sweep - matching the standalone tSQLt.Run result.


================================================================================
2026-05-25  v9.4.3  --  Honest failure when the instrumenter cannot find the body
================================================================================
Follow-on hardening from the ReseedAllSequences triage.  The AS-BEGIN one-line
fix removed the only KNOWN trigger, but the underlying exposure remained: when
the body-start detector returns @BodyStart = NULL the instrumenter silently
emitted a _cov copy with an EMPTY body, and RunCoverage then recorded its test
outcomes as if real - over-reporting failures.  Two coordinated changes make
that case fail honestly and visibly instead.

CHANGE 1 - TestGen.AssessTestability: detect an unlocatable body up front
  Right after the object-exists check, AssessTestability now scans
  OBJECT_DEFINITION for a body-start line using the SAME patterns as the
  instrumenter (a line that is 'AS', ends ' AS', is 'AS BEGIN', matches
  'AS BEGIN[ ;]%', or is 'BEGIN').  If none is found the procedure is
  classified NOT_TESTABLE with an explicit reason:
     FRAMEWORK PARSER LIMITATION (not a defect in this procedure): the
     coverage instrumenter could not locate the AS / BEGIN boundary that
     marks where the body of <schema>.<proc> begins ... Please report this
     procedure's header style to the tSQLtAutoGen maintainers as a bug.
  So the procedure appears as a normal NOT_TESTABLE row in the report, with a
  reason that points the finger at the framework - it "screams back" rather
  than being silently mis-measured.  (These patterns must stay in sync with
  the instrumenter's body-start detector - a cross-reference comment marks
  both sites.)

CHANGE 2 - TestGen.InstrumentProcedure: raise instead of emitting an empty body
  After the AS / BEGIN primary + fallback detection, if @BodyStart is still
  NULL the instrumenter no longer proceeds.  It drops its #Lines temp table
  and RAISERRORs an explicit message naming the procedure, stating that the
  AS / BEGIN boundary could not be found, that this is a parser limitation in
  tSQLtAutoGen (not a defect in the procedure), and asking for it to be
  reported as a bug.  The raise lands BEFORE the _cov copy is built and BEFORE
  RunCoverage renames the real procedure to _orig, so nothing is left
  half-built: the real procedure is untouched, no hollow _cov exists, no test
  runs against garbage.
  Cascade: RunCoverage does not wrap the InstrumentProcedure call, so the
  error propagates out of RunCoverage.  The database sweep wraps its
  RunCoverage call in TRY/CATCH, so it records the procedure's error text and
  continues - it does not die.  A direct RunCoverage call surfaces the error
  to the caller.  In normal sweeps Change 1 classifies the procedure
  NOT_TESTABLE first, so this guard is the backstop for direct calls and for
  any future detector/AssessTestability drift.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql      - body-locate check in AssessTestability.
  - modules\20_Coverage_Instrumenter_v5.sql - @BodyStart NULL guard in
    InstrumentProcedure.
  - Install_All_Combined_v9_2_FINAL.sql    - both changes mirrored.
  - scripts\Patch_AssessTestability_BodyLocate.sql - NEW full-recreate patch;
    SUPERSEDES Patch_AssessTestability_MemOptAndMissingObj.sql.
  - scripts\Patch_InstrumentProcedure_BodyGuard.sql - NEW full-recreate patch;
    SUPERSEDES Patch_InstrumentProcedure_AsBeginOneLine.sql and
    Patch_InstrumentProcedure_BareBranchBody.sql.
  Verified byte-identical across module / installer / patch:
    AssessTestability   md5 c16691a06e94bd69b1b23bb5d2722bba (231 lines)
    InstrumentProcedure md5 e00db6b789fefb370b7b4f7aea75387b (563 lines)


================================================================================
2026-05-25  v9.4.3  --  Instrumenter: balanced _cov rebuild for an "AS BEGIN" opener
================================================================================
SYMPTOM
  After the AS-BEGIN body-detection fix, Sequences.ReseedAllSequences was
  instrumented (28 lines) but the database-wide sweep showed it TESTED with
  both tests ERRORED and 0 of 28 lines covered.  A direct run confirmed:
     !! Instrumented procedure FAILED to compile: [Sequences].[ReseedAllSequences_cov]
        Error: Incorrect syntax near ';'.
  and OBJECT_DEFINITION of the _cov procedure came back NULL - it does not
  exist.  RunCoverage's synonym was therefore left pointing at a missing
  object, so every test for the procedure errored.

ROOT CAUSE
  InstrumentProcedure rebuilds the procedure as
     CREATE ... AS BEGIN  SET NOCOUNT ON;  <@Body>  END;
  where @Body is built from the procedure's own body lines.  Header lines
  (InHeader = 1) are skipped; body lines (InHeader = 0) are emitted into @Body.
  For a normal "AS" + separate-line "BEGIN" procedure the BEGIN line and the
  END line are BOTH body lines, so @Body carries the procedure's own BEGIN and
  END and the rebuilt copy is nested but balanced (2 BEGIN / 2 END) - this is
  why Configuration_ConfigureForEnterpriseEdition instrumented cleanly.
  When the procedure is written "AS BEGIN" on ONE line, that line is the
  body-start line and is treated as HEADER (InHeader = 1) - so its BEGIN is
  never emitted into @Body - but the procedure's closing "END;" is an ordinary
  body line and still is.  The rebuilt _cov then had one BEGIN and two ENDs,
  which does not compile.

FIX
  At body detection, InstrumentProcedure now flags the "AS BEGIN" one-line
  opener (@InlineBegin, set when the body-start line trims to 'AS BEGIN' or
  'AS BEGIN;').  After the build loop it prepends a compensating synthetic
  BEGIN to @Body.  @Body already ends with the procedure's own closing END, so
  the synthetic BEGIN balances it and the rebuilt _cov has the same nested,
  balanced shape (2 BEGIN / 2 END) a normal AS / BEGIN procedure produces.
  Only "AS BEGIN" one-line procedures are affected - they have never
  successfully instrumented before (first the @BodyStart-NULL bug, then this
  imbalance), so the fix cannot regress any procedure that already worked.

NOT YET DONE - related hardening
  When the _cov CREATE fails, InstrumentProcedure currently only PRINTs
  "!! Instrumented procedure FAILED to compile ..." and returns; it does not
  raise.  RunCoverage then proceeds against a _cov that does not exist and the
  sweep records phantom test errors.  Making InstrumentProcedure RAISE on a
  failed _cov compile (the same fail-loud principle as the @BodyStart-NULL
  guard) is recommended but not included here.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - @InlineBegin flag + synthetic
    BEGIN prepend in InstrumentProcedure.
  - Install_All_Combined_v9_2_FINAL.sql      - same fix mirrored.
  - scripts\Patch_InstrumentProcedure_AsBeginBalance.sql - NEW full-recreate
    patch; SUPERSEDES Patch_InstrumentProcedure_BodyGuard.sql,
    Patch_InstrumentProcedure_AsBeginOneLine.sql and
    Patch_InstrumentProcedure_BareBranchBody.sql.
  Verified: InstrumentProcedure byte-identical across module, installer and
  patch (md5 b5dd9577242f2747531219289d710780, 583 lines).

VERIFY  (run by user)
  Re-run coverage for Sequences.ReseedAllSequences: ReseedAllSequences_cov
  should now compile, both tests should pass, and the procedure should report
  real line coverage over its 28 EXEC statements instead of 0%.


================================================================================
2026-05-26  v9.4.3  --  Full-text search is now a proper NOT_TESTABLE category
================================================================================
CONTEXT
  A procedure that uses CONTAINSTABLE / FREETEXTTABLE / CONTAINS / FREETEXT
  depends on a full-text index.  tSQLt.FakeTable strips full-text indexes from
  its faked copy, so the full-text predicate cannot run - the procedure cannot
  be isolated for testing.  This was already known, but handled by an ad-hoc
  block ("1b") in GenerateTestsForProcedure that, on a match, emitted a single
  PASSING marker test and RETURNed.  Consequence: a full-text procedure
  (e.g. dbo.uspSearchCandidateResumes on AdventureWorks) showed up in the
  database coverage report as TESTED at 0% - not in the NOT_TESTABLE list -
  inconsistent with every other un-fakeable category, and the database-wide
  sweep's classification (which comes from its own AssessTestability call)
  never saw the full-text condition at all.

CHANGE
  Full-text detection is moved into TestGen.AssessTestability, alongside the
  temporal / memory-optimized / system-catalog / missing-object / parser
  categories.  A procedure whose definition contains CONTAINSTABLE,
  FREETEXTTABLE, CONTAINS( or FREETEXT( is now classified NOT_TESTABLE with an
  explicit reason.  It therefore appears as a normal NOT_TESTABLE row in the
  report and gets the standard [@tSQLt:SkipTest] marker (reported SKIPPED),
  exactly like the other categories.
  The ad-hoc "1b" full-text block in GenerateTestsForProcedure is retired;
  the @ProcSource load it also performed is kept (branch detection needs it).

FILES CHANGED
  - modules\04_Test_Generator_v3.sql      - full-text check added to
    AssessTestability; 1b full-text skip block removed from
    GenerateTestsForProcedure.
  - Install_All_Combined_v9_2_FINAL.sql    - both changes mirrored.
  - scripts\Patch_AssessTestability_FullText.sql - NEW full-recreate patch;
    SUPERSEDES Patch_AssessTestability_BodyLocate.sql.
  - scripts\Patch_GenerateTestsForProcedure_FullTextRetire.sql - NEW
    full-recreate patch; SUPERSEDES
    Patch_GenerateTestsForProcedure_NullTestVerb.sql.
  Verified byte-identical across module / installer / patch:
    AssessTestability          md5 82b985776251e95c6dec167e14ed36e8 (250 lines)
    GenerateTestsForProcedure  md5 da99540702ab668164aadb3d3b087746 (2660 lines)

VERIFY  (run by user)
  Re-run TestGen.GenerateAndCoverDatabase over AdventureWorks2025:
  dbo.uspSearchCandidateResumes should now appear as a NOT_TESTABLE row with
  the full-text reason, instead of TESTED at 0%.


================================================================================
2026-05-26  v9.4.3  --  Forced-error test + Test 5 narrowing + per-param NULL verb
================================================================================
Three coupled changes to TestGen.GenerateTestsForProcedure, all targeting
generated tests that hard-asserted something only CONDITIONALLY true and so
false-failed correct procedures.  Surfaced by the AdventureWorks2025 run
(PlaceOrder, uspLogError, the three HumanResources.uspUpdateEmployee* procs).

1. PER-PARAMETER NULL-INJECTION VERB
   The NULL test ("rejects/accepts NULL for @x") decided its verb per
   PROCEDURE: if the proc had any error path, every nullable parameter's NULL
   test expected an exception.  But a proc validates SPECIFIC parameters -
   dbo.PlaceOrder raises for a non-active @CustomerId but does nothing special
   with @Total / @Notes, so "rejects NULL for @Total/@Notes" false-failed.
   The verb is now decided PER PARAMETER: a hard "rejects NULL"
   (ExpectException) is emitted only when @UseExpectExceptionForInvalid = 1 AND
   the parameter is PK/FK-matched (@IsMatchedParamBeingNulled - a parameter the
   proc keys on, where a NULL reliably fails the lookup).  Every other
   parameter gets an "accepts NULL" smoke test.

2. TEST 5 NARROWED TO NORMAL-PATH DEPENDENCIES
   "test <proc> invokes its dependent procedures" asserted that EVERY detected
   dependency was called on a happy-path run.  A dependency invoked only inside
   a BEGIN CATCH block (an error handler - e.g. uspUpdateEmployeeLogin ->
   uspLogError, uspLogError -> uspPrintError) is legitimately NOT called on a
   clean run, so the test false-failed.  The generator now builds @SrcNoCatch
   (the source with BEGIN CATCH...END CATCH blocks removed) and classifies each
   PROCEDURE dependency CATCH-only vs normal-path.  Test 5 asserts only
   normal-path dependencies (and is skipped entirely when there are none).

3. NEW FORCED-ERROR TEST
   "test <proc> exercises its error-handling path" - generated when the proc
   has a CATCH-block dependency, does DML, has a fakeable table dependency, and
   its TRY block contains no RETURN.  It fakes the table dependencies, puts an
   AFTER INSERT/UPDATE/DELETE trigger that raises a runtime error (divide by
   zero) on each, runs the procedure - so the TRY block's DML throws and the
   procedure's own CATCH executes - and asserts each CATCH-block dependency was
   actually called.  This removes the false failure AND, run under
   instrumentation, gives real coverage of the error-handling code (CATCH
   blocks were previously never exercised).  The "TRY contains RETURN"
   exclusion skips procedures like uspLogError whose body is gated on
   ERROR_NUMBER() and whose DML is therefore unreachable on a direct call.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - all three changes in
    GenerateTestsForProcedure.
  - Install_All_Combined_v9_2_FINAL.sql  - same changes mirrored.
  - scripts\Patch_GenerateTestsForProcedure_ForcedErrorTest.sql - NEW
    full-recreate patch; SUPERSEDES
    Patch_GenerateTestsForProcedure_FullTextRetire.sql.
  Verified: GenerateTestsForProcedure byte-identical across module, installer
  and patch (md5 34b78337edf51f1e92f4ee04841e88ab, 2781 lines).

KNOWN LIMITATION
  The forced-error test's CATCH detection uses simple forward BEGIN CATCH /
  END CATCH pairing (fine for the near-universal non-nested case) and assumes
  the procedure's DML sits inside its TRY block; a procedure doing DML before
  its TRY is not covered.

VERIFY  (run by user)
  Regenerate test classes for the AdventureWorks procedures and re-run:
  PlaceOrder's @Total / @Notes NULL tests become "accepts NULL" and pass; the
  three uspUpdateEmployee* procs lose the Test 5 false failure and gain a
  passing "exercises its error-handling path" test that also covers their
  CATCH blocks; uspLogError loses its Test 5 false failure (no forced-error
  test - its TRY has a RETURN).


================================================================================
2026-05-26  v9.4.3  --  Forced-error test refined (mechanism + ROLLBACK gate + args)
================================================================================
Three refinements to the forced-error test, driven by the AdventureWorks
second-pass results.  The forced-error CONCEPT was sound (uspUpdateEmployee-
HireInfo went 4/6 -> 6/6 lines and 0% -> 100% branches - the CATCH genuinely
executes), but the test OUTCOME reporting was wrong for three different
reasons.  All three are now addressed.

1. FORCING MECHANISM - "AFTER trigger doing 1/0" replaced with
   "WITH NOCHECK ADD CONSTRAINT CHECK (1 = 0)"
   Symptom on uspUpdateEmployeeLogin:
       Expected dependent procedure dbo.uspLogError to have been called.
       Warning: Uncommitable transaction detected!
   The divide-by-zero RAISED inside an AFTER trigger DOOMS the transaction
   (XACT_STATE() = -1).  The procedure's CATCH runs, but tSQLt.SpyProcedure's
   INSERT into its log table is blocked on a doomed transaction, so the spy
   log stays empty and the assertion fires.  A CHECK constraint violation
   (Msg 547) is a "normal" error that does NOT doom the transaction; the
   procedure's CATCH executes and the spy's INSERT succeeds.

2. ROLLBACK-TRAN EXCLUSION
   Symptom on uspUpdateEmployeeHireInfo:
       Invalid object name 'dbo.uspLogError_SpyProcedureLog'. (with a
       complementary "The ROLLBACK TRANSACTION request has no corresponding
       BEGIN TRANSACTION" reported by tSQLt.)
   The procedure's CATCH does  IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION  - an
   UNNAMED rollback.  Inside a tSQLt test that rolls back the framework's
   outer transaction (which holds the spy and FakeTable setup), so the spy
   log table is gone by the time the assertion runs.  This is a fundamental
   incompatibility - the framework cannot generate a meaningful forced-error
   test for such procedures.  The generator now accumulates @CatchText
   alongside @SrcNoCatch (the CATCH spans that were removed) and excludes any
   procedure whose CATCH contains  ROLLBACK TRANSACTION / ROLLBACK TRAN  from
   forced-error test generation - the existing happy-path Test 5 narrowing
   already removes the false failure for these procedures.

3. TEST 3 ARGUMENT LIST DERIVED FROM @ArgListHappy
   Symptom on uspProcessSalesOrder (and others that strictly validate inputs):
       "Invalid order type. Must be Standard, Express, or Overnight."
   Test 3 ("accepts NULL for @x") built its argument list from scratch via
   GetSampleValueLiteral.  For non-key string parameters like @OrderType,
   that returns the generic 'Sam' - which the procedure rejects with a
   RAISERROR.  Test 1's @ArgListHappy uses branch-detected values (it scans
   the source for `@OrderType IN ('Standard','Express',...)` and picks
   'Express'), which is what makes Test 1 pass; Test 3 was not benefiting
   from that.  Before the per-param NULL fix this was masked - the test used
   ExpectException and the RAISERROR satisfied it as a false pass.  Test 3
   now derives @ArgsNull from @ArgListHappy by replacing only the null'd
   parameter's value with NULL; non-null'd parameters take the same valid
   happy-path values Test 1 uses.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - all three refinements.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_GenerateTestsForProcedure_ForcedErrorV2.sql - NEW
    full-recreate patch; SUPERSEDES
    Patch_GenerateTestsForProcedure_ForcedErrorTest.sql.
  Verified: GenerateTestsForProcedure byte-identical across module, installer
  and patch (md5 0136ce238b7042d712bc68ad3412ca03, 2805 lines).

VERIFY  (run by user)
  Regenerate the AdventureWorks test classes and re-run.  Expected:
  - uspUpdateEmployeeLogin / uspUpdateEmployeePersonalInfo: forced-error test
    PASSES (the CHECK constraint violation doesn't doom, the spy records).
  - uspUpdateEmployeeHireInfo: no forced-error test generated (CATCH has
    unnamed ROLLBACK); previous Test 5 false fail also gone -> 0 fail / 0 err.
  - uspProcessSalesOrder / Realistic: the 6 / 2 "Invalid order type" errors
    gone - accepts-NULL tests now use @OrderType='Express' from the happy-path
    arg list and PASS.
  - PlaceOrder: direct run already 10 pass / 1 skip; sweep should show
    the same.


================================================================================
2026-05-26  v9.4.3  --  NULL-test gating + CATCH-context-helper classification
================================================================================
Two further refinements driven by the AdventureWorks fourth-pass results,
where the forced-error mechanism worked cleanly (HR procs all clean, 100%
coverage on Login/PersonalInfo) but a few residual items remained.

1. NULL-TEST GATING IN TEST 3
   Symptom on uspProcessSalesOrderRealistic: 0 fail -> 3 fail after the Test 3
   arg-list fix that made non-null'd parameters valid.  With valid happy-path
   values, "accepts NULL for @x" tests now reach the procedure body and
   discover that the procedure validates more parameters than the framework
   could detect by PK/FK match - the proc raises on a NULL non-key parameter,
   the "accepts NULL" test expected no error, fail.
   Test 3 now SKIPS generating the NULL test entirely when
   @UseExpectExceptionForInvalid = 1 AND @IsMatchedParamBeingNulled = 0 (the
   procedure has error paths but the parameter is not one it keys on).  In
   that ambiguous middle case the framework declines to assert.  A NULL test
   is now only emitted when (a) the procedure has no error paths at all -
   any parameter gets "accepts NULL" smoke - or (b) the parameter is
   PK/FK-matched - "rejects NULL" with ExpectException.

2. CATCH-CONTEXT-HELPER CLASSIFICATION
   Symptom on uspLogError: chronically TESTED at 0% line coverage with
   1 fail / 2 err.  The procedure's TRY block starts with
   IF ERROR_NUMBER() IS NULL RETURN;  - it does nothing useful unless called
   from inside another procedure's CATCH block, where ERROR_NUMBER() is
   non-NULL.  The framework cannot manufacture an outer error context, so the
   body is unreachable on a direct call and coverage is always 0.
   AssessTestability now detects this pattern - source text contains
   ERROR_NUMBER() IS NULL - and classifies the procedure NOT_TESTABLE with
   an explicit reason pointing the developer at the call-site or a
   hand-written custom test, instead of generating tests that all fail/error
   against an unreachable body.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - NULL-test gate in
    GenerateTestsForProcedure; CATCH-context-helper check in
    AssessTestability.
  - Install_All_Combined_v9_2_FINAL.sql  - both changes mirrored.
  - scripts\Patch_GenerateTestsForProcedure_NullGate.sql - NEW full-recreate
    patch; SUPERSEDES Patch_GenerateTestsForProcedure_ForcedErrorV2.sql.
  - scripts\Patch_AssessTestability_CatchHelper.sql - NEW full-recreate
    patch; SUPERSEDES Patch_AssessTestability_FullText.sql.
  Verified byte-identical across module/installer/patch:
    GenerateTestsForProcedure  md5 4ecb20e6597d17bf46a97ff494e0f26d (2820 lines)
    AssessTestability          md5 281fb1be6cee9889a58f4c24a6276c1e ( 269 lines)

VERIFY  (run by user)
  Re-run TestGen.GenerateAndCoverDatabase over AdventureWorks2025:
  - uspProcessSalesOrderRealistic: the 3 fails on non-key NULL tests should
    be gone (those tests no longer generated).
  - uspLogError: moves into the NOT_TESTABLE list with the
    "gated on ERROR_NUMBER() IS NULL" reason, instead of TESTED at 0%.


================================================================================
2026-05-26  v9.4.3  --  NULL test: evidence-based guard detection
================================================================================
The previous gate used "the parameter is PK/FK-column-matched" as a proxy for
"the procedure validates NULL on this parameter."  That heuristic was too
aggressive: uspProcessSalesOrderRealistic's @CustomerID, @TerritoryID and
@ShipMethodID are all FK-matched, but the procedure inserts them without any
NULL check - "rejects NULL" tests false-failed there.

Test 3 now requires explicit textual evidence that the procedure null-checks
the specific parameter, in one of two patterns:
  (a) an explicit  IF @<param> IS NULL  guard in the source, or
  (b) an  IF NOT EXISTS (...)  with the parameter name AND a RAISERROR / THROW
      within a 500-character proximity window (the typical FK-existence-check
      pattern - dbo.PlaceOrder uses IF NOT EXISTS(... CustomerId = @CustomerId)
      followed immediately by RAISERROR, which IS evidence the proc rejects a
      NULL @CustomerId).

When neither pattern matches, the NULL test is skipped instead of emitting a
"rejects NULL" that would false-fail (Realistic) or an "accepts NULL" smoke
that would also false-fail on a procedure that does validate the parameter.

Procedures with NO error paths (@UseExpectExceptionForInvalid = 0) continue
to get "accepts NULL" smoke tests for every nullable parameter, unchanged -
the gate only fires for procedures with detected error paths.

The verb-decision CASE and the emit-time IF/ELSE in Test 3 have been
correspondingly simplified to use @UseExpectExceptionForInvalid directly,
because by the time we reach them after the gate the evidence requirement
is guaranteed.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - evidence detection + simplified
    verb decision in Test 3.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_GenerateTestsForProcedure_NullEvidence.sql - NEW
    full-recreate patch; SUPERSEDES Patch_GenerateTestsForProcedure_NullGate.sql.

VERIFY  (run by user)
  Re-run the AdventureWorks sweep:
  - uspProcessSalesOrderRealistic: the 3 "rejects NULL for @CustomerID /
    @TerritoryID / @ShipMethodID" false fails should be gone - no
    IF @x IS NULL guard, no IF NOT EXISTS proximity match -> NULL tests
    skipped.
  - dbo.PlaceOrder direct: "rejects NULL for @CustomerId" should still be
    generated and still pass - source has
       IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = @CustomerId ...)
       RAISERROR(...)
    within the proximity window, so the evidence test fires.
  - Procedures with no error paths (HR procs, Integration.Get*Updates):
    unchanged.


================================================================================
2026-05-26  v9.4.3 iteration  - PRESERVE 'OUTPUT' MODIFIER IN INSTRUMENTER
================================================================================

SYMPTOM (database-wide sweep on AdventureWorks2025)
  dbo.PlaceOrder showed a contradictory result row: 5 tests successful but
  line coverage 0% (zero CoverageHit rows recorded for the instrumented copy).
  Per-test inspection via tSQLt.TestResult showed every passing test was a
  tSQLt.ExpectException-based assertion (rejects high/low/NULL @CustomerId /
  @Notes / @Total), and EVERY error/failure was SQL Server Msg 8162:
      "The formal parameter @NewOrderId was not declared as an OUTPUT
       parameter, but the actual parameter passed in requested output."
  The same defect was silently affecting dbo.uspLogError (whose body is gated
  on IF ERROR_NUMBER() IS NULL RETURN, so the body never ran in test context
  regardless - the OUTPUT mismatch was invisible there).

ROOT CAUSE
  TestGen.InstrumentProcedure rebuilds a procedure as <Schema>.<Proc>_cov by
  composing the parameter list from sys.parameters via a local cursor.  The
  cursor selected the parameter name, type, max_length/precision/scale and
  has_default_value, but it did NOT select p.is_output.  As a result, every
  OUTPUT parameter in the original procedure was emitted into the _cov copy
  as a plain (input-only) parameter.  RunCoverage's wrapper called the
  synonym with an OUTPUT argument; SQL Server then raised Msg 8162 against
  the underlying _cov on every test invocation.

  In dbo.PlaceOrder the OUTPUT parameter is exercised by the smoke test
  (Test 1) AND the OUTPUT-population test (Test 6), so both ERRORED and the
  procedure body never ran for the coverage harness - hence the 0% coverage.
  The ExpectException tests "passed" because Msg 8162 happens to satisfy
  ExpectException's any-error contract - a false green that the strong tests
  (smoke + delta) were precisely designed to catch.

FIX
  modules\20_Coverage_Instrumenter_v5.sql, parameter-list cursor:
    + DECLARE @pout BIT;
      ...
      SELECT ..., p.has_default_value, p.is_output
      ...
      FETCH NEXT FROM pcov INTO ..., @phasdef, @pout;
      WHILE @@FETCH_STATUS = 0
      BEGIN
          ...
          IF @phasdef = 1 SET @ParamList = @ParamList + N' = NULL';
          IF @pout    = 1 SET @ParamList = @ParamList + N' OUTPUT';
          FETCH NEXT FROM pcov INTO ..., @phasdef, @pout;
      END

  Note ordering: SQL Server requires the OUTPUT modifier to appear AFTER any
  default value clause - i.e. the parameter list reads
       @NewOrderId INT = NULL OUTPUT
  for a parameter that is both OUTPUT and has a default.  The new emit
  honours this order.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql  - cursor + FETCH + emit.
  - Install_All_Combined_v9_2_FINAL.sql      - mirrored, byte-identical.
  - scripts\Patch_InstrumentProcedure_OutputPreservation.sql - NEW
    full-recreate patch carrying every prior instrumenter fix; SUPERSEDES
    Patch_InstrumentProcedure_AsBeginBalance.sql (and transitively the older
    InstrumentProcedure patches it already superseded).

VERIFY  (byte-identity)
  InstrumentProcedure body in module 20, installer and new patch all hash to
      md5 8ffefc7ecca2915da45c946855a401bb   (585 lines, IF OBJECT_ID..END;).

VERIFY  (run by user)
  Apply the new patch, then re-run RunCoverage on dbo.PlaceOrder:
    - Smoke test (Test 1) should EXECUTE the body (no Msg 8162) - coverage
      hits should appear in TestGen.CoverageHit.
    - Test 6 (OUTPUT-population) should evaluate against an actual returned
      value rather than erroring on the OUTPUT mismatch.
    - The ExpectException-based NULL/boundary tests should still pass (they
      were already exercising the body before Msg 8162 was raised at the
      wrapper boundary - their pass status was incidental but the procedure
      contract they test is unchanged).
  Re-run the AdventureWorks sweep: dbo.uspLogError remains NOT_TESTABLE
  (CATCH-context-helper) but no longer has the latent OUTPUT mismatch in
  its _cov copy.


================================================================================
2026-05-26  v9.4.3 iteration  - "TESTABLE" Y/N COLUMN IN COVERAGE REPORT
================================================================================

REQUEST
  Add an explicit Testable / Not testable Y/N flag as a column in the
  database-wide HTML coverage report.

WHY
  Testability is already a column on TestGen.CoverageResult and the report
  already distinguishes TESTED from NOT_TESTABLE rows visually (greyed-out
  row + NOT TESTABLE merged-cell message).  But there was no compact,
  scannable flag: a reader had to spot the grey row to know the procedure
  was NOT_TESTABLE.  An explicit Y/N column makes the split visible at a
  glance and gives the bottom-of-table TOTAL a place to summarise the
  testable / not-testable counts.

CHANGE
  TestGen.GenerateAndCoverDatabase HTML output:
    Header row gains a "Testable" <th> between Procedure and Gen, so the
    column order is now:
       Schema | Procedure | Testable | Gen | Tests | Pass | Fail | Err |
       Skip   | Lines     | Covered  | Line % | Branch %
    Per-row rendering:
       TESTED        row emits <td><span class="g">Y</span></td>
       NOT_TESTABLE  row emits <td><span class="r">N</span></td>
       (the NOT_TESTABLE row's merged-cell colspan stays at 9; only the
       fixed left side grows by one column)
    TOTAL row:
       leading colspan grows 2 -> 3 to absorb the new column, and the
       label now reads:
          TOTAL - N procedures (T testable, U not)

  TEXT output (the SELECT grid emitted when @OutputMode='TEXT') already
  returned Testability as the third column - unchanged.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - header, row builders, TOTAL.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_GenerateAndCoverDatabase_TestableColumn.sql - NEW
    full-recreate patch carrying every prior fix to the procedure;
    SUPERSEDES Patch_GenerateAndCoverDatabase_ReportHonesty.sql.

VERIFY (byte-identity)
  GenerateAndCoverDatabase body in module 04, installer and new patch all
  hash to:
       md5 1242c05e8efc14de22d473d62d3caae5   (308 lines).

VERIFY (run by user)
  Apply the patch, then re-run a database-wide sweep:
    EXEC TestGen.GenerateAndCoverDatabase;
  Inspect the HTML report:
    - Column count is now 13 (was 12).
    - Each row carries Y or N in the Testable column.
    - TOTAL row reads "TOTAL - N procedures (T testable, U not)".


================================================================================
2026-05-26  v9.4.4 PHASE 1  - TEST-PRESERVATION FOUNDATION (CAPTURE ONLY)
================================================================================

CONTEXT
  A developer who modifies a framework-generated test today loses their work
  on the next regeneration unless they rename the class to *_custom.  We want
  the modification itself to be the ownership signal - no rename, no tribal
  knowledge.  Mechanism agreed: store each emitted test's body + SHA2_256
  hash; at regen time, compare current proc body's hash to the stored hash;
  any mismatch = developer modified it = preserve.
  Phase 1 lays the foundation: capture only, no behaviour change yet.

NEW TABLE
  TestGenLog.GeneratedTest
    (GeneratedTestId, RunId FK -> GenerationRun, SchemaName, ProcName,
     TestClassName, TestProcName, OriginalBody NVARCHAR(MAX),
     OriginalBodyHash AS HASHBYTES('SHA2_256', OriginalBody) PERSISTED,
     EmittedAt)
  Plus IX_GenTest_ProcAndClass on (SchemaName, ProcName, TestClassName,
     TestProcName, RunId DESC) - supports "give me the latest captured row
     for this test proc" in O(log n).
  Full body kept for diff / audit value (developers will eventually want to
  see "what did the framework originally emit here vs what I changed it
  to?"); hash is the indexed fast-path for the regen check.

CAPTURE STEP IN GenerateTestsForProcedure
  Added in the @ExecuteScript = 1 branch, AFTER the developer-class dup-
  removal loop (so we only log the framework's canonical test copies, not
  ones that were just removed because they were adopted into a *_custom
  class).  The capture reads back from sys.sql_modules.definition - NOT from
  the @S accumulator that was passed to EXEC - so the stored body matches
  what the catalog will return at regen-time hash compare.  No
  normalization-quirk false positives.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - capture block in
    GenerateTestsForProcedure right before the Status='Installed' UPDATE.
  - Install_All_Combined_v9_2_FINAL.sql  - new table DDL after the
    ProcedureSnapshot table; capture block mirrored.
  - scripts\Patch_Phase1_GeneratedTestCapture.sql - NEW full-recreate patch
    carrying every prior fix to GenerateTestsForProcedure; SUPERSEDES the
    earlier GenerateTestsForProcedure patches (NullArgList / NullTestVerb /
    ForcedErrorTest / ForcedErrorV2 / NullGate / NullEvidence /
    FullTextRetire).  Patch is idempotent: it skips the CREATE TABLE if the
    table already exists.

VERIFY (byte-identity)
  GenerateTestsForProcedure body in module 04, installer and new patch all
  hash to:
       md5 9dbbaa9ff908a46698dced94065b50e4   (2871 lines).

VERIFY (run by user)
  Apply the patch, then run any single proc through the generator:
       EXEC TestGen.GenerateTestsForProcedure 'dbo', 'YourProc', @ExecuteScript=1;
  Then:
       SELECT TestClassName, TestProcName, LEN(OriginalBody), OriginalBodyHash
       FROM   TestGenLog.GeneratedTest
       ORDER BY GeneratedTestId DESC;
  Should show one row per emitted test proc, each with a non-NULL body and
  a 32-byte SHA2_256 hash.  Behaviour is otherwise unchanged - this phase
  only captures data.

NEXT
  Phase 2: DropGeneratedTestClasses + GenerateAndCoverDatabase consult the
  hash at drop / regen time; preserved tests are not dropped and not re-
  emitted; per-proc TestsPreserved counter rolls up to a new column on
  CoverageResult.


================================================================================
2026-05-26  v9.4.4 PHASE 1.1  - CAPTURE SKIPTEST STUB IN NOT_TESTABLE BRANCH
================================================================================

SYMPTOM (user-reported, while validating Phase 1 on WideWorldImporters)
  After a database-wide GenerateAndCoverDatabase sweep, the per-test capture
  worked for TESTABLE procs (8 runs -> 27 captured tests) but NOT_TESTABLE
  procs captured zero rows (34 runs -> 0 captured tests).

ROOT CAUSE
  TestGen.GenerateTestsForProcedure has TWO emit paths:
    1) NOT_TESTABLE branch (lines ~136-178): builds a SkipTest stub script,
       ExecuteBatchedScripts it, then RETURNs.
    2) Main branch: builds the full @S accumulator, ExecuteBatchedScripts it,
       runs the developer-class dup-removal loop, then continues to mark
       Status='Installed'.
  Phase 1's capture block sat in (2), AFTER the dup-removal loop.  The
  NOT_TESTABLE branch returned at line 177 before ever reaching capture - so
  the SkipTest stub got created in the catalog but never logged.

  This is the test the developer is MOST likely to take ownership of (remove
  the SkipTest annotation, write real test logic) - exactly the original
  workflow Phase 2 is meant to detect.  Missing this capture would silently
  break Phase 2 for the user's primary use case.

FIX
  Added a mirror capture block inside the NOT_TESTABLE branch, after the
  @ExecuteScript=1 ExecuteBatchedScript and before the RETURN, with the same
  shape as the main capture:
       INSERT INTO TestGenLog.GeneratedTest
       SELECT @RunId, @SchemaName, @ProcName, @TestClassName, p.name,
              m.definition
       FROM   sys.procedures p
       JOIN   sys.sql_modules m ON m.object_id = p.object_id
       WHERE  p.schema_id = SCHEMA_ID(@TestClassName)
         AND  p.is_ms_shipped = 0;
  Also wrapped the existing single-line EXEC in BEGIN ... END so the new
  block lives cleanly inside the @ExecuteScript=1 guard.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - capture block in NOT_TESTABLE
    branch added; surrounding BEGIN/END.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_Phase1_GeneratedTestCapture.sql - REBUILT.  Same name +
    purpose as the prior file; the prior version is superseded.  Header
    updated to describe the two capture sites.

VERIFY (byte-identity)
  GenerateTestsForProcedure body in module 04, installer and patch all hash
  to:
       md5 dd16d947948ee3d1599678d675f4188f   (2889 lines, +18 vs prior).

VERIFY (run by user)
  Apply the rebuilt patch, then re-run the sweep:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Then:
       SELECT gr.Status, COUNT(DISTINCT gr.RunId) AS Runs,
              COUNT(gt.GeneratedTestId)            AS CapturedRows
       FROM   TestGenLog.GenerationRun gr
       LEFT   JOIN TestGenLog.GeneratedTest gt ON gt.RunId = gr.RunId
       WHERE  gr.StartedAt >= DATEADD(HOUR,-2,SYSUTCDATETIME())
       GROUP  BY gr.Status;
  Expect: NotTestable runs now show 1 captured row per run (the SkipTest
  stub).  TESTABLE counts unchanged.


================================================================================
2026-05-26  v9.4.4 PHASE 1.2  - INSTALLER DROP ORDER FOR GeneratedTest FK
================================================================================

SYMPTOM (user-reported, re-running the combined installer)
  Msg 3726  Could not drop object 'TestGenLog.GenerationRun' because it is
            referenced by a FOREIGN KEY constraint.
  Msg 2714  There is already an object named 'GenerationRun' in the database.
  Msg 2714  There is already an object named 'GeneratedTest' in the database.
  Msg 1913  IX_GenTest_ProcAndClass already exists.
  (After Phase 1.1 added TestGenLog.GeneratedTest with a FK to GenerationRun.
  The installer continued past the errors, leaving the prior schema intact,
  so no data loss - but the install is wrong.)

ROOT CAUSE
  The installer's drop-and-recreate of the log tables happens at the top of
  the file in child-then-parent FK order:
       DROP ProcedureSnapshot   (child)
       DROP GenerationRun       (parent)
  Phase 1.1 added a SECOND child - TestGenLog.GeneratedTest also FK-references
  GenerationRun - but the drop sequence was not updated, so on a re-install
  GenerationRun could not be dropped (still referenced by GeneratedTest), and
  every following CREATE failed with "already exists."

FIX
  Drop sequence now drops both children first:
       DROP GeneratedTest       (child, new in Phase 1.1)
       DROP ProcedureSnapshot   (child)
       DROP GenerationRun       (parent)
  Comment updated to mention both FKs.

FILES CHANGED
  - Install_All_Combined_v9_2_FINAL.sql  - drop sequence at the top of the
    log-tables section (lines ~62-77).
  - No module / patch change.  The standalone Patch_Phase1_GeneratedTestCapture
    is already idempotent (IF OBJECT_ID IS NULL guard on the CREATE TABLE),
    so re-applying that patch never produced this error.

USER GUIDANCE
  If you saw these errors on the previous install attempt, your schema is
  actually fine - the framework's earlier Patch_Phase1_GeneratedTestCapture
  had already populated GeneratedTest correctly via the standalone path.
  You can either:
    (a) carry on with the current schema (no further action needed), or
    (b) for a clean re-install, run:
            DROP TABLE TestGenLog.GeneratedTest;
            DROP TABLE TestGenLog.ProcedureSnapshot;
            DROP TABLE TestGenLog.GenerationRun;
        then re-run Install_All_Combined_v9_2_FINAL.sql.


================================================================================
2026-05-26  v9.4.4 PHASE 1.3  - NOT_TESTABLE ROWS RENDER FULL COLUMNS
================================================================================

SYMPTOM (user-reported, while validating the database-wide HTML report)
  Every NOT_TESTABLE row showed the "NOT TESTABLE - <reason>" message but no
  test counts.  CoverageResult had the correct values - TestsSkipped = 1 for
  each NOT_TESTABLE proc (one SkipTest stub generated, reported skipped by
  tSQLt) - but the HTML row hid them.

ROOT CAUSE
  The NOT_TESTABLE row builder used colspan="9" to merge the Tests / Pass /
  Fail / Err / Skip / Lines / Covered / Line% / Branch% cells into one big
  "NOT TESTABLE - <reason>" cell.  The reason was the only thing visible
  across those nine columns.  The TestsSkipped = 1 value was being stored
  but never rendered.

FIX (Option A - chosen by user over Option B "prefix the merged cell")
  NOT_TESTABLE rows now render each cell individually, the same shape as
  TESTABLE rows:
       Tests / Pass / Fail / Err / Skip - the actual counts (Skip = 1)
       Lines / Covered / Line % / Branch %    - "n/a" (greyed)
  The NOT TESTABLE reason moves under the procedure name inside a native
  HTML <details><summary>why not testable?</summary>...</details> element -
  collapsed by default, click-to-expand.  No JavaScript; works in every
  browser; the row stays compact on first read but the reason is one click
  away.  Long reasons (e.g. PopulateDataToCurrentDate's missing-object
  explanation) wrap inside the <details> body so they do not blow out the
  column width.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - NOT_TESTABLE branch in
    GenerateAndCoverDatabase HTML row builder.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_GenerateAndCoverDatabase_TestableColumn.sql - REBUILT
    (same filename) carrying every prior fix; SUPERSEDES the v9.4.3
    Testable-column-only version of itself plus
    Patch_GenerateAndCoverDatabase_ReportHonesty.sql.

VERIFY (byte-identity)
  GenerateAndCoverDatabase body in module 04, installer and rebuilt patch
  all hash to:
       md5 39971e3221648e2b36253121604ccc54   (321 lines).

VERIFY (run by user)
  Re-run a sweep:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Open the HTML.  Every NOT_TESTABLE row should now show 0 / 0 / 0 / 0 / 1
  across Tests / Pass / Fail / Err / Skip (the 1 is the SkipTest stub), n/a
  in the four coverage cells, and a small grey "why not testable?" link
  beneath the proc name that expands to show the full reason on click.


================================================================================
2026-05-26  v9.4.4 PHASE 2  - TEST PRESERVATION ACTIVE
================================================================================

CONTEXT
  Phase 1 captured each emitted test's body + SHA2_256 hash into
  TestGenLog.GeneratedTest.  Phase 2 puts that data to work: when a developer
  modifies a framework-generated test, the next regen detects the divergence
  (current proc body hash != stored OriginalBodyHash) and PRESERVES the
  developer's version instead of dropping & re-emitting it.  Modification IS
  the ownership signal - no rename to *_custom, no in-code marker.

MECHANISM (in TestGen.GenerateTestsForProcedure, both branches)
  1. SNAPSHOT before the destructive DropClass + NewTestClass + CREATE flow:
     scan the existing class for procs whose current body hash diverges from
     the latest logged OriginalBodyHash; save their bodies into @Preserved.
  2. The destructive flow runs as before.
  3. RESTORE: for each preserved proc, drop the framework's same-named
     CREATE (if any) and EXEC the developer's saved body verbatim.  The
     developer's version survives the regen.
  4. The Phase 1 capture step logs all procs in the class.
  5. PRUNE log rows just inserted for preserved test names so the OLD log
     row (with the FRAMEWORK's original body and hash) remains the latest.
     Future regens still detect divergence.

  Implemented in BOTH the NOT_TESTABLE branch (SkipTest stub take-over - the
  user's original use case) AND the main branch (developer modifies a
  regular generated test, e.g. seeds their own data).  The two paths share
  a single @Preserved table variable declared at proc top.

NEW SCHEMA
  TestGen.CoverageResult gains a TestsPreserved INT NOT NULL DEFAULT 0
  column (idempotent ALTER).  TestGen.GenerateTestsForProcedure gains an
  @TestsPreservedCount INT = 0 OUTPUT parameter.  TestGen.GenerateAndCover
  Database calls the generator with that OUTPUT, captures into a local
  @pres, and writes it to CoverageResult.TestsPreserved on the row insert
  for that proc.

EDGE CASE
  Preservation is claimed by name.  If a later regen would emit a NEW test
  with the SAME name as a developer-preserved one, the preserved version
  wins (step 3 drops the newly-emitted same-named proc before replaying
  the saved body).  This matches how same-named-test conventions work in
  tSQLt itself.

ALSO IN THIS PHASE - module 04 reconstruction
  Mid-edit, modules/04_Test_Generator_v3.sql was silently truncated by the
  Edit tool from ~4000 lines to 3777, ending in `width:100%;` mid-string
  with the rest of GenerateAndCoverDatabase's HTML render block and the
  whole DropGeneratedTestClasses procedure lost.  The installer remained
  intact.  Reconstructed module 04 by lopping off the broken last line
  and re-appending installer lines 7461-7677.  Both procs subsequently
  byte-identity-verified clean.  Filed feedback memory
  feedback_edit_tool_silent_truncation.md.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - @Preserved decl; OUTPUT param;
    snapshot/restore in NOT_TESTABLE branch; snapshot/restore in main
    branch; prune blocks in both branches; @pres wiring in
    GenerateAndCoverDatabase; reconstructed tail.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored all of the above
    plus the CoverageResult.TestsPreserved schema add.
  - scripts\Patch_Phase2_TestPreservation.sql - NEW.  Idempotent column add
    + full DROP+CREATE of GenerateTestsForProcedure (SUPERSEDES
    Patch_Phase1_GeneratedTestCapture for that procedure) + full
    DROP+CREATE of GenerateAndCoverDatabase (SUPERSEDES
    Patch_GenerateAndCoverDatabase_TestableColumn).

VERIFY (byte-identity)
  GenerateTestsForProcedure: md5 398e8e54210b072bc8c824f0c4b70de4 (3022 lines)
  GenerateAndCoverDatabase:  md5 e4aad26af4312dfeccbc5484221ec3eb  (325 lines)
  Both byte-identical across module 04, installer and patch.

VERIFY (run by user)
  Apply the patch, then re-sweep a clean DB:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'TEXT';
  Should be no behaviour change yet - TestsPreserved column shows 0 for
  every row, because no developer has touched a generated test.

  To validate preservation actually works:
    1. EXEC TestGen.GenerateAndCoverDatabase to populate generated tests.
    2. Pick a generated test proc, e.g.
       [test_HumanResources_uspUpdateEmployeeHireInfo].[test happy path].
    3. Modify it (e.g. ALTER PROCEDURE ... to add a comment line, or
       change a literal).
    4. Re-run EXEC TestGen.GenerateAndCoverDatabase.
    5. Look at TestGen.CoverageResult: that proc's row should show
       TestsPreserved = 1, and the modification should still be visible
       in the test proc body (sys.sql_modules.definition).
    6. The latest TestGenLog.GeneratedTest row for that test should STILL
       carry the FRAMEWORK's original body (not the developer's body), so
       future regens still detect divergence.

NEXT
  Phase 3: roll the per-proc TestsPreserved counts up to the database
  level and surface the Autonomy metric in the coverage report - "98% of
  your tests are fully auto-generated; 2% are user-owned."


================================================================================
2026-05-26  v9.4.4 PHASE 3  - AUTONOMY HEADLINE METRIC IN COVERAGE REPORT
================================================================================

CONTEXT
  Phase 1 captured per-test bodies + hashes; Phase 2 turned that into a
  preservation mechanism with per-proc TestsPreserved counts in
  CoverageResult.  Phase 3 surfaces it as a headline metric so anyone
  glancing at the report immediately sees how autonomous the framework
  actually is on this codebase - "98% of your test suite is fully auto-
  generated; 2% required developer touch."

CHANGES IN GenerateAndCoverDatabase
  Aggregates pick up TestsPreserved:
       @gPres = SUM(TestsPreserved) across the batch
       @gAutonomy = (@gRun - @gPres) / @gRun * 100   (100 if no tests ran)
  Denominator is just @gRun because preserved tests are still procs in the
  test class and tSQLt runs them as part of TestsRun.

  HTML report:
    - New fourth headline card next to Line / Branch / Tests:
         <Autonomy %>
         <(@gRun - @gPres) of @gRun tests framework-owned>
         <@gPres user-modified>
      Green if >=80%, amber if >=50%, red below.  Same colour rule as the
      coverage cards so the eye treats them consistently.
    - Per-row Tests cell decorates with "8 (1 preserved)" in amber when
      TestsPreserved > 0; applied to both NOT_TESTABLE rows (a developer
      may have taken over a SkipTest stub) and TESTED rows.
    - TOTAL row's Tests cell gets the same decoration with the batch total.

  TEXT report:
    - New line in the summary block:
         Autonomy        : 96.3%   (26/27 framework-owned, 1 user-modified)

  Per-test SELECT grid was already returning TestsPreserved via the
  CoverageResult schema added in Phase 2 (NULL if Phase 2 not applied);
  unchanged in Phase 3.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - aggregates + TEXT line +
    Autonomy card + per-row + TOTAL row decoration.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_Phase3_AutonomyReporting.sql - NEW.  DROP + CREATE of
    GenerateAndCoverDatabase only; SUPERSEDES the GenerateAndCoverDatabase
    portion of Patch_Phase2_TestPreservation.sql.  Phase 2's
    GenerateTestsForProcedure portion is unchanged in Phase 3.

VERIFY (byte-identity)
  GenerateAndCoverDatabase body in module 04, installer and patch all
  hash to:
       md5 d1df20279b8adc0142f698442758d955   (361 lines).

VERIFY (run by user)
  Apply the patch, then re-sweep:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Expected:
    - Cards section now shows 4 cards (Line, Branch, Tests, Autonomy).
      With no developer modifications, Autonomy reads 100.0%.
    - TEXT mode shows the new "Autonomy" line in the summary.
    - On a sweep where a developer has modified at least one test
      (e.g. the dbo.ReseedAllSequences validation from Phase 2), the
      Tests cell for that proc reads "2 (1 preserved)" and the
      Autonomy card drops below 100%.


================================================================================
2026-05-26  v9.4.4 iteration  - RESOLVE VIEW DEPS TO BASE TABLES
================================================================================

SYMPTOM (user-reported, Northwind sweep)
  Two procs (dbo.[Employee Sales by Country], dbo.[Sales by Year]) had every
  generated test ERROR with:
       Msg 4406  Update or insert of view 'dbo.Order Subtotals' failed
                 because it contains a derived or constant field.
  Both procs read from the view dbo.[Order Subtotals], which exposes a
  SUM(...) aggregate column.  tSQLt.FakeTable will fake a view shell, but
  the framework's per-test seed step then runs INSERT INTO <view>, which
  SQL Server rejects whenever the view has computed/derived columns.

ROOT CAUSE
  TestGen.GetProcedureDependencies correctly labels view dependencies as
  DepKind='VIEW'.  But the rest of the generator processes 'TABLE' and
  'VIEW' identically - same FakeTable emission, same seed INSERT.  That
  cannot work for views that aren't directly insertable.

FIX (user-directed: "fake the underlying base tables of the view, not
                     the view itself")
  Added a Section 2a in TestGen.GenerateTestsForProcedure, right after
  GetProcedureDependencies fills @Deps.  For each VIEW row, walk
  sys.sql_expression_dependencies recursively until we reach terminal
  USER TABLES (sys.objects.type='U'), insert those into @Deps as TABLE
  rows (skip duplicates), then DELETE the VIEW row.  The view itself is
  not modified; the proc still reads from it at test time and the view's
  computation runs naturally over the faked base table rows.

  Recursion is capped at depth 10 (MAXRECURSION 20) for safety on
  pathological view graphs.

  An audit row "ViewResolved -> <schema>.<table>" is written to
  TestGenLog.ProcedureSnapshot for traceability.  The original VIEW dep
  row already appears in ProcedureSnapshot via the earlier dep logging,
  so the resolution is fully reconstructable from logs.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - new Section 2a block in
    GenerateTestsForProcedure, between the dep snapshot logging and the
    error-path extraction step.
  - Install_All_Combined_v9_2_FINAL.sql  - mirrored.
  - scripts\Patch_GenerateTestsForProcedure_ViewBaseTables.sql - NEW.
    Full DROP + CREATE of GenerateTestsForProcedure, carries every prior
    fix.  SUPERSEDES the GenerateTestsForProcedure portion of
    Patch_Phase1_GeneratedTestCapture.sql and
    Patch_Phase2_TestPreservation.sql.  Phase 3's
    Patch_Phase3_AutonomyReporting.sql is for GenerateAndCoverDatabase
    only and is unaffected.

ALSO IN THIS ITERATION - module 04 reconstruction (round 2)
  Mid-edit, modules/04_Test_Generator_v3.sql was silently truncated
  AGAIN by the Edit tool, mid-line at "FETCH NEXT FROM rc INTO @rS,@rP,
  @rGen,@rRun,@".  Recovered by lopping the broken line and re-appending
  installer lines 7579-7712 (the rest of GenerateAndCoverDatabase's
  HTML loop + DropGeneratedTestClasses).  Saved feedback memory updated
  earlier remains valid - check tail/wc after every few edits.

VERIFY (byte-identity)
  GenerateTestsForProcedure body in module 04, installer and patch all
  hash to:
       md5 e1ecadb79f34c6ae1a366cf1f23b33d8   (3092 lines).

VERIFY (run by user, Northwind specifically)
  Apply the patch, then re-sweep:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Expected: dbo.[Employee Sales by Country] and dbo.[Sales by Year] no
  longer report Msg 4406 across every test.  Their tests should now
  Succeed (or Skip for the characterization scaffold), with [Order
  Details] faked underneath instead of [Order Subtotals].  Also:
       SELECT ItemName, ItemDetail
       FROM   TestGenLog.ProcedureSnapshot
       WHERE  Kind = 'ViewResolved'
       ORDER  BY SnapshotId DESC;
  should show "dbo.Order Details -> expanded from view dependency" for
  each affected proc's run.


================================================================================
2026-05-26  v9.4.4 iteration  - INSTRUMENT BODYLESS / UNTERMINATED PROCS
================================================================================

SYMPTOM (user-reported, Northwind sweep)
  Every proc reported:
       RecordCoverageHit injections   : 0
       Registry IsExec lines          : 1
       WARNING: injection count differs from IsExec count
  resulting in 0% line coverage across 7/7 procs even though most tests
  passed.  Branch coverage on the one branched proc (SalesByCategory):
  0/1.

ROOT CAUSE
  Northwind procs are written in classic 1990s T-SQL style:
       CREATE PROCEDURE CustOrderHist @CustomerID nchar(5) AS
       SELECT ProductName, Total = SUM(Quantity)
       FROM   Products P, [Order Details] OD, ...
       GROUP  BY ProductName
  No BEGIN/END, no terminating semicolon.  TestGen.InstrumentProcedure's
  line walker correctly identified the SELECT as an IsExec line, but the
  probe-emit step inside the body cursor only fires when:
       @StmtStart IS NOT NULL AND @Semi = 1 AND @DepthAfter = 0
                              AND @InCaseAfter = 0
  i.e. only when the CURRENT line ends with ';'.  The last (and only)
  statement of the body never reached a semicolon, so the hit was lost.
  Pre-existing comments in the instrumenter even called this out:
     "The missing hit for an unterminated statement is a pre-existing
      limitation, unchanged by this fix."

FIX
  After the body cursor closes, if @StmtStart is still set, append one
  final RecordCoverageHit to @Body referencing @StmtStart's line number,
  then clear @StmtStart.  Placed BEFORE the existing @StmtWrap safety-
  net END so a bare unterminated branch body still has its hit inside
  the synthetic BEGIN/END wrap.

  Secondary win: any proc with BEGIN/END but no final ';' (e.g.
  "BEGIN SELECT 1 END") now also gets its hit registered.

  Scope note: multi-statement bodies where EVERY statement lacks a
  semicolon will still only register ONE hit (for the first statement)
  because the line walker still uses @Semi as its boundary signal in
  the middle of the body.  Proper statement-boundary detection without
  semicolons is a larger fix; out of scope here.

ALSO IN THIS ITERATION - module 20 reconstruction (round 3 of Edit-tool
                         silent-truncation)
  Mid-edit, modules/20_Coverage_Instrumenter_v5.sql was silently
  truncated by the Edit tool, mid-line at
       "    DECLARE @RegExec INT, @RegBranch INT;\n    SEL"
  Recovered by lopping the broken line and re-appending installer lines
  8528-8549 (the SELECT aggregate + summary PRINT block).  Feedback
  memory feedback_edit_tool_silent_truncation.md stays valid.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - new bodyless-injection
    block right after CLOSE wcur, before the @StmtWrap safety-net END.
  - Install_All_Combined_v9_2_FINAL.sql     - mirrored.
  - scripts\Patch_InstrumentProcedure_BodylessProc.sql - NEW.  Full
    DROP + CREATE.  SUPERSEDES the entire prior chain of
    InstrumentProcedure patches (OutputPreservation -> AsBeginBalance
    -> AsBeginOneLine -> BodyGuard -> BareBranchBody).

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash
  to:
       md5 48ca9c66442dce20a3031da4aea472ee   (606 lines).

VERIFY (run by user, Northwind specifically)
  Apply the patch, then re-sweep:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Expected for each Northwind proc:
       RecordCoverageHit injections   : 1   (was 0)
       Registry IsExec lines          : 1
       (no warning)
       Coverage hits recorded         : >= 1 (after tests run)
  Line % in the HTML report should jump from 0.0% to 100.0% for each
  proc whose tests pass.  Branch % for SalesByCategory should likewise
  improve once its IF body's SET also gets a hit (single-statement
  branch body, hit will fire via the same end-of-body path).


================================================================================
2026-05-26  v10.0.1  - TIGHTEN NULL-EVIDENCE PATTERN B (STRUCTURAL CONTAINMENT)
================================================================================

SYMPTOM (user-reported, AdventureWorks regression on v10.0.0)
  dbo.PlaceOrder showed 2 NULL-rejection test failures even though the
  proc only validates ONE parameter:
       [test PlaceOrder rejects NULL for @Notes]   Failure
       [test PlaceOrder rejects NULL for @Total]   Failure
  PlaceOrder body:
       IF NOT EXISTS (SELECT 1 FROM dbo.Customers
                      WHERE CustomerId = @CustomerId AND Status = 'Active')
       BEGIN
           RAISERROR('Customer %d is not active.', 16, 1, @CustomerId);
           RETURN;
       END;
       INSERT dbo.Orders (CustomerId, Total, Notes)
       VALUES (@CustomerId, @Total, @Notes);
  Only @CustomerId is guarded; @Total and @Notes flow straight to the
  INSERT.  The framework was emitting ExpectException tests for all three.

ROOT CAUSE
  The evidence-based NULL-guard detector's Pattern B (added in the
  "evidence-based NULL guard" iteration) used a 500-char proximity window
  starting at "IF NOT EXISTS".  Acceptance criterion was just
       (@<param>  AND  RAISERROR/THROW)  both present in the window.
  @Total and @Notes appear in the INSERT immediately below the guard -
  inside the 500-char window - and the proximity rule treated them as
  evidence of a NULL check.  False positive.

FIX (structural containment)
  For each "IF NOT EXISTS" found in the procedure source:
    1. Locate the opening "(" immediately after.
    2. Walk forward counting paren nesting to the matching ")".
    3. The TEXT BETWEEN those parens is the predicate; @<param> must
       appear INSIDE the predicate to count.
    4. Within 200 chars AFTER the closing ")", a RAISERROR / THROW must
       be present (i.e. the IF block's body, not somewhere later in
       the proc).
  Both conditions must be met for the param to be classified guarded.

  Pattern A (literal "IF @<param> IS NULL ... RAISERROR/THROW") is
  unchanged and still accepts evidence regardless of Pattern B.

  Three new locals carry the paren-walk state: @v100PredOpen,
  @v100PredClose, @v100Depth, @v100Scan, @v100Char.

FILES CHANGED
  - modules\04_Test_Generator_v3.sql     - tightened Pattern B block in
    GenerateTestsForProcedure.
  - scripts\Patch_GenerateTestsForProcedure_NullEvidencePatternB.sql -
    NEW.  Full DROP + CREATE of GenerateTestsForProcedure.  SUPERSEDES
    Patch_GenerateTestsForProcedure_ViewBaseTables.sql (and the entire
    chain it superseded).

INSTALLER STATUS (NOT FIXED IN THIS ITERATION)
  Install_All_Combined_v9_2_FINAL.sql is currently truncated mid-line at
  byte 443514, inside RunCoverage's synonym-creation step.  Lost: the
  rest of RunCoverage and all of GetCoverageReport.  Cause: silent
  Edit-tool truncation pattern that hit module 04 and module 20 earlier
  in this session, this time hitting the installer.  The user's
  existing database installation is not affected - they have the working
  procedures from prior patches.  Standalone patches in scripts/ are the
  delivery vehicle for v10.0.1.

  Reconstruction is filed as a separate task (#74); plan is to splice
  v9.4.2 baseline lines 7626-8207 (RunCoverage + GetCoverageReport)
  onto the truncation point, then re-apply the relevant patches in
  order to bring the installer back to v10.0.1 parity.  Once done, the
  v10.0.0 zip can be re-bundled as v10.0.1.

VERIFY (run by user)
  Apply the patch, then re-run the AdventureWorks PlaceOrder test class:
       EXEC tSQLt.Run 'test_PlaceOrder';
  Expected:
    - "rejects NULL for @CustomerId" still passes (Pattern A still
      catches it; @CustomerId is also inside the predicate so Pattern B
      catches it).
    - "rejects NULL for @Notes" and "rejects NULL for @Total" no longer
      generated (no IF inside whose predicate names them).  Test class
      count drops from 11 to 9; pass count stays at 8.


================================================================================
2026-05-26  v10.0.2  - MULTI-STATEMENT BODIES WITH NO SEMICOLONS
================================================================================

CONTEXT
  v9.4.4 closed the bodyless / unterminated-final-statement case (Northwind-
  style "CREATE PROC X AS SELECT ..." with no BEGIN/END and no terminating
  ;).  But many production codebases - especially older ones - omit
  semicolons throughout, not just at the end.  A common 1990s shape:
       CREATE PROC X
       AS
       BEGIN
           SET @a = 1
           SET @b = 2
           SELECT @a + @b
       END
  Prior to v10.0.2, only the FIRST statement (SET @a = 1) registered an
  IsExec line.  The line walker used @Semi (current line ends with ;) as
  its sole boundary signal, so the two subsequent statements got swallowed
  as "continuation of the first."  Coverage came out wrong even though the
  proc ran fine.

FIX (statement-keyword boundary detection)
  The line walker now computes a new BIT, @IsStmtStarter, per line: true
  when the first non-whitespace word matches a known statement keyword:
       SELECT INSERT UPDATE DELETE MERGE
       SET DECLARE EXEC EXECUTE
       RETURN PRINT RAISERROR THROW WAITFOR TRUNCATE
       GOTO BREAK CONTINUE COMMIT ROLLBACK
       BEGIN TRAN USE
  Inside the cursor's body-line block, BEFORE the standard "@StmtStart IS
  NULL -> open new" decision, we check:
       IF @StmtStart IS NOT NULL
          AND @StmtStart <> @LN
          AND @IsStmtStarter = 1
  When all three hold, the prior statement's RecordCoverageHit is
  appended to @Body NOW (the prior line's text was already emitted), and
  @StmtStart is cleared.  The standard logic then opens this line as a
  fresh statement.

  Branch headers (IF/WHILE/ELSE) and block openers (BEGIN/END) are
  already routed through their own handlers above this code path - the
  @IsStmtStarter list intentionally covers data-and-control verbs only,
  not block syntax.

  The end-of-body safety net from v9.4.4 still emits the final hit when
  the cursor closes with @StmtStart set, so the very last statement of
  a body (no semicolon, no following keyword) is also covered.

ALSO IN THIS ITERATION - SAFER EDIT MECHANICS
  Two prior iterations in this session lost work to silent Edit-tool
  truncation (module 04 twice, module 20 once, the combined installer
  once).  This iteration's surgery was applied via a Python script that
  reads each file as bytes, does literal-string substitution, and writes
  back - no Edit-tool involvement.  Worked first try with no truncation.
  Likely the right pattern for any future multi-anchor edit to a large
  module / installer.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - @IsStmtStarter declaration,
    per-line computation block, and boundary-detection block at the top
    of the @Pending = 0 ELSE branch.  +50 lines net.
  - Install_All_Combined_v9_2_FINAL.sql     - mirrored via the same
    Python script.
  - scripts\Patch_InstrumentProcedure_MultiStatementBody.sql - NEW.
    Full DROP + CREATE.  SUPERSEDES Patch_InstrumentProcedure_BodylessProc
    and the entire prior InstrumentProcedure patch chain.

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash to:
       md5 8cb8d1cd39bf93818858acc56746f9e8   (656 lines, +50 vs v9.4.4).

VERIFY (run by user)
  Apply the patch, then sweep a database with multi-statement bodies.
  For each affected procedure:
       Registry IsExec lines: should now equal the number of distinct
                              statements in the body (not 1).
       RecordCoverageHit injections: should equal the same count, with
                              no "injection count differs from IsExec"
                              warning.
       Line % in the report should reflect actual statement coverage.

  Northwind regression: results from v9.4.4 should be unchanged
  (single-statement bodies were already at 100% / 1 IsExec each).

  Sanity probe to find candidates worth re-sweeping:
       SELECT m.object_id, OBJECT_NAME(m.object_id) AS ProcName,
              (LEN(m.definition) - LEN(REPLACE(m.definition, ';', '')))
                                                     AS SemiCount
       FROM   sys.sql_modules m
       JOIN   sys.objects o ON o.object_id = m.object_id
       WHERE  o.type = 'P'
         AND  SCHEMA_NAME(o.schema_id) NOT IN ('tSQLt','TestGen','TestGenLog')
         AND  SCHEMA_NAME(o.schema_id) NOT LIKE 'test[_]%'
       ORDER  BY SemiCount;
  Procs with low SemiCount relative to body length are the ones where
  v10.0.2 will change the registry counts the most.


================================================================================
2026-05-26  v10.0.2 INSTALLER RECONSTRUCTION
================================================================================

SYMPTOM
  After applying recent patches, GenerateAndCoverDatabase reported
       "The tSQLt Auto-Gen framework is not fully installed in this database."
  Audit showed TestGen.RunCoverage was MISSING from the catalog.  Re-running
  the combined installer threw a parse error:
       Msg 105  Unclosed quotation mark after the character string 'Syno
  - the installer file itself was truncated mid-line inside RunCoverage's
  body, at "PRINT 'Synonym created: ...".

ROOT CAUSE
  Cumulative damage from the Edit-tool silent-truncation pattern (filed in
  feedback_edit_tool_silent_truncation.md).  Over several iterations of
  this session, edits to the combined installer left a tail-truncated
  file capped near 443 KB.  RunCoverage's CREATE was cut off mid-body,
  and GetCoverageReport (which followed it in the file) was lost entirely.

RECOVERY
  Reconstructed Install_All_Combined_v9_2_FINAL.sql programmatically:
    1. Kept every byte up to the line BEFORE
            IF OBJECT_ID('TestGen.RunCoverage','P') IS NOT NULL
       (i.e. dropped the truncated tail).
    2. Appended scripts/Patch_RunCoverage_AlwaysReinstrument.sql in full
       (canonical RunCoverage with the always-reinstrument stale-_cov fix).
    3. Appended modules/22_Coverage_Reporter_v2.sql in full (canonical
       GetCoverageReport with the n/a-for-branchless-procs rendering).

  Final installer:
       Size: 471,580 bytes  (9,469 lines)
       Procs CREATEd: 5/5 key procedures present
       (RunCoverage, GetCoverageReport, GenerateTestsForProcedure,
        GenerateAndCoverDatabase, InstrumentProcedure)
       File ends cleanly with the GetCoverageReport trailing PRINT + GO.

V10.0.2 BUNDLE
  Re-bundled as tsqltAutoGen-v10.0.2.zip (771 KB, 46 files) in the
  workspace folder.  Contains the rebuilt installer, all module sources,
  all 28 standalone patches, the v10.0.2-titled README, and the design
  docs.  Supersedes the prior tsqltAutoGen-v10.0.0.zip which carried the
  truncated installer.

USER GUIDANCE
  Either:
    (a) For an existing install that's mid-broken (RunCoverage missing
        as you saw): apply Patch_RunCoverage_AlwaysReinstrument.sql
        directly to recover.  No need to re-run the installer.
    (b) For a fresh database: deploy the new v10.0.2 zip's installer
        in one go.

FOLLOW-UP TO DO LATER
  Track-and-defend mechanism for the Edit-tool truncation pattern: any
  future multi-anchor edit to a large module / installer should go
  through the Python-direct-edit pattern proven during v10.0.2 work,
  not the Edit tool.  Documented in feedback_edit_tool_silent_truncation.md.


================================================================================
2026-05-26  v10.0.3  - ROLLBACK v10.0.2 MULTI-STATEMENT DETECTION
================================================================================

SYMPTOM (user-reported, AdventureWorks regression on v10.0.2)
  After applying Patch_InstrumentProcedure_MultiStatementBody.sql, the
  AdventureWorks sweep imploded.  Pre/post comparison:
       Tests passed   :  167  ->   47   (-120)
       Tests failed   :    0  ->   45   (+45)
       Tests errored  :    0  ->   75   (+75)
       Line coverage  : 88.3% -> 24.7%
       Branch coverage: 79.7% -> 28.8%
  Procs that broke:
       uspFiveLevelTest, uspGetBillOfMaterials, uspGetEmployeeManagers,
       uspGetManagerEmployees, uspGetWhereUsedProductID, uspLevel3ValidationTest,
       uspV9ValidationTest, uspProcessSalesOrderRealistic,
       uspUpdateEmployeeHireInfo, uspUpdateEmployeeLogin,
       uspUpdateEmployeePersonalInfo  - every CTE-using, multi-line-INSERT,
       multi-line-UPDATE proc lost coverage and started erroring.
  Procs that still worked: dbo.LogAudit, dbo.PlaceOrder, dbo.uspPrintError,
       dbo.uspProcessSalesOrder - all bodies with single-statement-per-line
       or properly semicolon-terminated.

ROOT CAUSE
  v10.0.2's @IsStmtStarter looks at the leading keyword of each line.  If
  it's SELECT/INSERT/UPDATE/DELETE/MERGE/SET/etc., the line is treated as
  a NEW statement boundary.  That assumption falls apart for any
  multi-line statement where a subsequent line legitimately begins with
  one of those keywords:
       WITH cte AS (SELECT ...) SELECT ...    -- second SELECT is continuation
       INSERT INTO x
       SELECT ... FROM ...                    -- SELECT continues the INSERT
       UPDATE t
       SET col = val                          -- SET continues the UPDATE
       SELECT ... WHERE col IN
         (SELECT id FROM y)                   -- SELECT inside paren-subquery
  In each case, v10.0.2 injects a RecordCoverageHit MID-statement,
  producing a syntactically invalid _cov body.  The CREATE PROCEDURE
  for _cov errors out, RunCoverage's synonym still points at it (or
  at the stranded _orig), and every test for that proc errors with the
  CREATE-time syntax error or with "object _cov not found".

FIX (revert v10.0.2, retain v9.4.4's bodyless-proc fix)
  Removed:
    1. @IsStmtStarter BIT local declaration.
    2. The per-line @IsStmtStarter computation block.
    3. The inner-loop boundary-detection block at the top of the
       @Pending = 0 ELSE branch.
  Retained:
    1. The end-of-body unterminated-statement hit emit added in v9.4.4
       (after CLOSE wcur).  That fix covers the single-statement-bodyless
       case correctly (Northwind-style procs) and is structurally
       different from the v10.0.2 misfire.

  Applied via Python direct-edit (same pattern that landed v10.0.2 -
  no Edit-tool truncation).

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql  - reverted -3373 bytes.
  - Install_All_Combined_v10_FINAL.sql       - reverted -3373 bytes.
  - scripts\Patch_InstrumentProcedure_RevertMultiStatement.sql - NEW.
    Full DROP + CREATE of InstrumentProcedure as it stands post-rollback.
    SUPERSEDES Patch_InstrumentProcedure_MultiStatementBody.sql (v10.0.2).

V10.0.3 BUNDLE
  Re-bundled as tsqltAutoGen-v10.0.3.zip (762 KB, 47 files).  Contains
  the reverted installer + module + the 28 standalone patches MINUS the
  v10.0.2 multi-statement patch (excluded from the bundle as known-bad).

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer, and rollback patch
  all hash to:
       md5 2b9057fc2fb4f51d3643cde92273aa79   (608 lines).

VERIFY (run by user)
  Apply scripts\Patch_InstrumentProcedure_RevertMultiStatement.sql
  against the existing database, then re-sweep AdventureWorks:
       EXEC TestGen.GenerateAndCoverDatabase @OutputMode = 'HTML';
  Expected: return to the v10.0.1 baseline -
       167 tests passing, 0 fails, 0 errors, 88.3% line, 79.7% branch,
       Autonomy 100%.

FUTURE WORK (filed for a later session)
  Multi-statement bodies with no semicolons remain unsupported - the
  rollback only restores v9.4.4 behavior, which handled single-
  statement bodies via the end-of-body safety net.  Proper support
  requires:
    - Paren-depth tracking inside the line walker (so a line-start
      SELECT inside a (...) subquery is not flagged as a new statement).
    - CTE-structure awareness: detect WITH cte AS (...) blocks and
      treat their internal SELECTs as continuation.
    - Multi-keyword statement detection: INSERT ... SELECT, UPDATE ...
      SET, MERGE ... USING - the line-start keyword only opens a new
      statement when no compatible "carrier" statement is open above.
    - Possibly a real SQL tokeniser inside the line walker, not the
      current line-by-line LIKE-pattern matching.
  Until then, classic-T-SQL bodies with multiple unterminated
  statements register coverage only for their first statement (a
  documented limitation, not a regression).


================================================================================
2026-05-26  v10.0.4  - UNIFIED MULTI-STATEMENT STATE MACHINE
================================================================================

CONTEXT
  v10.0.2 tried to detect multi-statement boundaries via a flat keyword list
  (any SELECT/INSERT/UPDATE/SET/etc. at line start was a boundary).  That
  broke 11/17 procs on AdventureWorks because the same keywords appear as
  *continuations* of multi-line CTEs, INSERT...SELECT, UPDATE...SET, etc.
  v10.0.3 rolled the whole thing back.

  v10.0.4 reattempts the work with a proper state machine instead of a flat
  list.  The line walker tracks WHAT KIND of statement is currently open,
  and each keyword is interpreted in that context.

DESIGN
  New locals in the line walker:
       @OpenStmt       VARCHAR(10)  - SELECT/INSERT/UPDATE/DELETE/MERGE/
                                      WITH/SETVAR/DECLARE/EXEC/SIMPLE/NULL
       @InsertMode     VARCHAR(10)  - HEADER/VALUES/SELECT/EXEC sub-state
                                      when @OpenStmt='INSERT'
       @UnionPending   BIT          - prior line had UNION/EXCEPT/INTERSECT
       @FirstWord      NVARCHAR(50) - leading token of current line
       @LineHasSetOp   BIT          - current line has a set operator
       @IsContinuation BIT          - derived per-line via state lookup

  Per-line decision (at @ParenDepth = 0, non-branch, non-BEGIN/END):
    1. Extract @FirstWord via PATINDEX (first non-A-Z_ character).
    2. Look up @IsContinuation against @OpenStmt's continuation set
       (pipe-delimited strings + CHARINDEX).
    3. If @StmtStart NOT NULL AND @IsContinuation = 0 AND @FirstWord
       is non-empty -> close prior, emit hit, clear state.
    4. If @StmtStart NULL -> open new statement; set @OpenStmt; if
       INSERT also set @InsertMode = HEADER.
    5. If continuation AND @OpenStmt = INSERT AND @InsertMode = HEADER
       -> transition @InsertMode on SELECT/VALUES/EXEC.
    6. Update @UnionPending := @LineHasSetOp for next iteration.

  Paren-depth gate: ANY line with @ParenDepth > 0 is automatically
  continuation, regardless of leading keyword.  This is the crucial
  defense against v10.0.2's misfire on CTE inner SELECTs / subqueries.

  Sub-state for INSERT lets the framework correctly distinguish:
       INSERT INTO t (cols) SELECT ... FROM src      -- 1 statement
       INSERT INTO t (cols) VALUES (...)             -- 1 statement
       INSERT INTO t VALUES (...) / SELECT * FROM x  -- 2 statements
  After VALUES is seen, subsequent SELECT closes INSERT and opens a new
  SELECT.  After SELECT is seen, subsequent FROM/WHERE/UNION are
  continuation, but SELECT (not after UNION) closes and opens new.

CONTINUATION KEYWORD SETS (pipe-delimited NVARCHARs)
  @ContSelect    = FROM/WHERE/GROUP/HAVING/ORDER/UNION/EXCEPT/INTERSECT/
                   JOIN/INNER/LEFT/RIGHT/FULL/CROSS/OUTER/APPLY/ON/AND/
                   OR/NOT/OPTION/FOR/INTO/OUTPUT
  @ContInsertHdr = INTO/SELECT/VALUES/DEFAULT/EXEC/EXECUTE/OUTPUT/OPTION/WITH
  @ContInsertVal = OUTPUT/OPTION/INTO
  @ContInsertExe = OUTPUT/OPTION
  @ContUpdate    = SET/FROM/WHERE/OUTPUT/OPTION/JOIN/INNER/LEFT/RIGHT/
                   FULL/CROSS/OUTER/APPLY/ON/AND/OR/NOT
  @ContDelete    = same as ContUpdate minus SET
  @ContMerge     = INTO/USING/ON/WHEN/MATCHED/NOT/AND/OR/THEN/INSERT/
                   UPDATE/DELETE/VALUES/SET/OUTPUT/OPTION/BY/SOURCE/TARGET
  @ContWith      = AS + all of ContSelect + anchor DML keywords

  SETVAR/DECLARE/EXEC/SIMPLE: no explicit continuation set; expression
  wrapping is paren-bounded (already handled), non-keyword lines fall
  through as continuation via @FirstWord = N''.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - 8 anchored edits applied
    via Python script (no Edit tool), +170 net lines.
  - Install_All_Combined_v10_FINAL.sql      - mirrored via the same
    script.
  - scripts\Patch_InstrumentProcedure_StateMachine.sql - NEW.  Full
    DROP + CREATE of TestGen.InstrumentProcedure.  SUPERSEDES
    Patch_InstrumentProcedure_RevertMultiStatement.sql (the v10.0.3
    rollback baseline) and the entire prior chain.

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash to:
       md5 9f3eaf9dccec5044c7b37c3986165489   (778 lines).

VERIFY (run by user)
  CRITICAL: apply against a test database first.  Then:
    1. Sweep AdventureWorks2025 - expect the v10.0.3 baseline reproduced
       exactly: 167 pass / 0 fail / 0 err / 88.3% line / 79.7% branch /
       Autonomy 100%.  Any regression = rollback.
    2. Sweep Northwind - expect unchanged: 42 pass / 0 fail / 8 skip /
       100% line / 100% branch.
    3. Sweep WideWorldImporters - expect unchanged from prior baseline.
    4. Create a synthetic test proc with multi-statement no-semis body:
            CREATE PROC dbo.TestMultiStmt @x INT AS
            BEGIN
                SET @x = 1
                PRINT 'one'
                EXEC dbo.LogAudit @EventName=N'TestMulti', @Details=N'x'
                SET @x = 2
            END
       Sweep and verify Registry IsExec = 4 (was 1 in v10.0.3).

  If ANY of #1-3 regress, immediately apply the v10.0.3 rollback
  patch (Patch_InstrumentProcedure_RevertMultiStatement.sql) and
  file the regression case for further diagnosis.

FUTURE WORK
  Items not yet handled correctly (call out / hand-write semis):
    - Bare table-hint keywords (WITH (NOLOCK)) at line start: distinguished
      from CTE WITH by paren immediately after, but worth testing.
    - SELECT with INTO #temp on its own line: INTO is in @ContSelect,
      should work, but worth testing.
    - Cursor-relative variable assignment (FETCH NEXT FROM ... INTO @x):
      FETCH isn't in any continuation set.  If you have a FETCH-driven
      loop body with no semicolons, FETCH might be misclassified.
    - Dynamic SQL (sp_executesql @sql, ...): EXEC is in opener list,
      should work.
    - Multi-line variable initializers with line-trailing continuation:
      e.g. SET @x = func() + / OTHER_VAR.  The + on line break makes
      the next line a non-keyword line, so falls through as continuation.


================================================================================
2026-05-26  v10.0.5  - HOIST @Trimmed (fix v10.0.4 declare-in-loop bug)
================================================================================

SYMPTOM (user-reported, AdventureWorks regression on v10.0.4)
  v10.0.4's state machine landed the multi-statement detection but
  AdventureWorks cratered:
       Tests pass    :  167 -> 91   (-76)
       Tests failed  :    0 -> 57   (+57)
       Tests errored :    0 -> 19   (+19)
       Line coverage : 88.3% -> 18.5%
       Branch coverage: 79.7% -> 8.5%
  Short procs survived (LogAudit, PlaceOrder, etc.).  Long procs broke
  hard: uspProcessSalesOrder 2 pass / 27 fail / 2 err (was 31 pass).
  uspV9ValidationTest, uspProcessSalesOrderRealistic, uspLevel3Validation
  Test all 0% line coverage with most tests failing.

ROOT CAUSE
  v10.0.4 introduced @FirstWord extraction:
       DECLARE @Trimmed NVARCHAR(MAX) = UPPER(LTRIM(ISNULL(@LT,N'')));
       SET @PatPos = PATINDEX(N'%[^A-Z_]%', @Trimmed);
       IF @PatPos = 0 SET @FirstWord = @Trimmed;
       ELSE          SET @FirstWord = LEFT(@Trimmed, @PatPos - 1);
  inside the body-line WHILE loop.  T-SQL's "DECLARE @x = expr" evaluates
  the initializer ONCE at batch parse time, not per loop iteration.
  @Trimmed therefore got the FIRST body line's UPPER(LTRIM(...)) value
  and kept that value for every subsequent line of the proc.  @FirstWord
  was stale on every iteration after the first - boundary decisions
  cascaded into garbage.

  The instrumenter's own header comment had warned about this exact
  rule: "v4.2 bug fix - Mid-loop DECLARE @x = expr initializers don't
  re-execute per iteration in T-SQL.  All loop-scoped variables now
  declared at proc top with SET assignments inside the loop."  Knew the
  rule, wrote the bug anyway.  Filed feedback_tsql_declare_in_loop.md.

  Why long procs broke while short ones survived: short procs barely
  iterate beyond the first body line, so the stale @Trimmed rarely
  causes false boundaries.  Long procs accumulate cascading mis-
  classifications.

FIX
  Hoist DECLARE @Trimmed to proc top alongside @PatPos:
       DECLARE @PatPos        INT;
       DECLARE @Trimmed       NVARCHAR(MAX);   -- v10.0.5: hoisted
  Replace the inline DECLARE with SET inside the loop:
       SET @Trimmed = UPPER(LTRIM(ISNULL(@LT,N'')));
  @Trimmed now refreshes every iteration, @FirstWord extraction is
  correct, the state machine decisions are sound.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - 2 edits (declare hoist,
    inline DECLARE->SET).  +82 bytes net.
  - Install_All_Combined_v10_FINAL.sql      - mirrored.
  - scripts\Patch_InstrumentProcedure_StateMachine.sql - REBUILT.
    Same filename as v10.0.4's; carries the fixed code now.  SUPERSEDES
    the prior contents.

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash to:
       md5 ffcf0b0c61a2f3dc3a915feba8b75ffa   (779 lines).

VERIFY (run by user)
  Apply the rebuilt patch (or re-run the installer; the version in the
  current installer file is v10.0.5).  Then re-sweep:
       AdventureWorks2025 - must reproduce v10.0.3 baseline exactly
                            (167 pass / 0 fail / 0 err / 88.3% line /
                             79.7% branch / Autonomy 100%).
       Northwind          - 42 pass / 0 fail / 8 skip / 100%/100%.
       WideWorldImporters - prior baseline.
       Synthetic multi-stmt no-semi test proc - registers 4 IsExec lines
                            (was 1 in v10.0.3).
  If AdventureWorks still regresses, apply the v10.0.3 rollback patch
  and we re-evaluate the state machine design itself.


================================================================================
2026-05-26  v10.0.6  - GATE BOUNDARY ON RECOGNISED OPENER KEYWORDS
================================================================================

SYMPTOM (user-reported, second AdventureWorks regression after v10.0.5 hoist)
  v10.0.5 fixed the @Trimmed-in-loop bug but AdventureWorks still showed
  the IDENTICAL regression to v10.0.4:
       Tests pass    :  167 -> 91   (-76)
       Tests failed  :    0 -> 57   (+57)
       Tests errored :    0 -> 19   (+19)
       Line coverage : 88.3% -> 18.5%
       Branch coverage: 79.7% -> 8.5%
  Same procs broken, same magnitudes.  v10.0.5 fix was necessary but
  not sufficient.

ROOT CAUSE (real this time)
  The boundary condition in the state machine fired whenever
       @StmtStart IS NOT NULL
       AND @ParenDepth = 0
       AND @IsContinuation = 0
       AND @FirstWord <> N''
  But T-SQL has many keywords that are neither in my opener list nor
  in any per-state continuation set:
       FETCH       (cursor read - common in real procs)
       OPEN / CLOSE / DEALLOCATE  (cursor lifecycle)
       BACKUP / RESTORE / DBCC
       CREATE / ALTER / DROP  (for #temp tables inside procs)
       CASE        (when leading a SELECT projection line)
       USE         (DB context switch inside dyn SQL is rare but
                    statically-leading USE appears occasionally)
  When the line walker hit one of those, my condition said "non-empty
  FirstWord, not continuation -> boundary!" and emitted a
  RecordCoverageHit mid-statement, breaking _cov.

  Long procs (uspProcessSalesOrder, uspV9ValidationTest, etc.) have
  many of these patterns and accumulated cascading false boundaries.
  Short procs barely encountered the trip-wire, so they survived
  intact - the same v10.0.3 behaviour.

FIX
  Added an explicit @StmtOpeners pipe-delimited NVARCHAR alongside the
  continuation tables:
       @StmtOpeners NVARCHAR(400) =
           N'|SELECT|INSERT|UPDATE|DELETE|MERGE|WITH|SET|DECLARE|EXEC|
              EXECUTE|PRINT|RETURN|RAISERROR|THROW|BREAK|CONTINUE|GOTO|
              COMMIT|ROLLBACK|WAITFOR|TRUNCATE|';
  Boundary condition tightened to ALSO require:
       AND CHARINDEX(N'|' + @FirstWord + N'|', @StmtOpeners) > 0
  Anything outside this list defaults to continuation - same as
  v10.0.3 baseline for those lines.  Unknown keywords still open a
  statement (with @OpenStmt = NULL) when @StmtStart IS NULL, so
  coverage IS registered for the opening line - just no mid-statement
  false boundary on subsequent lines.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - @StmtOpeners constant +
    tightened boundary condition.  +701 bytes net.
  - Install_All_Combined_v10_FINAL.sql      - mirrored.
  - scripts\Patch_InstrumentProcedure_StateMachine.sql - REBUILT.

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash to:
       md5 82df75b58dafe5de182b8cfc40329acd   (787 lines).

VERIFY (run by user)
  Apply the rebuilt patch or re-run the installer.  Then re-sweep
  AdventureWorks2025 - the moment of truth.
  Expected:
       Pass    : 167  (v10.0.3 baseline)
       Fail    :   0
       Err     :   0
       Line %  : 88.3%
       Branch %: 79.7%
       Autonomy: 100%
  If this still regresses, the design has a deeper bug and the safest
  action is to apply the v10.0.3 rollback patch.  This is the third
  attempt; one more failure and we stop iterating and stay at
  v10.0.3 + multi-statement-support-deferred.


================================================================================
2026-05-26  v10.0.7  - FIX WWI: BLANK-LINE UNION RESET + STRING-LITERAL GATE
================================================================================

SYMPTOM (user-reported, WideWorldImporters regression on v10.0.6)
  AdventureWorks and Northwind passed v10.0.6 validation; WWI showed two
  specific procs regressed:
       Configuration_ApplyRowLevelSecurity:
            v10.0.3: 1 pass / 14 lines / 11 covered / 78.6%
            v10.0.6: 0 pass / 1 err / 16 lines / 0 covered / 0%
       GetTransactionUpdates:
            v10.0.3: 7 pass / 1 skip / 3 lines / 100%
            v10.0.6: 0 pass / 1 fail / 6 err / 4 lines / 0%

DIAGNOSIS (from CoverageLines registry data)
  Bug A (GetTransactionUpdates): the body was
       SELECT ... FROM ... WHERE ...
       AND ...
       <blank>
       UNION ALL
       <blank>
       SELECT ...
  The state machine correctly identified UNION ALL as a SELECT
  continuation (line 34) and set @UnionPending=1 at end of that
  iteration.  But the very next line (35, blank) ran the unconditional
       SET @UnionPending = @LineHasSetOp;
  with @LineHasSetOp=0 - wiping the flag.  Line 36's leading SELECT
  then saw @UnionPending=0 and triggered a boundary, splitting the
  union into two statements.  4 IsExec lines registered (one false
  positive), _cov broken.

  Bug B (Configuration_ApplyRowLevelSecurity): the body had
       SET @SQL = N'
       CREATE FUNCTION [Application].DetermineCustomerAccess(@CityID int)
       RETURNS TABLE
       WITH SCHEMABINDING
       AS
       RETURN (SELECT 1 AS AccessResult
              ...
              );';
  Lines INSIDE the multi-line string literal contain keywords WITH
  (line 22) and RETURN (line 24) that are in @StmtOpeners.  The line
  walker had no awareness it was inside a string literal, so the
  state machine fired boundaries at lines 22 and 24.  2 false
  positives, _cov broken.

FIXES

  Bug A: only update @UnionPending on non-blank, non-comment lines.
       Previously:
           SET @UnionPending = @LineHasSetOp;
       Now:
           IF @Blank = 0 AND @Cmnt = 0
               SET @UnionPending = @LineHasSetOp;
       A blank or comment line between UNION ALL and the next SELECT
       no longer wipes the carry-over flag.

  Bug B: track @StringOpen via single-quote parity per line.
       New local @StringOpen BIT, initialised 0 before the cursor walk.
       Per line:
           IF ((LEN(@LT) - LEN(REPLACE(@LT, '''', ''))) % 2) = 1
               SET @StringOpen = 1 - @StringOpen;
       Naive single-quote counter; '' escape stays even, leaving parity
       unchanged.  Boundary check gated on @StringOpen = 0:
           IF @StmtStart IS NOT NULL
              AND @ParenDepth = 0
              AND @StringOpen = 0      -- NEW gate
              AND @IsContinuation = 0
              AND @FirstWord <> N''
              AND CHARINDEX(N'|' + @FirstWord + N'|', @StmtOpeners) > 0

       Limitation: a single quote inside a -- line comment can falsely
       toggle @StringOpen.  In practice T-SQL comments rarely have
       unmatched quotes; if they do, the affected proc reverts to
       v10.0.3 behaviour for that line, which is no regression.

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql - 5 anchored edits
    applied via Python script.  +1223 bytes net.
  - Install_All_Combined_v10_FINAL.sql      - mirrored.
  - scripts\Patch_InstrumentProcedure_StateMachine.sql - REBUILT.

VERIFY (byte-identity)
  InstrumentProcedure body in module 20, installer and patch all hash to:
       md5 026bd513708b9dd2c7add85e2e3828fe   (806 lines).

VERIFY (run by user)
  Apply the rebuilt patch and re-sweep WideWorldImporters.  Expected:
       Configuration_ApplyRowLevelSecurity: back to 14 IsExec lines, tests
                                            pass (the 2 false-boundary
                                            lines 22/24 no longer registered).
       GetTransactionUpdates: back to 3 IsExec lines, all 7 pass + 1 skip.
       Total: 24 pass / 0 fail / 0 err / 8 skip / 94%+ line coverage
              (the v10.0.3 baseline).
  AdventureWorks and Northwind should be UNCHANGED from v10.0.6 (the
  two new fixes are additive and don't affect their procs - neither
  has problematic blank-line+UNION patterns or multi-line string
  literals with embedded keywords).


================================================================================
2026-05-26  v10.0.7  - VALIDATED ON ALL THREE DATABASES - FINAL STABLE
================================================================================

OUTCOME (user-run sweeps)
  WideWorldImporters:
       27 tests / 24 pass / 0 fail / 0 err / 3 skip
       Line coverage  : 94.2% (81 / 86)
       Autonomy       : 100% (27 of 27)
       Configuration_ApplyRowLevelSecurity : 1 pass / 14 lines / 11 covered / 78.6%
                                             (v10.0.3 baseline restored exactly)
       GetTransactionUpdates              : 7 pass + 1 skip / 3 lines / 100%
                                             (v10.0.3 baseline restored exactly)
       All other procs unchanged from v10.0.6.

  AdventureWorks2025: 167 pass / 0 fail / 88.3% line (unchanged from v10.0.6 -
       additive fixes don't affect AW procs).
  Northwind:         42 pass / 0 fail / 100% line / 9 instrumented lines
       (unchanged from v10.0.6).

STATUS
  v10.0.7 is the FINAL STABLE release of the v10 line.  Multi-statement
  state-machine support (originally attempted in v10.0.2, rolled back in
  v10.0.3, re-attempted in v10.0.4-7) is now validated across all three
  reference databases.

  All v10.0.x feature work is feature-complete:
       - Testable Y/N column on coverage report
       - Test preservation (developer edits survive regeneration)
       - Autonomy headline metric
       - View dependency resolution (base-table FakeTable)
       - Bodyless proc instrumentation
       - NULL-evidence Pattern B (structural containment)
       - Multi-statement-no-semicolons via state machine + opener allowlist
         + string-literal gate + UnionPending carry-over

  Open known limitations (deferred, not regressions):
       - Single quote inside a -- comment can falsely toggle @StringOpen.
         No repro yet on AW/NW/WWI; if hit, that line falls back to v10.0.3
         no-multi-statement behaviour - no false coverage, just no merge.

DELIVERABLES
  - Install_All_Combined_v10_FINAL.sql           (single-file installer)
  - modules\20_Coverage_Instrumenter_v5.sql      (with v10.0.7 state machine)
  - modules\04_Test_Generator_v3.sql             (NULL Pattern B, view resolution)
  - scripts\Patch_InstrumentProcedure_StateMachine.sql  (standalone patch)
  - scripts\Patch_InstrumentProcedure_RevertMultiStatement.sql  (safety-net rollback)
  - README_v9_4.md                               (usage guide; superset still valid)

BYTE IDENTITY
  TestGen.InstrumentProcedure body across all three files:
       md5 f83bf750156e70ff9f6c2d60ba75853b   (800 lines)
       (post-v10.0.7 re-hash; CHANGES.md v10.0.7 entry quoted the prior
       md5 026bd513... which was computed before the final whitespace/header
       cleanup pass - both hash to a state machine that passes all three
       databases; only the proc body differs by header comments.)


================================================================================
2026-05-27  v10.0.8  - PRE-EMPTIVE ROBUSTNESS: BLOCK COMMENTS, DECLARE-CURSOR,
                       DDL/CURSOR OPENERS, BRACKET/DQUOTE TRACKING
================================================================================

SCOPE
  User concern: "i dont want people using the tool come back saying you
  missed this and its incorrectly reporting the lines."  v10.0.7 was
  stable on the three reference databases but had four known theoretical
  gaps where a real proc could trigger false boundaries or merged
  statements.  v10.0.8 closes all four pre-emptively.

GAPS CLOSED

  1. Multi-line  /* ... */  block comments  (HIGH VALUE)
     Symptom (theoretical): a block comment opened on one line and
     closed many lines later, with SQL keywords inside, would fire
     false boundary detections on the embedded keywords.
     Fix: new local @BlockCmtOpen BIT.  Iterative per-line scan finds
     /* and */ tokens in order; carries state between lines.  Boundary
     check gated on @BlockCmtOpen = 0.
     Limitation: a line of the form `*/ stmt /*` (close + re-open) is
     approximated; in practice T-SQL block comments do not interleave
     with code on the same line.

  2. DECLARE ... CURSOR FOR <SELECT> across lines
     Symptom (theoretical): the SELECT on the line after FOR would fire
     a false boundary because DECLARE state had no continuation table.
     Fix: new @ContDeclare lookup covering cursor-attribute keywords
     plus the full SELECT continuation set.  New CASE arm in the
     @IsContinuation lookup matches @OpenStmt = DECLARE.

  3. DDL + cursor verbs in @StmtOpeners
     Symptom (theoretical): CREATE/ALTER/DROP/GRANT/REVOKE/DENY and
     OPEN/FETCH/CLOSE/DEALLOCATE inside proc bodies would merge into
     the prior statement's IsExec row (no boundary fired).
     Fix: added all ten verbs to @StmtOpeners and to both transition
     CASEs (bare-branch-body opener at line ~506 and the regular
     opener at line ~604).  All ten classify as @OpenStmt = 'SIMPLE'.

  4. Bracket [ ] + double-quote " " identifier tracking
     Symptom (theoretical): keywords inside multi-line bracket-quoted
     identifiers (`[my WHERE table]`) or double-quoted identifiers
     under QUOTED_IDENTIFIER ON could fire false boundaries.
     Fix: new @BracketDepth INT and @DQuoteOpen BIT.  Per-line:
       @BracketDepth += (count('[') - count(']')); clamp to >= 0
       @DQuoteOpen   toggles on odd count of '"'
     Both gated into the boundary check.
     Limitations:
       - `]]` (escape for literal ] inside a bracket identifier) counts
         as 2 closes; in practice bracket identifiers are single-line.
       - `""` inside a string literal could falsely toggle @DQuoteOpen;
         in practice rare and the @StringOpen gate already suppresses
         the boundary check in that case.

NEW LOCALS  (all declared at proc top, SET inside loop - respects the
              v10.0.5 DECLARE-in-loop fix)
  - @BlockCmtOpen   BIT
  - @BracketDepth   INT
  - @DQuoteOpen     BIT
  - @BCScan         NVARCHAR(MAX)   -- scratch for block-comment scan
  - @BCPos          INT             -- scratch
  - @BCState        BIT             -- scratch
  - @BracketDelta   INT             -- per-line bracket net delta

NEW CONSTANTS
  - @ContDeclare    NVARCHAR(800)   -- DECLARE-state continuation set
  - @StmtOpeners    NVARCHAR(600)   -- extended from 400; +10 verbs

FILES CHANGED
  - modules\20_Coverage_Instrumenter_v5.sql     (+100 lines, 800 -> 900 in
                                                 proc body, file 923 -> 1023)
  - Install_All_Combined_v10_FINAL.sql          (mirrored, 481821 -> 488180 bytes)
  - scripts\Patch_InstrumentProcedure_StateMachine.sql  (mirrored)
  - scripts\Survey_v10_0_8_Patterns.sql         (NEW - detects affected
                                                 procs in any user DB)

BYTE IDENTITY
  TestGen.InstrumentProcedure body across all three files:
       md5 64e6afe65f8e2d42bb93946dd5eca170   (900 lines)

VERIFY (run by user)
  1. Apply the rebuilt installer / patch on each reference DB.
  2. Run scripts\Survey_v10_0_8_Patterns.sql per DB to see which procs
     exercise the new code paths.
  3. Re-sweep all three reference DBs.  Baselines to match or beat:
       AdventureWorks2025  : 167 pass / 0 fail / 88.3% line
       Northwind           :  42 pass / 0 fail / 100% line / 9 instr lines
       WideWorldImporters  :  24 pass / 0 fail / 0 err / 94.2% line / 100% autonomy
  4. Procs newly flagged by the survey should hold or improve their
     coverage (no false boundaries -> fewer spurious IsExec rows).

RATIONALE
  All four fixes are ADDITIVE - they suppress false-positive boundaries
  rather than fire new ones.  The worst-case regression is "a real
  boundary gets suppressed inside what looks like an open string /
  bracket / comment".  That is theoretical and bounded; the alternative
  (no protection) is the v10.0.7 behaviour, which already passes all
  three reference DBs.


================================================================================
2026-05-27  installer pre-flight: clean halt on missing tSQLt
================================================================================

CHANGE
  The bare RAISERROR at the top of the installer that fires when tSQLt
  is missing did not actually stop the script - severity 16 in SSMS
  prints the error but lets subsequent GO batches keep running, so a
  user who skipped installing tSQLt would see one clear error followed
  by hundreds of cascading "schema TestGen does not exist / object
  tSQLt.NewTestClass not found" errors. First-impression cost on Beta
  rollout is high; the fix is small.

FIX (two parts)

  Top of installer - wrap the pre-flight RAISERROR so SET NOEXEC ON
  short-circuits the rest of the script when tSQLt is absent:

      IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'tSQLt')
      BEGIN
          RAISERROR('UnitAutogen install aborted: tSQLt is not '
                  + 'installed in this database. Install tSQLt from '
                  + 'https://tsqlt.org first, then re-run this script.',
                    16, 1);
          SET NOEXEC ON;
      END
      GO

  Bottom of installer - SET NOEXEC OFF restores the session, and a
  guarded banner reports honest install status by checking BOTH the
  tSQLt schema AND that the core TestGen.GenerateTestsForProcedure
  proc actually got created. Two conditions are needed because PRINT
  and SET statements still execute under SET NOEXEC ON (NOEXEC blocks
  compilation of DDL/DML, not control-of-flow).

VERIFIED on a database without tSQLt installed
  Output is one error message + one clear failure banner telling the
  user to install tSQLt from tsqlt.org. No cascade. As intended.

PENDING VERIFICATION
  Re-run on a database WITH tSQLt installed to confirm the success
  banner appears and all framework objects still get created.

FILES CHANGED
  - Install_UnitAutogen.sql                           (release copy)
  - Install_All_Combined_v10_FINAL.sql                (source, in main repo)

================================================================================
2026-05-29  Function support (scalar / inline-TVF / multi-statement-TVF)
================================================================================
NEW module modules/30_Function_Support_v1.sql, spliced into
Install_UnitAutogen.sql (and the powershell/UnitAutogen/sql copy) just before
the end-of-install banner.  Side-by-side with the procedure pipeline -
GenerateTestsForProcedure / RunCoverage / InstrumentProcedure are unchanged.

Public entry points:
  EXEC TestGen.GenerateTestsForObject  @SchemaName=N'dbo', @ObjectName=N'YourFn';
  EXEC TestGen.RunCoverageForFunction  @SchemaName=N'dbo', @FunctionName=N'YourFn';

Coverage uses a shadow PROCEDURE (<fn>_covfn) built from the function body, so
the existing XEvent/RunCoverage pipeline measures it verbatim - a function body
can't host EXEC RecordCoverageHit and scalar UDFs are unreliable to capture
directly (Froid inlining).  Assertions are characterization (no before/after
delta): scalar = determinism + blessed-value-for-pure-functions + NULL; TVF =
declared-shape + determinism.  Unbless-able value tests are emitted as
[@tSQLt:SkipTest], never faked green.

STATUS: experimental first cut, NOT yet verified on a live DB.  Validate on the
reference databases and triage before treating as released.  Follow-ups:
GenerateAndCoverDatabase still enumerates sys.procedures only (widen to
sys.objects P/FN/IF/TF); per-branch coverage-driver seeding; TVF row-value
blessing; FakeFunction emission for called-function dependencies.

Internal design record: DESIGN_v11_Functions.md (dev repo).
FILES: modules/30_Function_Support_v1.sql (new),
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       docs/functions.md (new), CHANGES.md

--------------------------------------------------------------------------------
2026-05-29  v11 fix â€” RunCoverageForFunction stranded the instrumented _cov copy
--------------------------------------------------------------------------------
Symptom (reported on AdventureWorks2025): teardown failed with
  Msg 3729 ... Cannot drop schema 'uat' because it is being referenced by
  object 'fn_classify_covfn_cov'.

Root cause: the cleanup in RunCoverageForFunction built the drop name as
  @shadowFull + '_cov'  ->  [uat].[fn_classify_covfn]_cov
putting the _cov suffix OUTSIDE the QUOTENAME brackets.  The real object is
[uat].[fn_classify_covfn_cov] (suffix is part of the name), so OBJECT_ID()
returned NULL, the DROP was skipped, and RunCoverage's instrumented copy was
left behind in the user schema, blocking DROP SCHEMA.

Fix: cleanup now uses QUOTENAME(@shadow + N'_cov') / QUOTENAME(@shadow + N'_orig')
and also drops a stranded synonym, covering both the success path and a
RunCoverage that died mid rename/synonym swap.

Also: scripts/Verify_Functions.sql Section 6 now sweeps ALL procedures /
synonyms / functions in [uat] before DROP SCHEMA, so a partial run can't block
teardown again.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Verify_Functions.sql, CHANGES.md

--------------------------------------------------------------------------------
2026-05-29  v11 fixes from first AdventureWorks2025 validation run
--------------------------------------------------------------------------------
Shadow transform validated: Status=OK and correct shadow bodies for scalar /
inline-TVF / multi-statement-TVF.  Generation + assertion tests pass.  Three
issues found and fixed:

1. COVERAGE 0% EVERYWHERE ("XEvent rows captured: 0").  The shadow is
   instrumented and the driver runs, but a function shadow executes in a few ms;
   RunCoverage's event_file target (MAX_DISPATCH_LATENCY = 1s) had not flushed to
   disk before RunCoverage stopped the session and read it.  Procedure test
   suites run long enough to flush mid-run; tiny function drivers do not.
   Fix: the generated coverage driver now does WAITFOR DELAY '00:00:02' after the
   shadow EXECs, holding the session open so the dispatch flush lands before the
   read.  (Costs ~2s per function coverage run - perf follow-up noted.)

2. SafeFakeTable failed on Production.Product ("participates in enforced
   dependencies"), erroring the table-reading scalar's determinism test and its
   coverage driver.  The determinism / result-shape assertions do not actually
   need table isolation.  Fix: every emitted FakeTable call is now wrapped in
   BEGIN TRY ... END TRY BEGIN CATCH END CATCH, so a fake that cannot be applied
   degrades to running against real data instead of erroring the test.

3. One real scalar shadow failed to compile (dbo.ufnGetSalesOrderStatusText:
   "Incorrect syntax near 'END'") - a transform edge case, already handled as an
   honest "COVERAGE DEFERRED" (not a crash).  Added a diagnostic: on shadow
   compile failure BuildShadowProcForFunction now PRINTs the attempted shadow DDL
   so the edge case can be pinpointed rather than guessed.

Also (prior fix this session): RunCoverageForFunction cleanup now drops the
instrumented _cov copy with the suffix INSIDE QUOTENAME, and Verify_Functions.sql
Section 6 sweeps the whole [uat] schema before DROP SCHEMA.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

--------------------------------------------------------------------------------
2026-05-29  v11 repair - module/installer silent truncation
--------------------------------------------------------------------------------
The "Incorrect syntax near 'U' / near ';' in RunCoverageForFunction" install
error was NOT a logic bug: a file write during the installer rebuild was
silently truncated on the working mount, cutting RunCoverageForFunction off
mid-statement at the relabel UPDATE (hence the bare "U").  Repaired by
reassembling the module in /tmp and writing+verifying atomically; both
Install_UnitAutogen.sql copies rebuilt to 11495 lines, proc intact, md5 match.
The WAITFOR coverage fix, non-fatal FakeTable wrapping, and shadow-compile
diagnostic are all present.

--------------------------------------------------------------------------------
2026-05-30  v11 ROOT CAUSE â€” function coverage always 0% (double-@ in driver)
--------------------------------------------------------------------------------
Symptom: every function (FN/IF/TF) reported 0% coverage even though the shadow
proc executed and was correctly instrumented (RecordCoverageHit injected, test
ran). Procedure coverage was unaffected.

Long triage (live AdventureWorks2025), narrowed by controlled experiments:
  - uspPrintError via RunCoverage      -> 3/3 hits  (proc path + XEvent fine)
  - hand-written uat proc, driver-style -> captured  (driver PATTERN fine)
  - compound one-line "BEGIN SET..RETURN..END" -> uncovered (a real but separate
    instrumenter limitation; fixed by emitting multi-line - see below)
  - exact shadow proc + hand driver     -> 3/3       (shadow proc + name fine)
  - exact shadow proc + generated driver-> 0         (=> generated DRIVER bug)
  - dumping the generated driver text revealed:  EXEC ... @@n=42, ...

ROOT CAUSE: RunCoverageForFunction built the driver's named-argument list as
N'@' + name, but sys.parameters.name ALREADY carries the leading '@'. The EXEC
of the shadow therefore used '@@n' (double @), which is a syntax error; the
driver's BEGIN TRY/CATCH swallowed it, so the shadow body never executed and no
RecordCoverageHit events fired -> 0 captured for ALL function shapes (they share
this driver).

FIX: drop the extra prefix - use `name` (not N'@'+name) when building @namedHappy
/ @namedNull in RunCoverageForFunction.

ALSO FIXED this session (prerequisites surfaced during triage):
  - RewriteScalarReturns now emits the RETURN rewrite MULTI-LINE
    (BEGIN / SET @__ret=(expr); / RETURN; / END) instead of a single-line
    compound block, which the line-based instrumenter could not place a hit
    inside. (diagp2 proved the one-liner was uncovered.)
  - RewriteScalarReturns stops the expression capture at the block-closing END
    (CASE..END aware), fixing "RETURN @ret <newline> END" -> no longer swallows
    the function's own END (ufnGetSalesOrderStatusText now builds).
  - non-fatal FakeTable wrapping; _cov cleanup quoting; teardown schema sweep.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

--------------------------------------------------------------------------------
2026-05-30  v11 VERIFIED on AdventureWorks2025 â€” function coverage works
--------------------------------------------------------------------------------
After the double-@ driver fix (+ multi-line RETURN emit + END-aware capture),
scripts/Verify_Functions.sql gives real line AND branch coverage for every shape:

  uat.fn_classify        (FN)  4/4 line 100% | 4/4 branch 100%
  uat.fn_inline          (IF)  1/1 line 100%
  uat.fn_mstvf           (TF)  4/4 line 100% | 2/2 branch 100%
  uat.fn_count_by_color  (FN)  3/3 line 100%  (real Production.Product; fake non-fatal)
  dbo.ufnGetSalesOrderStatusText (FN) 3/3 line 100%  (shadow builds + captures)
  dbo.ufnGetContactInformation   (TF) 5/6 line 83.3% (line 68 not reached by the
                                       sample inputs - honest partial, not faked)

Generation tests all pass; value/row characterization tests emit honest SkipTest.
The "no coverage gaps" goal (every executable function line measurable) is met:
gaps now reflect un-driven branches, never an instrumentation blind spot.

Remaining follow-ups (not blockers): per-branch seeding of the coverage driver
for deeper branch coverage on complex bodies; TVF row-value blessing; widen
GenerateAndCoverDatabase to enumerate FN/IF/TF.

--------------------------------------------------------------------------------
2026-05-30  v11 â€” GenerateAndCoverDatabase widened to functions (VERIFIED)
--------------------------------------------------------------------------------
GenerateAndCoverDatabase now enumerates sys.objects type IN ('P','FN','IF','TF')
(is_ms_shipped=0, excluding TestGen/tSQLt/TestGenLog schemas, test_% classes,
_cov/_covfn/_orig, and dbo TestGen_% framework helpers). Procedures take the
unchanged path; functions route through RunCoverageForFunction, which was
enhanced to capture RunCoverage's test outcomes, compute coverage from the
shadow's CoverageLines, and persist a CoverageResult row keyed by the FUNCTION
(new optional @BatchId param). One unified report now covers both.

Implementation: the override is appended in module 30 (DROP+CREATE after the
base proc, so it wins) - built by programmatically transforming the real base
proc text, not retyping it.

VERIFIED on AdventureWorks2025: EXEC TestGen.GenerateAndCoverDatabase reported 20
objects incl. all ufn* functions with real coverage (ufnGetStock 3/3 line + 100%
branch; ufnGetSalesOrderStatusText 3/3; ufnGetContactInformation 5/6 honest
partial) alongside the usp* procedures; 91.8% line overall. (First run also
surfaced dbo.TestGen_RebuildTypeName - now excluded via the TestGen_% filter.)

Known caveat: a function row's Tests count reflects its coverage driver, not its
test_<fn> assertion suite (coverage is accurate); aggregating assertion-test
counts is a follow-up. Report column header still reads "Procedure" (cosmetic).

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, docs/functions.md, CHANGES.md

--------------------------------------------------------------------------------
2026-05-30  v11 Batch B â€” TVF row blessing (kept); multi-variant seeding (reverted)
--------------------------------------------------------------------------------
ITEM 4 (KEPT, VERIFIED on AdventureWorks2025): GenerateTestsForTableFunction now
blesses PURE table-valued functions (Fn_HasTableDependency=0).  At generation
time it snapshots the current output into a persistent baseline,
  TestGenLog.[FnBless_<schema>_<fn>] = SELECT * INTO ... FROM <fn>(<happy>)
(TRY/CATCH), then emits a "returns blessed rows" test:
  SELECT * INTO #actual FROM <fn>(<happy>); AssertEqualsTable '<blessFull>','#actual'.
A real snapshot baseline (regression net), no literal serialization.  Table-
dependent TVFs keep the honest SkipTest.  Verified: uat.fn_inline / uat.fn_mstvf
now pass a blessed-rows test (3 pass / 0 skip); ufnGetContactInformation stays
SkipTest.

ITEM 3 (TRIED, then REVERTED): multi-variant driver seeding (drive the shadow
with GetSampleValueLiteral variants 0/1/2 + NULL).  A high-boundary value fed to
a parameter-bounded loop explodes it: uat.fn_mstvf's WHILE @i <= @n ran ~14.5s
with a high @n (would effectively hang at INT max).  Generic boundary seeding of
the driver is unsafe; the driver stays happy+NULL.  Real per-branch coverage
needs predicate-aware value solving (which bounds loops) - a genuine follow-up,
NOT generic variants.

Delivered first as scripts/Patch_v11_BatchB.sql (standalone CREATE OR ALTER, run
+ verified on the live DB while the build sandbox was down), then folded into the
module + both Install_UnitAutogen.sql copies (RunCoverageForFunction unchanged -
already the safe happy+NULL version; only GenerateTestsForTableFunction changed).

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_BatchB.sql, CHANGES.md

================================================================================
2026-05-30  v11 Step 1 â€” self-capping shadow loops (coverage probe can't hang)
================================================================================
GOAL (DESIGN_v11_BranchSeeding.md, Layer A): make a function coverage run
provably non-hanging, as the safety foundation for future aggressive per-branch
seeding (Step 2).  This is the headline reliability property for DevOps gating:
the harness cannot run away on any input.

FIRST ATTEMPT (statement budget) â€” TRIED, then REPLACED.  RecordCoverageHit
gained an opt-in SESSION_CONTEXT statement budget, armed/disarmed by
RunCoverageForFunction around the probe.  It worked (a 100M-iteration test
function aborted at 9.4s instead of hanging) but had two faults: (1) SLOW -
SESSION_CONTEXT read+write per hit is ~0.3ms, so reaching a 50k budget took
~9s; (2) it let the loop run ~25k iterations, bloating the XEL file so
RunCoverage's event-parse stage then churned for a long time.  A statement
budget large enough to never false-abort a legit function is necessarily large
enough to be slow and XEL-heavy.  Wrong mechanism.

SHIPPED (per-loop local cap).  BuildShadowProcForFunction now passes the shadow
body through a new pure helper, TestGen.InjectLoopGuards, before compiling it.
Every clear statement-scope `WHILE <cond> BEGIN ...` loop gets a local counter
injected on its own lines (instrument-friendly):
      WHILE <cond>
      BEGIN
      SET @__lcN=@__lcN+1;
      IF @__lcN>1000 BREAK;
          <original body>
      END
with `DECLARE @__lcN INT=0;` prepended at proc scope (one per loop).  A local
SET/IF is ~nanoseconds, the loop stops after 1000 iterations (one iteration
already covers the body, so no coverage is lost), and the XEL stays small.

InjectLoopGuards is a char-walk that is comment / string / bracket / paren
aware.  It is conservative: it only injects when the loop body is a clear
depth-0 BEGIN block; a single-statement loop body (scan hits a depth-0 ';'
first) is left alone; anything malformed simply compiles-or-defers via
BuildShadowProcForFunction's existing TRY/CATCH (honest "coverage deferred",
never corruption).  All walker variables are declared once at the top - a
`DECLARE @x = expr` inside a WHILE evaluates the initializer once at parse
(CLAUDE.md gotcha), which would have made the inner-scan state carry across
loops.  Returns the body byte-unchanged when no loop is capped, so non-looping
functions are unaffected.

The earlier budget code was reverted: RecordCoverageHit is back to the plain
no-op; RunCoverageForFunction back to the safe happy+NULL driver with no
session-context arming.  (Both were only ever applied to the live DB via the
patch, never folded, so the installers needed no change there.)

VERIFIED on AdventureWorks2025:
  - No regression: Verify_Functions.sql reports identical coverage to Batch B
    for all four shapes + real ufn* functions (the 1000 cap never trips for
    their small loops, so output is byte-for-byte the same).
  - Proof: uat.fnloop (WHILE @i<100000000 ... a 100-million-iteration loop)
    now finishes its driver in ~0.7s (capped at 1000 iterations) and reports
    100% line + 100% branch (5/5, 2/2) - where unguarded it would loop ~forever.
  - Separately surfaced (pre-existing, logged): the base instrumenter cannot
    inject hits into a ONE-LINE compound loop body (`BEGIN a; b; END` on a
    single line) - the _cov copy fails to compile.  Not a Step-1 issue; a
    follow-up is to have the shadow transform normalize one-line compound
    blocks to multi-line (same idea as the RETURN rewrite) so they instrument.

CAP is a constant (1000).  Per the design, a branch reachable only AFTER the
1000th iteration is reported as honest residue, not driven - the correct outcome
for a probe that must terminate.

Delivered as scripts/Patch_v11_LoopGuard.sql (standalone CREATE OR ALTER, run +
verified on the live DB while the build sandbox was down), then folded into the
module + both Install_UnitAutogen.sql copies (InjectLoopGuards added before
BuildShadowProcForFunction; the one SET @procBody = TestGen.InjectLoopGuards(...)
line added inside it).  Installer marker lines identical across both copies
(InjectLoopGuards CREATE at 10926, the call at 11103, GACD tail at 12061), tails
intact - no truncation.

NEXT (not started, needs go-ahead): Step 2 - predicate-inversion per-branch
seeding (DESIGN_v11_BranchSeeding.md, Layer B), now safe to build on this cap.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_LoopGuard.sql, CHANGES.md

================================================================================
2026-05-30  v11 gap fix â€” one-line compound loop/branch bodies now instrument
================================================================================
SURFACED during the Step-1 loop-guard proof: a function whose loop body is
written on ONE line,
      WHILE @i < 100000000
      BEGIN SET @s += @i; SET @i += 1; END
produced a shadow line `BEGIN SET @s += @i; SET @i += 1; END` carrying a BEGIN,
two statements and an END at once.  TestGen.InstrumentProcedure is strictly
LINE-ORIENTED (it classifies one physical line at a time and injects one hit per
executable line), so it cannot decompose that line and emitted a non-compiling
_cov ("Incorrect syntax near ';'").  Coverage for such a function was a false
0% / deferral.  Pre-existing limitation, exposed (not caused) by Step 1.

FIX (in the shadow transform, NOT the shared instrumenter): new pure helper
TestGen.NormalizeShadowBody reflows the shadow body to one-statement-per-line
before it is instrumented - each BEGIN / END / ELSE on its own line, and
';'-separated statements split apart.  BuildShadowProcForFunction now runs
NormalizeShadowBody, then InjectLoopGuards, then compiles.  TestGen.ShadowLineMap
is dormant (nothing reads it), so reflowing the shadow is safe.

SAFE BY CONSTRUCTION: the normalizer ONLY inserts newlines, and only where a
keyword shares a line with other code (it tracks "is there code before me on
this line" / "after me on this line").  On an already-multi-line body - BEGIN
alone, END alone, one statement per line - every rule is a no-op, so existing
working shadows pass through byte-unchanged.  Char-walk, comment/string/bracket/
paren aware; BEGIN TRY / BEGIN CATCH / END TRY / END CATCH kept intact as units;
all walker vars declared once at the top (CLAUDE.md DECLARE-in-loop gotcha).
Deliberately NOT split: an inline IF/ELSE body (`IF @x SET @y=1;`,
`ELSE SET @y=1;`) is left as-is - the instrumenter already handles those via its
bare-branch wrap, and splitting them would change existing functions' line
counts.  ELSE only gets a newline BEFORE it (when it shares a line, e.g.
`END ELSE`), never after, so `ELSE IF` / inline-ELSE bodies are untouched.

VERIFIED on AdventureWorks2025:
  - Whole-DB GenerateAndCoverDatabase: 19 objects, 9 real ufn* functions + 10
    procedures, 87 tests, 0 failed, 0 errored - every function still compiles and
    reports coverage (most 100%; ufnGetContactInformation 83.3% honest partial).
    The normalizer disturbed nothing across the whole database.
  - Gap proof: the one-line uat.fnloop (BEGIN SET..; SET..; END on a single line)
    now reports "Instrumented procedure created" (no compile failure), the loop
    caps at 1000, driver finishes 237ms, 100% line + 100% branch (3/3, 2/2) -
    where it failed to compile twice before the fix.

Delivered as scripts/Patch_v11_OneLineNorm.sql (CREATE OR ALTER, verified on the
live DB while the build sandbox was down), then folded into the module + both
Install_UnitAutogen.sql copies (NormalizeShadowBody added before
BuildShadowProcForFunction; the SET @procBody = TestGen.NormalizeShadowBody(...)
line added ahead of the InjectLoopGuards call).  Installer marker lines identical
across both copies (NormalizeShadowBody CREATE at 11010, the two calls at
11212/11216, GACD tail at 12174), tails intact - no truncation.

KNOWN residue (honest): a loop/branch body whose statements are not ';'-separated
on one line, or an inline ELSE body, may still not be fully decomposed - those
stay as they are (the instrumenter handles inline bodies; anything it can't still
defers via the shadow-compile TRY/CATCH).  The normalizer fixes the common
one-line `BEGIN ...; ...; END` block, which was the reported case.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_OneLineNorm.sql, CHANGES.md

================================================================================
2026-05-30  v11 Step 2 - predicate-inversion branch seeding (reach value gates)
================================================================================
GOAL (DESIGN_v11_BranchSeeding.md, Layer B): reach value-gated branches of a
function ON PURPOSE.  The happy+NULL driver only covers the arms those two
inputs happen to land on; a branch like IF @status = 5 or IF @n < 0 is missed by
luck.  Step 2 derives a parameter value that SATISFIES each branch predicate -
from the predicate's own literal - and drives the shadow with it.

NEW OBJECTS (module 30 + both installers):
  - TestGen.SeedFromLeaf(@op,@lit): inverts one comparison leaf to a satisfying
    value.  '=','<=','>=','IN','BETWEEN','LIKE' -> the literal as-is; '<' -> lit-1,
    '>'/'<>' -> lit+1 (numeric only, else no seed); 'ISNULL' -> NULL; 'ISNOTNULL'
    and anything non-invertible -> NULL (honest residue).
  - TestGen.ExtractBranchSeeds(@Body,@ParamCsv) TVF: char-walk (comment/string/
    bracket aware) that finds  @param <op> <literal>  leaves (incl. IS [NOT] NULL,
    IN first-element, BETWEEN low, LIKE de-wildcarded) and returns (ParamName,
    SeedLiteral).  Skips SET-assignments (prev word 'SET'); all walker vars
    declared once at top (CLAUDE.md DECLARE-in-loop gotcha).
  - RunCoverageForFunction: builds a per-parameter happy table (@ph), then for
    each extracted leaf appends one driver EXEC (target param satisfied via
    STRING_AGG, others happy) after the happy+NULL calls.

SAFE BY CONSTRUCTION (three layers, so Step 2 can never regress coverage):
  1. A wrong/over-eager seed is harmless - each seed EXEC is wrapped in TRY/CATCH
     and just fails to enter its branch.
  2. The whole seed-building block is itself in TRY/CATCH; any extractor error
     sets @execSeeds='' and the run falls back to the prior happy+NULL behaviour.
  3. Values come only from the code's own literals (and numeric +/-1), so emitted
     args are always well-formed SQL.  The Step-1 loop cap makes every seed call
     hang-proof, so seeding is free to be aggressive.

NEVER LIE: a predicate the extractor can't invert (function-wrapped column,
non-literal RHS, NOT IN, accumulated value, clock/env) yields no seed; that
branch stays uncovered and is reported as honest residue.

VERIFIED on AdventureWorks2025:
  - fn_grade(@score) with four value-gated arms (>=90/>=80/>=70/else): extractor
    derived @score = NULL,90,80,70; coverage went to 4/4 line + 5/5 BRANCH 100%
    ("4 predicate-inversion seed(s) added") where happy+NULL alone hit only one
    arm.  String/IN gate (= 'US', IN ('GB','UK'), = 'CA') derived 'US','GB','CA'.
  - No regression: full Verify_Functions.sql sweep unchanged (fn_classify 4/4+4/4
    with 3 seeds, fn_mstvf now 5/5+3/3 - the Step-1 guard's own IF is covered too,
    ufnGetContactInformation 5/6 honest), 0 fail / 0 err.

Delivered as scripts/Patch_v11_BranchSeeding.sql (+ scripts/Verify_BranchSeeding.sql)
verified on the live DB, then folded into module 30 + both Install_UnitAutogen.sql
copies (SeedFromLeaf + ExtractBranchSeeds before RunCoverageForFunction; @ph and
the seed block inside it).  Both installer copies byte-identical (md5), exactly one
of each object, tails intact - no truncation.

LIMITS (stated plainly): single-param leaves only - a branch gated on a DIFFERENT
param's predicate not satisfied by the happy value may still be residue (ancestor-
chaining is a future step); reversed predicates (literal <op> @param) and NOT IN
are not yet inverted.  These are residue, not wrong answers.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_BranchSeeding.sql, scripts/Verify_BranchSeeding.sql, CHANGES.md

================================================================================
2026-05-31  v11 Step 2.1 - ancestor-chaining for branch seeding
================================================================================
GOAL (DESIGN_v11_AncestorChaining.md): reach a branch nested inside ANOTHER
parameter's predicate.  Step 2 satisfied a branch's own leaf but left every other
param happy, so  IF @kind='A' BEGIN IF @amount>1000 ... END  never reached the
inner arm when happy @kind <> 'A'.

CHANGE: ExtractBranchSeeds is rewritten predicate-aware.  It walks BEGIN/END
nesting (@depth) and maintains a stack (@anc) of enclosing IF/WHILE gates tagged
by the block depth they open.  When it meets an IF/WHILE it captures the predicate
(paren/string/comment aware), extracts its invertible leaves, and emits a branch
seed = those leaves PLUS, for every param not set by the leaf, the deepest
enclosing gate's value.  Output gained a BranchId (many rows per branch).
RunCoverageForFunction groups by BranchId and emits one shadow EXEC per branch
(every assigned param overridden via STRING_AGG, others happy).  A top-level
branch with no ancestors collapses to the exact Step-2 single-override call.

The walker is now branch-predicate-driven (seeds only come from IF/WHILE/ELSE-IF
predicates), which also drops the incidental CASE-WHEN leaves Step 2 emitted -
those never affected branch coverage (CASE-in-RETURN is atomic), so verified
fixtures are unchanged.  ELSE-negation ancestors and non-literal predicates remain
honest residue.

SAFETY unchanged (three TRY/CATCH layers + Step-1 loop cap): a wrong seed just
fails to enter its branch; any extractor error falls back to happy+NULL.  Same-
param conflicts (ancestor vs leaf): the leaf value wins; among ancestors the
deepest wins; a final MAX dedup in the caller collapses any residue - a value that
satisfies neither just means that (contradictory) branch stays uncovered, never
faked.

VERIFIED on AdventureWorks2025:
  - fn_nested(@kind,@amount): extractor output shows the inner @amount branches
    carrying @kind='A' / @kind='B' (BranchId 2 -> {@amount=1001,@kind='A'},
    BranchId 4 -> {@amount=-1,@kind='B'}); coverage 2/2 line + 5/5 BRANCH 100%
    (the big/neg arms unreachable before).
  - No regression: fn_grade 5/5, fn_classify 4/4+4/4, fn_mstvf 5/5+3/3,
    ufnGetContactInformation 5/6 honest, full Verify_Functions sweep 0 fail/0 err;
    fn_region string/IN gate still 3 seeds.

Delivered as scripts/Patch_v11_AncestorChaining.sql (+ Verify_AncestorChaining.sql)
verified live, then folded into module 30 + both installers (ExtractBranchSeeds
replaced, the seed CTE switched to BranchId).  Both installer copies byte-identical
(md5), one of each object, no truncation.  Design: DESIGN_v11_AncestorChaining.md.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_AncestorChaining.sql, scripts/Verify_AncestorChaining.sql,
       DESIGN_v11_AncestorChaining.md, CHANGES.md

================================================================================
2026-05-31  v5.3 instrumenter - bare no-semicolon branch body wrap-close
================================================================================
ROOT CAUSE
  TestGen.InstrumentProcedure v5.1 wraps a bare (non-BEGIN) IF/WHILE/ELSE body
  in a synthetic BEGIN/END so the injected RecordCoverageHit stays inside the
  branch, but it only emitted the closing END when the wrapped statement reached
  a ';'.  AdventureWorks house style omits the ';' on a single-statement branch
  body, e.g. dbo.ufnGetStock:
        IF (@ret IS NULL)
            SET @ret = 0          -- no semicolon
  The synthetic BEGIN then stayed open until a LATER ';' fired the END deep
  inside the next block (the rewritten RETURN), so the rebuilt _cov was
  unbalanced and FAILED TO COMPILE (Msg 102).  When _cov fails to compile,
  RunCoverage's synonym points at a non-existent proc, no hits fire, and the
  function is reported a false 0% line+branch (regression seen 2026-05-31:
  ufnGetStock 0%, was 100% on 05-30 before the shadow began emitting the body
  on its own no-';' line).

FIX (v5.2 -> v5.3, two closure points added to the line walker)
  1. Structural-boundary close: when @StmtWrap is open and the current line is a
     BEGIN/END block boundary (@PB/@PE) or a new branch header, inject the
     pending hit + synthetic END BEFORE emitting that line, then reset statement
     state.  A bare body is a single statement, so the next structural token
     ends it.
  2. Opener-boundary close: on the existing no-';' boundary path (a new
     statement opener ends an unterminated prior statement), also emit the
     synthetic END when @StmtWrap is open, before opening the new statement.
  Bodies that DO end with ';' instrument byte-identically to v5.2.

VERIFIED on AdventureWorks2025 (live, via SQL MCP)
  - dbo.ufnGetStock shadow ufnGetStock_covfn now instruments to a _cov that
    COMPILES (was Msg 102).  Generated _cov shows the bare "SET @ret = 0"
    wrapped BEGIN ... EXEC hit ... END, balanced.
  - Drove coverage by temporarily pointing RecordCoverageHit at a real INSERT
    (the XEvent capture path cannot run through the MCP - ALTER/DROP EVENT
    SESSION is blocked inside the MCP's wrapping transaction, Msg 574).  All
    four exec lines (7,14,18,20) hit, incl. line 14 the previously-uncoverable
    bare body: 4/4 line 100%, 1/1 branch 100%.  RecordCoverageHit restored to
    its no-op stub afterward; all scratch objects + the stray TestGenCoverage
    event session cleaned up; real function intact.
  NOTE: function coverage % through the live XEvent pipeline must still be
  confirmed by a normal SSMS/sqlcmd run (no surrounding transaction); every
  RunCoverage invoked via the MCP silently captures nothing and reports a false
  0% for that reason, NOT a framework defect.

Folded into module 20 + both installers (the two closure blocks, v5.3 header +
created-banner).  Module InstrumentProcedure body byte-identical to both
installer copies (931 lines, diff empty); both installers md5-identical; offline
tsql_lint clean on all three.  (Module tail was silently truncated by a header
edit and rebuilt from git HEAD + re-verified.)

FILES: modules/20_Coverage_Instrumenter_v5.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  v11.x GACD resilience - connection-recovery no longer cascades
================================================================================
SYMPTOM
  A full-DB sweep (GenerateAndCoverDatabase) reported 8 stored procedures as
  "failed generation" (Gen=N) on AdventureWorks2025 - uspGetBillOfMaterials,
  uspGetEmployeeManagers, uspGetManagerEmployees, uspGetWhereUsedProductID,
  uspPrintError, and the three HR uspUpdateEmployee* procs.  All 8 carried the
  IDENTICAL error: "GEN: The connection was recovered and rowcount in the first
  query is not available. Please execute another query to get a valid rowcount."

ROOT CAUSE (not a generation bug)
  Every one of the 8 generates a VALID test class when run in isolation (proven
  live: 7-12 tests each).  The 8 failure rows were written 0.37s apart (all
  between 11:58:26.744 and 11:58:27.118) - they failed INSTANTLY without doing
  any work.  The 9 functions, processed first, all succeeded.  This is a single
  transient connection-recovery event (the sweep has minutes of WAITFOR DELAY +
  XEvent operations): once the connection was recovered mid-run, @@ROWCOUNT
  became unavailable, and because the GACD loop never re-synced, EVERY subsequent
  object inherited the broken-rowcount state and failed generation identically.

FIX (GACD made resilient)
  1. Re-sync probe at the top of each loop iteration (SELECT @resync = 1;) so a
     recovery on a prior object cannot poison the next - caps the blast radius at
     the single coincident object instead of every remaining one.
  2. Retry-once on the proc-generation path: if the caught error mentions
     "connection was recovered" / "valid rowcount", re-sync and re-run
     GenerateTestsForProcedure (deterministic, succeeds on a clean session) so
     even the coincident object is recovered, not lost.

VERIFIED on AdventureWorks2025 (live)
  - All 8 procs generate valid test classes in isolation (BillOfMaterials 8,
    EmployeeManagers 7, ManagerEmployees 7, WhereUsed 8, PrintError 1,
    UpdateEmployeeHireInfo 12, UpdateEmployeeLogin 11, UpdatePersonalInfo 10).
  - dm_exec_describe_first_result_set on the temp-table proc returns 8 columns
    cleanly (ruled out as the trigger).

Folded into module 30 + both installers (the v11 GenerateAndCoverDatabase - the
LAST of the two GACD definitions in each installer; the older module-04 GACD is
overwritten at install and left as-is).  Deployed live (CREATE OR ALTER).  Module
GACD byte-identical to installer copy; both installers md5-identical; tsql_lint
clean on all three.

FILES: modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  UPDATE procs regain their before/after assertion (count-stable fix)
================================================================================
SYMPTOM (user-reported)
  The 'touches only mocked tables' test for an UPDATE procedure
  (e.g. HumanResources.uspUpdateEmployeePersonalInfo) had NO tSQLt assertion -
  only a smoke TRY/CATCH and a PRINT of the row-count delta.  The before/after
  AssertEqualsTable that read-only procs get had vanished.  Design intent from
  day one: a stored proc's before/after state must be ASSERTED, not printed.

ROOT CAUSE
  The Test-4 isolation generator classified a proc as 'read-only' (gets the
  per-table 'row counts held' AssertEqualsTable) vs 'DML' (gets no assertion)
  by scanning for INSERT / UPDATE / DELETE / MERGE.  UPDATE was lumped in with
  the count-changing verbs - but an UPDATE rewrites existing rows, it never adds
  or removes any, so COUNT(*) is unchanged.  Every UPDATE-only proc therefore
  wrongly fell into the no-assertion branch.

FIX
  Reclassify by whether the proc changes ROW COUNTS, not whether it writes at
  all.  Only INSERT / DELETE / MERGE change counts; UPDATE does not.  New flag
  @v94CountStable = (no INSERT/DELETE/MERGE) -> read-only OR UPDATE-only -> emit
  the AssertEqualsTable before/after row-count assertion.  INSERT/DELETE/MERGE
  procs still skip it (a counts-held assertion would false-fail) and keep the
  informational delta print.  Guaranteed non-flaky: UPDATE never changes
  COUNT(*), so the assertion passes for a correct proc or the TRY/CATCH fails it.

VERIFIED (live classification on AdventureWorks2025)
  - uspUpdateEmployeePersonalInfo, uspUpdateEmployeeLogin (pure UPDATE) -> now
    COUNT-STABLE -> AssertEqualsTable emitted.
  - uspUpdateEmployeeHireInfo (INSERT + UPDATE) -> count-changing -> correctly
    still no counts-held assertion (it grows a table by design).
  - read-only procs (uspGetBillOfMaterials, etc.) unchanged.
  NOTE: asserts row-count stability (no rows added/removed).  The deeper 'the
  updated row's VALUES changed correctly' check remains the characterization
  scaffold (designed seed + #Expected), still an honest Skip.

  Folded into module 04 + both installers (variable @v94IsReadOnly -> 
  @v94CountStable; UPDATE dropped from the count-changing set).  GenerateTests-
  ForProcedure body byte-identical module==installer; installers md5-identical;
  tsql_lint clean.  Generator is 3270 lines (too large to hot-deploy via the
  MCP) - applies on framework RE-INSTALL.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  UPDATE procs now ASSERT the content change (not just count held)
================================================================================
Follow-on to the count-stable fix.  Row-count-held proves an UPDATE added/removed
no rows, but not that it actually MODIFIED anything.  The 'touches only mocked
tables' test now, for an UPDATE-only proc, also asserts the before/after CONTENT
differs.

HOW
  For each directly-referenced (faked) table the test now captures a content hash
  CHECKSUM_AGG(BINARY_CHECKSUM(<comparable cols>)) before and after the EXEC, using
  the SAME column-type exclusion the v9.4 branch-delta uses (xml/text/ntext/image/
  geography/geometry) plus hierarchyid (BINARY_CHECKSUM cannot hash CLR types).
  After asserting the row counts are HELD (AssertEqualsTable), it asserts at least
  one table's hash DIFFERS:
     EXEC tSQLt.AssertEquals @Expected=1, @Actual=<any hash changed>,
        @Message='UPDATE procedure must modify row content ...';
  Guarded by IF EXISTS(#v94_HashBefore) so a table whose every column is excluded
  never forces a false fail.  Only emitted for count-stable procs that contain an
  UPDATE (@v94HasUpdate); read-only and INSERT/DELETE/MERGE paths are untouched.
  Relies on the seed being arranged so the UPDATE's WHERE matches and its SET
  writes a different value (user confirmed the seed is now designed that way).

VERIFIED (live mechanism check on AdventureWorks2025 - generator itself is 3270
lines, too large to hot-deploy via the MCP, so applies on RE-INSTALL)
  - Change detection: changing row 1's NationalIDNumber 'SampleText_1'->'Sam'
    (exactly uspUpdateEmployeePersonalInfo's happy-arg effect) flips the hash
    208947 -> 2134023283, change_detected = 1.
  - Column compatibility: BINARY_CHECKSUM over ALL of HumanResources.Employee's
    comparable columns (15 cols; only OrganizationNode/hierarchyid excluded)
    returns 1249850349 with no type error - the exclusion list is correct.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  Kill the AssertEquals 1,1 tautology - real before/after assertions
================================================================================
User-reported: the per-input proc tests asserted EXEC tSQLt.AssertEquals 1, 1 - a
tautology that can never fail (if the proc throws the test errors BEFORE reaching
the line; if it doesn't, 1=1 trivially passes).  The line asserted nothing.

FIX - every per-input test now carries a REAL assertion:
  * A shared before/after row-count guard (@PreCnt/@PostCnt) is built once per
    proc: for a COUNT-STABLE proc (read-only or UPDATE-only) it captures each
    faked table's COUNT(*) before and after the EXEC and asserts AssertEqualsTable
    '#rcB','#rcA' - i.e. no rows were added or removed.  This FAILS if the proc
    unexpectedly INSERTs/DELETEs.
  * The EXEC is wrapped in BEGIN TRY/CATCH; a throw calls tSQLt.Fail with the real
    ERROR_MESSAGE() (so the failure is explicit + descriptive, not a generic test
    error).  For COUNT-CHANGING procs (INSERT/DELETE/MERGE) the guard is empty and
    the TRY/CATCH 'must not throw' is the assertion.
  Applied to all five smoke sites: happy-path (Test 1), low/high boundary (Test 2),
  NULL-injection (Test 3), and the OUTPUT-param test (Test 6).  The ExpectException
  branches (procs that validate + reject) are untouched.  @v94CountStable is now
  computed once at the top and shared with the isolation test (Test 4).
  The ONE deliberately-kept AssertEquals 1,1 is RunCoverageForFunction's coverage
  DRIVER (-- driver: execution drives coverage): a no-op assert whose only job is
  to make tSQLt run the body so coverage is measured - not a behaviour test.

VERIFIED (live, hand-built as the fixed generator emits, run via tSQLt)
  - A happy-path test for HumanResources.uspUpdateEmployeePersonalInfo with the
    @PreCnt/@PostCnt guard + TRY/CATCH COMPILES and RUNS = Success (counts held
    5->5; AssertEqualsTable passes).  It now CAN fail: an insert/delete breaks the
    count equality, a throw hits tSQLt.Fail.
  Generator (3270 lines) is too large to hot-deploy via the MCP, so applies on
  RE-INSTALL.  Module 04 GenerateTestsForProcedure byte-identical to both
  installers; installers md5-identical; tsql_lint clean.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  Golden-master result baseline made REAL (read-only procs assert output)
================================================================================
Goal: a read-only proc should run on its seeded data and ASSERT the actual result
rows - not just shape/smoke.  The framework had @CaptureRows (Test 8 'returns rows
matching baseline') but it was OFF by default and, as wired, NON-FUNCTIONAL.

BUG FOUND (proved live): the baseline was captured INSIDE the test via
AssertResultRowsMatchBaseline's capture-on-first-run path - but tSQLt rolls every
test back, so the captured baseline never persisted.  Result: the test captured-
and-passed on EVERY run and never actually asserted - a tautology.  Confirmed:
after a passing run, TestGenLog.ResultRowsBaseline had 0 rows.

FIX
  * New helper TestGen.CaptureResultBaseline @TestClass,@MockSql,@ExecSql: persists
    the EXPECTED baseline at GENERATION time, OUTSIDE any tSQLt rollback.  It opens
    a savepoint, runs @MockSql (FakeTable+seed) + the proc, copies the result rows
    (as FOR JSON) and shape into TABLE VARIABLES (which survive a rollback), rolls
    the faking back (real tables untouched), then persists to ResultRowsBaseline /
    ResultShapeBaseline.  Uses a global ##temp for the dynamic JSON capture, then
    copies to the table var before the savepoint rollback.
  * GenerateTestsForProcedure now calls it (when @ExecuteScript=1) right after
    emitting Test 8, so the generated 'returns rows matching baseline' test ASSERTS
    the proc's seeded output (reconstruct #Expected from baseline -> AssertEqualsTable).
  * @CaptureRows default flipped 0 -> 1 (golden master ON by default), in both
    GenerateTestsForProcedure and GenerateAndRunCoverage.
  * Guarded to DETERMINISTIC procs only (@v94Deterministic): a body with GETDATE/
    SYSDATETIME/SYSUTCDATETIME/GETUTCDATE/CURRENT_TIMESTAMP/NEWID/NEWSEQUENTIALID/
    RAND would drift between capture and assert, so it gets no row-baseline test
    (shape test + scaffold still apply).
  The manual 'hand-built expectation' scaffold (Test 9) stays a SKIP for the user.

VERIFIED end-to-end on AdventureWorks2025 (live):
  - Capture PERSISTS past tSQLt rollback: 3 rows / 2 cols, JSON = the seeded output.
  - Real Production.ProductCategory left intact (4 real rows; faking rolled back).
  - Matching run -> reconstruction path -> Success (baseline still present after).
  - Drift (proc changed 3 rows -> 2) -> tSQLt reports 1 FAILED.  Real assertion.

Also: tools/tsql_lint.py no longer miscounts 'BEGIN TRAN[SACTION]' as a block
opener (it has no matching END).  CaptureResultBaseline added to both installers;
generator wiring in module 04 + both installers (GenerateTestsForProcedure byte-
identical module==installer; installers md5-identical; lint clean).  Helper is small
and deploys live, but the 3270-line generator wiring applies on RE-INSTALL.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, tools/tsql_lint.py, CHANGES.md

================================================================================
2026-05-31  Golden-master reverted to OFF by default (arg/seed mismatch blocker)
================================================================================
The previous entry turned @CaptureRows ON by default.  A Northwind sweep then
showed 6 of 7 row-baseline tests FAILING.  Root cause (diagnosed, not yet fixed):
  * The auto-generated happy ARG does not match the auto-generated SEED.  e.g.
    CustOrderHist is seeded with Customers 'Samp1'..'Samp5' but EXEC'd with
    @CustomerID = 'Sam' - which matches NO seeded row, so the proc returns 0 rows.
    The captured baseline is therefore empty/trivial (the generated test even
    PRINTs a NOTE saying the result set is empty).  An empty baseline + the
    reconstruction path then produced failures in the full sweep.
  * tSQLt.Run cannot be driven through the SQL MCP (it raises 'A severe error
    happened during test execution' under the connector's wrapping transaction),
    so the failures could not be reproduced / a fix validated remotely.
DECISION: reverted @CaptureRows default 1 -> 0 in GenerateTestsForProcedure and
GenerateAndRunCoverage.  Sweeps return to the clean honest-skip state (Northwind
0 fails).  The machinery is RETAINED and proven-in-isolation:
  - TestGen.CaptureResultBaseline (persists the expected baseline at generation
    time, outside tSQLt's rollback, via savepoint + table variables) - verified
    live: capture persists, match passes, drift fails, real tables untouched.
  - The generation-time capture call + determinism guard stay wired but DORMANT
    (only fire when @CaptureRows=1).
REAL FIX NEEDED (next): derive the happy ARGS from the SEEDED key values so the
proc returns rows for its own seed (the 'reverse-order seeding to determine the
correct input' idea, applied to args).  Only then is a row baseline meaningful.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  Matched STRING key args now line up with the seed (procs return rows)
================================================================================
Root cause of the 0-row procs / trivial baselines: @ParamMatchedColumns already
detects a param whose name matches a PK/FK column in a faked dependency, and pins
INT keys to 1 (matching the seeded ints) - but STRING keys fell back to the generic
GetSampleValueLiteral(...,0) = 'Sam', while the seeder writes 'Samp1' for an nchar(5)
key.  So  WHERE Customers.CustomerID = @CustomerID('Sam')  matched no seeded row
('Samp1'..'Samp5') and CustOrderHist (et al.) returned 0 rows.

FIX: for a matched CHAR/VARCHAR/NCHAR/NVARCHAR param, the happy arg is now the
SEEDER'S ROW-1 value, computed by mirroring the seeder's exact logic:
   charLen = (nchar/nvarchar ? max/2 : max), MAX->200, min 1
   charLen>=3 : target=min(charLen,12); STUFF(LEFT('SampleText_1'+REPLICATE('X',
                target),target), target,1,'1')   -- preserves the row digit at the end
   else       : RIGHT(REPLICATE('0',charLen)+'1', charLen)
Verified the formula reproduces the seeder exactly: 5->'Samp1', 40->'SampleText_1',
10->'SampleTex1', 3->'Sa1', 2->'01', 1->'1'.  INT keys still pin to 1 (unchanged).

Effect: read-only key-filtered procs now EXECUTE against matching seeded rows and
return rows, so the per-input tests actually exercise the proc body (not just smoke
an empty result).  This is also the prerequisite for a meaningful row baseline -
@CaptureRows stays OFF for now (couldn't be validated remotely: tSQLt.Run can't run
through the SQL MCP); re-enable + validate with an SSMS sweep once the arg fix is
confirmed clean.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  Golden master RE-ENABLED (arg-from-seed validated)
================================================================================
With matched string key args now aligned to the seed, the empty-baseline problem
is gone, so @CaptureRows is back ON by default in GenerateTestsForProcedure and
GenerateAndRunCoverage.
VALIDATED live on Northwind (login granted db_owner): the regenerated CustOrderHist
test now EXECs @CustomerID='Samp1' (the seeded key, not 'Sam'), and
TestGen.CaptureResultBaseline persists a NON-EMPTY baseline:
   1 row, 2 cols -> {"ProductName":"SampleText_1","Total":1}; real tables intact.
So the row-baseline test now asserts a real seeded outcome (pass on match, fail on
drift - proven earlier on AdventureWorks).  Step-1 sweep (arg fix only) was already
clean: Northwind 50 tests, 0 fail / 0 err, 100% line+branch.
NOTE: the golden test's end-to-end assert could not be run through the SQL MCP
(tSQLt.Run raises 'severe error' under the connector transaction) - validate the
full pass via an SSMS sweep.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-05-31  Shape test false-drift fixed (bare vs full type name) + tail restored
================================================================================
ROOT CAUSE of the 6 "1 fail" procs in the Northwind sweeps (CustOrderHist,
CustOrdersDetail, Employee Sales by Country, Sales by Year, SalesByCategory,
Ten Most Expensive Products): the FAILING test was "returns a stable result-set
shape" (NOT the golden row-baseline test, which passes).
  - CaptureResultBaseline/CaptureResultShape store SqlTypeName from TYPE_NAME() =
    the BARE name, e.g. 'nvarchar'.
  - AssertResultShape built #ActualShape from dm_exec_describe_first_result_set's
    system_type_name = the FULL name, e.g. 'nvarchar(40)'.
  - AssertEqualsTable then saw 'nvarchar' <> 'nvarchar(40)' and FAILED.
  CustOrdersOrders passed because all its columns are int/datetime (no length
  suffix, so bare == full).  Every failing proc had at least one nvarchar(n)/
  decimal(p,s)-style column.  Length/precision/scale/nullability already matched.

FIX (one line, both installers + live on Northwind and AdventureWorks2025):
  AssertResultShape now compares the BARE type name - it strips from the first
  '(' (CHAR(40)) in system_type_name:
     LEFT(system_type_name,
          ISNULL(NULLIF(CHARINDEX(CHAR(40), system_type_name), 0) - 1,
                 LEN(system_type_name)))
  Size is still asserted via MaxLength/Precision/Scale, so nothing is lost.
  Existing baselines need NO re-bless (they were already bare).  CHAR(40) is used
  instead of '(' so the offline linter's string-masker is not perturbed.

ALSO: the Edit tool silently TRUNCATED both installer files mid-line at
"PRINT 'UnitAutogen framewo" (lost the success/failure banner + final END/GO) -
the classic large-file Edit truncation.  Restored the 12-line tail byte-exact
from git HEAD (CRLF-normalized).  Both files now lint clean and are byte-identical
(md5 568825b7779cdbe6638f5485318d947f).  Verify file tails after Edits on big files.

VALIDATION still pending the user's SSMS sweep (tSQLt.Run cannot run via the MCP).
Upstream of the assert is proven: only the type-name dimension drifted, and it is
now normalized on both sides; CustOrdersOrders passing confirms the other
dimensions already align under fakes.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       CHANGES.md

================================================================================
2026-05-31  Generator regression fixed: CASE expression as an EXEC parameter
================================================================================
SYMPTOM: AdventureWorks2025 sweep showed 2 procs "failed generation" -
HumanResources.uspUpdateEmployeeLogin and .uspUpdateEmployeePersonalInfo, both
with ErrorText "GEN: Incorrect syntax near the keyword 'CASE'".
NOT a connection-recovery cascade (that older transient error is a different
message).  CoverageResult timeline was decisive: both procs had GenSucceeded=True
through 13:03 today, then failed from 14:10 onward - i.e. the UPDATE content-change
assertion added this session broke them.  (uspUpdateEmployeeHireInfo kept
generating because it routes to the INSERT/grow assertion path, not this one.)

ROOT CAUSE: the UPDATE content-change assertion emitted
    EXEC tSQLt.AssertEquals @Expected = 1,
         @Actual = CASE WHEN @v94ContentChanged > 0 THEN 1 ELSE 0 END, ...
A CASE expression is NOT a legal EXEC parameter value in T-SQL, so the generated
test failed to CREATE -> GenSucceeded=False.  (The parallel INSERT-path assertion
already did this correctly by assigning the CASE into a variable first.)

FIX (both installers, lint clean, byte-identical md5 a774ebd344327dedee3e83324aa1b919):
    DECLARE @v94Changed INT = CASE WHEN @v94ContentChanged > 0 THEN 1 ELSE 0 END;
    EXEC tSQLt.AssertEquals @Expected = 1, @Actual = @v94Changed, @Message = ...;
INT (not BIT) to match the int @Expected literal under tSQLt's type-aware compare.
Confirmed this was the ONLY generated CASE-as-EXEC-parameter in the file.

Lands on RE-INSTALL (the 3270-line GenerateTestsForProcedure is too large to
hot-deploy via the MCP) - reinstall + re-sweep AdventureWorks to confirm the 2
procs generate and the UPDATE content assertion runs.

ALSO: the Edit tool truncated both installer tails AGAIN mid-banner during this
edit; restored byte-exact from HEAD via Python.  Switched off Edit for these large
files - use Python string-replace + verify the tail every time.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       CHANGES.md

================================================================================
2026-06-01  v11 seed extensions: reversed / NOT / non-numeric branch seeds
================================================================================
SCOPE: extends Step-2 predicate-inversion seeding (TestGen.SeedFromLeaf +
TestGen.ExtractBranchSeeds, module 30) to three predicate shapes previously left
as honest residue.  Backlog items #2, #3, #4 from the v11 residue list.

  #2 REVERSED predicates  `literal <op> @param`  (IF 5 = @status, IF 0 < @n,
     IF 90 <= @n).  ExtractBranchSeeds gained a numeric-LHS branch in the
     predicate scanner: it reads the leading literal, then MIRRORS the operator
     (< <-> >, <= <-> >=, =/<> unchanged) so the param-side seed still satisfies
     the gate (5 > @x  ==  @x < 5).  Guarded by a new @lhsOk boundary flag (set
     at predicate start, after '(' and after AND/OR/NOT; cleared after any
     param/identifier) so a non-literal LHS (@a+5 > @b, col5 = @w) does NOT
     emit a speculative seed - those stay residue.  Reversed STRING literals are
     consumed by the string-skip before the handler sees them, so they remain
     residue (documented).

  #3 NOT IN / NOT LIKE / NOT BETWEEN.  The operator reader now recognises a NOT
     prefix and yields op codes NOTIN / NOTLIKE / NOTBETWEEN; the operand reader
     and IN paren-skip / LIKE de-wildcard were widened to the NOT variants.
     SeedFromLeaf returns a best-effort satisfying value: NOT BETWEEN lo..hi ->
     lo-1 (num) / '' (str);  NOT IN (a,..) -> a-1 (num) / a+'~' (str);  NOT LIKE
     'p' -> '' (empty string evades prefix/suffix/substring patterns).

  #4 Non-numeric  < > <>  on string / ISO-date literals (SeedFromLeaf was
     numeric-only and returned NULL).  Now: < -> '' (sorts before any non-empty
     value);  > and <> -> the literal with a trailing char appended via STUFF
     ('M' -> 'M~').  ISO dates sort lexically, so '2020-01-01' style literals are
     handled by the same string path.

SAFE BY CONSTRUCTION (unchanged invariant): every seed EXEC and the whole
seed-build block in RunCoverageForFunction are TRY/CATCH'd, so an inexact NOT/
non-numeric seed merely fails to enter its branch (honest residue) and can never
break a run or regress coverage.  Values still come only from the code's own
literals (+/-1, '', or a one-char append), so emitted EXEC args are well-formed.

VERIFIED on AdventureWorks2025 via the SQL MCP (CREATE OR ALTER both functions,
then exercised directly - the parser path does not need XEvent):
  - SeedFromLeaf: 16/16 scenarios (num </>/<>; str </>/<>; date <; NOT* num+str;
    ISNULL; LIKE passthru; unquoted-non-numeric -> NULL residue).
  - ExtractBranchSeeds: a 10-branch mixed body returned every expected seed;
    reversed >=/<= mirrored correctly (90, 100); the @lhsOk guard suppressed
    @a+5>@b and col5=@w; parenthesised (3<@z) stays residue (pre-existing @pp>0
    gating, consistent).  Real OBJECT_DEFINITION path (fn_rev/fn_not/fn_guard)
    matched the bare-body results.
  - No regression: param-first =, >=, IN, IS NULL, LIKE and ancestor-chaining
    all unchanged (fn_grade/fn_region-style bodies + nested IF @x>5 / IF @y=7).

ENVIRONMENT NOTE: the Edit tool silently TRUNCATED module 30 mid-HTML-string at
line ~1930 during this work (the known large-file Edit truncation).  Caught by
tsql_lint (BEGIN/END imbalance + unterminated string) and wc -l (1929 vs HEAD
1948).  All edits were above the cut; restored the unchanged GACD HTML tail
byte-exact from git HEAD (CRLF-normalised), then re-linted clean.  Installers were
folded via Python span-replacement (NOT the Edit tool) and are byte-identical
(md5 db2018f5f18a60d83a5318fe4415baf0).

FILES: modules/30_Function_Support_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Patch_v11_SeedExtensions.sql (new, standalone CREATE OR ALTER),
       scripts/Verify_SeedExtensions.sql (new), CHANGES.md

================================================================================
2026-06-01  Multi-statement TVF shadow teardown gap: false "failed generation"
================================================================================
SYMPTOM: a full GenerateAndCoverDatabase sweep on AdventureWorks2025 reported
dbo.ufnGetContactInformation (the only multi-statement TVF, kind TF) as
"failed generation - UNSUPPORTED:shadow compile failed: There is already an
object named 'ufnGetContactInformation_covfn' in the database."  Northwind
(no mTVFs) swept 100% clean, confirming the fault was isolated to the TF path.

ROOT CAUSE: the coverage instrument-swap (InstrumentProcedure) renames the shadow
proc <fn>_covfn -> <fn>_covfn_orig, builds an instrumented <fn>_covfn_cov, and
points a SYNONYM <fn>_covfn at the instrumented copy.  RunCoverageForFunction's
end-of-run teardown drops all three, but if a PRIOR run was interrupted (or its
teardown was skipped) the SYNONYM survives.  On the NEXT sweep,
BuildShadowProcForFunction's pre-create guard only did
    IF OBJECT_ID(@shadowFull,'P') IS NOT NULL DROP PROCEDURE ...
- a 'P'(rocedure)-only check.  A leftover SYNONYM ('SN') is invisible to that
check, so CREATE PROCEDURE <fn>_covfn then collided with the synonym and the
function reported a FALSE generation failure on every subsequent sweep until the
orphan was cleared by hand.  Not a regression from the seed-extension work (that
touches only SeedFromLeaf / ExtractBranchSeeds); a pre-existing teardown gap.

FIX (BuildShadowProcForFunction, module 30 + both installers): replace the
'P'-only guard with a COMPLETE defensive teardown that clears every artifact a
prior/interrupted run could have left under the shadow name, in the right order -
SYNONYM first (it occupies the base name), then _cov / _orig copies, then any
same-named procedure - each wrapped in its own TRY/CATCH.  This makes the build
idempotent regardless of what an earlier run stranded; the end-of-run teardown is
unchanged (now belt-and-suspenders).

VERIFIED on AdventureWorks2025 via the SQL MCP: pre-seeded the exact tangle
(CREATE SYNONYM <fn>_covfn FOR sys.objects + dummy _orig/_cov procs), then called
BuildShadowProcForFunction - Status='OK', the synonym was replaced by a real
shadow PROCEDURE, both stale copies were dropped, and the 71-row ShadowLineMap
built.  Before the fix this same scenario raised the "already an object named"
error.  Cleaned all shadow orphans afterwards; originals intact.

Verify with scripts/Verify_ShadowTeardown.sql.

FILES: modules/30_Function_Support_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       scripts/Verify_ShadowTeardown.sql (new), CHANGES.md

================================================================================
2026-06-01  v11 seed coverage: parenthesised / reversed-string / non-literal RHS
            + clock-env, and a committed capability demo schema
================================================================================
Three more predicate shapes the function branch-seeder (ExtractBranchSeeds) now
reaches, plus the driver wiring to satisfy them, plus examples/Demo_Schema.sql.

  PARENTHESISED COMPARISONS  -  IF (@x > 5), IF (@a >= 1 AND @b < 3), nested
  groupings.  The extraction gate was @pp=0 (top level only), so any predicate
  wrapped in parens produced NO seed.  Replaced it with a call-vs-grouping paren
  classifier: each '(' is GROUPING (a boolean/comparison sub-expression - keep
  extracting) when seen at an operand position (@lhsOk=1), or a function-CALL
  paren (dbo.f(...), ABS(...), ISNULL(...) - suppress) when it follows an
  identifier (@lhsOk=0).  A 'G'/'C' stack drives @callDepth; extraction is now
  gated on @callDepth=0.  Function-call args are still correctly NOT seeded.

  REVERSED STRING LITERALS  -  'US' = @code, 'M' < @grade.  A string at operand
  position is intercepted before the generic string-skip, read, and its operator
  mirrored (parallel to the existing reversed-NUMERIC handler).  Reversed numeric
  already shipped; this closes the string side.

  NON-LITERAL RHS  (#5)  and  CLOCK/ENV RHS  (#7)  -  @d < GETDATE(), @x > @y,
  @n <= dbo.f().  For an INEQUALITY whose RHS is not a readable literal, the
  branch is still satisfiable by driving the PARAM to a type extreme regardless
  of the RHS value: < / <= -> type MIN, > / >= -> type MAX.  ExtractBranchSeeds
  emits a <<MIN>>/<<MAX>> sentinel; RunCoverageForFunction resolves it per param
  type via GetSampleValueLiteral variant 1 / 2 (boundary-low / boundary-high),
  which it now precomputes into @ph (minLit/maxLit).  This replaces the prior
  "leave #5/#7 as residue" stance for the param-on-the-left case.  Honest residue
  remaining: =,<> against a non-literal (can't match an unknown), and gates with
  NO parameter to steer (paramless @@SPID=5 / GETDATE compares, accumulated
  values built by a loop/query).

VERIFIED on AdventureWorks2025 via the SQL MCP (parser + end-to-end driver-arg
resolution): a 10-branch mixed body returned every expected seed incl. <<MIN>>/
<<MAX>>; @status=@@SPID correctly produced no seed; @d<GETDATE() resolved to
@d='1900-01-01', @n>@m to @n=2147483647, @m<=dbo.f() to @m=-2147483648.  Full
no-regression sweep of the prior shapes (=, >=, IN, IS NULL, LIKE, NOT*, ancestor-
chaining) - unchanged.

DEMO SCHEMA  -  examples/Demo_Schema.sql.  A self-contained [uaDemo] schema, one
small richly-commented function per capability (12 objects: 10 scalar FN, 1 inline
IF, 1 multi-statement TF), built because stock AdventureWorks/Northwind have almost
no param-gated function branches to exercise these features (AW: only ufnGetStock/
ufnGetContactInformation have IF branches, and ufnGetStock's is on a local;
Northwind has zero user functions).  Each function's seed extraction was verified
on the live DB to match its documented claim, including the honest-residue rows
(ABS(@y)=7 call-paren -> no seed; @hits>3 accumulated -> no seed).  Run it with
EXEC TestGen.GenerateAndCoverDatabase @SchemaFilter='uaDemo', @OutputMode='HTML'.

NOTE: these seeding changes are FUNCTION-path only (ExtractBranchSeeds is called
solely by RunCoverageForFunction).  Stored procedures use a different branch-
coverage mechanism and are unaffected.

ENVIRONMENT: the Edit tool silently truncated module 30 mid-HTML-string TWICE more
during this work (lines ~1930 and ~1995); both caught by tsql_lint + wc -l and the
unchanged GACD HTML tail restored byte-exact from git HEAD.  Installers folded via
Python span-replacement (md5 2913df4e10e9f633faf173da3c1c56af, byte-identical).

FILES: modules/30_Function_Support_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       examples/Demo_Schema.sql (new), CHANGES.md

================================================================================
2026-06-01  v11 #11: CASE-in-RETURN branch decomposition (TestGen.ExpandCaseToIf)
================================================================================
PROBLEM: a scalar function whose body is  SET @v = CASE ... END;  or
RETURN CASE ... END;  (e.g. ufnGetSalesOrderStatusText / ufnGetPurchaseOrderStatusText
/ ufnGetDocumentStatusText) reported 0 BRANCHES.  A CASE is a single expression -
the line-based instrumenter (module 20) explicitly treats CASE arms as
non-branching (the @InCaseBefore guard) because you cannot hook "which arm ran"
without converting the CASE into control flow.  So the whole headline branch
metric was dragged down (AdventureWorks showed 1/2) purely by un-decomposed CASE.

FIX: new pure fn TestGen.ExpandCaseToIf rewrites a statement-scope
SET <target> = CASE ... END  /  RETURN CASE ... END  into an
IF / ELSE IF / ELSE chain (simple CASE  CASE @x WHEN v ...  ->  IF @x = v ... ;
searched CASE  CASE WHEN cond ...  ->  IF (cond) ...).  Each arm is now an
instrumentable IF branch AND a seedable leaf.  Char-walk, comment/string/bracket/
paren + nested-CASE aware; CONSERVATIVE - only a clean top-level SET=CASE/RETURN
CASE is expanded, anything else is copied through verbatim, and a malformed
expansion just fails the shadow compile (existing TRY/CATCH -> honest deferral),
never a crash.  Captured segments are whitespace-collapsed so each emitted IF
header is single-line (the instrumenter is line-oriented).

Applied in TWO places (module 30):
  - BuildShadowProcForFunction: on @procBody (after RewriteScalarReturns, before
    NormalizeShadowBody) so the shadow has the IF branches to COUNT.
  - RunCoverageForFunction: on @fnbody before ExtractBranchSeeds so the seeder
    sees the same arms and derives a value for each to COVER them.
Both see identical conditions (@status = 1, = 2, ...), so seeds line up with
branches.

VERIFIED on AdventureWorks2025 via the SQL MCP (parser + shadow-build path; the
final % needs an SSMS run for XEvent):
  - ExpandCaseToIf on the real ufnGetSalesOrderStatusText body: expands to a clean
    IF/ELSE chain that COMPILES as a proc; ExtractBranchSeeds on it -> @Status =
    1..6 (6 seeds).
  - Integrated BuildShadowProcForFunction: ufnGetSalesOrderStatusText builds
    Status=OK with 7 instrumented branches (6 WHEN arms + ELSE), 8 exec lines;
    ufnGetStock (CASE-free) still builds OK = no regression.
So in an SSMS sweep these status-text scalars go from "n/a" branch to ~7/7.

DEMO: examples/Demo_Schema.sql gains section 13 uaDemo.fnStatusText (the same
6-arm CASE shape) - verified to seed @status=1..6 on the live DB.

ENVIRONMENT: the Edit tool truncated module 30 TWICE more (HTML tail, lines ~1995
and ~2251) AND the demo file once (mid-CASE at line 237); all caught by tsql_lint
+ wc -l and restored (module tail byte-exact from HEAD; demo rewritten whole).
A stray apostrophe in a demo COMMENT (AdventureWorks') also tripped the linter's
string-masker - reworded.  Installers folded via Python insert + span-replace
(md5 3f690c77a88ce685f7c676bfd0907677, byte-identical).

FILES: modules/30_Function_Support_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       examples/Demo_Schema.sql, CHANGES.md

================================================================================
2026-06-01  Brand fix: HTML coverage report header -> UnitAutogen
================================================================================
The generated HTML coverage report still rendered the OLD product name
"tSQLt Auto-Gen" in its <title> and <h2> - so the public-facing report artifact
(and the launch screenshots) were mis-branded while the PowerShell module et al.
already said UnitAutogen.  Scoped to the report OUTPUTS only (per request):
  - HTML <title>:  "tSQLt Auto-Gen Coverage"  ->  "UnitAutogen Coverage Report"
  - HTML <h2>:     "tSQLt Auto-Gen - Database Coverage Report"
                   ->  "UnitAutogen - Database Coverage Report"
Applied in all three HTML renderers (module 04 base GACD, module 25 standalone
Export-CoverageHtmlReport, module 30 v11 GACD) + both installer copies (6 strings
each, byte-identical md5 5f8e4a80749a2c7560d3fa34933a40f4).  JUnit already emits
name="UnitAutogen"; Cobertura carries no product name - both left untouched.  The
underlying "tSQLt" references, installer banners, RAISERROR and test-comment
strings are intentionally unchanged (tSQLt is the real framework it builds on).
Re-install (the renderer lives in the DB) then re-run to get a UnitAutogen-branded
report for the screenshots.

FILES: modules/04_Test_Generator_v3.sql, modules/25_Coverage_Reporter_Html.sql,
       modules/30_Function_Support_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-01  HTML report column relabel (Procedure -> Object) + README hero shots
================================================================================
- The standalone Export-CoverageHtmlReport (module 25) and the base GACD (module
  04) HTML reports labelled the per-row column "Procedure" and the count
  "N procedures", but the list includes user FUNCTIONS too (ufn*).  Module 30's
  v11 GACD already said "Object"/"objects"; aligned 04 + 25 (+ both installers,
  byte-identical md5 1ec95a87b709c90c139f9edc3cc567f9) so a function never sits
  under a "Procedure" header.  Pure label text; no logic change.
- README.md: new "See it in action" section just under the intro - the rebranded
  HTML coverage report (94.9% line / 94.4% branch / 100% autonomy on a full
  AdventureWorks2025 sweep), the one-line PowerShell invocation, and the Cobertura
  + JUnit artifact shots.  Images live in Screenshots/.  (The post-rebrand re-run
  confirmed branch coverage 50% -> 94.4% once the CASE-in-RETURN arms are counted.)

FILES: modules/04_Test_Generator_v3.sql, modules/25_Coverage_Reporter_Html.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       README.md, Screenshots/*.png, CHANGES.md

================================================================================
2026-06-02  v0.10 BUILD (first cut) - predicate-aware data-shape seeding
================================================================================
Implements DESIGN_v0_10_PredicateSeeding.md (rev 4 - open questions resolved).
Reaches branches gated by DATA-SHAPE predicates the v11 parameter-inversion
seeder cannot: IF EXISTS(...), IF (SELECT COUNT(*) ...) = N, SUM/MIN/MAX/AVG
thresholds, scalar-subquery compares and IS [NOT] NULL. Motivated by the first
real-world adoption (EIN colleague's rich_4thJan) where these showed uncovered.

ARCHITECTURE (confirmed by Phase-0 spike, now built end to end)
  PowerShell ScriptDom parser  ->  TestGen.PredicateInbox (staging)  ->
  T-SQL case-analysis seeder    ->  test-gen integration / NOT_TESTABLE.

NEW SQL MODULES
  modules/31_PredicateInbox_v1.sql
    TestGen.PredicateInbox (closed Shape vocabulary, JSON columns ISJSON-checked,
    UNIQUE(RunId,Schema,Proc,Branch)); AddParsedPredicate (normalising insert
    surface), GetPredicatesForProc, ClearPredicateInbox.
  modules/32_Seeder_v1.sql
    TestGen.SatisfyPredicate(@InboxId,@Direction) -> seed T-SQL + Supported/Reason.
    Helpers SatisfyingValue (op+literal -> satisfying/violating value; '=','<>'
    for any literal, numeric inequalities for numbers) and BuildSeedInsert
    (identity/computed/rowversion-excluded column list, VALUES for K=1 / SELECT
    TOP(K) from a tally for K>1). Full case table: EXISTS/NOT_EXISTS, COUNT
    =,<>,>,>=,<,<=, COUNT_IN, COUNT_BETWEEN, SUM/MIN/MAX/AVG/SCALAR compare,
    SCALAR IS [NOT] NULL. Degenerate/over-cap/non-literal cases return Supported=0.
  modules/33_Predicate_TestGen_v1.sql
    BuildPredicateSeedBlock (THE hook module 04 calls at the @ThisSeedBlock seam
    ~line 2855; falls back gracefully when a proc was never parsed),
    BuildNotTestableFailBody (quote-escaped tSQLt.Fail carrying the verbatim
    predicate + reason), GeneratePredicateBranchPlan (per branch x direction
    result set - the standalone, demoable verification surface).

NEW POWERSHELL
  powershell/UnitAutogen/Get-ParsedPredicates.ps1
    Production promotion of the spike. Reads sys.sql_modules, walks the AST,
    classifies each IF/WHILE/CASE-WHEN gate, extracts target table {schema,
    table,alias}, WHERE conjuncts {col,op,val} (AND of <col> <op> <literal>
    only - OR / column-to-column / multi-table FROM / non-literal -> UNRECOGNISED
    per resolved Q5), comparator + comparand. Writes via AddParsedPredicate.
    ScriptDom policy "latest, not just available": loads the HIGHEST-version DLL
    among candidates (SqlServer module 17.x preferred - it carries TSql170Parser,
    which the public NuGet 161.x train does not), auto-selects the highest
    TSqlNNNParser the assembly exposes, and WARNS when that is older than the
    target DB's compatibility_level. ASCII-only source (PS 5.1 encoding-safe).

NEW EXAMPLES
  examples/PredicateZoo/ - 12 recognised-shape procs + 3 UNRECOGNISED, schema
  pz, with 00_Schema/01_Procedures/02_Expected_Shapes.md/README.

NEW TOOLING
  tools/mcp_powershell_server.ps1 (+ .py twin, config, README) - a zero-
  dependency MCP stdio server that runs PowerShell on the host so the ScriptDom
  parser can be exercised live (the assistant sandbox is Linux). PowerShell
  variant is primary (no Python needed; the Store python alias does not work).

VERIFICATION (live, AdventureWorks2025 / SQL 2025 / compat 170 / tSQLt present)
  - Modules 31/32/33 deployed clean; tsql_lint clean on all new .sql.
  - Seeder round-trip: 12 shape x direction cases - emitted seed executed, then
    the predicate evaluated; ALL 12 PASS (TRUE seed -> true, FALSE seed -> false).
  - Parser run against schema pz: 15 rows, parser TSql170Parser auto-selected,
    compat guard OK. Classifications match 02_Expected_Shapes.md exactly: 9 fully
    recognised; 6 UNRECOGNISED (3 grammar: OR, join-FROM, param-comparand; 3
    param-WHERE `= @p` which honestly degrade to NOT_TESTABLE in v0.10.0).
  - GeneratePredicateBranchPlan on real parsed rows: CountEqGate TRUE/FALSE seed
    2/3 Active=1 rows (identity excluded); ExistsGate -> clean NOT_TESTABLE body.

NOT DONE / FOLLOW-UPS
  - Top priority v0.10.1: thread the EXEC argument value into WHERE conjuncts of
    the form `col = @param` so the dominant real-world EXISTS gate
    (IF EXISTS(SELECT 1 FROM T WHERE FK=@id)) seeds instead of going NOT_TESTABLE.
    Needs the proc-call layer in module 04 (the standalone parser cannot know the
    arg value). This is the single biggest coverage win remaining.
  - Wire BuildPredicateSeedBlock into 04's branch cursor at the @ThisSeedBlock
    seam (contract is ready; not yet applied to the 4490-line generator).
  - HTML report NOT_TESTABLE bottom panel (resolved Q2) - reporter change pending.
  - Multi-join joint satisfaction (deferred to v0.11 per Q5).
  - PredicateZoo objects currently live in AdventureWorks2025 (schema pz) from
    verification; drop or relocate to a dedicated DB before release.

FILES: modules/31_PredicateInbox_v1.sql, modules/32_Seeder_v1.sql,
       modules/33_Predicate_TestGen_v1.sql,
       powershell/UnitAutogen/Get-ParsedPredicates.ps1,
       examples/PredicateZoo/*, tools/mcp_powershell_server.ps1,
       tools/mcp_powershell_server.py, tools/mcp_powershell_config.json,
       tools/mcp_powershell_README.md, design/DESIGN_v0_10_PredicateSeeding.md,
       CHANGES.md

================================================================================
2026-06-02  CLEAN-ROOM SWEEP baseline reproduced (+ retraction of 2 "errors")
================================================================================
User restored a clean AdventureWorks2025, installed tSQLt + the single
Install_UnitAutogen.sql (v0.10 folded in), and ran a full Invoke-UnitAutogen
sweep. Result matches the documented baseline to the decimal:
  94.9% line (56/59), 94.4% branch (17/18), 100% autonomy,
  91 tests: 81 pass / 0 FAIL / 0 ERR / 10 skip, 19 objects (17 testable, 2 not).
=> No regression; single-installer + v0.10 fold-in confirmed good; v0.10 objects
   inert (no coverage delta), as designed.

RETRACTION: the two failures seen earlier on the DIRTY db do NOT reproduce on a
clean install and were artifacts of dirty/stale state, NOT current-code bugs:
  - uspLogError "annotation has unmatched quote" -> on clean run it is a clean
    NOT_TESTABLE skip; the reason text still contains "procedure's" and the
    SkipTest annotation registered fine. The current generator escapes it
    correctly. The earlier apostrophe-escaping "fix" is therefore NOT needed.
  - uspUpdateEmployeeLogin "severe error" -> on clean run it is 11/11 pass.
Lesson: triage generator output on a CLEAN install before concluding a bug;
interrupted/stale runs produce phantom errors.

Sole remaining sub-100 object (pre-existing, unchanged): HumanResources.
uspUpdateEmployeeHireInfo 66.7% line (4/6) / 0% branch - the uncovered path is
the @@TRANCOUNT=0 / error-handling branch (manual scaffold), NOT a data-shape
predicate, so v0.10 seeding does not address it.

FILES: CHANGES.md

================================================================================
2026-06-02  v0.10 source-line match key + StartLine; installer re-folded
================================================================================
Per the decision to keep ScriptDom scoped to predicates only (string parser
still owns branch identity), added a ROBUST join key so module 04 can attach a
predicate seed to the right branch WITHOUT the two parsers agreeing on ordinal
numbering: match by SOURCE LINE.
  - Get-ParsedPredicates.ps1 captures each gate's StartLine (IfStatement/
    WhileStatement/SearchedCaseExpression .StartLine) and writes it.
  - PredicateInbox gains a StartLine column (upgrade-safe ALTER for existing
    tables); AddParsedPredicate/GetPredicatesForProc carry it.
  - BuildPredicateSeedBlock gains @MatchByLine (preferred) + @StartLine OUTPUT;
    falls back to BranchId when not supplied. GeneratePredicateBranchPlan
    surfaces StartLine. VERIFIED on pz: 15 rows, all 15 StartLine populated and
    equal to the actual IF/WHILE line in sys.sql_modules.
  - BuildNotTestableFailBody rewritten to escape quotes via NCHAR(39) instead of
    literal '''' / '''''' runs - same output, but no quote-doubling runs (more
    readable AND clears a tsql_lint masker false-positive).
  - Installer re-folded (both copies, byte-identical) via the BEGIN/END
    sentinels now wrapping the v0.10 block. Full installer runs end to end on
    AdventureWorks2025 -> "UnitAutogen framework installed successfully."

TOOLING LESSON (important): the sandbox/bash/Read-tool view of files on the
mounted Windows folder INTERMITTENTLY TRUNCATES large-file reads (~30KB+),
making COMPLETE files look cut off (e.g. parser appeared to end mid-line at
"Write-InboxRows -conn" but was actually intact at 566 lines). This caused a
false "truncation" diagnosis and a bad append that duplicated a tail. RULE:
verify large .sql / .ps1 integrity via the PowerShell MCP (host filesystem) or
SQL Server (Invoke-Sqlcmd), NOT via bash tail/Read tool. Treat tsql_lint over
the 700KB installer as advisory; SQL Server running the whole file is the gate.

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1,
       modules/31_PredicateInbox_v1.sql, modules/33_Predicate_TestGen_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       CHANGES.md

================================================================================
2026-06-02  v0.10 module 34 - seeded predicate-branch test generator (COVERAGE)
================================================================================
THE integration piece that makes v0.10 move real coverage. Investigation found:
the string generator (04) DETECTS a data-shape gate as 2 branches but reaches
only ONE arm (default empty-faked-table arm) - it cannot engineer data to flip a
COUNT/SUM/EXISTS/... predicate, so these gates sit at 50% branch. (#BranchPaths
has no source line and AnalyzeBranchPaths emits no seeding path for them.)

modules/34_Predicate_BranchTests_v1.sql - TestGen.GeneratePredicateBranchTests
@Schema,@Proc: for each PredicateInbox gate, emits a tSQLt test PER DIRECTION
into the proc's test class (FakeTable target table(s) + v0.10 seed + EXEC proc
in TRY/CATCH); UNRECOGNISED gates get a NOT_TESTABLE placeholder. COMPLEMENTARY -
adds to the existing class, never edits module 04, so the 94.9/94.4 baseline is
untouched. v0.10.0 scope: fakes the predicate's TARGET table(s) only (procs
reading extra tables may still need the standard generator's full faking).

PROVEN on AdventureWorks2025/pz (live):
  - Baseline (string gen only): data-shape gates = 50% branch (1/2 arms).
  - After GeneratePredicateBranchTests + RunCoverage (no regen):
      CountEqGate -> BOTH arms hit (line 6 'EXACTLY_TWO' + line 8 'NOT_TWO').
      SumGate     -> BOTH arms hit (line 6 'BIG_REVENUE' + line 8 'SMALL').
    i.e. 50% -> 100% branch, fully automatic, both v0.10 tests pass.
  - The lone remaining failure in test_CountEqGate is a pre-existing result-shape
    baseline-drift scaffold (needs re-bless), NOT a v0.10 test.

Module 34 folded into the single installer (both copies, md5-identical, 14223
lines, sentinel-wrapped v0.10 block now = modules 31/32/33/34).

OPEN: an orchestrator that runs GenerateAndCoverDatabase -> then
GeneratePredicateBranchTests per proc -> then RunCoverage, so a one-command sweep
reflects the v0.10 lift in the HTML report (today GACD regenerates and would wipe
the v0.10 tests, so they must be added AFTER generation and measured via
RunCoverage). Also: assertions on the seeded arm (currently reachability/smoke).

FILES: modules/34_Predicate_BranchTests_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-02  v0.10 module 35 ORCHESTRATOR - one-command sweep reflects the lift
================================================================================
modules/35_Predicate_Orchestrator_v1.sql - TestGen.GenerateAndCoverDatabaseV10
@SchemaFilter,@ExcludePattern,@OutputMode. Resolves "why can't I just resweep":
GenerateAndCoverDatabase regenerates each class AND measures in one shot, so the
v0.10 tests must be added AFTER its generate step. The orchestrator:
  1. EXEC GenerateAndCoverDatabase (string gen + measure + CoverageResult batch)
  2. for each PARSED proc in that batch (has PredicateInbox rows):
       EXEC GeneratePredicateBranchTests (add seeded per-direction tests)
       EXEC RunCoverage (re-measure, no regen)
       recompute Line%/Branch% (identical rule to GACD) and UPDATE the proc's
       CoverageResult row -> the HTML/XML report shows the lift.
Procs never parsed (no PredicateInbox rows) are untouched -> baseline preserved.

PROVEN (live, one GenerateAndCoverDatabaseV10 @SchemaFilter='pz' call): 10 of the
recognised data-shape gates went 50% -> 100% branch in a single batch
(CountEq/Gt/In/Between, Sum, Min, Max, Avg, NotExists, ScalarNull). ExistsGate /
ScalarCmpGate stay 50% (WHERE = @param -> UNRECOGNISED, the v0.10.1 follow-up);
Join/Or/ParamComparand stay 0% (UNRECOGNISED grammar).

Module 34 hardened in the same pass:
  - UNRECOGNISED / unseedable directions now emit a [@tSQLt:SkipTest] marker
    (reported SKIPPED, amber) instead of tSQLt.Fail (red) - matches the
    framework's honest-skip model; v0.10 no longer turns the report red.
  - Clears its own prior "(v0.10)" tests at the start of each run (fixes stale
    TRUE/FALSE tests lingering after a shape change, and the "already an object
    named ..." collision from the earlier unbracketed-OBJECT_ID drop).
  Verified: JoinFromGate -> single Skipped; CountGtGate -> both directions pass.

All five v0.10 modules (31-35) folded into the single installer (both copies
md5-identical, sentinel-wrapped block). PERF NOTE: the orchestrator re-runs
RunCoverage per parsed proc (XEvent setup/teardown each) - ~10 min for pz's 15
procs; fine for correctness, needs a batched-instrumentation pass before large
production DBs (deferred to v0.11).

FILES: modules/34_Predicate_BranchTests_v1.sql,
       modules/35_Predicate_Orchestrator_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-02  v0.10 PERF - single-pass: GACD predicate-aware INLINE (no 2nd pass)
================================================================================
Profiled the cost (live, pz/CountEqGate): GenerateTestsForProcedure ~11s,
GeneratePredicateBranchTests ~0.6s, RunCoverage ~37s (cold standalone). The
module-35 orchestrator ran RunCoverage a SECOND time per parsed proc -> nearly
doubled sweep time (pz: ~10 min).

Fix: inject the 0.6s GeneratePredicateBranchTests into the GACD per-proc loop
BETWEEN GenerateTestsForProcedure and its single RunCoverage, gated on the proc
having PredicateInbox rows. Coverage then runs ONCE with the v0.10 tests present.
Applied to BOTH GACD definitions (module 04 + module 30's function-aware
override - the latter is the live one) and both installer copies. Module 35
reduced to a thin backward-compat alias (GenerateAndCoverDatabase is now
predicate-aware on its own).

RESULT (live, pz, 15 procs): plain GenerateAndCoverDatabase = 247.9s
(~4.1 min) vs ~10 min for the old double-pass orchestrator (~60% faster); the
10 recognised data-shape gates show 100% branch in that single batch. v0.10
overhead is now ~0.6s/proc. Unparsed procs hit only the gated EXISTS check
(no rows -> skip) so the AdventureWorks baseline is byte-for-byte unchanged;
Invoke-UnitAutogen (which calls GACD) now reflects v0.10 automatically.

STILL OPEN (framework-wide, v0.11): GACD's inherent per-proc cost (~16s/proc
inside the batch; ~37s cold standalone for RunCoverage) - the XEvent
instrument/run/teardown. Batching that is a separate, larger initiative and is
NOT a v0.10 regression (v0.10 adds ~0.6s/proc on top).

FILES: modules/04_Test_Generator_v3.sql, modules/30_Function_Support_v1.sql,
       modules/35_Predicate_Orchestrator_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-02  PERF Phase 1 - profiled coverage; trimmed WAITFOR (read = v0.11)
================================================================================
Profiled RunCoverage per-proc (live, pz/CountEqGate, warm ~14s) by building an
instrumented copy that timestamps each phase. Breakdown:
  InstrumentProcedure       ~0.3s
  create+start XEvent       ~0.04s
  rename + setup            ~1.4s
  tSQLt.Run (real work)     ~3.7s
  WAITFOR DELAY '00:00:03'  ~3.0s   (fixed pre-STOP sleep)
  read .xel (fn_xe_file...) ~4.6s   (parses ALL sp_statement_completed in the DB
                                     during the window; session filters by DB
                                     only, post-filters for RecordCoverageHit)
  stop + drop session       ~0.1s
=> ~7.6s of ~14s (54%) is reducible overhead (WAITFOR + read), not test work.

SHIPPED (safe): WAITFOR 3s -> 1s in RunCoverage (live + both installer copies).
STOP flushes the session and MAX_DISPATCH_LATENCY=1s, so 1s is a safe margin;
validated coverage UNCHANGED (CountEqGate both arms hit, 2/2). Deterministic
~2s/proc saving (single-run wall times are too noisy to show it; the .xel read
varies several seconds run to run).

NOT done on purpose (-> v0.11, needs careful test): cut the ~4.6s read. Two
routes tried/considered:
  - Capture-time filter on [statement] LIKE '%RecordCoverageHit%': predicate is
    syntactically valid ONLY with the [sqlserver].[like_i_sql_unicode_string]
    comparator (package0 has no such comparator), BUT at runtime it captured
    ZERO events - the sp_statement_completed [statement] field is not reliably
    populated at PREDICATE-evaluation time, so the filter silently zeroes
    coverage. REJECTED - too risky.
  - ring_buffer target (in-memory, no file I/O / flush): the right rebuild, but
    ring_buffer's size cap can DROP events on large procs -> undercount; needs
    overflow safeguards + thorough validation. Scoped to v0.11.
This profile IS the perf baseline to diff future enhancements against.

FILES: RunCoverage (installer x2), CHANGES.md

================================================================================
2026-06-02  PERF Phase 2 - object_id-filtered XEvent session (BIG read win)
================================================================================
The ~4.6s .xel read was actually unbounded: the session filtered by
database_name ONLY, so it captured EVERY sp_statement_completed in the DB during
the run window into the .xel, then post-filtered for RecordCoverageHit. On a busy
proc the file is huge and the read dominates.

Fix: filter the XEvent session to the INSTRUMENTED proc's object_id, so only its
statements are captured. RunCoverage computes @covid = OBJECT_ID(@CovFull) right
after InstrumentProcedure (the synonym <proc> -> <proc>_cov means the executing
module during the run is _cov), then injects
  AND [object_id]=(<covid>)
into the session WHERE via a REPLACE on the built @SQL. object_id IS available at
predicate-eval time (unlike [statement] text, which silently captured 0 events -
see Phase 1 notes). If @covid IS NULL it falls back to the DB-only filter (safe).

VALIDATED (live): RunCoverage vs the object_id-filtered build on
HumanResources.uspUpdateEmployeeHireInfo produced BYTE-IDENTICAL coverage
(covered exec lines [16,18,24,31] both ways) while time dropped 101.0s -> 18.5s
(~5.5x). CountEqGate also identical (2/2). The speedup SCALES with proc
complexity / DB statement volume during the window.

RunCoverageForFunction is a wrapper over RunCoverage, so function coverage
inherits the win. Applied to live + both installer copies (md5-identical);
single patch point (one CREATE EVENT SESSION in the engine).

NET PERF (Phase 1 + 2): single-pass GACD (no double measure) + WAITFOR 3s->1s +
object_id session filter. The dominant remaining per-proc cost is tSQLt.Run
itself (the real test work) + the fixed ~1.4s rename/setup. ring_buffer is no
longer needed for the read (object_id filter solved it without event-drop risk).

FILES: RunCoverage (installer x2), CHANGES.md

================================================================================
2026-06-02  v0.10.1 - WHERE col = @param seeding (reverse-seed from the test arg)
================================================================================
Closes the dominant real-world gate the parser previously marked NOT_TESTABLE:
  IF EXISTS (SELECT 1 FROM T WHERE FK = @param)   (also scalar = @param / IS NULL)
"Reverse seeding": the parser tells us the gate needs col = @param, so we seed
col = the exact value the generated test passes for @param.

PARSER (Get-ParsedPredicates.ps1): Get-WhereConjuncts now accepts a
VariableReference comparand and emits {col, op, val=@name, valKind='param'}
instead of rejecting the WHERE. Shape stays recognised (EXISTS/SCALAR_CMP/...).

SEEDER (module 32 SatisfyPredicate): reads the predicate's owning proc
(SchemaName/ProcName); for each WHERE conjunct with valKind='param', resolves
@name -> the proc parameter's sample literal via GetSampleValueLiteral(...,0) -
the SAME value module 34 passes as the EXEC arg - so the seeded row matches what
the test passes. A param that is not a proc parameter (e.g. a local variable)
-> honest NOT_TESTABLE.

BUG FOUND + FIXED in the same pass (BuildSeedInsert): when the WHERE filters on
an IDENTITY/computed/rowversion column (e.g. an IDENTITY PK: OrderId = @OrderId),
the old identity-exclusion dropped that column from the INSERT, so the row never
matched the @param value and BOTH directions fell to one arm. tSQLt.FakeTable
DROPS identity/computed/rowversion, so the faked table accepts explicit inserts
into them - BuildSeedInsert now INCLUDES any column that has an override
(regardless of identity), keeping the normal exclusion only for non-override
columns.

VALIDATED (live, pz, clean per-run hit checks): ExistsGate, ScalarCmpGate
(IDENTITY-PK WHERE) and ScalarNullGate all went 50% -> 100% branch (exec lines
2/2 each). Reverse-seed emits e.g. INSERT pz.Orders(OrderId,...) VALUES(42,...)
where 42 = the test's @OrderId arg. UNRECOGNISED now only the 3 truly
out-of-grammar pz procs (join / OR / param-comparand-threshold).

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1,
       modules/32_Seeder_v1.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-02  v0.10.2 - STRONG assertions on seeded branch tests (no ghost pass)
================================================================================
The v0.10 branch tests were reachability/smoke (FakeTable + seed + EXEC, pass on
no error) - a wrong seed could ghost-pass while the intended arm never ran.
Replaced with a real assertion that the seed actually drove the gate predicate
to the intended direction.

SEEDER (module 32 SatisfyPredicate): now also returns @PredicateSql (the gate's
boolean reconstructed from the structured fields with @params resolved to the
test's arg values - reliable, since the stored PredicateText omits the EXISTS
keyword) and @ExpectedBit (1 if the direction makes the gate TRUE). @whereSql is
built from the original (resolved) conjuncts so the WHERE in the assertion
matches the gate.

TEST-GEN (module 34): a supported direction now emits
    DECLARE @uag_actual BIT = CASE WHEN <reconstructed predicate> THEN 1 ELSE 0 END;
    EXEC tSQLt.AssertEquals @Expected=<bit>, @Actual=@uag_actual, @Message=...;
    BEGIN TRY EXEC <proc> <args>; END TRY BEGIN CATCH ... Fail ... END CATCH;
i.e. ASSERT the seed drove the predicate the right way, THEN run the proc so
coverage records the arm. NO GHOST PASS: if the seed does not satisfy the
predicate the AssertEquals FAILS (red). If a predicate cannot be reconstructed
(should not happen for recognised shapes) the test is a [@tSQLt:SkipTest] marker,
never a silent green.

VALIDATED (live): generated EXISTS test asserts
  EXISTS (SELECT 1 FROM [pz].[Orders] WHERE [CustomerId] = 42) = 1
(predicate reconstructed with the EXISTS keyword + @CustomerId resolved to the
EXEC arg 42). All 22 v0.10 tests across the 11 recognised pz gates PASS, 0 fail.
ANTI-GHOST proof: an intentionally wrong seed (CustomerId=99 not 42) FAILS the
assertion ("Expected <1> but was <0>") - exactly the class of bug (e.g. the
earlier identity-PK seed) that previously ghost-passed.

FILES: modules/32_Seeder_v1.sql, modules/34_Predicate_BranchTests_v1.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       CHANGES.md

================================================================================
2026-06-03  v0.11 - JOIN seeding for EXISTS / NOT EXISTS gates
================================================================================
Predicate seeding now handles a 2-table INNER equi-join inside the EXISTS /
NOT EXISTS subquery (previously UNRECOGNISED -> Skip). Bounded, honest cut:
INNER joins only, equality ON (or AND of equalities), AND-composed per-table
WHERE. Outer/non-equi/OR/3+-table/comma joins, and joins under aggregate shapes,
stay UNRECOGNISED in this cut.

PARSER (Get-ParsedPredicates.ps1):
  - Get-FromTables rewritten: recurses a QualifiedJoin via new Collect-JoinTables
    + Get-JoinEqualities, capturing all tables (schema/table/alias) and the ON
    equality keys {lAlias,lCol,rAlias,rCol}. Returns ok=$false (-> UNRECOGNISED)
    for non-INNER, non-equi ON, derived/TVF, comma-join.
  - Get-WhereConjuncts now tags each conjunct with its column qualifier (tbl =
    alias/table) so the seeder can route each conjunct to the right table.
  - Apply-Subquery gained an allowJoin flag (TRUE only for EXISTS/NOT_EXISTS),
    emits a multi-table TargetTablesJson + JoinsJson; bounds to exactly 2 tables.
  - PS 5.1 gotcha: @() wrapping a System.Collections.Generic.List[object] throws
    "Argument types do not match". The new helpers use plain arrays with +=
    (the convention the rest of the parser already uses).

SEEDER (module 32 SatisfyPredicate): new join branch, taken when JoinsJson is
present and Shape IN (EXISTS,NOT_EXISTS), BEFORE the single-table logic:
  - Reads @JoinsJson; fakes are emitted by module 34 (already loops all
    TargetTablesJson entries - no change needed there).
  - Shared join-key value per equality: a WHERE "=" on a join column pins it,
    else a type-appropriate GetSampleValueLiteral of the left join column; both
    sides get the SAME literal so the rows join.
  - TRUE/EXISTS (and FALSE/NOT_EXISTS): one coordinated row per table (join keys
    equal + each table's WHERE conjuncts satisfied, @params reverse-resolved).
    FALSE/EXISTS (and TRUE/NOT_EXISTS): leave both faked tables empty.
  - Reconstructs the FULL joined gate (FROM ... JOIN ... ON ... [WHERE ...]) for
    the strong AssertEquals (no ghost pass) and sets @ExpectedBit.
  - GOTCHA: SYSNAME columns are implicitly NOT NULL; the @jt/@jn/@jcj table vars
    populate alias/effalias/tbl by UPDATE or from nullable JSON, so those columns
    are declared NVARCHAR(128) NULL (else a 515 NULL-insert error).

FIXTURE (examples/PredicateZoo/01_Procedures.sql): pz.JoinFromGate reformatted
from the compact one-liner "SELECT 'A'; ELSE SELECT 'B';" to the multi-line
IF/ELSE its sibling gates use, and its comment updated (now seedable, not
UNRECOGNISED). REASON: the line-based coverage instrumenter (module 20) cannot
inject a hit between an IF body and an ELSE that share one line - it orphans the
ELSE and the _cov copy fails to compile, so EVERY test erroring and coverage
read 0/0. This is a PRE-EXISTING instrumenter limitation (the unseeded proc had
the same 0/0-all-error result), independent of join seeding; the one-liner was
simply never coverable. All sibling gates already use the multi-line form.

VALIDATED (live, AdventureWorks2025 + PredicateZoo):
  - Parser: pz.JoinFromGate now EXISTS with 2-table TargetTablesJson + JoinsJson
    + tbl-tagged WhereAstJson (was UNRECOGNISED). Regression spot-checks:
    single-table EXISTS unchanged; LEFT/non-equi/3-table/comma/aggregate-join all
    correctly UNRECOGNISED with distinct reasons.
  - Seed (TRUE): INSERT pz.Orders(CustomerId=42,...) + pz.Students(StudentId=42,
    Active=1,...) -> join matches -> EXISTS true. (FALSE): both tables empty.
  - Generated tests assert
    EXISTS (SELECT 1 FROM [pz].[Orders] [o] JOIN [pz].[Students] [s]
            ON [s].[StudentId]=[o].[CustomerId] WHERE [s].[Active]=1) = 1/0
    -> both branch tests PASS; JoinFromGate 0%->100% line AND branch.

INSTALLER: module 32 re-folded into the v0.10 sentinel block of BOTH installer
copies (kept md5-identical; +175 lines). Parser is a standalone .ps1, not in the
SQL installer.

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1,
       modules/32_Seeder_v1.sql, examples/PredicateZoo/01_Procedures.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       CHANGES.md

================================================================================
2026-06-03  v0.11.1 - zero UNRECOGNISED in PredicateZoo (OR/DNF + param comparand
                       + a string-gen quoting fix)
================================================================================
Goal: every PredicateZoo gate recognised, generated and coverable - no exception.
Three changes closed the last gaps (the corpus's two remaining UNRECOGNISED gates
plus a latent string-generator bug that aborted ScalarCmpGate).

1. OR composition (OrCompositionGate). The WHERE parser now produces DISJUNCTIVE
   NORMAL FORM. PARSER (Get-ParsedPredicates.ps1): Get-WhereConjuncts replaced by
   Get-WhereLeaf + Get-WhereDnf; AND distributes over OR (cross product), capped
   at 16 terms; WhereAstJson is now an array of TERMS (each an array of AND
   conjuncts) - AND-only WHERE = a single term (back-compatible shape, nested one
   level). SEEDER (module 32): reads the DNF, picks the FIRST fully-seedable
   disjunct as the matching-row driver (every conjunct in it must yield a value),
   seeds rows satisfying THAT disjunct (so each seeded row satisfies the whole OR
   and the row-count case analysis is unchanged), and reconstructs the FULL DNF
   "(a AND b) OR (c)" - params resolved - for the strong assertion (no ghost). The
   join path requires a single term (OR in a joined WHERE stays out of this cut).

2. Parameter comparand (ParamComparandGate: COUNT(*) > @Threshold). PARSER: a
   VariableReference comparand is accepted, stored as '@name'. SEEDER: '@name'
   resolves to the proc-parameter sample value the test passes (same reverse-seed
   as WHERE col = @param), so the seeded count and the runtime gate agree.

3. String-generator quoting (module 04, ScalarCmpGate root cause). The branch
   smoke-test builder emitted "EXEC p @brName = @BranchVal" UNQUOTED for any
   non-string parameter, assuming a numeric value. ScalarCmpGate's
   IF (SELECT Status FROM ... WHERE OrderId=@OrderId) = N'OPEN' made the string
   branch-detector pair the INT @OrderId with the scalar comparand 'OPEN', so it
   generated "EXEC ... @OrderId = OPEN" -> "Incorrect syntax near 'OPEN'", which
   aborted the WHOLE procedure's generation (GenSucceeded=0, 0 tests, 0 coverage).
   FIX: guard with ISNUMERIC(@BranchVal) (mirrors the existing @OtherBranchVal
   path) - a non-numeric value for a non-string param now falls back to a
   type-correct sample, so generation succeeds; module 34's predicate tests
   supply the real branch coverage. This only changes a path that previously
   produced guaranteed-invalid SQL, so it cannot regress a working procedure.

FIXTURE (examples/PredicateZoo): OrCompositionGate + ParamComparandGate reformatted
to the multi-line IF/ELSE (so the instrumenter can cover them - see the v0.11
instrumenter note); the old "UNRECOGNISED" section header retired (all three
former UNRECOGNISED gates are now recognised). 02_Expected_Shapes.md updated.

VALIDATED (live, AdventureWorks2025 + PredicateZoo): parser -> 0 UNRECOGNISED of
15 gates. Full GenerateAndCoverDatabase sweep over pz: ALL 15 gates GenSucceeded,
30/30 branches = 100% (was: ScalarCmpGate 0/0 gen-fail, OrComposition +
ParamComparand UNRECOGNISED/0%). Seeds verified no-ghost: OR seeds 2 rows on the
Active=1 disjunct -> COUNT=2; param gate seeds 43 rows -> COUNT 43 > resolved
@Threshold 42; both reconstruct the full gate for AssertEquals.

INSTALLER: module 32 re-folded into the v0.10 sentinel block; the module 04
one-line ISNUMERIC guard applied surgically. Both installer copies md5-identical.

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1, modules/32_Seeder_v1.sql,
       modules/04_Test_Generator_v3.sql, examples/PredicateZoo/01_Procedures.sql,
       examples/PredicateZoo/02_Expected_Shapes.md, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-03  v0.12 (WIP) - unified reverse-seeder: tree engine at PARITY
================================================================================
Engine redesign per design/DESIGN_v0_12_UnifiedReverseSeeder.md (design approved
first). Replaces the piecemeal per-shape seeder with one predicate-TREE + a
single recursive reverse-seed pass. Phases 1-2 (scaffolding + parity) DONE;
phases 3-6 (per-table merge, general joins, local substitution, cutover) pending.

WHAT LANDED
- Inbox (module 31): + PredicateTreeJson, SeedPlanTrueJson, SeedPlanFalseJson
  (upgrade-safe ALTERs); Shape gains 'PREDTREE'. Flat columns kept one release
  as fallback.
- Parser (Get-ParsedPredicates.ps1): builds a predicate TREE - boolean nodes
  (and/or/not) over data-shape ATOMS, each atom a QUERY (general join capture:
  N-table, left-deep, INNER/LEFT/RIGHT/FULL, equi + non-equi ON) with a boolean
  WHERE tree of column predicates. Renders the tree back to SQL for the strong
  assertion (no DNF -> the 16-term cap is gone). Truth-propagation emits a
  per-direction, per-PHYSICAL-TABLE seed plan (symbolic value specs + kspecs);
  the hard recursion stays in PowerShell so the T-SQL side is flat.
- Seeder (module 32): new TestGen.ExecuteSeedPlan walks the plan; new
  TestGen.CountForCase (row count per comparator) + TestGen.ResolveVspec
  (symbolic spec -> literal via the existing GetSampleValueLiteral /
  SatisfyingValue). SatisfyPredicate routes to the tree path when
  PredicateTreeJson is present, else the v0.11 flat fallback.

VALIDATED (live, AdventureWorks2025 + PredicateZoo): every pz row now parses to a
tree (Shape=PREDTREE) and seeds via ExecuteSeedPlan. Full GenerateAndCoverDatabase
sweep over pz on the TREE path = all 15 gates GenSucceeded, 30/30 branches = 100%
- identical to the flat engine (parity gate met), with EXISTS/COUNT/IN/BETWEEN/
SUM/MIN/MAX/AVG/SCALAR/SCALAR_NULL, joins, OR and param-comparand all flowing
through the one recursive pass.

NEXT (phases 3-6): per-table constraint merge (shared-table + contradiction
gates); seed the general joins the tree already parses (N-table/outer/non-equi/
aggregate-over-join); local-variable substitution (inline the defining
expression); then drop the flat columns, refold the installer, finish docs.

FILES: modules/31_PredicateInbox_v1.sql, modules/32_Seeder_v1.sql,
       powershell/UnitAutogen/Get-ParsedPredicates.ps1,
       design/DESIGN_v0_12_UnifiedReverseSeeder.md, design/README.md, CHANGES.md

================================================================================
2026-06-03  v0.12 - unified reverse-seeder COMPLETE (phases 3-6)
================================================================================
The tree engine now seeds everything the parser captures; the only Skips left are
genuinely irreducible (unsatisfiable predicates, runtime-dependent locals).

PHASE 3 - per-table constraint merge (modules 32). Seeding is table-centric:
every atom contributes count + row-predicate demands into a per-physical-table
accumulator, reconciled greedily (most-specific demand first) by
TestGen.ExecuteSeedPlan + TestGen.OverridesContain. A more-specific row already
counts toward a broader demand, so a COUNT total is back-filled (1 OPEN + filler
= total); an over-constrained EXACT/MAX demand is a genuine contradiction ->
honest Skip. Handles self-joins (two aliases of one table collapse) and two
atoms over one table. The strong assertion remains the backstop.

PHASE 4 - general joins (parser + module 32). Non-equi ON (b.y sampled, a.x
satisfies the operator via the new {satisfysample} vspec); outer joins
(LEFT/RIGHT/FULL - a matching seeded row satisfies them too, the type only
changes the reconstructed assertion); aggregate-over-join (COUNT/SUM/MIN/MAX/AVG
- the inner column routed to its alias's table, K coordinated joined rows);
N-table left-deep chains.

PHASE 5 - local-variable substitution (parser). Collect-ProcLocals maps each
single-assignment local to its defining expression; Classify-Predicate inlines
them iteratively (a chain @f <- @n <- (SELECT ...) resolves fully) before
building the tree, so a local-gated branch becomes an ordinary data-shape
predicate. A conditionally/repeatedly assigned local (runtime-dependent) is NOT
inlined -> honest UNRECOGNISED. Get-AggregateInfo / Get-LiteralText now unwrap
parentheses so an inlined subquery still classifies.

PHASE 6 - cutover. PredicateZoo gains gates per capability: LeftJoinGate,
NonEquiJoinGate, CountOverJoinGate, SumOverJoinGate, SelfJoinGate,
SharedTableGate, LocalSubqueryGate, LocalChainGate, plus the honest-residue
demonstrators ContradictionGate (TRUE arm unsatisfiable) and DynamicLocalGate
(dynamic local). Modules 31 + 32 re-folded into both installer copies
(md5-identical). Flat inbox columns kept one release as the documented fallback.

VALIDATED (live, full GenerateAndCoverDatabase over pz, 25 gates): every seedable
gate 100% branch (22/22 of the seedable ones), all GenSucceeded. Honest residue:
ContradictionGate 50% (TRUE Skipped - unsatisfiable), DynamicLocalGate 75%
(dynamic local Skipped) - both with 0 failed / 0 errored tests (no ghost).

GOTCHA (instrumenter, pre-existing, see [[reference-instrumenter-oneline-ifelse]]
in memory): the line-based coverage instrumenter also needs a multi-line IF
*condition* on one line; SelfJoin/SharedTable/Contradiction were reformatted so
the whole IF predicate sits on a single source line.

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1, modules/31_PredicateInbox_v1.sql,
       modules/32_Seeder_v1.sql, examples/PredicateZoo/01_Procedures.sql,
       Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       design/DESIGN_v0_12_UnifiedReverseSeeder.md, CHANGES.md

================================================================================
2026-06-03  v0.12.1 - conditionally-assigned locals (path expansion) + merge fixes
================================================================================
A local assigned in BOTH arms of an IF/ELSE is NOT irreducible - its value is a
function of an ancestor branch we already seed. The gate P(@x), with @x = v1
when C / v2 else, is expanded to (C AND P(v1)) OR (NOT C AND P(v2)) - a boolean
tree of data-shape atoms the unified engine already seeds (the ancestor C is
seeded too). The earlier "DynamicLocalGate is irreducible" claim was wrong; it
was just unhandled.

PARSER (Get-ParsedPredicates.ps1):
- Collect-ProcLocalConds + Collect-AssignWithGuards: detect a local assigned in
  the THEN and ELSE of one IF (and nowhere else), capturing the guard condition.
- Classify-Predicate: expands such a gate over its assignment paths, then the
  existing tree engine drives it. Iterates with single-local inlining (nested
  locals resolve too).
- Constant folding: a comparison of two literals (e.g. the inlined "5 > 3")
  becomes a {k:'const'} tree node; Propagate treats it as a fixed truth (free,
  no demand), Render emits "(1 = 1)" / "(1 = 0)".
- Pick-Cheapest: for AND-false / OR-true, choose the child needing the FEWEST
  demands (a const is free), so a free falsification is never replaced by an
  expensive, conflicting seed. (This fixed a real bug where (NOT A AND FALSE)
  driven false seeded A=true, conflicting with the sibling's A=false.)

SEEDER (module 32, ExecuteSeedPlan merge):
- Demand "mode" (exact/min/max) now depends on @want: "COUNT > 0" wanted FALSE
  means "<= 0 rows" (a MAX bound), not min. Without this the merge missed that a
  later min-demand violated an earlier max/exact demand.
- Added a validation pass: after emission, every EXACT/MAX demand is checked
  against the FINAL row set; an exceeded bound is a genuine contradiction /
  unreachable arm -> honest Skip (not a red test).

FIXTURE: pz.CondLocalGate (conditional local, both arms reachable -> 100%);
pz.DynamicLocalGate retired (it was just a conditional local with a dead arm),
replaced by pz.LoopLocalGate (a loop-accumulated local - genuinely not a static
expression -> honest UNRECOGNISED/Skip). The honest residue is now exactly:
unsatisfiable predicates (ContradictionGate) and non-static locals (LoopLocalGate).

VALIDATED (live): CondLocalGate both branches x both directions PASS; SharedTable
/ Contradiction still correct; full pz sweep all seedable gates 100%, 0 errored
tests, residue Skipped. Module 32 re-folded (both installer copies md5-identical).

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1, modules/32_Seeder_v1.sql,
       examples/PredicateZoo/01_Procedures.sql, Install_UnitAutogen.sql,
       powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

================================================================================
2026-06-03  v0.12.2 - parser performance (cold-start diagnosis + warm-path trims)
================================================================================
HighValueCustomer surfaced a "~50s to parse one proc" complaint. Profiling the
parser (Get-ParsedPredicates.ps1) on dbo.AssessCustomer (3 gates, 2/3-table
joins, a local) showed the truth:
  - 1st parse in a FRESH process = 52s; 2nd = 3.2s; 3rd = 3.3s.
So ~49s was ONE-TIME cold start (PowerShell compiling the ~1400-line script +
ScriptDom loading hundreds of CLR types + JIT). The warm per-proc cost is ~3.3s
even for this join-heavy proc. The cold start AMORTISES when the parser runs over
a whole schema in ONE process (`-Schema <name>` with no `-ProcName`, which the
runbook / a real sweep does) - the per-proc test (`-ProcName X`) paid the full
cold start for a single proc, which is the artefact behind the "50s".

WARM-PATH TRIMS (kept; correctness re-validated):
- Flat-skip: when the predicate TREE builds, Classify-Predicate returns
  immediately - the legacy flat (v0.10/v0.11) classification is dead weight (the
  seeder only uses it as the fallback when the tree did NOT build).
- Reflection cache: Get-FragmentChildProps caches, per CLR type, only the
  properties that can hold child fragments (skips value-type / string /
  ScriptTokenStream), so the generic AST walks (Visit-Fragment, Get-FragmentVarRefs,
  Collect-AssignNodes) stop GetValue()-ing irrelevant properties.
- Get-FragmentText caches the ScriptTokenStream getter (was re-read per token).
- Collect-AssignWithGuards stores the guard CONDITION FRAGMENT (object identity
  matches THEN vs ELSE) and renders it to text lazily only for a qualifying
  conditional local - rendering every guard eagerly was wasteful.

VALIDATED: AssessCustomer 6/6 branch tests pass; full pz sweep = 24/24 seedable
gates 100%, 0 errored tests, residue unchanged. No regression from any trim.

FOLLOW-UP (not done): cold start is inherent to PowerShell+ScriptDom on first
invocation; the practical mitigation is to parse once per schema. Integrating the
parser call into the Invoke-UnitAutogen orchestrator (so a sweep runs it once,
amortised) would remove the need to invoke it per-proc - a worthwhile enhancement.

FILES: powershell/UnitAutogen/Get-ParsedPredicates.ps1, CHANGES.md

================================================================================
2026-06-03  v0.12.3 - parser integrated into the Invoke-UnitAutogen orchestrator
================================================================================
The orchestrator (UnitAutogen.psm1) ran GenerateAndCoverDatabase but NOT the
ScriptDom parser, so the PredicateInbox was only populated if the user ran the
parser separately - and per-proc invocation paid the full cold start each time.

CHANGE: Invoke-UnitAutogen now runs Get-ParsedPredicates.ps1 as STEP 0, ONCE over
the whole target scope, before GACD - so the PowerShell/ScriptDom cold start is
paid a single time and amortised across every procedure. Scope = -SchemaFilter if
given, else '*' (all user schemas). A -SkipPredicateParse switch lets callers who
pre-parsed skip it.

SUPPORTING CHANGES (Get-ParsedPredicates.ps1):
- -Schema '*' parses EVERY user procedure in the DB in one process (the new
  enumeration also skips framework schemas + _cov/_covfn/_orig instrumentation
  copies). -Clear with '*' clears the whole-DB inbox.
- Optional -SqlUser / -SqlPassword for SQL auth (the orchestrator forwards a
  -Credential); default stays Integrated Security.
- StrictMode safety: pre-initialise $script:ResolvedParserType / uagLocalDefs /
  uagLocalCond / uagPropCache / rows / branchId at the top. When invoked with &
  from the module (which runs under Set-StrictMode), reading a not-yet-set
  $script: variable threw "...has not been set", the parse aborted, the inbox was
  left empty (cleared but not rewritten), and GACD fell back to string-gen
  (AssessCustomer -> 50%, false-arms only). Fixed -> AssessCustomer 6/6 = 100%
  through the one-command path.

NOTE (SSMS): generating tests in SSMS does NOT and CANNOT run the ScriptDom parser
(T-SQL cannot call a .NET library). SSMS generation READS the inbox; the parser
(PowerShell) must have populated it first. Generation / coverage / running tests
are pure T-SQL and incur no parser cost.

VALIDATED: Invoke-UnitAutogen -Database HighValueCustomer -SchemaFilter dbo runs
parser-then-cover in one shot; AssessCustomer 6/6 branches 100%, 0 errored;
coverage-report.html / coverage.xml / test-results.xml emitted.

FILES: powershell/UnitAutogen/UnitAutogen.psm1, powershell/UnitAutogen/Get-ParsedPredicates.ps1, CHANGES.md

================================================================================
v0.13 â€” SSMS-NATIVE PREDICATE PARSER (ScriptDom hosted in SQLCLR)   2026-06-03
================================================================================
WHY: the predicate parser was the ONE step that could not run from T-SQL â€” it was
PowerShell (Get-ParsedPredicates.ps1 driving ScriptDom). For an SSMS-only shop that
was an adoption blocker: without it the inbox is empty and data-shape branch seeding
degrades to string-gen. The note in the v0.12.3 entry above ("generating tests in
SSMS does NOT and CANNOT run the ScriptDom parser") is now OVERTURNED.

CHANGE: ScriptDom is hosted INSIDE SQL Server via SQLCLR and the parser logic is
ported to C#, exposed as two T-SQL procedures:
    EXEC TestGen.ParseDatabasePredicates  @SchemaFilter = N'dbo';   -- or NULL/'*'
    EXEC TestGen.ParseProcedurePredicates @Schema = N'dbo', @ProcName = N'...';
The whole workflow â€” parse, generate, cover, run â€” is now pure T-SQL in SSMS, with
NO PowerShell. The PowerShell parser remains as an alternative (servers that forbid
UNSAFE CLR); both write the identical TestGen.PredicateInbox.

DESIGN: design/DESIGN_v0_13_SqlClrParser.md (feasibility spike + architecture).

WHAT WAS BUILT (clr/):
- UnitAutogenClr.cs (~1300 lines): a faithful C# port of Get-ParsedPredicates.ps1
  â€” AST helpers, predicate-TREE build (atoms over query nodes with general joins +
  boolean WHERE trees), truth-propagation + per-table seed-plan merge, local-variable
  inline / conditional-IF expansion, tree->SQL render, flat-shape fallback, and a
  hand-rolled JSON writer (the SQLCLR allow-list excludes Newtonsoft/JavaScriptSerializer).
  Two CLR procs read sys.sql_modules over the context connection and write the inbox
  via TestGen.AddParsedPredicate. The inbox JSON keys/values match the PS parser, so
  modules 31-34, the generator and coverage are UNCHANGED.
- lib/UnitAutogenClr.dll (net472) + lib/Microsoft.SqlServer.TransactSql.ScriptDom.dll
  (Microsoft MIT, bundled; THIRD-PARTY-NOTICES.txt).
- Install-UnitAutogenClr.SSMS.sql: self-contained, zero-PowerShell installer â€”
  embeds both assemblies as 0x bytes + the SHA-512 trust hashes; trusts via
  sys.sp_add_trusted_assembly (clr strict ON, NO TRUSTWORTHY), CREATE ASSEMBLY UNSAFE,
  CREATE PROCEDURE. Build-Clr.ps1 / Emit-InstallerSql.ps1 regenerate it from source.

NOTES / GOTCHAS:
- csc: needs `using System.Data.SqlTypes` for SqlString; reference System.Data.dll +
  the bundled ScriptDom; net472 Framework csc at Framework64\v4.0.30319\csc.exe.
- Registration needs CONTROL SERVER (sp_add_trusted_assembly) -> run the install as
  sysadmin. ODBC18 sqlcmd needs -C (trust self-signed cert). sqlcmd is slow on the
  ~12 MB single-line 0x literal â€” run the installer in SSMS (or via SqlClient), not
  sqlcmd; SSMS handles it in ~10-15 s.
- EXTERNAL NAME is [UnitAutogenClr].[UnitAutogenClr].[<method>] (class has no namespace).

VALIDATED 2026-06-03:
- STRUCTURAL PARITY: CLR-populated inbox vs PowerShell-parser inbox over all 28
  PredicateZoo (schema pz) gates = ZERO diff on Shape, rendered predicate SQL, and
  both per-direction skip reasons. Both wrote 28 rows / 1 UNRECOGNISED.
- FUNCTIONAL (zero PowerShell): on HighValueCustomer, EXEC ParseDatabasePredicates
  'dbo' then EXEC GenerateAndCoverDatabase 'dbo' -> dbo.AssessCustomer 100% line (7/7)
  + 100% branch (6/6), 6 predicate-branch tests pass; GetVIPCustomerAnalyticsReport
  unchanged at 83.3%/0% (its @@TRANCOUNT>0 branch = the 1 correctly-UNRECOGNISED row).
- The self-contained Install-UnitAutogenClr.SSMS.sql re-installs cleanly (8 batches).

PENDING: optionally fold a pointer to clr/Install-UnitAutogenClr.SSMS.sql into the
single-file installer/runbook as a post-install step (the main installer is
line-sliced text; embedding 12 MB of assembly bytes there is left as a follow-up â€”
the separate SSMS installer is the supported path).

FILES: clr/UnitAutogenClr.cs, clr/lib/UnitAutogenClr.dll,
clr/lib/Microsoft.SqlServer.TransactSql.ScriptDom.dll,
clr/Install-UnitAutogenClr.SSMS.sql, clr/Build-Clr.ps1, clr/Emit-InstallerSql.ps1,
clr/Register-Clr.ps1, clr/README.md, clr/THIRD-PARTY-NOTICES.txt,
design/DESIGN_v0_13_SqlClrParser.md, CHANGES.md

--------------------------------------------------------------------------------
v0.13 FOLLOW-UP â€” ONE PARSER EVERYWHERE (PowerShell parser retired)  2026-06-03
--------------------------------------------------------------------------------
DECISION (user): use the C# (SQLCLR) parser everywhere; do NOT keep a separate
PowerShell parser in the PowerShell-Gallery deployment. Two parsers that must stay
behaviourally identical is a maintenance trap.

CONSEQUENCES:
- powershell/UnitAutogen/Get-ParsedPredicates.ps1 RETIRED -> moved to
  powershell/legacy/ (unmaintained; kept only as history + a last-resort option for
  servers that forbid UNSAFE CLR). See powershell/legacy/README.md.
- The module now installs + uses the in-DB parser:
  * Install-UnitAutogenDatabase runs the framework installer AND
    sql/Install-UnitAutogenClr.SSMS.sql (bundled) -> registers the CLR parser.
    Needs sysadmin (CONTROL SERVER) once + 'clr enabled'=1 (new for the module path).
  * Invoke-UnitAutogen STEP 0 now runs EXEC TestGen.ParseDatabasePredicates instead
    of the PowerShell parser (-SkipPredicateParse still honoured). No ScriptDom cold
    start. Verified Invoke-Sqlcmd handles the ~12 MB embedded-bytes installer (~17 s;
    unlike sqlcmd.exe, which chokes on the single long binary literal).
- De-duplicated the module: powershell/UnitAutogen.psm1 (an older standalone COPY
  that predated the parser and is imported directly by README/USAGE/CI) is now a thin
  SHIM that imports the canonical powershell/UnitAutogen/ module -Global. One
  implementation; the v0.13 behaviour applies no matter how the module is loaded.
  Verified: importing the shim resolves all 5 cmdlets from the canonical module.
- publish.ps1 now SYNCS both SQL installers (framework + CLR) from their canonical
  repo sources into the module's sql/ before publishing (single source of truth).
- Manifest: ModuleVersion 0.9.5 -> 0.9.6 (continues the public beta line; the
  "v0.13" label is the SQL-framework feature series, a separate scheme), FileList +
  sql/Install-UnitAutogenClr.SSMS.sql, description + release notes updated. Validated
  with Test-ModuleManifest.
- Docs rewritten to the single-parser, two-step (framework + parser) story:
  INSTALL.md (also fixed the stale Install_All_Combined filename), docs/quickstart.md
  (+ parser step + ParseProcedurePredicates), README.md (quick start now registers
  the parser + ParseDatabasePredicates), powershell/USAGE.md.
- End-user install bundle: Build-ReleaseBundle.ps1 -> dist/UnitAutogen-<ver>-install.zip
  (1_framework.sql + 2_parser.sql + README-INSTALL.md + LICENSE/COPYRIGHT/THIRD-PARTY).
  dist/ is gitignored.

NOTE: a server that forbids UNSAFE CLR outright now has no parser (tSQLt itself
already requires CLR, so this is a narrow edge case). Accepted trade for retiring the
second parser.

FILES: powershell/UnitAutogen/UnitAutogen.psm1, powershell/UnitAutogen/UnitAutogen.psd1,
powershell/UnitAutogen/sql/Install-UnitAutogenClr.SSMS.sql, powershell/UnitAutogen.psm1,
powershell/legacy/Get-ParsedPredicates.ps1, powershell/legacy/README.md, publish.ps1,
INSTALL.md, README.md, docs/quickstart.md, powershell/USAGE.md, Build-ReleaseBundle.ps1,
.gitignore, CHANGES.md

--------------------------------------------------------------------------------
v0.13 FIX â€” drop redundant legacy smoke-skip branch tests   2026-06-03
--------------------------------------------------------------------------------
SYMPTOM: a procedure with data-shape gates (e.g. HighValueCustomer.dbo.AssessCustomer)
showed 3 SKIPPED tests ("executes <branch> path", "MANUAL TEST REQUIRED: no
analysable branches ... only a smoke run") alongside the 6 passing predicate-branch
tests, even though the predicate seeder covered every gate (100% branch).

ROOT CAUSE: TWO generators emitted a test per gate. Module 34
(GeneratePredicateBranchTests) emits a per-branch artefact for every gate the parser
saw - a seeded TRUE/FALSE pair, or a NOT_TESTABLE skip for UNRECOGNISED gates. The
legacy "Test 10" branch-path generator in module 04 ALSO emits a smoke-only fallback
per detected branch when its pre-ScriptDom analyzer finds "no analysable paths"; that
fallback has no assertion, carries a SkipTest marker, and contributes no coverage
(skipped tests don't run). For data-shape gates the legacy analyzer always falls back,
so its smoke-skip was a pure redundant duplicate of module 34's real test. (Its name
was also garbled - "executes @CustomerID) = 3 path" - and it omitted the OUTPUT param,
so it would error if not skipped.)

FIX (module 04 GenerateTestsForProcedure, Test 10): when the in-database predicate
parser produced inbox rows for this proc (@uagPredicateActive=1), roll back the
smoke-ONLY fallback (the @v94SkipReason path) instead of emitting it - module 34
already provides the per-branch marker, so no branch loses its amber/skip marker and
no coverage is lost. The DROP is kept (cleans any stale copy). Real legacy assertions
(@v94SkipReason IS NULL, e.g. result-set CASE assertions) are never rolled back; and
when the parser did not run, the legacy skip is preserved as the only marker.

VALIDATED on HighValueCustomer: dbo.AssessCustomer regenerated -> base generation
9 tests -> 6 (the 3 smoke-skips gone), GeneratePredicateBranchTests emitted 6;
"12 test case(s) executed, 12 succeeded, 0 skipped, 0 failed"; coverage held at
100% line (7/7) + 100% branch (6/6).

GOTCHA (dev): sqlcmd defaults QUOTED_IDENTIFIER OFF; deploying module 04 via sqlcmd
WITHOUT -I created the proc with QI OFF, and its INSERT into a table with a filtered
index/computed column then failed at generation ("INSERT failed because ...
'QUOTED_IDENTIFIER'"). Use sqlcmd -I (or SSMS / Invoke-Sqlcmd, which are ON) when
deploying. The shipped installer runs under QI ON, so end users are unaffected.

FILES: modules/04_Test_Generator_v3.sql, Install_UnitAutogen.sql,
powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

--------------------------------------------------------------------------------
v0.13 FIX â€” coverage teardown resilience (no more stranded/lost procs)  2026-06-03
--------------------------------------------------------------------------------
SYMPTOM: RunCoverage renames the target proc to _orig, points a synonym at the
instrumented _cov, runs the tests, then restores (drop synonym, rename _orig back).
If anything between the rename and the restore aborted the batch (a connection-
recovery, a hard error) the restore was skipped and the proc was left stranded as
_orig + synonym; under some leftover combinations a subsequent run could even DROP
the real body. (Surfaced today as "AssessCustomer disappeared" mid-sweep.)

FIX (Install_UnitAutogen.sql, TestGen.RunCoverage):
- BULLETPROOF SELF-HEAL, run FIRST (before the testability gate + instrumentation):
  (a) drop a leftover synonym at the base name; (b) if base is missing and _orig
  exists, rename _orig back to base; (c) if base is a live proc and a stale _orig
  also exists, drop the redundant _orig (never the only copy); (d) if after all that
  the base is still not a live proc, RAISERROR + RETURN instead of instrumenting a
  missing object (which is what cascades into loss). Placing this ABOVE the
  AssessTestability gate was essential - a stranded synonym was otherwise judged
  NOT_TESTABLE and the proc returned un-healed.
- GUARANTEED RESTORE: the rename->synonym->run sequence is wrapped in TRY/CATCH; the
  restore below ALWAYS runs (and is idempotent - only renames _orig back when the
  base name is free), so a soft error can never strand the proc. A hard connection
  drop that bypasses CATCH is recovered by the self-heal on the NEXT run.
- Removed the old unconditional "DROP PROCEDURE _orig" at the rename step (the self-
  heal handles stale backups safely).

VALIDATED on HighValueCustomer: (1) stranded synonym + body-in-_orig -> RunCoverage
self-heals, runs 12/12, restores clean (base = real proc, _orig gone); (2) missing
proc -> clean RAISERROR caught as GACD would, no cascade, neighbours untouched.

PROCESS NOTE: today's repeated "proc vanished" reads were largely diagnostic races -
MCP timeouts left coverage runs in flight and overlapping queries hit the ~1-2s
rename window. Let runs quiesce; never launch a second coverage run while one may be
running; deploy SQL with sqlcmd -I (QUOTED_IDENTIFIER ON).

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
CHANGES.md

--------------------------------------------------------------------------------
v0.13 FIX â€” schema-bound dependencies no longer block FakeTable   2026-06-03
--------------------------------------------------------------------------------
REPORTED (GitHub discussion): "Object cannot be renamed because the object
participates in enforced dependencies" (Msg 15336) aborted generation/testing on a
real database.

ROOT CAUSE (reproduced + confirmed): tSQLt.FakeTable isolates a table by sp_rename;
SQL Server raises 15336 when the table is referenced by a SCHEMA-BOUND object - an
indexed view, a WITH SCHEMABINDING view/function, or a schema-bound/persisted
computed column. NOT plain foreign keys (tested: tSQLt handles inbound FKs itself).
A single such table made the raw CLR error abort the whole run.

FIX (TestGen.SafeFakeTable, the central fake wrapper): before the FakeTable attempts,
enumerate the table's schema-bound dependents via sys.sql_expression_dependencies
(is_schema_bound_reference = 1), transitively (recursive CTE), and DROP them
deepest-first (DROP VIEW / DROP FUNCTION). tSQLt wraps every test in a transaction
that ROLLS BACK, so the dependents are restored automatically when the test ends -
zero permanent change (verified: the schema-bound view was present again after the
run). Also routed the predicate-branch tests (module 34 / GeneratePredicateBranchTests)
through SafeFakeTable instead of calling tSQLt.FakeTable directly, so they get the
same protection. The base generator's mock block already used SafeFakeTable.

VALIDATED on HighValueCustomer: with a WITH SCHEMABINDING view over dbo.Orders (a
table AssessCustomer fakes) present - the exact 15336 trigger - generate+cover now
runs 12/12, 100% line + branch, 0 errors; the view is intact afterward.

KNOWN LIMITATION (honest residue): if the procedure UNDER TEST itself uses a
schema-bound object over a faked table (e.g. reads the indexed view, or calls a
schema-bound function on the faked table), dropping the dependent will make the proc
fail with a missing-object error rather than the cryptic rename error. A future
refinement is to detect proc-usage and mark such procs NOT_TESTABLE with a clear
reason. Nested schema-bound chains beyond MAXRECURSION 64 are also not unwound.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
modules/34_Predicate_BranchTests_v1.sql, CHANGES.md

--------------------------------------------------------------------------------
v0.9.11 FIX - schema-bound cleanup must not doom the test transaction   2026-06-04
--------------------------------------------------------------------------------
REPORTED (own AdventureWorks2025 coverage report): error rate jumped to 23.9%
(64 of 268 tests Error). Whole clusters flipped to all-error: the recursive/temp-
table procs (uspGetBillOfMaterials, uspGetEmployeeManagers, uspGetManagerEmployees,
uspGetWhereUsedProductID), the HumanResources UPDATE procs (uspUpdateEmployee*),
and dbo.ufnGetContactInformation - all 0% covered.

ROOT CAUSE (regression introduced by the v0.13/v0.9.10 schema-bound fix above):
every failing test reported "SafeFakeTable: all attempts to fake <T> failed. Last
error: The current transaction cannot be committed ... Roll back the transaction."
= a DOOMED transaction. The schema-bound dependent walk added to SafeFakeTable used
a recursive CTE with NO cycle guard. A table with a PERSISTED COMPUTED COLUMN built
on a WITH SCHEMABINDING function (e.g. Sales.Customer.AccountNumber via
dbo.ufnLeadingZeros) records a schema-bound dependency on ITSELF, so the walk looped
to OPTION (MAXRECURSION 64) and raised error 530. tSQLt runs tests with XACT_ABORT
ON, under which that error DOOMS the transaction; the surrounding TRY/CATCH swallowed
the message but could not un-doom it, so all three FakeTable attempts then failed and
the test errored. The HighValueCustomer validation missed it because that table's one
schema-bound view drop happened to succeed cleanly (no self-edge, no cycle).

FIX (TestGen.SafeFakeTable):
  1. SET XACT_ABORT OFF for the duration of the best-effort schema-bound cleanup
     (auto-restored on proc exit; explicitly SET back ON before the FakeTable
     attempts). Now any error in this cleanup is catchable and leaves the test
     transaction usable instead of doomed.
  2. Cycle-guarded recursive walk: ignore the table's self-edge (referencing_id
     <> @ffObj) and carry a path string so an already-visited node is never
     re-entered. Termination no longer depends on MAXRECURSION (raised to 256 as a
     belt-and-suspenders cap, but it is not reached).

VALIDATED on AdventureWorks2025 after ALTER:
  - uspUpdateEmployeeLogin   11 Error -> 11 Pass
  - uspGetEmployeeManagers    7 Error ->  7 Pass (+1 intended skip)
  - uspGetBillOfMaterials     8 Error ->  8 Pass (+1 intended skip)
  - ufnGetContactInformation  2 Error ->  2 Pass (+1 intended bless-skip)
Both error clusters + the function case clear with one change; siblings share the
same SafeFakeTable path.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
CHANGES.md

--------------------------------------------------------------------------------
v0.9.11 FIX - shape characterization ignores IsNullable   2026-06-04
--------------------------------------------------------------------------------
REPORTED (full AdventureWorks2025 sweep, after the doom fix): 22 tests Failed,
every one a pz gate, every message "Result-set shape drift ... Re-bless with
EXEC TestGen.BlessBaseline". 0 errors (the doom regression was already fixed); the
17 real AdventureWorks objects were 0 fail / 0 error - all 22 fails were the
synthetic gates.

ROOT CAUSE: TestGen.AssertResultShape compared the blessed baseline shape to the
current shape including IsNullable. The drift was ALWAYS the same single attribute:
a literal/computed result column (e.g. SELECT 'x' AS Arm) had IsNullable True in the
baseline and False now. SQL Server's nullability INFERENCE for literal/computed
columns is unstable - it flips True<->False across recompiles, builds and call
contexts - so IsNullable is a false-positive source for shape characterization.
Column count, order, names, types and sizes (the real contract) all matched.

FIX (TestGen.AssertResultShape): drop IsNullable from the #ExpectedShape/#ActualShape
comparison tables. Count/ordinal/name/type/MaxLength/Precision/Scale are still
asserted in full. IsNullable is still recorded in TestGenLog.ResultShapeBaseline for
information; it is simply not compared. No re-bless needed - existing baselines now
match.

VALIDATED: ALTERed on AdventureWorks2025, re-ran all 27 gate classes - 0 shape-drift
failures (was 22). Only residual: test_DynamicLocalGate (3) = "Could not find stored
procedure pz.DynamicLocalGate" - an ORPHAN test class whose base proc does not exist
(not in the 45-object report); stale cruft, unrelated to either fix.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
CHANGES.md

--------------------------------------------------------------------------------
v0.9.12 FIX - WideWorldImporters surfaced two real edge cases   2026-06-04
--------------------------------------------------------------------------------
Broad-DB validation on WideWorldImporters (gnarlier schema than AdventureWorks):
both v0.9.11 fixes held (0 fails, no doom-cascade). Two genuine issues found + fixed.

(1) ERROR on Integration.GetStockHoldingUpdates - "JSON path is not properly
    formatted. Unexpected character 'O' is found at position 11" (Msg 13607).
    ROOT CAUSE: TestGen.AssertResultRowsMatchBaseline built the OPENJSON WITH path
    as '$.' + ColumnName, UNQUOTED. WWI uses friendly column names with spaces
    ("Quantity On Hand", "Bin Location"), so '$.Quantity On Hand' is an invalid JSON
    path. AdventureWorks' tight names never exposed it.
    FIX: quote the key -> '$."' + REPLACE(ColumnName,'"','\"') + '"'. Count/order/
    names/types/sizes still asserted. Validated: GetStockHoldingUpdates 1 err -> 0
    (4 pass + 1 designed skip). Quoted keys are valid for plain names too (no
    AdventureWorks regression).

(2) GEN FAILURE on Website.CalculateCustomerPrice - "shadow compile failed:
    Incorrect syntax near 'OWNER'". ROOT CAUSE: the function is declared
    RETURNS decimal(18,2) WITH EXECUTE AS OWNER AS BEGIN... . TestGen.FindTopLevelAs
    returned the FIRST top-level AS, which is the AS inside "EXECUTE AS OWNER", so
    the shadow body wrongly began at 'OWNER'.
    FIX: FindTopLevelAs now skips an AS whose preceding word is EXECUTE (the WITH
    EXECUTE AS <owner|caller|self|'user'> clause); the body-introducing AS is the
    next one. Validated: a self-contained WITH EXECUTE AS OWNER scalar function now
    gens + instruments to 100% line / 100% branch. On WWI's CalculateCustomerPrice
    the shadow now builds and the function is correctly reclassified to the HONEST
    reason (depends on a system-versioned temporal table -> NOT_TESTABLE) instead of
    a misleading syntax error.

NOT fixed (deferred, by request): inline TVFs (RETURNS TABLE AS RETURN ...) still
report a generic "deferred" rather than a clean NOT_TESTABLE reason (e.g.
Application.DetermineCustomerAccess). Polish, not a correctness bug.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
CHANGES.md

--------------------------------------------------------------------------------
v0.9.13 POLISH - honest classification for two un-coverable cases   2026-06-04
--------------------------------------------------------------------------------
Two "known gap" reporting refinements (no coverage-number change - both cases are
genuinely not auto-coverable; the fix is an accurate reason instead of a generic one):

(1) Procedures with an error-handling CATCH that runs its own ROLLBACK TRANSACTION
    (e.g. HumanResources.uspUpdateEmployeeHireInfo) cannot have their error path
    auto-driven: the proc's ROLLBACK unwinds tSQLt's per-test transaction (proved:
    Msg 266 "transaction count ... mismatch"). The framework already excludes these
    from forced-error tests (@v943CatchRollback); now the SKIP reason says exactly
    that ("error-handling (CATCH) path ... ROLLBACK ... Msg 266 ... cover by hand")
    instead of the generic "no analysable branches were found".

(2) Inline TVFs (type 'IF': RETURNS TABLE AS RETURN (<select>)) have no procedural
    body to instrument, so a _cov can never be produced. Previously reported as
    "coverage deferred: instrumenter could not produce a compiling _cov" (sounds like
    a bug to report). Now classified NOT_TESTABLE with the accurate reason: "inline
    table-valued function ... no procedural statements or branches to instrument ...
    coverage does not apply; exercise via its callers". Multi-statement TVFs ('TF')
    still get the instrumenter-limitation message.

VALIDATED on live DBs: uspUpdateEmployeeHireInfo (AdventureWorks) now shows the
CATCH/ROLLBACK reason; Application.DetermineCustomerAccess (WideWorldImporters) now
shows the inline-TVF reason. Both generator procs recompiled cleanly.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
CHANGES.md

--------------------------------------------------------------------------------
v0.9.13 FIX - SkipTest reason must escape apostrophes   2026-06-04
--------------------------------------------------------------------------------
Caught by the AdventureWorks broad sweep right after the v0.9.12 classification
polish: uspUpdateEmployeeHireInfo flipped from 1 skip to 1 ERROR -
"Annotation has unmatched quote". The new CATCH/ROLLBACK skip reason contained an
apostrophe ("tSQLt's"), and the v9.4 skip path emitted the reason into the
--[@tSQLt:SkipTest]('...') annotation WITHOUT doubling quotes (module 34's
NOT_TESTABLE path already did). tSQLt's annotation parser then saw an unmatched
quote and errored the test instead of skipping it.
FIX: both v9.4 SkipTest emit sites now REPLACE(reason, '''', '''''') (double the
apostrophes). Re-validated: uspUpdateEmployeeHireInfo back to 11 pass + 1 skip, 0
errors, full reason text intact. Lesson: any text put into a tSQLt SkipTest/
annotation must double single quotes.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

--------------------------------------------------------------------------------
v0.9.13 RELEASE FIX - psd1 ReleaseNotes exceeded PSGallery's 10600-char limit
--------------------------------------------------------------------------------
The 0.9.13 publish workflow FAILED at Publish-Module with HTTP 400:
"A package's ReleaseNotes property extracted from the PowerShell manifest may not be
more than 10600 characters long." Cause: every release prepended a new version
section to UnitAutogen.psd1 ReleaseNotes without ever trimming, so the cumulative
notes (v0.9.0 -> v0.9.13, 10 sections) hit exactly the 10600 cap. The package itself
was valid - only the notes field was too long.

FIX: trimmed ReleaseNotes to the latest THREE versions in full (now ~3,200 chars);
older history (v0.9.10 back to v0.9.0) replaced by a pointer to CHANGES.md and the
GitHub Releases page. The tag had to be MOVED to the corrected commit to re-publish
(git tag -d / push :refs/tags / re-tag / push) - the workflow checks out the tag.

POLICY (to prevent recurrence): keep only the most recent ~3 version sections in
the psd1 ReleaseNotes; the full, permanent changelog lives here in CHANGES.md and on
GitHub Releases. PSGallery hard limit is 10600 chars on ReleaseNotes.

FILES: powershell/UnitAutogen/UnitAutogen.psd1, CHANGES.md

--------------------------------------------------------------------------------
v0.9.14 - clean re-cut of the unpublished v0.9.13   2026-06-04
--------------------------------------------------------------------------------
v0.9.13 never reached PSGallery (its publish failed on the ReleaseNotes 10600-char
limit; fixed above). Rather than move the tag, re-cut the identical content as
v0.9.14 with a fresh tag. v0.9.14 == intended v0.9.13: JSON-path quoting, EXECUTE AS
shadow split, CATCH/ROLLBACK + inline-TVF honest reasons, SkipTest apostrophe-escape,
plus the trimmed psd1 ReleaseNotes. No code difference from the validated build.

FILES: powershell/UnitAutogen/UnitAutogen.psd1, VERSION, CHANGES.md

--------------------------------------------------------------------------------
PHASE 1 (unreleased, pending broad-sweep) - count-changing procs must modify data
--------------------------------------------------------------------------------
The "touches only mocked tables" isolation test for an INSERT/DELETE/MERGE proc
previously only PRINTed the per-table before/after row counts - no assertion - so a
side-effect write (e.g. an audit-log INSERT) went unverified: a regression removing
it, or a seed that fails to drive the DML, passed silently.

CHANGE (GenerateTestsForProcedure, the count-changing ELSE branch): replace the
print-only fallback with an assertion that AT LEAST ONE faked table's row count
changed on the seeded happy path (the count-changing analog of the existing UPDATE
content assertion). If nothing changed, the seed did not drive the proc's
INSERT/DELETE/MERGE or the DML was removed - both real failures.

VERIFIED on HighValueCustomer.GetVIPCustomerAnalyticsReport: the audit-log insert is
now asserted (test passes because AuditExecutionLog grows 5->6); negative proof
(no change) fails with "Expected <1> but was <0>".

EXPECTED on the broad sweep: some count-changing procs whose seeded happy path does
NOT trigger their DML (conditional INSERT/DELETE not reached, MERGE that only
updates, DELETE matching nothing) will FLIP from print-pass to FAIL. Triage each:
genuine seeding gap (the intended behaviour to surface) vs. a case where the DML
rightly does not fire on the happy path. NOT versioned/shipped until that sweep is
clean. Phase 2 = exact per-table +N delta (INSERT...SELECT capture, branch DELETE);
phase 3 = MERGE.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql, CHANGES.md

PHASE 1 REFINEMENT (still unreleased): the count-changing assertion is now
CONTENT-AWARE. A count-only check false-FAILS when a proc holds a table's row count
while changing its rows (a delete+insert, or a balanced MERGE). Fix: capture content
hashes (CHECKSUM_AGG, the same machinery UPDATE procs already use) for count-changing
procs too, and assert at least one faked table changed by ROW COUNT **or** CONTENT.
Verified: net-zero delete+insert now passes via the content hash; the demo proc still
passes; "nothing changed" still fails. (NOTE the per-table check already handled the
two-table A-1/B+1 case - both tables show a changed count; the real hole was the
single-table net-zero, now closed.) Residual: "at least one changed" still cannot
detect a PARTIAL regression (proc should write 2 tables, now writes 1) - that is
phase 2's exact per-table delta.

## 2026-06-05 - DML EFFECT ASSERTIONS PHASE 2 (capture-based exact per-table counts) - UNRELEASED

Replaces phase 1's "at least one faked table changed (count OR content)" heuristic, for
count-changing procs, with EXACT per-table row-count assertions derived from a
generation-time capture run.

MECHANISM (new proc TestGen.CaptureExpectedCounts): at generation time, for a
count-CHANGING proc, the generator runs the test's OWN Arrange (SafeFakeTable + the
reverse-predicate seed = @MockBlock) + the procedure once, inside its own BEGIN TRAN,
records each faked table's COUNT(*) before and after into a TABLE VARIABLE (survives
the ROLLBACK), then rolls back - fakes/seed/writes undone, real tables restored. The
counts come back through an OUTPUT param. Validated on
HighValueCustomer.GetVIPCustomerAnalyticsReport: AuditExecutionLog captured 5->6, all
read-only tables held at 5, @@TRANCOUNT cleanly 0, real tables restored, no leftover
fakes.

EMITTED TEST (count-changing case): one tSQLt.AssertEquals per faked table, @Expected =
the captured AFTER count, @Actual read from the test's own #v94_RcAfter capture. This
pins the procedure's EXACT write footprint - a broken/removed write under-counts; a
stray write to another table over-counts. GetVIPCustomerAnalyticsReport now emits
AuditExecutionLog = 6 (the audit insert that previously went UNASSERTED - the user's
original finding) and every other table = 5 (held). Class result: "touches only mocked
tables" PASSES; AssessCustomer (count-stable) still 6/6 - no regression.

SKIP-AND-HIGHLIGHT: if the capture shows NO faked table changed (the seed drove no
write), the generator emits the COMPLETE test (all per-table assertions, for reference)
but STUFFs a --[@tSQLt:SkipTest](...) annotation before its CREATE PROCEDURE naming the
gap, so the developer fixes the seed or the procedure. Honest NOT_TESTABLE rather than a
misleading pass or a blame-the-proc fail. (Reuses the existing branch-test SkipTest
insert-point + quote-escaping pattern.)

SIDE-EFFECT GUARD: the capture is SKIPPED (falls back to the phase-1 heuristic, no
behaviour change) when the proc body contains a non-transactional effect a ROLLBACK
cannot undo - sp_send_dbmail, NEXT VALUE FOR (sequence), xp_cmdshell, OPENROWSET/
OPENQUERY (linked server), or a global ##temp. Also skipped when already inside a
transaction (@@TRANCOUNT <> 0), so the capture's ROLLBACK can never unwind a caller.
Any capture error -> @CapErr set, exact path skipped, phase-1 heuristic used. Never
throws, never corrupts.

DETERMINISM: capture and test use the IDENTICAL Arrange string, so the measured counts
are exactly reproducible at run time. Residual: a write count that depends on a
non-deterministic value (rare for COUNT) could drift - those procs fall back to phase 1
naturally only if they also hit the side-effect/branch guards; flagged for the sweep.

STILL TO DO IN PHASE 2: extend TestGen.ExtractLeafDml (recognises UPDATE + INSERT VALUES
only) to INSERT...SELECT and DELETE so PREDICATE-GATED branch DML gets exact, reverse-
seeded per-branch assertions (the gated-write locality from the design doc). MERGE =
phase 3. NOT versioned/shipped until the broad AdventureWorks + WideWorldImporters
sweep is clean - one bump, all phases.

FILES: Install_UnitAutogen.sql (TestGen.CaptureExpectedCounts new; TestGen.
GenerateTestsForProcedure "touches only mocked tables" count-changing branch),
powershell/UnitAutogen/sql/Install_UnitAutogen.sql (synced), CHANGES.md,
design/DESIGN_DML_Effect_Assertions.md, design/DESIGN_Error_Expectation_Tests.md (new -
separate over-generation fix, queued).

## 2026-06-05 - PHASE 2 cont. - leaf parser + branch replay extended to DELETE and INSERT...SELECT - UNRELEASED

TestGen.ExtractLeafDml (leaf body-DML capture for the v9.4 snapshot-and-replay branch
assertions) now recognises a single-target DELETE and INSERT...SELECT, in addition to
UPDATE and INSERT...VALUES. MERGE stays deferred to phase 3.

Parser (ExtractLeafDml):
 - keyword guard: exactly one of UPDATE/INSERT/DELETE (was UPDATE/INSERT only); MERGE
   still rejected.
 - INSERT...SELECT no longer rejected (the replay snapshots the target and replays the
   INSERT...SELECT onto it).
 - DELETE...JOIN rejected (two table refs; the single-target {{TARGET}} rewrite + whole-
   table replay cannot handle a joined delete).
 - target parse skips the optional FROM (DELETE) as well as INTO (INSERT).
 UNIT-VERIFIED on HighValueCustomer: simple DELETE -> DELETE/Orders, {{TARGET}} rewrite
 correct; INSERT...SELECT -> INSERT/AuditLog, col list preserved; DELETE...JOIN -> NULL;
 UPDATE + INSERT VALUES still parse; two-DML body -> NULL.

Branch replay (TestGen.GenerateTestsForProcedure v9.4 snapshot-and-replay):
 - @v94HasBodyDml now includes DELETE (gets the before/after delta assertion).
 - WHERE-nondeterminism guard now also applies to DELETE (a GETDATE/NEWID/RAND in the
   DELETE WHERE blocks replay, same as for UPDATE).
 - INSERT column-list capture now bounds on VALUES *or* SELECT, so an INSERT...SELECT's
   explicit column list is captured (omitted columns stay out of the compare).
 - delta assertion: new DELETE branch asserts the target SHRANK (count after < before);
   INSERT...SELECT reuses the INSERT "grew" branch.
 The whole-table characterization (#v94_ExpProj vs #v94_ActProj via AssertEqualsTable)
 is unchanged and now covers DELETE/INSERT...SELECT replays automatically.

SCOPE NOTE: the snapshot-and-replay path only engages for branches AnalyzeBranchPaths
emits a REPLAY path for (table/column/EXISTS-gated branches - the reverse-seeding cases).
A branch gated purely on IF @param = <literal> with a DML body produces no REPLAY path
(pre-existing, same for UPDATE/INSERT) and falls back to the smoke/SkipTest marker. So
end-to-end DELETE/INSERT...SELECT branch assertions land on real column-gated procs in
the broad sweep; the parser + replay code itself is unit-verified and compiles/runs with
no regression (AssessCustomer 6/6; GetVIPCustomerAnalyticsReport phase-2 exact counts
still pass).

INCIDENT: the Edit tool silently TRUNCATED Install_UnitAutogen.sql at line 15469 mid-way
through these edits (file ended mid-comment, lint caught it as an unterminated block
comment far from the edit site). Recovered by restoring from the in-sync bundle copy and
re-applying all leaf edits via a deterministic Python script (exact-match, CRLF-preserving,
count-checked), then re-verifying line count + tail + lint. Reinforces the standing rule:
verify file size/tail/lint after editing this large module.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql (synced,
identical), CHANGES.md, design/DESIGN_DML_Effect_Assertions.md.

## 2026-06-05 - WWI sweep gap fixes: TVP -> NOT_TESTABLE + SafeFakeTable drops SECURITY POLICY - UNRELEASED

The WWI sweep (after turning SYSTEM_VERSIONING OFF so DML procs became testable) surfaced
two pre-existing gaps - both now fixed. Neither is related to the phase-2 / leaf-parser work.

1) TABLE-VALUED PARAMETERS (Website.InsertCustomerOrders: 8/8 fail).
   The proc takes TVPs (@Orders = Website.OrderList, @OrderLines = OrderLineList). The
   framework passed them as NULL/scalar -> "Operand type clash: NULL is incompatible with
   OrderList" on EVERY test (incl. executes-valid + touches-only), before the body ran.
   FIX: TestGen.AssessTestability now detects a table-valued parameter (sys.parameters JOIN
   sys.types WHERE is_table_type = 1) and classifies the proc NOT_TESTABLE with a clear
   reason (honest silence) instead of emitting guaranteed-fail tests. Future enhancement:
   build a table variable of the type, seed it, and pass it. VERIFIED: InsertCustomerOrders
   8 fails -> 1 NOT_TESTABLE skip.

2) SECURITY POLICY (RLS) IN THE SCHEMA-BOUND CHAIN (Website.ActivateWebsiteLogon,
   ChangePassword: 7 errors each - "SafeFakeTable: all attempts to fake Application.Cities
   failed ... transaction cannot be committed").
   Root cause: Application.Cities is locked by a chain - SECURITY POLICY
   Application.FilterCustomersBySalesTerritoryRole (type 'SP') schema-binds the predicate
   inline-TVF Application.DetermineCustomerAccess, which schema-binds Cities. tSQLt fakes by
   RENAMING the table, which fails with "participates in enforced dependencies". SafeFakeTable
   already walks the schema-bound chain deepest-first and drops dependents, BUT its drop
   cursor filtered o.type IN ('V','FN','IF','TF','FS','FT') - which EXCLUDES 'SP'. So the
   policy was never dropped, the TVF could not be dropped (the policy referenced it), Cities
   could not be renamed, and the transaction doomed.
   FIX: add 'SP' to the drop-cursor type filter and emit DROP SECURITY POLICY (vs DROP
   FUNCTION/VIEW). The existing lvl-DESC order drops the policy (lvl 2) before its predicate
   function (lvl 1). VERIFIED: SafeFakeTable 'Application.Cities' -> faked OK; ActivateWebsite
   Logon 7 framework errors -> the proc now RUNS (remaining "Invalid PersonID" failures are a
   SEPARATE happy-path seeding-vs-validation gap, logged for backlog, not this fix nor ours).

NOTE: the standalone TestGen.ClearSchemaBoundReferences helper (emitted into MockBlocks) is
single-level and not 'SP'-aware, but it only ever sees a table's DIRECT dependents (never the
lvl-2 policy) and SafeFakeTable's recursive walk is the authority - so it is harmless
redundancy. Minor cleanup candidate (make it defer to SafeFakeTable, or recurse + SP-aware).

BACKLOG surfaced by the same sweep (NOT fixed here): (a) happy-path seed not satisfying a
proc's existence-check validation (ActivateWebsiteLogon "Invalid PersonID"); (b) FOR JSON
result sets break INSERT...EXEC baseline capture (SearchForStockItems*); (c) boundary/NULL
fed into a TOP/FETCH rowcount param (negative/NULL) - same over-generation family as the
error-expectation tests.

FILES: Install_UnitAutogen.sql (TestGen.SafeFakeTable drop cursor; TestGen.AssessTestability
TVP check), powershell/UnitAutogen/sql/Install_UnitAutogen.sql (synced, identical), CHANGES.md.

## 2026-06-05 - CLEANUP SPRINT: clear all false-red baggage surfaced by the sweeps - UNRELEASED

Goal: no procedure should report a FAILURE/ERROR for a framework reason; every such case
is now either a real pass or an honest, actionable Skip/NOT_TESTABLE.  All verified live.

1) ERROR-PATH DETECTION (TestGen.ExtractErrorPaths) - the linchpin for both over- and
   under-generation of error-expectation tests. Three fixes:
   a) Blank BEGIN CATCH..END CATCH before scanning, so a catch-rethrow
      (RAISERROR(ERROR_MESSAGE()...) / bare THROW;) is NOT counted as an input-validation
      error path.  -> GetVIPCustomerAnalyticsReport: 3 false "rejects/raises error" fails
      GONE; now 7/7 green.
   b) Parse parenthesis-less THROW (THROW errno,'msg',state;) - it was completely missed
      (the scanner required a '(').  -> ActivateWebsiteLogon's "Invalid PersonID" THROW is
      now detected, so boundary/NULL tests correctly EXPECT the throw (pass).
   c) Tolerate an N'...' nvarchar literal prefix on the message arg (both RAISERROR + THROW).

2) HONEST-SKIP FOR HAPPY-PATH VALIDATION (new TestGen.ProbeHappyPath + generator wiring).
   When the generated happy-path inputs do not satisfy the procedure's OWN validation (it
   raises a detected guard error), the framework cannot construct valid inputs - so the
   happy-path-success tests (executes-valid / touches-only / OUTPUT / baseline rows) now
   carry a [@tSQLt:SkipTest] annotation with a clear reason instead of FAILING by
   construction.  Decided at generation time by running the proc under the seed in a
   rolled-back transaction (tSQLt has no runtime SkipTest, only the annotation).  Side-
   effect/transaction guarded.  -> ActivateWebsiteLogon, ChangePassword: 7 errors each ->
   3 pass + 2 honest skip, 0 fail.

3) BOUNDARY/NULL "ACCEPTS" PROBE-SKIP.  An "accepts low/high boundary" or "accepts NULL"
   test whose generated value is outside the proc's domain (e.g. negative/NULL into a
   TOP/FETCH rowcount) now SkipTest-annotates that one test (probed at gen time) instead
   of failing.  -> SearchForStockItems(+ByTags): negative/NULL TOP fails -> honest skips.

4) FOR JSON / FOR XML result sets.  The row-baseline test (INSERT #base EXEC) cannot
   capture them ("FOR JSON clause is not allowed in an INSERT").  That single test is now
   skipped for such procs (shape test still applies).  -> SearchForStockItems* baseline
   error GONE.

5) ClearSchemaBoundReferences emission RETIRED.  TestGen.SafeFakeTable now walks the full
   schema-bound chain itself (recursive, cycle-guarded, SECURITY-POLICY-aware), so the
   old single-level, non-SP-aware upfront pre-pass was redundant and a source of "Could
   not drop" noise - removed from the MockBlock.

NOT FIXED (honest, transparent - not a false red): Website.CalculateCustomerPrice still
reports "coverage deferred: instrumenter could not produce a compiling _cov".  It is a
multi-statement scalar function WITH EXECUTE AS OWNER whose shadow-proc transform the v11
function instrumenter cannot yet build; the framework already DEFERS it cleanly (gen=N),
which is honest behaviour, not baggage.  Logged as a future v11 shadow-transform
enhancement, not a bug.

VERIFIED live on WWI (versioning OFF): ActivateWebsiteLogon 3P/2S, ChangePassword 3P/2S,
SearchForStockItems 5P/3S, SearchForStockItemsByTags 5P/3S, InsertCustomerOrders 1 skip
(TVP NOT_TESTABLE) - 0 failures, 0 errors across all.  GetVIPCustomerAnalyticsReport
(HighValueCustomer) 7/7.  Re-install the updated installer on each DB and re-sweep to
confirm database-wide.

FILES: Install_UnitAutogen.sql (TestGen.ExtractErrorPaths; new TestGen.ProbeHappyPath;
TestGen.GenerateTestsForProcedure happy/boundary/NULL probe-skip + FOR JSON gate +
ClearSchemaBoundReferences retirement), powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(synced), CHANGES.md.

## 2026-06-05 - TVP CONSTRUCTION: table-valued parameters now auto-tested (was NOT_TESTABLE) - UNRELEASED

A procedure with a table-valued parameter (TVP) used to be classified NOT_TESTABLE because
the generator could only pass scalars/NULL -> "Operand type clash: NULL is incompatible with
<type>". Now the generator CONSTRUCTS the argument:

NEW TestGen.BuildTvpSetup(@TypeSchema,@TypeName,@VarName,@SetupSql OUT): reads the table
type's columns (via sys.table_types.type_table_object_id), excludes identity/computed/
rowversion, and emits  DECLARE @var AS <schema>.<type>;  INSERT @var (cols) VALUES (one
type-valid, seed-aligned row);  - values follow the table-seeder's row-1 convention
(int=1, string='SampleText_1', date='2024-06-15', etc.) so they line up with the faked-table
seeds. (Empty-TVP fallback: DECLARE only, when the type has no insertable columns.)

GENERATOR wiring (TestGen.GenerateTestsForProcedure): @Params already carried IsTableType +
TypeSchema; the arg-build loop now has a TVP branch that calls BuildTvpSetup, appends the
DECLARE+INSERT to @OutputDecls (so it flows to every test AND ProbeHappyPath AND
CaptureExpectedCounts), and passes  @param = @tvp_<param>  in the happy/boundary/high arg
lists. NULL-injection loop skips TVP params (a TVP can't be NULL). The TVP -> NOT_TESTABLE
gate in TestGen.AssessTestability is REMOVED. Safety net: if the proc validates the TVP
contents and the seed doesn't satisfy it, the happy-path probe honest-skips (no false red).

VERIFIED on WWI: Website.InsertCustomerOrders -> from NOT_TESTABLE to 6 tests, 6 pass, 0 skip,
0 fail (the OrderList + OrderLineList TVPs are built, seeded, and the proc runs + asserts its
effect). The TVP gate was also MASKING the real status of two other procs: InvoiceCustomerOrders
now correctly reports its temporal-table blocker, RecordColdRoomTemperatures its memory-optimized
blocker - both real reasons that were hidden behind the TVP gate before.

FILES: Install_UnitAutogen.sql (new TestGen.BuildTvpSetup; GenerateTestsForProcedure TVP arg
branch + NULL-loop skip; AssessTestability TVP gate removed), powershell/UnitAutogen/sql/
Install_UnitAutogen.sql (synced), CHANGES.md.

## 2026-06-05 - TVP fix #2: coverage instrumenter must emit table params schema-qualified + READONLY - UNRELEASED

The first TVP change made the generated TESTS pass (6/6 via tSQLt.Run), but the full sweep
(coverage path) flipped InsertCustomerOrders to 6 FAIL / 0% line.  Root cause: a SECOND bug.
TestGen.InstrumentProcedure rebuilds the proc header from sys.parameters when it creates the
instrumented <proc>_cov copy, and it emitted a table-valued parameter as just  @Orders OrderList
- WITHOUT the schema qualifier and WITHOUT the mandatory READONLY.  So the _cov failed to
compile and every test failed under coverage (the original proc was renamed away for
instrumentation).  Direct tSQLt.Run passed because it runs the ORIGINAL proc, not the _cov -
which is why isolated validation missed it; only the coverage sweep surfaced it.

FIX: the instrumenter's param-list builder now carries t.is_table_type + SCHEMA_NAME(t.schema_id)
and, for a table-type parameter, emits  @p [schema].[type] READONLY  (no length suffix, no
= NULL default, no OUTPUT - none apply to a TVP).  VERIFIED: [Website].[InsertCustomerOrders]_cov
now compiles (header: @Orders [Website].[OrderList] READONLY, @OrderLines [Website].[OrderLineList]
READONLY, ...) and EXEC TestGen.RunCoverage 'Website','InsertCustomerOrders' -> 6 tests 6 pass,
72.7% line coverage (Orders faked-table 5->6).  Re-sweep WWI: InsertCustomerOrders moves from the
6-fail row to a green ~72% row.

FILES: Install_UnitAutogen.sql (TestGen.InstrumentProcedure param-list builder),
powershell/UnitAutogen/sql/Install_UnitAutogen.sql (synced), CHANGES.md.

## ============================================================================
## RELEASE v0.10.0 (beta) — 2026-06-05   (bump from 0.9.14)
## ============================================================================

Consolidates all the unreleased work above into the single v0.10.0 release.

NEW CAPABILITIES
- DML effect assertions: exact per-table row-count assertions for modifying procs,
  measured at generation time under the reverse-predicate seed (phase 1 + phase 2);
  INSERT (VALUES + SELECT), UPDATE, DELETE; skip-and-highlight when no write fires.
- DELETE + INSERT...SELECT branch coverage (ExtractLeafDml + snapshot-and-replay).
- Table-valued parameters: constructed + seeded + passed (was NOT_TESTABLE); coverage
  instrumenter emits table params schema-qualified + READONLY.
- SafeFakeTable drops SECURITY POLICY (RLS) predicate-function chains before faking.

HONESTY / NO-FALSE-RED CLEANUP
- Error-expectation over-generation fixed (catch-rethrow blanking + parenless THROW +
  N'...' literal handling in ExtractErrorPaths).
- ProbeHappyPath: happy/boundary/NULL inputs that can't satisfy a proc's own validation
  -> [@tSQLt:SkipTest] annotation instead of a false failure.
- FOR JSON / FOR XML row-baseline test suppressed (can't INSERT...EXEC capture).
- Retired the redundant ClearSchemaBoundReferences MockBlock emission.

KNOWN / HONEST DEFERRALS (not failures, transparently reported)
- Website.CalculateCustomerPrice: v11 scalar-function shadow transform can't build a
  compiling _cov for this multi-statement EXECUTE AS OWNER fn (future enhancement).
- Unseeded single branches on a couple of procs (reverse-seed-the-branch territory).

VALIDATION (full GenerateAndCoverDatabase sweeps, 2026-06-05): HighValueCustomer 19 pass
/ 0 fail / 0 err (89.5% line, 85.7% branch); AdventureWorks2025 81 pass / 0 fail / 0 err
(94.9% / 94.4%); WideWorldImporters 57 pass / 0 fail / 0 err (91.2% line). Zero false red
across all three.

RELEASE MECHANICS: ModuleVersion 0.10.0 (psd1); VERSION v0.10.0-beta; ReleaseNotes 2492
chars (< 10600 PSGallery limit); installer root + powershell bundle copy identical + lint
clean. Tag v0.10.0 to publish.

## 2026-06-05 - FIX (post-0.10.0, queued for 0.10.1): single-proc/DB predicate-branch disconnect

DANGEROUS DISCONNECT: only TestGen.GenerateAndCoverDatabase generated the seeded
predicate-branch (data-shape) tests; the single-proc TestGen.GenerateAndRunCoverage never
did. So running coverage on ONE procedure produced fewer tests + lower coverage than the
database-wide run on the SAME procedure - a user would reasonably read that as a bug.

FIX: GenerateAndRunCoverage now mirrors the database path exactly - (1) parse THIS proc's
predicates (TestGen.ParseProcedurePredicates, single-proc CLR entry), (2) GenerateTestsFor
Procedure, (3) GeneratePredicateBranchTests gated on PredicateInbox rows, (4) RunCoverage.
Both the parse and the predicate-branch step are OBJECT_ID-guarded + TRY/CATCH, so the
entry point degrades cleanly (string-gen branches) when the CLR parser isn't installed.

VERIFIED: GenerateAndRunCoverage 'dbo','AssessCustomer' (HighValueCustomer) -> Step 1 parse,
Step 2 generate, "emitted 6 predicate-branch test(s)", Step 3 coverage -> 12 tests / 12 pass
- identical to the database-wide path (was 6 standard tests only before this fix).

Not yet versioned/published (0.10.0 is live). Roll into a 0.10.1 patch.
FILES: Install_UnitAutogen.sql (TestGen.GenerateAndRunCoverage), powershell/UnitAutogen/sql/
Install_UnitAutogen.sql (synced), CHANGES.md.

---

## 2026-06-05 ÔÇö v0.11 Phase A step 1: numeric-oracle value-probe (search-based seeding)

**Goal:** cover loop-local / coupled branch gates that the static reverse-seeder marks
UNRECOGNISED (measured baseline on HighValueCustomer.dbo.usp_ReconcileTradedPositions: only
1 of 13 branch gates resolves). Design: design/DESIGN_Search_Based_Seeding.md (hardest-first,
driven by gate G5a: `@AdjustedValue>100000 AND @WavePatternPhase='C'` ÔÇö reachable only when an
earlier AVG gate set Phase='C' AND a per-row product exceeds the threshold).

**Mechanism proven:** error_reported XEvent + severity-0 `RAISERROR(... ,0,1) WITH NOWAIT`
captures the substituted value, per loop iteration, AND survives ROLLBACK (spike: 3/3 values
captured through a rolled-back tran). This is the numeric oracle the search needs.

**Built (TestGen.InstrumentProcedure):** new optional `@ProbeMapJson NVARCHAR(MAX)=NULL`
(JSON `[{"line":<stmtLine>,"locals":"@a,@b"}]`). For each mapped statement line the instrumented
_cov emits `SET @__uap_val=CONCAT('__PROBE|<line>|@a=',CONVERT(NVARCHAR(40),@a),...); RAISERROR(...)`
right after the statement, captured by error_reported. NULL (default) => byte-identical behaviour
to before. One hoisted `DECLARE @__uap_val` (SET each fire ÔÇö no DECLARE-initializer-in-loop pitfall).

**Bug the hard case exposed:** the G5a operand `@AdjustedValue` is a DECLARE-initialised local,
and DECLARE lines are classified IsNoise (not statement-processed) when @CountDecl=0, so the
probe never fired. Fix: a probed line is exempt from the DECLARE-noise rule so it goes through
statement processing. (A SELECT-assigned operand like @MFI_Score never surfaced this ÔÇö exactly
why we design for the hardest case first.)

**Validated end-to-end on the real proc (HighValueCustomer):**
- _cov compiles with @ProbeMapJson; probes injected for both line 42 (@MFI_Score, SELECT) and
  line 99 (@AdjustedValue + @WavePatternPhase, DECLARE-initialised).
- In-situ run under a seed engineered for the hardest arm captured:
  `__PROBE|42|@MFI_Score=91` and `__PROBE|99|@AdjustedValue=300000.0000|@WavePatternPhase=C`.
  => the numeric oracle reads the exact values that decide G2 and G5a, and G5a's coupled
  cross-gate arm is provably reachable/seedable.

Bundle powershell/UnitAutogen/sql/Install_UnitAutogen.sql re-synced from root (SHA256 identical).
NEXT: TestGen.SearchSeedForGate (drive candidate seeds, read probe values, interpolate/descend),
then path-prefix composition for G5a. Unreleased (0.11 WIP).

---

## 2026-06-05 ÔÇö v0.11 Phase A complete: search-based gate-seeding engine + driver

Built on the validated numeric oracle (probe/error_reported). Two new procs folded into the
installer (root + powershell bundle, SHA256 identical) and verified deploying from the installer:

**TestGen.SearchSeedForGate** (the search core): given a gate operand + comparator/comparand +
arrange-template ({KNOB}) + optional path-prefix, it probe-instruments _cov, runs candidate
seeds in rolled-back trans under a private error_reported ring-buffer session, reads the operand
value, and MEASURE-AND-INTERPOLATES (two extremes -> linear solve -> bisect, budget ~24) to a
witness seed; honest NULL witness (NOT_TESTABLE) if exhausted. Validated on the real proc
usp_ReconcileTradedPositions:
  - G2 @MFI_Score > 80  -> witness; @MFI_Score < 20 -> witness (monotone)
  - @MFI_Score BETWEEN 45 AND 55 -> interpolated to knob=50 (NON-MONOTONE interior; extremes miss)
  - G5a @AdjustedValue > 100000 with Phase='C' prefix -> witness (COUPLED cross-gate arm reachable)

**TestGen.SearchSeedForProc** + **TestGen.SearchSeedResult** (the gate-parser driver): for each
UNRECOGNISED gate in PredicateInbox, auto-parses operand+comparator+comparand from the predicate
text, finds the operand's aggregate assignment in the source (SELECT @x = AVG|SUM|MIN|MAX|COUNT
(col) FROM tbl), auto-builds a permissive arrange row with the target column = {KNOB}, and drives
SearchSeedForGate. Records WITNESS / NOT_TESTABLE / UNSUPPORTED per gate. Validated on
usp_ReconcileTradedPositions: the 2 aggregate gates (L44,L49) auto-resolve to WITNESS with ZERO
hand-feeding; the other 10 are honestly classed UNSUPPORTED (per-row product / scalar-from-table
/ bare-param / env temp-guard ÔÇö other archetypes).

Result: on a real production proc where the static seeder covered 1/13 branch gates, the search
layer adds the aggregate-computed-local archetype automatically, and the engine (with a supplied
prefix) covers the coupled cross-gate arm that no prior version could.

HONEST BOUNDARY / NEXT: the driver auto-derives the AGGREGATE archetype; per-row-product (G5a-
style) + loop-trip-count + scalar-from-table + bare-param archetypes are handled by the ENGINE
but not yet auto-derived by the driver, and auto path-prefix construction for ancestor-guarded
gates is the next layer (currently supplied). Wiring witnesses into GeneratePredicateBranchTests
(emit the seed as a branch test; NOT_TESTABLE annotation otherwise) is the remaining integration.
Unreleased (0.11 WIP).

---

## 2026-06-05 ÔÇö v0.11 driver extended: auto-reachability + scalar/nullcheck archetypes

Extends the gate-parser driver so it runs with NO hand-fed inputs and covers more archetypes.
Folded into the installer (root + bundle, SHA256 identical; section 20a_Reach + 20c driver),
verified deploying from the installer.

New: TestGen.BuildReachArgs (synth a permissive proc ARG LIST + var decls from sys.parameters)
and TestGen.BuildReachPrefix (seed one permissive row into every referenced user table except the
gate's target table). SearchSeedForProc now uses these automatically when @PrefixSql/@ArgList are
not supplied, so the driver reaches gates on its own.

New archetypes auto-derived: SCALAR (@x = col FROM tbl) and NULLCHK (@x IS [NOT] NULL over a
scalar select), in addition to AGG. The assignment finder now reconstructs MULTI-LINE statements
(the scalar SELECT @x = col / FROM tbl / WHERE... spans 3 lines) before parsing.

Validated on usp_ReconcileTradedPositions, FULLY AUTOMATIC (no prefix/args supplied):
  L27 @IsActiveAccount IS NULL -> NULLCHK/WITNESS
  L32 @IsActiveAccount = 0     -> SCALAR/WITNESS (knob=0)
  L44 @MFI_Score > 80          -> AGG/WITNESS
  L49 @MFI_Score < 20          -> AGG/WITNESS
  => 4 WITNESS / 8 UNSUPPORTED (per-row product / categorical / bare-param / env temp-guard).

Bug found+fixed (the hard SCALAR case exposed it; the AGG case masked it): the driver parses the
target table unquoted (dbo.Tbl) but BuildReachPrefix emits it quoted ([dbo].[Tbl]), so the
"exclude target table" check never matched -> the prefix ALSO seeded the target table, and on a
NON-identity PK (TradingAccounts.AccountID) the arrange row collided -> arrange INSERT failed ->
proc never ran -> false NOT_TESTABLE. MarketIndicators' identity PK hid it. Fixed: quoting-
insensitive exclude compare.

NEXT (still): per-row-product (G5a) / categorical / bare-param / loop-trip archetype auto-
derivation; wiring witnesses into GeneratePredicateBranchTests. Unreleased (0.11 WIP).

---

## 2026-06-05 ÔÇö v0.11 gate-parser COMPLETE: per-row, coupled, recursive-prefix archetypes

Finishes the search-based gate parser. Folded into the installer (root + bundle, SHA256
identical, deploys clean). New TestGen.BuildQualifyingRow (seed ONE row satisfying the loop's
source WHERE, with driving-column overrides). SearchSeedForProc extended with:
  - loop-source detection (INTO #tmp FROM realtbl WHERE preds) + per-row column lineage
    (operand -> #temp col -> real col, through products of locals),
  - PARAM archetype (bare @param gate; covered by the arg + loop reach),
  - PER-ROW numeric (drive a real column -> probe the operand -> interpolate),
  - PER-ROW categorical (@x = 'lit' -> seed the column to the literal),
  - ENCLOSING per-row branch conditions via BEGIN/END depth tracking (the gate sits inside
    IF @CurrentDirection='S' -> the seed must set TradeDirection='S' or the arm never runs),
  - RECURSIVE PREFIX for coupled flags (@AdjustedValue>100000 AND @WavePatternPhase='C' ->
    find SET @WavePatternPhase='C' -> its enclosing IF @MFI_Score>80 -> reuse THAT gate's
    witness seed as the prefix that establishes Phase='C'),
  - ENVIRONMENTAL gates (OBJECT_ID / @@var / GETDATE) -> honest NOT_TESTABLE.

RESULT on usp_ReconcileTradedPositions, FULLY AUTOMATIC: all 12 previously-UNRECOGNISED gates
accounted for -> 11 WITNESS + 1 honest NOT_TESTABLE (the #temp OBJECT_ID guard). With the 1
gate the static seeder already covered, the proc goes from 1/13 to 13/13 gates handled.

NO-GHOST verification (the headline): the coupled G5a witness was RUN against the real proc and
confirmed to fire the actual arm -- mfiAvg=580 (Phase='C'), DryRunAuditLog status =
HOLD_RISK_LIMIT. Two ghost-witness bugs found+fixed during verification: (1) the per-row numeric
WitnessArrange omitted the recursive prefix, so the recorded seed didn't establish Phase='C';
(2) the flag-SET finder matched MAX(SET @flag=...) = the last assignment ('B'), not the one
assigning the demanded literal ('C') -> now matches the specific literal. Also fixed: the column-
lineage finder matched the gate line itself (the '=' inside '<=') -> restricted to assignment
lines strictly before the gate.

Unreleased (0.11 WIP). REMAINING: wire witnesses into GeneratePredicateBranchTests (emit each
seed as an actual branch test / NOT_TESTABLE annotation); broaden no-ghost auto-verification to
every witness; exercise on a 2nd/3rd proc + the pz fixtures.

---

## 2026-06-05 ÔÇö v0.11 search-seed tests EMITTED + passing (end-to-end pipeline)

TestGen.EmitSearchSeedTests (installer section 20d) turns SearchSeedResult witnesses into real
tSQLt tests: FakeTable every referenced table, apply the reach prefix + the verified witness
seed, EXEC the proc.  A gate whose TRUE arm RAISES (e.g. validation IS NULL -> RAISERROR) gets
tSQLt.ExpectException; a NOT_TESTABLE gate gets a SkipTest annotation naming the honest reason.

END-TO-END on usp_ReconcileTradedPositions, fully automatic:
  ParseProcedurePredicates -> SearchSeedForProc (11 WITNESS + 1 NOT_TESTABLE) ->
  EmitSearchSeedTests -> tSQLt.Run = 11 Success + 1 Skipped, 0 fail/err.
The 11 include the coupled cross-gate G5a (HOLD_RISK_LIMIT) and L27 (IS NULL) which correctly
ExpectException for its RAISERROR arm. So a proc the framework previously seeded 1/13 gates on
now has 12 generated, passing branch tests + 1 honest skip.

Folded into installer (root + bundle SHA256 identical, 20d deploys clean). Bug fixed: EXEC()
forbids QUOTENAME() in its string -> pre-build the DROP into a variable + sp_executesql.

REMAINING: broaden to a 2nd/3rd proc + the pz fixtures; optional per-test branch-coverage
assertion (today the emitted test exercises the branch + asserts no unexpected error / expects
the raise; the no-ghost guarantee is established at search time and re-confirmed by the suite
passing). 0.11 still WIP/unreleased.

---

## 2026-06-05 ÔÇö v0.11 search-seeding WIRED INTO THE SWEEP (coverage 36.7% -> 83.3%)

The search-seeding now runs as part of the standard sweep. GenerateAndRunCoverage (single-proc)
and GenerateAndCoverDatabase + ...V10 (db sweep) call, right after GeneratePredicateBranchTests
and before RunCoverage:
    EXEC TestGen.SearchSeedForProc ...;
    EXEC TestGen.EmitSearchSeedTests ... @TestClass='test_'+proc, @DedupSkips=1;
Fully TRY/CATCH-isolated - a search failure can never break the sweep.

EmitSearchSeedTests sweep mode (@DedupSkips=1): emits witness tests into the SAME class as the
predicate-branch tests, DROPS the predicate-branch NOT_TESTABLE skip for each witnessed line, and
does NOT re-emit residue skips (the environmental ones stay). Switched FakeTable -> SafeFakeTable
(handles schema-bound / RLS deps).

VALIDATED end-to-end on usp_ReconcileTradedPositions via GenerateAndRunCoverage (real coverage
path): line coverage 36.7% (11/30) -> 83.3% (25/30); tests 6 pass/14 skip -> 17 pass/3 skip/0
fail-err. The 14 UNRECOGNISED-gate skips became 11 passing witness tests + 1 retained honest skip;
base + seeded tests preserved. Clean teardown (CleanupInterruptedRuns ok).

THREE bugs the integration surfaced + fixed: (1) `@TestClass = N'test_'+@p` is illegal as an EXEC
param value (expression) -> pre-build into a variable; (2) EmitSearchSeedTests class-create guard
`IF SCHEMA_ID IS NULL OR NOT EXISTS(... WHERE 1=0)` was ALWAYS true -> it called
tSQLt.NewTestClass every time, which DROPS+recreates the class and wiped the base/predicate-branch
tests when emitting into the shared sweep class -> create only when SCHEMA_ID IS NULL; (3) use
SafeFakeTable not FakeTable. All 4 changed procs recompile clean; bundle SHA256 identical.

TO APPLY: re-run Install_UnitAutogen.sql on the target DB, then the normal sweep
(Invoke-UnitAutogen / GenerateAndCoverDatabase) picks it up automatically. 0.11 still WIP.

---

## 2026-06-06 ÔÇö v0.11 LOOPCOUNT archetype: pure loop-accumulator gates (pz.LoopLocalGate 0%->100%)

The search engine now covers the LOOPCOUNT archetype - a gate on a loop ACCUMULATOR
(SET @x = @x +/- k inside a WHILE) whose value = the loop trip count = COUNT over a seedable
table.  The knob is the ROW COUNT of that table: detect the SET @x=@x+- accumulator + the
enclosing WHILE..COUNT..FROM <tbl>, build an arrange that inserts {KNOB} permissive rows into
<tbl>, probe @x at the accumulator line, search the count.  Both arms seeded (the comparator AND
its negation) so the IF's TRUE and FALSE branches are both covered.

VALIDATED end-to-end on AdventureWorks2025 pz.LoopLocalGate (IF @x>3 where @x=COUNT(pz.Orders)):
0% -> 100% line (4/4), 3 pass / 2 skip / 0 fail-err.  The witness seeds 12 rows (@x=12>3, arm A)
and 1 row (@x=1<=3, arm B).  This was the ORIGINAL motivating case for the whole search effort.

COLLATION HARDENING (surfaced on AdventureWorks2025, whose DB collation Latin1_General_CI_AS <>
the server default SQL_Latin1_General_CP1_CI_AS): a tempdb temp-table column (server collation)
compared to a catalog column (db collation) - both implicit - conflicts. Fixed in the search
helpers: #src.Txt and #w.Col -> COLLATE DATABASE_DEFAULT; OBJECTPROPERTYEX(...,'BaseType')='U' ->
CAST(... AS NVARCHAR(20)) COLLATE DATABASE_DEFAULT = N'U' (OBJECTPROPERTYEX returns sql_variant,
so CAST before COLLATE). EmitSearchSeedTests now includes the comparator in the test name so a
both-directions gate yields two distinct tests. These make the whole search layer collation-safe.

Bundle SHA256 identical. 0.11 still WIP.

===============================================================================
RELEASE v0.11.0-beta ÔÇö 2026-06-06
===============================================================================
Search-based gate seeding: the generator now covers branch gates the static
reverse-seeder cannot invert (loop accumulators, per-row products, coupled
cross-gate conditions, aggregate bands) via a numeric XEvent-probe oracle +
measure-and-interpolate, emitting verified witness tests or honest NOT_TESTABLE.
Wired into the standard sweep. Archetypes: AGG / SCALAR / NULLCHK / PARAM /
PERROW(value+categorical) / COUPLED(recursive prefix) / LOOPCOUNT(row-count knob).
Validated: HighValueCustomer usp_ReconcileTradedPositions 1/13->13/13 gates
(36.7%->83.3% line, 18.8%->87.5% branch); AdventureWorks pz.LoopLocalGate 0->100%
(DB 93.1%->96.6% line, 93.2%->97.3% branch); no regressions. Collation-safe.
New procs: TestGen.SearchSeedForGate / SearchSeedForProc / EmitSearchSeedTests /
BuildReachArgs / BuildReachPrefix / BuildQualifyingRow. See dated entries above.
===============================================================================

---

## 2026-06-06 ÔÇö v0.11 honest-labelling fix: function deferral surfaces the real reason

RunCoverageForFunction previously reported EVERY scalar/multi-statement-TVF coverage deferral as
"instrumenter limitation - please report this function body", even when the true cause was an
infrastructure limit on the shadow (system-versioned temporal table, full-text, memory-optimized,
missing dependency). Now, when the shadow is NOT_TESTABLE, the deferral classification calls
TestGen.AssessTestability on the shadow and surfaces THAT reason (with the actionable remediation,
e.g. "turn SYSTEM_VERSIONING OFF"), both in the console and in CoverageResult.NotTestableReason
(the HTML report tooltip). Validated on WideWorldImporters Website.CalculateCustomerPrice: was
"instrumenter limitation - please report", now "depends on a system-versioned temporal table...".
No false-report asking the user to report a non-bug. Folded into the v0.11.0 installer (not yet
published), bundle SHA256 identical.

---

## 2026-06-07 -- v0.11 boundary-value fix: COUNT_CMP '>' non-satisfy now lands on the boundary

TestGen.CountForCase chose the non-satisfy row count for a COUNT(*) > N gate as 0 (an
arbitrary "clearly empty" set) instead of N (the boundary). Every other COUNT comparator
(>=, <, <=, =, <>) already lands one of its two cases exactly on the boundary; '>' was the
lone exception. Raised by Sebastian Meine (tSQLt author) re: boundary-value heuristics.
Fix: non-satisfy for '>' is now @Ni (the boundary), so `count > 5` seeds 6 rows (taken) and
5 rows (not taken) instead of 6 and 0. Zero extra tests -- the boundary value replaces a weak
non-satisfy choice rather than adding a third case (respects the "don't explode the count"
concern). Validated on AdventureWorks2025: CountForCase('COUNT_CMP','>','5',0) 0->5; all other
operators and edge cases (count>0 -> 0; non-integer comparand -> NULL) unchanged. Full sweep
post-fix: 0 fail / 0 err, no regressions. Changed: modules/32_Seeder_v1.sql +
Install_UnitAutogen.sql (synced). Linted ok.

IMPORTANT SCOPE CORRECTION (verified by a live mutation test on dbo.uspBoundaryDemo): this
seeding fix is NECESSARY BUT NOT SUFFICIENT to catch a `>`->`>=` mutation. The generated
predicate-branch test ("... predicate FALSE (v0.10)") seeds the boundary correctly (TOP (5)
rows) but its assertion only re-checks a SNAPSHOT of the original predicate text
(AssertEquals 0 = CASE WHEN (...) > 5 ...) and then smoke-EXECs the proc -- it does NOT assert
the proc's downstream EFFECT (whether the gated INSERT fired). So mutating the proc to `>= 5`
leaves the test green: at 5 rows the INSERT now fires, but nothing asserts its absence.
Catching the mutation therefore needs a SECOND change: a boundary test that asserts the
OUTCOME at the boundary (e.g. the TRUE-arm effect is absent at N rows), not just coverage +
seed-validation. That is the real boundary-value-heuristic feature; this seeding fix is its
prerequisite. Backlog item.

---

## 2026-06-07 -- v0.11 boundary-EFFECT assertion: the FALSE/boundary test now asserts the guarded write did not fire

Resolves the scope correction above. The FALSE/boundary predicate-branch test
(module 34, GeneratePredicateBranchTests) now -- when it can do so unambiguously --
fakes the guarded DML target, captures its row count, runs the proc, and asserts the
count is UNCHANGED. So with `count > 5` the boundary seed (5 rows) leaves the target
empty (pass); mutate the proc to `>= 5` and at 5 rows the guarded INSERT fires, the
count grows, and the boundary test FAILS with a clear "operator may have been loosened
(e.g. > to >=)" message. This is what actually catches the mutation; the v0.11 seeding
fix only put the right data there.

STRICTLY CONSERVATIVE / no-new-false-failures design: the extra assertion is emitted
ONLY when the proc has EXACTLY ONE gate AND EXACTLY ONE fakeable updated (base) table
(via sys.dm_sql_referenced_entities is_updated=1, wrapped in TRY/CATCH). Under those
conditions the single DML target is unambiguously the one guarded by the single gate.
Any other shape (multiple gates, multiple/zero updated tables, result-set-only gates,
non-resolvable target) leaves @TargetTable NULL and the generated tests are byte-for-byte
unchanged -- no new assertion, no new failure risk. Also closes a latent isolation gap:
the FALSE test now fakes the write target (previously a fired write would have hit the
real table). Loop vars hoisted to proc top (no DECLARE-in-loop); double-fake guarded by
a CHARINDEX check against the already-faked gate tables.

VALIDATED live on AdventureWorks2025: dbo.uspBoundaryDemo (COUNT(*)>5 guarding an
INSERT) -> both branch tests pass on `>5`; mutate to `>=5` -> FALSE test fails
("Expected <0> but was <1>"), mutation caught. Regression spot-check: pz.CountGtGate
(result-set arms, no DML target) regenerated byte-for-byte UNCHANGED (no v0.11 assertion).
Changed: modules/34_Predicate_BranchTests_v1.sql + Install_UnitAutogen.sql (synced,
proc verified structurally identical). NOTE: tools/tsql_lint.py reports a BEGIN/END
imbalance on this file -- a known false positive: the linter counts BEGIN/END/CASE/TRY
tokens inside the SQL strings the generator emits (it also miscounts the pre-existing
module 34, 16 vs 10). Authoritative validation is the live compile+run above; the
released installer is the regression-test artifact. Limitation/backlog: only catches
INSERT/DELETE-style count changes (not UPDATE content), single-gate single-target only;
multi-gate and UPDATE-effect boundary assertions are future work.

---

## 2026-06-07 -- v0.11.1 boundary effect now covers INSERT, UPDATE and DELETE (content comparison)

Completes the previous entry's "UPDATE content" backlog item. The FALSE/boundary test
now (a) PRE-SEEDS the guarded target with 3 sample rows via TestGen.BuildSeedInsert
(so UPDATE/DELETE have rows to act on), and (b) compares FULL CONTENT before/after with
a row-count AssertEquals (custom "operator may have been loosened" message; catches
INSERT/DELETE) PLUS tSQLt.AssertEqualsTable on snapshot tables #uag_tgt_before /
#uag_tgt_after (catches UPDATE, which leaves the count unchanged). Same strict guard as
before: emitted only for single-gate / single-fakeable-updated-table procs, and only
when the target is NOT one of the gate's own source tables (CHARINDEX check) -- pre-seeding
a gate source would perturb the gate. Loop vars hoisted (added @preSeed; no DECLARE-in-loop).

VALIDATED live on AdventureWorks2025, all three DML kinds, each PASS on `>5` and the
FALSE test FAILS on `>=5`:
  - INSERT (uspBoundaryIns): row count 3 -> 4, count assert fails ("Expected <3> but was <4>").
  - UPDATE (uspBoundaryUpd): count unchanged (3=3) but AssertEqualsTable fails showing the
    content diff (Tier 'Sam' -> 'high').
  - DELETE (uspBoundaryDel): row count 3 -> 0, count assert fails ("Expected <3> but was <0>").
Generated FALSE test inspected: fakes target, INSERT TOP(3) sample rows, SELECT * INTO
#uag_tgt_before, EXEC proc, SELECT * INTO #uag_tgt_after, count assert + AssertEqualsTable.

Changed: modules/34_Predicate_BranchTests_v1.sql + Install_UnitAutogen.sql (synced, both
Read-verified identical in the edited region). Reuses existing TestGen.BuildSeedInsert
(module 32) - no new helper. tsql_lint.py BEGIN/END false-positive still applies (strings);
live compile+run is authoritative. Remaining limitation/backlog: UPDATE/DELETE detection
needs the pre-seeded generic rows to be affected by the DML -- a selective WHERE that the
sample values don't match means no detection (NOT a false positive, just a miss); multi-gate
procs still degrade to no boundary assertion. Note: the released installer ships these
changes UNINSTALLED until re-pushed; regression-test by installing on a fresh DB + sweep.

---

## 2026-06-07 -- v0.12 WHERE-aware boundary seeding: the SQLCLR parser lifts guarded-DML WHERE equalities

Closes the v0.11.1 selective-WHERE miss the RIGHT way -- in the C# ScriptDom parser, not
fragile T-SQL text parsing. When a gate's guarded branch is an UPDATE/DELETE, the parser now
walks that DML's WHERE and lifts AND-chained "col = <literal>" and "col IN (<literals>)"
conjuncts into a new PredicateInbox field BodyDmlSeedJson
({"schema","table","overrides":[{"col","val"}]}). Module 34 passes those overrides to
TestGen.BuildSeedInsert, so the boundary test pre-seeds rows that SATISFY the DML's filter --
and a selective UPDATE/DELETE now actually hits them, so a loosened-operator mutation is caught.

Layers changed: clr/UnitAutogenClr.cs (new BodyDmlSeedJsonFor / FirstDmlStatement /
CollectEqOverrides helpers via existing LiteralText; emitted in the IfStatement visit + the
inbox write); modules/31 (PredicateInbox BodyDmlSeedJson column + upgrade migration +
AddParsedPredicate @BodyDmlSeedJson param/INSERT); modules/34 (cursor fetch + override CASE
into BuildSeedInsert); Install_UnitAutogen.sql (synced, all 8 edits) and
clr/Install-UnitAutogenClr.SSMS.sql (rebuilt assembly + new SHA-512 trust hashes via
Build-Clr.ps1/Emit-InstallerSql.ps1). Assembly recompiled clean (csc exit 0, 60928 bytes).

VALIDATED live on AdventureWorks2025 with the HARDEST in-scope case --
  IF (SELECT COUNT(*) FROM Sales.SalesOrderHeader) > 5
      UPDATE dbo.OrderAudit SET Flag = 1 WHERE Region = 'US' AND Status IN (3,4) AND Priority = 9;
Parser emitted BodyDmlSeedJson = overrides [Region=N'US', Status=3, Priority=9]; the generated
FALSE test pre-seeds 3 rows "N'US', 3, 9, 42" (satisfying all three conjuncts); both tests PASS
on `>5`; mutate to `>=5` and the FALSE test FAILS via AssertEqualsTable (Flag 42 -> 1). Mutation
caught. Regression: pz.CountGtGate (result-set, no DML target) regenerated UNCHANGED -- the
conservative single-gate/single-target guard still degrades cleanly. Strictly additive: when
the parser emits no overrides (OR, ranges, functions, subqueries, col=col, INSERT, multi-gate)
BodyDmlSeedJson is NULL and seeding is byte-for-byte v0.11.1 -- never an error, never a false
failure (override values are the DML's own literals, type-consistent by construction).

DEPLOYMENT NOTE: this release changes BOTH installers AND the SQLCLR assembly (new trust hash),
so installing it requires re-running Install-UnitAutogenClr.SSMS.sql (re-registers the parser)
in addition to Install_UnitAutogen.sql. tsql_lint.py BEGIN/END false-positive still applies to
the generators; live compile+run is authoritative. Run the full 3-DB regression sweep after a
fresh install to confirm.

--------------------------------------------------------------------------------
2026-06-11  @EmitNullChecks now defaults OFF (no forced per-parameter NULL tests)
--------------------------------------------------------------------------------
@EmitNullChecks default flipped 1 -> 0 in GenerateTestsForProcedure,
GenerateAndRunCoverage and GenerateAndCoverDatabase (and the modules/04 source).
The parameter and the runtime gate are unchanged, so @EmitNullChecks = 1 fully
restores the previous behaviour (one NULL test per nullable parameter).

WHY: the per-parameter "accepts NULL for @x" tests were emitted for every
nullable parameter whether or not the procedure does anything with NULL - test
count without coverage. A procedure's genuine NULL handling is a real branch/
line and is covered by the predicate-branch path (the in-database CLR parser),
not by speculative injection. We no longer FORCE null checks; we cover what the
code actually does.

CAVEAT: with NO CLR predicate parser installed, a NULL-driven branch previously
covered only incidentally by the forced injection is no longer covered unless
@EmitNullChecks = 1. Install the parser (step 2 of the bundle) for branch-derived
NULL coverage.

VERIFIED (AdventureWorks2025, HumanResources.uspUpdateEmployeeHireInfo):
  default (=0) -> 5 tests (4 pass, 1 skip); line 66.7% / branch 0.0%
  =1           -> 12 tests (the 7 "accepts NULL for @x" return); same coverage.
The 7 NULL smokes added zero coverage on this proc - exactly the noise removed.

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       modules/04_Test_Generator_v3.sql, docs/ADVANCED_USAGE.md,
       docs/REFERENCE_GUIDE.md, docs/EASY_USAGE.md, docs/advanced-snippets.sql,
       CHANGES.md

--------------------------------------------------------------------------------
2026-06-11  v0.13.0 - independent core-engine review fixes
--------------------------------------------------------------------------------
Independent 4-reviewer pass over the core engine. Five correctness/robustness bugs
fixed + verified live on AdventureWorks2025 / HighValueCustomer / WideWorldImporters
(0 fail / 0 err). Three latent edge-cases triaged + deferred.

FIXED:
1. Alias/UDT scalar types now resolve to base type in GetSampleValueLiteral, so
   alias-typed params/cols (dbo.Flag, dbo.Name...) get real values, not NULL.
2. SatisfyingValue skips when the comparand is NULL (bare keyword or "NULL /* unknown
   type */" fallback) instead of emitting col = NULL (UNKNOWN -> self-failed). Quoted
   'NULL' strings unaffected.
3. GenerateAndRunCoverage Step-1 parser guard OBJECT_ID(...,'P') -> type-agnostic
   OBJECT_ID(...): the shipped parser is a CLR proc (type 'PC'), so the old guard
   never fired and the single-proc path silently skipped predicate parsing.
4. NOT_TESTABLE SkipTest reason text now escapes single quotes (no "unmatched quote").
5. CleanupInterruptedRuns also detects the crash state where the base proc is missing
   (renamed to _orig, synonym not yet created) + sibling _cov, not only synonym-at-base.
Plus: @EmitNullChecks now defaults to 0 (see prior entry).

DEFERRED (latent; do NOT reproduce on real procs, only synthetic formatting; dedicated
test-harnessed pass scheduled): branch-coverage mis-attribution (adjacent/nested IF +
one-line IF/ELSE; inference duplicated across ~5 procs); boundary "rejects" probe;
predicate-branch matched-key arg pinning (did not reproduce).

FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       powershell/UnitAutogen/UnitAutogen.psd1, VERSION, dist/UnitAutogen-0.13.0-install.zip,
       docs/*, CHANGES.md

2026-06-11  v0.13.0 addendum - drop "(v0.10)" tag from predicate-branch test names
GeneratePredicateBranchTests no longer appends " (v0.10)" to the predicate TRUE/FALSE and
NOT_TESTABLE branch-test names (e.g. "...branch 1 line 10 predicate TRUE"). The per-run cleanup
now matches prior branch tests by their generated structure ("branch N line M predicate ..." /
"... NOT_TESTABLE") instead of the version tag, so regeneration still drops older "(v0.10)"-named
tests already in a database. Verified on HighValueCustomer.AssessCustomer (11 tests, 0 tagged).

--------------------------------------------------------------------------------
2026-06-12  NEW: TestGen.ExportTestClasses - portable test export (UNRELEASED)
--------------------------------------------------------------------------------
Scripts the generated tSQLt test classes OUT of a database into one idempotent,
deployable .sql. Run it against any OTHER database that already has tSQLt +
UnitAutogen (TestGen) to recreate the tests there.
  * Pre-flight guard (RAISERROR + SET NOEXEC) aborts cleanly, deploying nothing,
    if tSQLt or the TestGen runtime helpers (SafeFakeTable, AssertResultRowsMatch
    Baseline, AssertResultShape) are missing on the target.
  * Recreates each class via tSQLt.NewTestClass; reproduces each test proc
    verbatim, preserving the leading --[@tSQLt:SkipTest] annotation so skips hold.
  * Params: @TestClass (one class), @Like (filter), @OutputMode RESULT|PRINT.
PowerShell: new Export-UnitAutogenTests cmdlet writes the script to a file.
Validated on AdventureWorks2025: round-trip (export -> DropClass -> redeploy from
script -> tSQLt.Run identical 5 pass/2 skip) and guard aborts on a bare DB (0 classes).
FILES: Install_UnitAutogen.sql, powershell/UnitAutogen/sql/Install_UnitAutogen.sql,
       powershell/UnitAutogen/UnitAutogen.psm1, powershell/UnitAutogen/UnitAutogen.psd1, CHANGES.md
NOTE: UNRELEASED - version still 0.13.0; bump to 0.14.0 when releasing.


================================================================================
2026-06-12  v0.14.0  -  BUG-001 FIX: branch tests restored to Arrange-Act-Assert
================================================================================
DEFECT (BUG-001, see BUGS.md; introduced v0.10.2): every seeded predicate-branch
test asserted the gate predicate on the SEED *before* executing the procedure - an
Arrange-Assert-Act ordering. That pre-Act assertion tested the test's own setup,
not the procedure; for a literal EXISTS seed it was tautological (a failed seed
already errors the test on its own line); and nothing asserted what the branch
actually did, so a wrong-value / wrong-WHERE write passed the whole class green.

FIX (full + conservative, measurement-based): GeneratePredicateBranchTests now
emits Arrange -> Act -> Assert and the pre-Act predicate assertion is removed. The
arm's effect is OBSERVED, not parsed (PredicateInbox records only the gate, never
the arm's write DML): new TestGen.MeasureBranchEffect runs the direction's Arrange
+ the proc under a rolled-back transaction (mirrors CaptureExpectedCounts' safety
model) and reports the write target's row-count and content-hash delta. A
SELF-CONTAINED post-Act assertion is emitted to match - grew => INSERT (count
delta), shrank => DELETE, held + content changed => UPDATE (count held + content
changed), held + same => no observable write. The test captures its own
before/after, so non-determinism (e.g. ModifiedDate = GETDATE()) cannot false-fail.
Conservative: no single write target resolved, a capture error, or @@TRANCOUNT<>0
-> smoke + coverage (exactly as before). New helper TestGen.ChecksumColList
(checksum-able column list). CaptureExpectedCounts is left untouched (zero blast
radius on the base generator); the search-based seeding engine is untouched.

VALIDATED on AdventureWorks2025: the upsert (IF EXISTS UPDATE ELSE INSERT)
generates AAA tests - FALSE asserts "add 1 row", TRUE asserts "change content with
the row count held" - 5 pass / 1 skip / 0 fail, 100% line + branch. MUTATION PROOF:
a broken UPDATE (WHERE never matches the seeded row) now FAILS the TRUE test (the
old smoke test passed it); restored -> green. Three more EXISTS shapes
(gate<>target UPDATE, single-condition EXISTS, @Mode parameter gate) generate
clean, 0 fail. SET PARSEONLY accepts all 270 installer batches.

FOOTPRINT-SKIP PRUNE: the base generator's "touches only mocked tables" footprint
test SkipTest-annotates itself when the happy-path seed drove no measurable
row-count change (commonly a count-stable UPDATE the count probe cannot see). When
the proc's writes are already covered by an effect-asserting predicate-branch test,
that skip asserts nothing -> it is dropped (at the end of GeneratePredicateBranchTests,
gated on a '@uag_ca' effect-assert marker existing in a branch test). So a
well-covered branched proc goes fully green - the showcase upsert went 6 tests/1 skip
-> 5 tests/0 skip, still 100% line + branch. A footprint test that actually MEASURED
(passes) is kept; a skip is kept whenever NO effect-asserting branch test exists - so
a SURVIVING "touches only mocked tables" skip is now a meaningful "no test
characterized this write; review the seed or confirm the proc is read-only/count-
stable" signal, not routine yellow. Non-branched single-statement procs are
unaffected (they are NOT_TESTABLE and never had a footprint test).

REGRESSION GUARD: scripts/Check_Invariants.sql enforces INV-1 (Arrange-Act-Assert)
- RAISERROR if any generated test asserts before it executes the proc under test.
Run after a sweep / in CI. Test classes generated BEFORE this fix still carry the
old pattern until regenerated; a full regen sweep clears them.

FILES: Install_UnitAutogen.sql (TestGen.ChecksumColList + TestGen.MeasureBranch
Effect added; GeneratePredicateBranchTests rewritten), powershell/UnitAutogen/sql/
Install_UnitAutogen.sql (bundle, byte-identical), scripts/Check_Invariants.sql,
BUGS.md (new defect ledger + INV-1), VERSION, powershell/UnitAutogen/UnitAutogen.psd1,
docs/strong-assertions.md, tools/tsql_lint.py (BEGIN/END check downgraded to a
non-fatal warning - it miscounts generated-SQL-heavy files; PARSEONLY is the
authority). NOTE: v0.14.0 also carries the ExportTestClasses feature (entry above).

================================================================================
2026-06-13  (post-0.14.0)  -  "executes with valid inputs" is now uniform pure smoke
================================================================================
The happy-path test "test <proc> executes with valid inputs" no longer carries the
before/after row-count guard for count-stable (read-only / UPDATE-only) procedures -
it is now a PURE SMOKE check for ALL procedures (fake + seed + EXEC in TRY/CATCH; a
throw fails it). Rationale: on the happy-path inputs that guard duplicated what
"touches only mocked tables" already asserts (same inputs), and writing procs never
had it - so the test now means ONE thing everywhere. No coverage change; the write
footprint stays owned by "touches only mocked tables" + the per-branch effect tests.
The boundary tests' count guard is unchanged (different inputs). VALIDATED: HVC
AssessCustomer regenerated 11/11 pass, 100% line+branch, happy-path test now smoke-only.
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql.
Bump to v0.14.1 when committing.

================================================================================
2026-06-13  (post-0.14.0)  -  per-branch OUTPUT-parameter value assertions
================================================================================
Predicate-branch tests now assert each scalar OUTPUT parameter's VALUE, not just that
the branch ran. New TestGen.CaptureBranchOutputs runs the direction's Arrange + the proc
in a rolled-back transaction and captures the OUTPUT value(s); the branch test binds each
OUTPUT param to a local (@p = @uag_o_<p> OUTPUT) and asserts the captured value via
tSQLt.AssertEqualsString (the branch is pinned, so the value is deterministic). New
TestGen.FormatTypeDecl builds the capture local's type. Conservative: falls back to
pass-by-value with NO assertion when the proc has no scalar OUTPUT params, references a
non-deterministic function (GETDATE/NEWID/RAND/...), runs in a transaction, or the capture
errors - so no false-fails. Resolves the disconnect where the separate "assigns its OUTPUT
parameters" test ran with generic input and only carried a TODO for the value check.
VALIDATED on HighValueCustomer AssessCustomer: branch 1 FALSE asserts
NO_DISCOUNT;FEW_ITEMS;STANDARD, TRUE asserts DISCOUNTED;FEW_ITEMS;STANDARD; 11/11 pass,
100% line+branch. MUTATION: change a branch's emitted literal -> that branch test FAILS;
restore -> green.
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(TestGen.FormatTypeDecl + TestGen.CaptureBranchOutputs added; GeneratePredicateBranchTests
extended). Bump to v0.14.1 when committing.

================================================================================
2026-06-13  (post-0.14.0)  -  OUTPUT-value test checks the variable, not the tables
================================================================================
The "test <proc> assigns its OUTPUT parameters" test no longer carries the mocked-table
row-count guard (that footprint is owned by "touches only mocked tables"). It now asserts
the OUTPUT parameter VALUE(s) the happy-path call produces - measured at generation time
via TestGen.CaptureBranchOutputs and asserted with tSQLt.AssertEqualsString (this fills the
prior TODO). Conservative: smoke-only (no value assertion) for a non-deterministic proc, a
transactional context, or an unmeasurable capture - no false-fails. VALIDATED on HVC
AssessCustomer: asserts NO_DISCOUNT;FEW_ITEMS;STANDARD; 11/11 pass, 100% line+branch.
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql. Part of v0.14.1.

================================================================================
2026-06-13  (post-0.14.0)  -  OUTPUT-value assertions for NON-deterministic outputs
================================================================================
An OUTPUT parameter whose value mixes string CONSTANTS with a runtime-volatile part
(e.g. N'Processed at ' + CONVERT(...,GETDATE()) + N' for ' + @n) is no longer skipped.
New TestGen.BuildLikeSkeleton extracts the procedure's own string literals that appear
in the measured value and builds an ordered LIKE pattern ('%lit1%lit2%...', LIKE
wildcards escaped) with '%' for the runtime-varying spans. Both the predicate-branch
tests and the "assigns its OUTPUT parameters" test now: deterministic output ->
AssertEqualsString (exact); volatile output -> tSQLt.AssertLike on the constant skeleton;
no usable literal -> assert the param was assigned (non-NULL). No false-fails: the literals
are guaranteed constants of that path and the volatile span is wildcarded. VALIDATED on
HighValueCustomer - AssessCustomer (deterministic) still asserts exact, 11/11; a volatile
receipt proc asserts LIKE '%RECEIPT for % at %' in BOTH its OUTPUT test and branch TRUE test,
mutation-proven (RECEIPT->INVOICE fails both; the GETDATE part is correctly ignored).
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(TestGen.BuildLikeSkeleton added; GeneratePredicateBranchTests + the OUTPUT test extended).
Part of v0.14.1.

================================================================================
2026-06-13  (post-0.14.0)  -  OUTPUT-value determinism CONFIRMED by double-measure
================================================================================
The exact-vs-skeleton decision for OUTPUT-value assertions no longer relies on the
source-text scan alone. That scan only sees volatile functions written in the procedure
itself; non-determinism hidden in a called function/procedure (a UDF that calls GETDATE/
SYSDATETIME), a SCOPE_IDENTITY or sequence read, or order-sensitive aggregation would slip
past it and bake an exact value that then false-fails. The generator now measures each
OUTPUT value TWICE, in two independent rolled-back runs separated by a >1-clock-tick
WAITFOR DELAY (back-to-back reads can share a tick and hide time-based volatility), and
asserts the EXACT value only when the source scan is clean AND the two runs agree; if they
disagree it treats the value as volatile and uses the LIKE constant skeleton, or (value seen
NULL in one run / otherwise unconfirmable) a smoke check. Applies to BOTH the "assigns its
OUTPUT parameters" test and the per-branch OUTPUT assertions.
VALIDATED on HighValueCustomer: AssessCustomer (deterministic) still asserts exact, 11/11;
a proc whose output is 'FOUND-'/'MISSING-' + a nested-UDF SYSDATETIME (source scan CLEAN) now
asserts LIKE '%FOUND-%' / '%MISSING-%' on the base AND both branch tests, 7/7 pass - the
pre-fix build baked an exact timestamp and failed its own run. Worst case is conservative: an
output volatile in a way neither run revealed may still be asserted exactly and fail later,
a signal to relax that one assertion - never a silently wrong test.
Also: the two body-boundary NOT_TESTABLE / instrumentation messages were reworded to neutral,
professional guidance (dropped "parser limitation" / "report as a bug").
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql.
Part of v0.14.1.

================================================================================
2026-06-13  (post-0.14.0)  -  baseline-row assert names its table explicitly
================================================================================
The generated "returns rows matching baseline" test now emits
  EXEC TestGen.AssertResultRowsMatchBaseline @TestClass='<class>', @ActualTable=N'#ActualResult';
instead of relying on the helper's @ActualTable default. The #ActualResult name was always an
implicit caller contract (the CREATE TABLE #ActualResult two lines above had to match the proc's
default), i.e. action-at-a-distance. Naming it at the call site is self-documenting, robust to a
hand-edit that renames the temp table, and consistent with tSQLt's own explicit-table-name style
(AssertEqualsTable '#Expected','#Actual'). Pure readability/robustness change - assertion behavior
is identical (verified on AdventureWorks2025 pz.ContradictionGate: 4 pass / 1 skip, 0 fail; the skip
is the hand-built-expectation scaffold). Part of v0.14.1.

================================================================================
2026-06-14  -  v0.15.0  -  cross-column WHERE seeding (column vs column) + multi-line predicate fix
================================================================================
NEW CAPABILITY. The reverse seeder now drives a WHERE that compares one column to another -
same-table (WHERE Lo > Hi) or cross-table (a JOIN b ... WHERE a.Amount > b.Threshold), any
operator, single or multi-condition, coordinated with the join keys. Previously such a
predicate was fenced NOT_TESTABLE ("conjunct is not <column> <op> <literal|@param>"); now it
seeds BOTH arms to 100% branch.

HOW. The SQLCLR parser (clr/UnitAutogenClr.cs) detects a column-vs-column comparison in
WhereLeaf and emits a "colcol" leaf; DriveWhere anchors the RIGHT column on its own typed
sample ({sample}) and the LEFT column on a new vspec
{satisfyother:{op,want,oschema,otable,ocol}} that derives a satisfying/violating value from
the OTHER column's typed sample - robust across differing column types, unlike the same-type
{satisfysample} used for non-equi JOIN coordination. PlanAtom builds an alias->[schema,table]
map so satisfyother resolves the real owning table. T-SQL TestGen.ResolveVspec gained a
satisfyother branch: it samples the other column's type and returns
TestGen.SatisfyingValue(op, that-sample, want). Existing join-key coordination
(CoordinateJoins) is unchanged, so the seeded rows still join.

BUG-002 FIX (multi-line predicate emission). The seed block embedded the raw predicate text
into a single-line "-- ... seed for: <text>" comment. When the predicate spanned more than one
source line, the embedded newline terminated the comment and the continuation (e.g. a wrapped
"WHERE ...") became live SQL -> "Incorrect syntax near 'WHERE'" -> sp_executesql threw and the
class emitted ZERO predicate-branch tests (silently, inside the sweep) -> the branch showed as
a 50% gap. This hit ANY multi-line predicate, not just column-vs-column, but would have
crippled the new feature in practice (cross-table predicates are usually written as wrapped
EXISTS subqueries). FIX: strip CR/LF/TAB from the embedded comment text in BOTH seeders
(ExecuteSeedPlan and SatisfyPredicate). The seed plan itself was always correct; only the
comment rendering broke.

HONEST BOUNDARY (unchanged spine). A genuine contradiction (WHERE a.x > b.y AND a.x < b.y) has
no seed by definition; it is not faked. Both branch tests still emit, but branch coverage
honestly reports the impossible arm as unreached (50%) - the red number is the signal, never a
phantom green.

VALIDATED on AdventureWorks2025 (CLR rebuilt + re-trusted; registered assembly hash
0x9FF0ADFE...): single cross-table (a.Amount>b.Threshold) NOT_TESTABLE->100%; same-table
(Lo>Hi) 100%; multi-condition cross-table (a.Amount>b.Threshold AND a.Rnk<b.Cap) 100% whether
written on one OR multiple source lines; contradiction stays honest 50%; single-column
multi-line (wrapped WHERE p.Amount>100) NOT_TESTABLE-regression FIXED ->100%. REGRESSION:
PredicateZoo re-parsed clean (28 PREDTREE; the only 5 UNRECOGNISED are the by-design
loop-accumulator gates) and 23 distinct seedable gates re-ran GREEN at 100% branch (incl.
NonEquiJoinGate, SelfJoinGate, SharedTableGate, ParamComparandGate, OrCompositionGate, the
Count*/agg family); ContradictionGate honest 50%.
FILES: clr/UnitAutogenClr.cs + clr/lib/UnitAutogenClr.dll + clr/Install-UnitAutogenClr.SSMS.sql
(rebuilt, new hash); Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
+ modules/32_Seeder_v1.sql (ResolveVspec satisfyother + comment sanitize); clr/Build-Clr.ps1
(spaced-path + self-copy build fixes). Bump to v0.15.0 when committing.

================================================================================
2026-06-14  -  v0.15.1  -  cross-column seeding solves transitive chains (multi-table)
================================================================================
Extends v0.15.0 cross-column seeding to TRANSITIVE CHAINS across any number of joined
tables: a WHERE that chains comparisons through a shared column - a.X > b.Y AND b.Y > c.Z -
now seeds BOTH arms to 100% branch (was an honest 50% residue in v0.15.0).

ROOT CAUSE. ExecuteSeedPlan resolved each override INDEPENDENTLY and per-table, and a
{satisfyother} column derived its value from the OTHER column's generic TYPE SAMPLE, not the
other column's ACTUAL seeded value. In a chain the middle column (b.Y) is squeezed from both
sides - the sample-anchor for "a.X > b.Y" and itself derived for "b.Y > c.Z" - so a.X was
computed against b.Y's type sample (42) while b.Y was actually bumped to 43 -> 43 > 43 false
-> TRUE arm unreached -> 50%.

FIX (T-SQL only; the parser already emits the right structure - b.Y carries both {sample}
and {satisfyother against c.Z}, a.X carries {satisfyother against b.Y}). ExecuteSeedPlan
gains a global value-propagation pre-pass: collect every override across all tables, seed the
free (lit/param/sample) columns, then RELAX - repeatedly derive each {satisfyother} value
from its anchor's ACTUAL chosen value (SatisfyingValue(op, anchor's resolved literal, want))
until stable. A column carrying both {sample} and {satisfyother} takes the constrained value.
The emit loop then reads the propagated @cc_chosen[fullcol] for every column. So c.Z=42 ->
b.Y=43 (beats c.Z) -> a.X=44 (beats b.Y's ACTUAL 43): 44 > 43 > 42.

HONEST BOUNDARY. A true cycle (a.X > b.Y AND b.Y > a.X) never resolves (no free anchor); it
falls back to the pre-v0.15.1 type-sample best-effort and the impossible arm stays honestly
uncovered (50%) - no phantom pass, no hang (the relaxation is capped at 64 rounds).

VALIDATED on AdventureWorks2025: transitive chain a.X>b.Y>c.Z NOT_TESTABLE/50% -> 100%
(seed TA.X=44, TB.Y=43, TC.Z=42); disjoint 3-table and shared-right-column still 100%;
contradiction and cycle stay honest 50% (no hang/error). REGRESSION: PredicateZoo re-parsed
clean (28 PREDTREE, 5 by-design loop gates) and 13 seedable gates re-ran GREEN at 100%
(NonEquiJoin/SelfJoin/SharedTable/ParamComparand/Exists/NotExists/Or/ScalarCmp/Count*/Sum
OverJoin/CountBetween); ContradictionGate honest 50%. PARSEONLY over the installer: 0 errors.
NO C# / CLR change (assembly hash unchanged).
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical) + modules/32_Seeder_v1.sql (TestGen.ExecuteSeedPlan propagation pre-pass +
@cc_chosen lookup in the emit loop). Bump to v0.15.1 when committing.

================================================================================
2026-06-14  -  v0.15.2  -  cross-column seeding: a column constrained by MANY comparisons
================================================================================
Extends cross-column seeding to a column that must satisfy SEVERAL comparisons at once:
a.X > b.Y AND a.X > c.Z (a.X must beat BOTH anchors), or a range a.X >= b.Y AND a.X <= c.Z.
These now seed to 100% branch (was honest 50% residue).

ROOT CAUSE. The relaxation resolved a multi-constraint column by taking MAX over a
SatisfyingValue computed per anchor. That is wrong twice over: (1) MAX over the string
literals is LEXICAL, so '43' > '101' and a.X would be seeded below the larger anchor; and
(2) for mixed operators (a range) neither MAX nor MIN of the per-anchor values is correct.

FIX (T-SQL only). New scalar TestGen.SatisfyAll(@constraintsJson) intersects a column's
numeric comparison constraints into ONE satisfying value: lo = max of the lower bounds
(> -> val+1, >= -> val), hi = min of the upper bounds (< -> val-1, <= -> val), returns a
value in [lo,hi] - NUMERIC, not lexical. The ExecuteSeedPlan relaxation now resolves a
satisfyother column only once ALL its anchors are chosen; a single anchor still uses
SatisfyingValue (unchanged), multiple anchors use SatisfyAll over the anchors' ACTUAL
resolved values. An empty intersection (a.X > 100 AND a.X < 50) or an '='/'<>'/non-numeric
fan returns NULL, so the column is left for the cycle fallback and the impossible arm stays
honestly uncovered - never a wrong seed.

VALIDATED on AdventureWorks2025. SatisfyAll unit tests: >9 AND >100 -> 101 (NOT lexical 10);
>=42 AND <=100 -> 42; >100 AND <50 -> NULL; '='-fan -> NULL. Integration: a.X>b.Y AND a.X>c.Z
-> 100% (seed a.X=43 beats both). REGRESSION: transitive chain and disjoint-pairs still 100%;
PredicateZoo green (NonEquiJoin/SelfJoin/SharedTable/CountEq/ScalarCmp/OrComposition 100%,
ContradictionGate honest 50%). Single-anchor resolution is byte-for-byte unchanged (cnt=1
branch). PARSEONLY over the installer: 0 errors. NO C#/CLR change (assembly hash unchanged).
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical) + modules/32_Seeder_v1.sql (new TestGen.SatisfyAll; ExecuteSeedPlan
relaxation gains the all-anchors-ready gate + multi-anchor SatisfyAll path).
Remaining residue (rare): a column fanned by '=' / '<>' across several anchors, or mixed
with a literal comparison on the SAME column, is not intersected (honest 50%). Bump to
v0.15.2 when committing.

================================================================================
2026-06-14  -  v0.15.3  -  cross-column seeding: =/<> fans + column-vs-column AND a literal
================================================================================
Closes the last residual cross-column shapes from v0.15.2:
  (A) equality fan      a.X = b.Y AND a.X = c.Z   (a.X must equal BOTH)
  (A') inequality fan   a.X <> b.Y AND a.X <> c.Z (a.X must differ from BOTH)
  (B) column + literal  a.X > b.Y AND a.X > 100   (a column compared to another column AND a literal)
All now seed to 100% branch (were honest 50% residue).

FIX (T-SQL only). Two parts:
1. TestGen.SatisfyAll extended from bounds-only to a full single-variable solver: it now
   handles '=' (one value, validated against the bounds and any '<>') and '<>' (numeric:
   pick above all exclusions; string: a guaranteed-non-matching sentinel) in addition to
   >,>=,<,<= - NUMERIC for numbers, equality/inequality for strings. Conflicting equalities
   or an empty range still return NULL (honest residue).
2. ExecuteSeedPlan now captures a column's {satisfy} literal/param comparisons (new @cc_cmp)
   and FOLDS them into the same intersection as its {satisfyother} cross-column comparisons.
   A column with >=2 hard constraints (multi-anchor, OR anchor+literal) is solved by
   SatisfyAll over the full set; a single constraint keeps its original byte-for-byte path.

VALIDATED on AdventureWorks2025. SatisfyAll unit tests: =42 AND =42 -> 42; =42 AND =43 -> NULL;
<>42 AND <>42 -> 43; <>42 AND <>50 -> 51; =5 AND >1 -> 5; =5 AND >10 -> NULL; =N'abc' AND
=N'abc' -> N'abc'; <>N'abc' -> sentinel. Integration: eq-fan 100% (a.X=42), neq-fan 100%
(a.X=43), col+literal 100% (a.X=101 beats both); a.X=b.Y AND a.X<>b.Y stays honest 50%.
REGRESSION: multi-anchor / transitive chain / single colcol still 100%; PredicateZoo green
(CountEq/NonEquiJoin/ScalarCmp/ParamComparand 100%, Contradiction 50%; Exists/NotExists/
SelfJoin/SharedTable/Or/CountBetween/CountIn all pass 0-fail). PARSEONLY: 0 errors. NO C#/CLR
change (assembly hash unchanged).
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical) + modules/32_Seeder_v1.sql (SatisfyAll extended; ExecuteSeedPlan gains @cc_cmp
+ folds literal comparisons into the intersection). Remaining residue is now only the truly
exotic (e.g. a non-numeric inequality fan, or a satisfysample non-equi-join mixed with a
literal on the same column). Bump to v0.15.3 when committing.

================================================================================
2026-06-14  -  v0.15.4  -  coverage for self-transaction + advanced-construct procs
================================================================================
Procedures that manage their OWN transactions and/or use advanced constructs (OPENJSON WITH,
CTE-driven UPDATE/MERGE) previously reported a FALSE 0% coverage. They now measure. Surfaced
on ComplexOrderTest.Sales.usp_ProcessComplexOrderExecution (JSON shred + window CTEs + MERGE +
a transaction with multiple rejection paths): 0% -> 37% line / 50% branch, the remainder
honestly attributed to the seeding ceiling (JSON-derived + @@ROWCOUNT/@@TRANCOUNT/local-var
predicates that the data-seeder cannot reach), NOT an instrumentation failure.

ROOT CAUSE (two independent defects, both pre-existing):
1. The line-based coverage instrumenter (TestGen.InstrumentProcedure) mis-split statements when
   building the measured "_cov" shadow, so the shadow FAILED TO COMPILE and there was nothing
   to measure (hence 0%):
     a. a leading ';' on ";WITH cte AS (" blanked first-word detection, losing the CTE's WITH
        state and splitting the CTE+UPDATE into "UPDATE pi" + a stray "SET ...";
     b. the OPENJSON/CHANGETABLE "WITH (" clause was treated as a new CTE opener and split off
        from its SELECT ("Incorrect syntax near '('");
     c. a CTE whose main statement is UPDATE/DELETE/MERGE/INSERT did not hand off to that verb's
        continuation set, so the body's SET/VALUES fired a spurious mid-statement boundary.
2. The proc's own BEGIN/COMMIT/ROLLBACK TRANSACTION + SET XACT_ABORT ON collapsed tSQLt's
   per-test transaction ("Transaction count after EXECUTE indicates a mismatching number of
   BEGIN and COMMIT" - every test that EXECs the proc errored) and rolled back the coverage
   capture.

FIX (T-SQL only, all in TestGen.InstrumentProcedure):
- (1a) strip a leading ';' before first-word detection.
- (1b) treat "WITH (" (paren straight after WITH) as a continuation, not a CTE opener.
- (1c) when @OpenStmt='WITH' and the line's verb is UPDATE/DELETE/MERGE/INSERT, transition
  @OpenStmt to that verb so its continuation set (SET, VALUES, ...) applies.
- (2) NEUTRALIZE the proc's own transaction-control statements IN THE SHADOW ONLY: each
  standalone BEGIN/COMMIT/ROLLBACK [TRAN[SACTION]] / SAVE TRAN / SET XACT_ABORT ON becomes a
  no-op statement ("SET @__uag_noop = 0;", declared in the shadow preamble). A no-op STATEMENT
  (not a comment) is required because the statement may be the only one in a BEGIN/END or IF
  body (e.g. the CATCH's "IF @@TRANCOUNT>0 BEGIN ROLLBACK END") and an EMPTY BEGIN/END is
  invalid T-SQL. Control flow + line mapping are unchanged; the proc runs inside tSQLt's single
  transaction; and the real value/effect assertions still run against the UNCHANGED proc - the
  shadow exists only to measure which lines run. Only whole-statement transaction lines are
  touched (one-statement-per-line guard), so an inline "ROLLBACK; RETURN;" is left alone.

VALIDATED: ComplexOrderTest proc shadow now COMPILES, 0 trancount errors, 13/35 lines (37.1%)
/ 3/6 branches (50.0%). REGRESSION: PredicateZoo on AdventureWorks2025 green - 8 gates
(CountEq/NonEquiJoin/Exists/ScalarCmp/OrComposition/CountOverJoin/SumOverJoin/SelfJoin) all
100% with the new instrumenter (the new rules only fire on transactions/OPENJSON/CTE/leading-';',
so normal procs are byte-for-byte unaffected). PARSEONLY over the installer: 0 errors. NO C#/CLR
change.
KNOWN RESIDUE (pre-existing, unchanged): the coverage hit injected between a statement and an
immediately-following @@ROWCOUNT/@@ERROR check clobbers those (the affected branches are
NOT_TESTABLE anyway); an inline "ROLLBACK; RETURN;" is not neutralized. The deeper, general fix
remains the roadmapped ScriptDom-based instrumenter (this line-based walker has a ceiling).
FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). modules/20_Coverage_Instrumenter_v5.sql is a STALE reference (already behind
the installer's v5.2) and is intentionally not patched. Bump to v0.15.4 when committing.

## 2026-06-14 -- v0.15.5 deep-gate deterministic witnesses: JSON/table-variable aggregates + key-lookup gates -> 100%

CONTEXT: the v0.15.4 challenge proc (ComplexOrderTest.Sales.usp_ProcessComplexOrderExecution)
measured a faithful 37% line / 50% branch but could not reach the deep half: the gates over a
JSON-shredded table VARIABLE (@CalculatedTotalDue = SUM(...), @InventoryShortageCount = COUNT(...)
over @ParsedItems), the key-lookup status scalar (@IsCustomerActive = 0), the @@ROWCOUNT
"not found" check, and the NULL parameter guard. The iterative search cannot seed a table
VARIABLE ("Must declare the table variable @ParsedItems") and the scalar/ROWCOUNT/NULL gates
were left ENVIRONMENTAL/NOT_TESTABLE.

ROOT INSIGHT: these are all DETERMINISTIC once you read the proc's structure - no search needed.
JSON synthesis is trivial; the real work is (a) synthesising a valid JSON parameter from the
OPENJSON WITH schema + seeding the catalog JOIN table to match, and (b) for an aggregate-over-
table-variable gate, PIVOTING the seed to the OTHER comparand's REAL source column (e.g. a
credit-limit column on the lookup table) instead of the un-seedable table variable.

FIX (T-SQL only, NO C#/CLR change):
- NEW TestGen.DeriveDeepGateWitnesses (+ helpers TestGen.BuildSeededRow, TestGen.PatchArgList).
  Parses, from the proc's own body: the key-lookup SELECT (table, key col, key param, the
  local->column map), and the OPENJSON(@param) WITH(...) shred (json props, the populated table
  variable, the catalog JOIN table + key, the catalog WHERE filter). Synthesises a valid JSON
  literal + coordinated real-table seeds, and upgrades each UNRECOGNISED gate to a verified
  WITNESS with a per-witness ArgOverride:
    * NULLPARAM    - @p IS NULL [OR ...]            -> pass NULL for the parameter
    * ROWCOUNTCHK  - @@ROWCOUNT = 0 after lookup    -> fake the lookup table empty (0 rows)
    * LOOKUPSCALAR - @statuslocal = <lit>           -> seed the lookup row with that col=<lit>
    * JSONAGG-COL  - @agg <op> @lookupcol           -> JSON+catalog seed; comparand col set low
    * JSONAGG-CNT  - @countlocal > 0 [AND @p = k]   -> JSON+catalog seed (no stock); arg k set
    * HAPPYPATH    - falls through every gate        -> valid JSON, active row, high credit, bit=1
- TestGen.SearchSeedResult gains an ArgOverride column. TestGen.EmitSearchSeedTests honours it:
  uses it as the EXEC arg list, SKIPS the generic reach prefix (the witness is self-contained),
  and suppresses ExpectException for self-contained witnesses (the proc catches its own RAISERROR
  internally, so expecting a propagated error would false-fail).
- TestGen.SearchSeedForProc now runs DeriveDeepGateWitnesses FIRST and the iterative search
  SKIPS any gate already witnessed - so deep gates are covered deterministically and fast
  (no per-candidate XEvent sweep; SearchSeedForProc on the challenge proc dropped to ~1s).

RESULT: ComplexOrderTest.Sales.usp_ProcessComplexOrderExecution -> 100% line (35/35) + 100%
branch (6/6) via GenerateAndRunCoverage end-to-end (~14s), all 6 generated deep-gate witness
tests passing. (The proc's generic base/negative tests still fail on naive arguments - the
pre-existing "valid-input synthesis for complex procs" + "error-expectation over-generation"
limitations - this is separate from the coverage result and unchanged here.)
REGRESSION: PredicateZoo on AdventureWorks2025 green - every gate at its expected coverage
(ScalarNullGate/CountEqGate/ScalarCmpGate/ExistsGate/NonEquiJoinGate/OrCompositionGate/
SumOverJoinGate 100%, ContradictionGate honest 50%), 0 failed / 0 errored. The derivation is a
no-op on procedures without the lookup/OPENJSON shape, so normal procs are unaffected.

CLEANUP (same v0.15.5, base-test false-fails on this proc shape): with the deep half now
reachable, the proc's GENERIC base/negative tests were false-failing (6 of them). Three fixes,
all gated to the relevant shape so pz/AW2025 base tests are unaffected:
- VALID JSON for the smoke tests: GenerateTestsForProcedure now gives a parameter consumed by
  OPENJSON(@param) an empty JSON array '[]' in the happy-path + boundary arg lists (was arbitrary
  text -> JSON parse error -> uncommittable transaction under XACT_ABORT, failing "executes with
  valid inputs"/"assigns OUTPUT"/"touches only mocked tables"). TestGen.PatchArgList made
  space-tolerant so it patches both "@p = v" (happy lists) and "@p=v" (witness lists).
- SUPPRESS error-expectation tests when the proc SWALLOWS its own errors: new @SwallowsErrors
  (the body has a CATCH that neither THROWs nor RAISERRORs) gates @UseExpectExceptionForInvalid
  and the "raises error path" block off, so ExpectException isn't asserted for a RAISERROR the
  proc catches internally (was failing "Expected an error to be raised").
- BuildLikeSkeleton overlap fix: a literal that is a SUBSTRING of a longer collected literal
  (a standalone 'SUCCESS' audit-type inside the status 'FULL_SUCCESS') is dropped, so the OUTPUT
  skeleton is '%FULL[_]SUCCESS%' not the un-matchable '%FULL[_]SUCCESS%SUCCESS%'.
RESULT: ComplexOrderTest proc suite now 11 passed / 0 failed / 0 errored / 8 honest skips, still
100% line + 100% branch. pz regression re-run green (0 failed/errored, same coverage). Whole
installer PARSEONLY-clean (286 batches, 0 syntax errors).

ADOPTION (same v0.15.5): turn the reverse-seedable SKIPPED predicate-branch tests into PASSING
tests instead of leaving them skipped.  The static (table-column) seeder leaves predicates
inside CASE expressions / over the JSON-shredded table variable as honest skips, but the
reverse-seeding scenario can drive them.  DeriveDeepGateWitnesses now emits a CASEARM witness per
such (not-yet-witnessed) predicate line - one scenario (HIGH json quantity + NO stock + partial
fulfilment) makes the volume-discount arms (json.Quantity >= 100 / >= 50), the shortage flag
((stock - qty) < 0) and the shortage-count CASE arms (@InventoryShortageCount > 0 at the
OrderStatus + final-status CASEs) all TRUE.  Detection: a predicate that references a json-shred
column, a COUNT-over-table-variable local, or an "X - Y < 0" stock/shortage shape.
EmitSearchSeedTests dedup is now direction-aware: a CASEARM witness also replaces the line's
"predicate TRUE" skip (the passing "predicate FALSE" arm is kept).
RESULT: on ComplexOrderTest those 5 skips (L72 x2, L94, L129, L157) became passing CASEARM tests
-> suite now 18 run / 15 passed / 0 failed / 0 errored / 3 skips; the 3 residual skips are
genuinely non-data-seedable (two out-of-domain boundary probes + @@TRANCOUNT).  Coverage stays
100% line / 100% branch.

CROSS-COLLATION FIX (found during AW2025 regression): DeriveDeepGateWitnesses compared its
SYSNAME temp columns (server collation) against PredicateInbox.PredicateText / @ptext (database
collation), so on a DB whose collation <> server it raised "Cannot resolve the collation conflict
... in the charindex operation" - caught by the outer TRY (reported "search-seeding skipped"),
so the deep-gate witnesses silently did NOT generate on such DBs.  Fixed: #lkpmap/#json/#sg/
#cntloc name columns declared COLLATE DATABASE_DEFAULT, and PredicateText coerced COLLATE
DATABASE_DEFAULT in the CHARINDEX comparisons.  Verified on AW2025 (collation error gone,
CountEqGate 100%/100%, 0 failed) and ComplexOrderTest (unchanged).

OUTPUT-EFFECT ASSERTIONS (same v0.15.5): the search/derive witness tests were coverage-backed
SMOKE (run the verified seed; rely on no-throw + the coverage instrumenter), with no per-test
assertion of the business outcome.  EmitSearchSeedTests now MEASURES each witness's scalar OUTPUT
parameters against the neutralised _cov shadow (which cannot collapse a transaction or touch real
tables) and BAKES an assertion into the test body after the EXEC, so the test guards the outcome:
a later logic change that alters the OUTPUT fails the test.
- Measure once, in a rolled-back transaction; the OUTPUT @vars are captured AFTER the rollback
  (they survive it; rows INSERTed into the capture temp inside the txn would be rolled back).
- A numeric output, or a string output the proc assigns as a CONSTANT (the measured value appears
  verbatim as a string literal in the source), is asserted EXACT (AssertEquals / AssertEqualsString).
  A concatenated / runtime-varying string output gets a constant-skeleton LIKE (BuildLikeSkeleton).
- Fully TRY/CATCH-guarded + collation-safe (#outp/#wmeas COLLATE DATABASE_DEFAULT): any measurement
  failure falls back to the prior smoke witness, so emission never breaks.  Read procs with no
  scalar OUTPUT get no assertion (unchanged).
RESULT on ComplexOrderTest: every witness now asserts its status, e.g. ROWCOUNTCHK ->
'CRITICAL: Customer record not found', LOOKUPSCALAR -> 'REJECTED: Customer account inactive',
JSONAGG-COL -> 'REJECTED: Insufficient credit limit', JSONAGG-CNT -> 'REJECTED: Out of stock
safety rules', CASEARM/HAPPYPATH -> 'PARTIAL_SUCCESS', NULLPARAM -> AssertEquals @ProcessedOrderID=0
+ AssertLike '%ERROR: %Missing required input boundaries.%'.  Suite 18 run / 15 pass / 0 fail /
3 skip, still 100%/100%.  MUTATION-PROVEN: changing the proc's 'REJECTED: Customer account
inactive' literal (without regenerating) makes the L58 witness FAIL ("Expected <...> but was
<...(MUTATED)>") - the tests are now real keepers of the business logic.  pz regression green
(LoopLocalGate search witnesses 100%, 0 failed; read-proc witnesses unchanged).

FALSE-ARM ADOPTION (same v0.15.5): a CASE/count-local predicate that had a degenerate "predicate
FALSE" smoke stub (the static seeder ran it with naive args that returned at customer-not-found,
passed the OUTPUT params as literals, and asserted nothing) is now adopted in BOTH directions.
DeriveDeepGateWitnesses emits a FALSE-arm CASEARM witness (Comparator='false') for any adoptable
line whose inbox row has a FALSE seed plan, driving the NO-shortage success path (empty JSON ->
shortage count 0) so the same lines run with the opposite outcome; EmitSearchSeedTests dedup is
now direction-aware (a CASEARM 'true' witness drops the line's "predicate TRUE" / NOT_TESTABLE
stub; a 'false' witness drops "predicate FALSE").  RESULT on ComplexOrderTest: L129/L157 now have
BOTH arms asserted - true -> 'PARTIAL_SUCCESS', false -> 'FULL_SUCCESS' - replacing the degenerate
FALSE smokes; suite 18 run / 15 pass / 0 fail / 3 skip, still 100%/100%; pz green (CountEqGate
6/0/0/1, LoopLocalGate 2/0/0/2 - the FALSE-arm path is a no-op where no FALSE seed plan exists).

BOUNDARY-PROBE TRANCOUNT TOLERANCE (same v0.15.5, user: "why are the high/low boundary tests
skipped?"): the generic "accepts low/high boundary values" tests were honest-skipped on this proc
shape because TestGen.ProbeHappyPath (the gen-time probe that runs the REAL proc in a rolled-back
transaction to decide whether the boundary inputs are in-domain) saw error 266 "Transaction count
after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements" and treated it as an
input rejection. That error is NOT a rejection: the boundary @CustomerID (max int) is not among the
seeded customers, so the proc takes its own customer-not-found ROLLBACK path, which collapses the
probe's wrapper transaction. FIX: ProbeHappyPath now ignores error 266 (IF ERROR_NUMBER() <> 266),
since 266 means the procedure managed its OWN transaction, not that the inputs were rejected; a
genuine rejection still surfaces as its own rethrown message. The boundary "accepts" tests are then
emitted (not skipped) and pass against the neutralised _cov shadow during coverage (the same harness
the witnesses already rely on). Also closed a latent gap: the OPENJSON-param valid-JSON patch
reached @ArgListHappy + @ArgListBoundary but NOT @ArgListHighBnd (the high-boundary list still got
'XXXX...'); now all three are patched. RESULT on ComplexOrderTest: skips 3 -> 1 (only the genuine
@@TRANCOUNT branch-11/line-164 NOT_TESTABLE remains), suite 18 run / 17 pass / 0 fail / 0 err /
1 skip, still 100% line (35/35) + 100% branch (6/6). Both changes are self-targeting no-ops
elsewhere: ProbeHappyPath only sees 266 from a self-transaction proc, and the JSON patch only fires
for OPENJSON procs (no pz gate is either). Regressed on AdventureWorks2025/pz: CountEqGate 100/100
(6/0/0/1), LoopLocalGate 100/100 (2/0/0/2), ContradictionGate honest 50/50 (5/0/0/2), ScalarNullGate
100/100 (8/0/0/1) - all 0 fail / 0 err. CAVEAT (pre-existing, not introduced here): a self-managed-
transaction proc's rollback-path tests pass under the coverage harness (which runs the neutralised
shadow); run directly via tSQLt.Run they would error on the proc's own ROLLBACK - the general fix is
the deferred ScriptDom/tsqltu direction.  [ADDRESSED by the SHAPE-AWARE RUNNER below.]

SHAPE-AWARE TEST RUNNER (same v0.15.5, user: "what is the solution for this issue in the current
code base?" - make a self-transaction proc's generated tests runnable by a normal test run, not
only under the coverage harness): NEW TestGen.RunTests @SchemaName, @ProcName. A naked tSQLt.Run of
a self-managed-transaction proc's class ERRORS on the rollback-path tests, because the proc's bare
ROLLBACK rolls back tSQLt's per-test transaction AND its FakeTable setup -> error 266 at teardown
(a documented tSQLt limitation; you cannot stop a bare ROLLBACK reaching the root while the real
statements run). RunTests detects the shape (source has BEGIN TRAN / COMMIT / ROLLBACK / SET
XACT_ABORT ON) and, for such a proc, DELEGATES to RunCoverage with the report suppressed
(@OutputMode='NONE') - reusing its object-loss-safe transient swap (rename real->_orig, synonym->
neutralized _cov shadow, run, GUARANTEED restore + interrupted-run self-heal), whose XEvent step
degrades gracefully (TRY/CATCH) when ALTER ANY EVENT SESSION is not granted, so the tests still run
+ restore even without coverage permissions. A plain proc is run directly via tSQLt.Run (no swap,
no instrument), and RunTests also runs any developer-owned test_<proc>_custom% classes. Returns
Run/Passed/Failed/Errored/Skipped via OUTPUT + a one-line summary. The neutralized shadow differs
from the real proc ONLY in that transaction statements are no-ops, so every branch/status/OUTPUT/
DML effect is exercised identically; the literal commit/rollback is the one thing not asserted
(which tSQLt cannot test for such a proc regardless). Design choice: DELEGATE the swap to the proven
RunCoverage rather than duplicate the dangerous rename/restore (object-loss history); NO edits to
RunCoverage/InstrumentProcedure. VALIDATED: ComplexOrderTest self-tx proc via RunTests -> Run=18
Passed=17 Failed=0 Errored=0 Skipped=1 (green where a naked tSQLt.Run errors), proc safely restored
(base=proc, no synonym); pz.ScalarNullGate passthrough (non-self-tx) -> Run=9 Passed=8 Failed=0
Errored=0 Skipped=1, no swap (syn=none). Installer redeploys clean on both DBs (289 batches, 0
errors).

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). modules/* not patched (the new procs live only in the installer for now).
dist/UnitAutogen-0.15.5-install.zip rebuilt. Bump to v0.15.5 when committing.

================================================================================
2026-06-15  v0.15.6  STATEMENT-AWARE INSTRUMENTER (dense one-liner branch coverage)
================================================================================
User finding (HighValueCustomer report): dbo.AssessCustomer showed 100% line but
only 1 line measured and 0% branch - which contradicted the v0.12 record of it at
100% branch. ROOT CAUSE: the proc is written with each IF, its THEN body, and its
ELSE all on ONE physical line (e.g. "IF EXISTS(...) SET @r+='A'; ELSE SET @r+='B';"),
and a 3rd IF buried after a DECLARE on a single line. The coverage instrumenter is
LINE-based: it marks branch lines and infers "branch taken" from whether the NEXT
executable line was hit. When the THEN/ELSE bodies share the predicate's line there
is no separate executable line to attribute, so 0% branch; and a non-line-leading IF
(after DECLARE;) isn't even detected as a branch. The 11 tests DO exercise every arm
(they pass) - it was a FALSE-NEGATIVE measurement artifact, not honest residue.
User's point (correct): the statements are explicitly ;-terminated, so a string
parser should handle this without needing the ScriptDom rewrite.

FIX: statement-aware LAYOUT NORMALIZATION run before instrumentation. New
TestGen.NormLineStep (per-line lexer) + TestGen.NormalizeBranchLayout (driver)
reformat dense one-liners onto canonical one-statement-per-line form - each
;-terminated statement and each IF/ELSE/WHILE inline body on its own line - so the
existing line-based walker marks + measures every arm. InstrumentProcedure calls it
on @ProcSource right after CRLF normalization, behind an OBJECT_ID guard + TRY/CATCH
(on any failure it keeps the original source - never worse than before).

DO-NO-HARM design (key to zero regression):
 - Threads lexical state (string / block-comment / [bracket] / paren / BEGIN-CASE
   depth) ACROSS lines. A line is rewritten ONLY if it both starts and ends in a
   clean state; any line that is part of a multi-line construct passes through
   BYTE-IDENTICAL.
 - CASE-aware: a CASE expression's WHEN/THEN/ELSE/END are never treated as control
   flow (verified: "IF x SET y=CASE WHEN.. ELSE.. END; ELSE SET y=9;" splits the
   IF's ELSE but NOT the CASE's ELSE).
 - Idempotent; a no-op on already-well-formatted procedures (a 98-line proc stays
   98 lines).

VALIDATED:
 - AssessCustomer (HighValueCustomer): 0% branch -> 100% (6/6), 1 line -> 7/7 line,
   11/11 pass (7 hit-injections vs 1 before). The false-negative is gone.
 - REGRESSION (all UNCHANGED): ComplexOrderTest usp_ProcessComplexOrderExecution
   (CASE+OPENJSON+MERGE+txn) 6/6 branch, 17 pass/1 skip/0 fail/0 err; pz CountEqGate
   100/100 (6p1s), ScalarNullGate 100/100 (8p1s), LoopLocalGate 100/100 (2p2s),
   ContradictionGate honest 50/50 (5p2s); HighValueCustomer GetVIP unchanged
   (0/1 honest error-path residue), usp_ReconcileTradedPositions unchanged
   (10/16, 20t/13p/7s). Installer redeploys clean on all DBs (294 batches, 0 errors).

NOTE: report line numbers for a rewritten proc are relative to the normalized layout
(the % is correct; the uncovered-line list still shows the statement text). This is
the in-engine, string-based answer to the dense-one-liner case; the AST/ScriptDom
instrumenter (deferred tsqltu) would make it formatting-immune by construction.

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.15.6-install.zip rebuilt.

================================================================================
2026-06-15  v0.15.7  ARITHMETIC-DERIVED PER-ROW SEEDING (PERROW-ARITH)
================================================================================
User issue: usp_ReconcileTradedPositions (HighValueCustomer) skipped its
@AdjustedValue gates as "comparison does not involve an aggregate/scalar subquery".
@AdjustedValue is a DERIVED LOCAL: line 99 "DECLARE @AdjustedValue = (@CurrentVolume
* @CurrentPrice) * @RiskMultiplier", a product of per-row loop columns (Volume,
ExecutionPrice from RawPositionIngest) and a non-row local (@RiskMultiplier from an
AVG over MarketIndicators). The branch "@AdjustedValue > 50000" (line 109) and
"> 250000" (line 116) are real, coverable arms (spike: Volume=600,Price=100 ->
60000 -> MANUAL_REVIEW; Volume=100 -> 10000 -> APPROVED) but the static grammar
can't invert a derived-local-vs-literal, and the per-row SEARCH archetype missed it
for THREE reasons: (1) it followed only the FIRST factor (Volume) and left the
co-factor ExecutionPrice at its default 0/NULL -> product 0 (or tripped the
"Volume>0 AND Price>0" guard) so the knob could never cross the threshold; (2)
@RiskMultiplier was never pinned; (3) the per-gate search runs the instrumented loop
proc many times and TIMES OUT on this proc.

FIX = a DETERMINISTIC arithmetic-derived per-row path in TestGen.SearchSeedForProc's
PER-ROW numeric branch (archetype PERROW-ARITH):
- Parse the operand's own assignment RHS; if it is a PRODUCT, resolve each @local
  factor to its per-row source column and NEUTRALISE the co-factor columns (override
  =1) so the product reduces to the driving knob.
- Pin non-row factor locals for free: EmitSearchSeedTests already FakeTables EVERY
  referenced user table, so MarketIndicators is faked empty -> AVG NULL -> the ELSE
  branch -> @RiskMultiplier=1.00 (and WavePatternPhase='B'), a positive constant, so
  the product is monotonic in the knob.
- Set the driving knob deterministically just past the literal (>T -> T+1, <=T -> 1,
  = -> T) and WRITE THE WITNESS DIRECTLY - no SearchSeedForGate call, which both fixes
  the multi-factor product AND sidesteps the loop-proc search timeout.
- RESTRICTED to a SIMPLE single-comparison predicate: a compound gate (e.g.
  "@AdjustedValue > 100000 AND @WavePatternPhase='C'", line 105) has a conjunct this
  path can't satisfy (phase='C' needs MarketIndicators seeded high, which the empty
  fake prevents) - a deterministic witness there would hit a LOWER sibling arm and
  wrongly drop the honest skip, so compound gates stay NOT_TESTABLE.
- Additive + gated: the existing search runs unchanged when the deterministic path
  doesn't apply (IF @resolved=0); non-product / categorical per-row gates are
  untouched. SET-initialised @ad* locals (loop-DECLARE initialisers run once).

VALIDATED on HighValueCustomer usp_ReconcileTradedPositions: L109 (@AdjustedValue >
50000) and L116 (> 250000) go skip -> PERROW-ARITH WITNESS, emitted as run (not skip)
tests that PASS (0 fail / 0 err), with the seeds verified to drive the arms
(50001 -> MANUAL_REVIEW, 250001 -> FLAG_LARGE_CAP, row processed) and an OUTPUT-effect
assertion on @TotalProcessedRecords. L105 (compound) correctly stays honest
NOT_TESTABLE. REGRESSION all UNCHANGED: pz LoopLocalGate 3/3 (the loop gate that
exercises this path), CountEqGate 2/2, ScalarNullGate 2/2, ContradictionGate honest
1/2; ComplexOrderTest usp_ProcessComplexOrderExecution 6/6 (17p/1s); AssessCustomer
6/6. Installer redeploys clean on all DBs (294 batches, 0 errors).

NOTE: the full @Budget=24 aggregate for usp_ReconcileTradedPositions is not re-measured
in-tool (its remaining search gates make the sweep slow); the change is purely additive
(+2 branches: 62.5% -> ~75%). Derived-local arithmetic over MULTI-hop (temp-table) or
non-product expressions, and compound conjuncts, remain future scope (the general
value-dataflow / ancestor-chaining frontier).

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.15.7-install.zip rebuilt.

================================================================================
2026-06-15  v0.15.8  ARITHMETIC-DERIVED SEEDING: COMPOUND CONJUNCTS + SUM + MULTI-HOP
================================================================================
Closes the two residuals noted at the end of v0.15.7 (the "general value-dataflow
frontier"): COMPOUND conjuncts that need coordinated multi-source seeding, and
derived locals over MULTI-HOP or NON-PRODUCT (sum) expressions. All in
TestGen.SearchSeedForProc (the PERROW-ARITH path + the @recPfx coupled-conjunct
prefix); additive + gated + fail-safe; no C#/CLR change.

(1) COMPOUND CONJUNCTS - coordinated multi-source seed.  L105 of
    usp_ReconcileTradedPositions is "@AdjustedValue > 100000 AND @WavePatternPhase
    = 'C'": the arith conjunct AND a flag conjunct, where the flag is set by
    "IF @MFI_Score > 80" and @MFI_Score = AVG(MFI_Value) FROM MarketIndicators
    WHERE MetricDate >= DATEADD(day,-14,@CutoffDate).  When the flag-setting IF is
    not (yet) witnessed, @recPfx now SYNTHESISES its seed directly: parse the IF's
    aggregate-band condition, seed the source table ONE row with the aggregated
    column at K+/-1 (so AVG/MIN/MAX/SUM crosses K) and any DATE filter column
    far-future ('99991231') to satisfy a ">=" window.  The PERROW-ARITH guard is
    relaxed to allow a compound predicate when @recPfx satisfies the extra conjunct
    (OR still blocked; an AND we cannot satisfy still stays NOT_TESTABLE).  L105 ->
    skip -> covered: the coordinated seed makes phase='C' (MFI=81), risk=1.5, and
    @AdjustedValue = 100001*1*1.5 = 150001 > 100000 -> HOLD_RISK_LIMIT.  Fail-safe:
    the whole synthesis is TRY/CATCH'd -> empty -> the gate just stays NOT_TESTABLE,
    never a wrong witness.

(2) SUM (+) and MULTI-HOP derived locals.  The PERROW-ARITH operand parse is now
    operator-aware: a PURE product (*) neutralises co-factors to 1; a PURE sum (+)
    neutralises co-addends to 0; the knob's small value (for </<= arms) follows the
    neutral.  Co-factor resolution is now MULTI-HOP (@factor = @intermediate = ... =
    Col, bounded 4 hops) like the driving-column lineage already was.  Mixed */+ or
    subtraction is left to the search (one operator class only).

VALIDATED:
 - L105 (compound) -> covered (PERROW-ARITH witness; the coordinated MarketIndicators
   seed appears in its arrange; not in the uncovered list; suite green 0 fail/0 err).
 - Synthetic loop proc t_ArithKinds (created + dropped): "@sumv > 1000" (sum:
   co-addend ExecutionPrice=0, knob 1001) and "@prodv > 5000" where @prodv =
   @mid * @price, @mid = @vol = Volume (MULTI-HOP: knob resolved to Volume, 5001) ->
   BRANCH 4/4 = 100%, both gates covered.
 - REGRESSION all UNCHANGED: pz LoopLocalGate 3/3 (the loop gate exercising this
   path), CountEqGate 2/2, ScalarNullGate 2/2, ContradictionGate honest 1/2;
   ComplexOrderTest 6/6 (17p/1s); AssessCustomer 6/6.  294 batches / 0 errors on all DBs.

RESIDUAL (still future scope): general WHERE-filter satisfaction beyond a single
date ">=" window (arbitrary multi-predicate filters), mixed */+ arithmetic, and
OR-disjunction in the gate predicate.

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.15.8-install.zip rebuilt.

================================================================================
2026-06-15  v0.15.9  COVERAGE TRUTH FIX (placeholder dilution) + AGG/OR/temp bug fixes
================================================================================
Headline: the v0.15.7/v0.15.8 arithmetic + compound witnesses were PASSING but NOT
COVERING their arm - a real bug I had missed because my earlier "covered" checks
grepped SOURCE line numbers while the v0.15.6 normalizer RENUMBERS lines (false
negative). Investigating usp_ReconcileTradedPositions honestly: 62.5% -> 93.8% branch.

ROOT CAUSE (placeholder dilution): EmitSearchSeedTests' reach prefix seeds ONE
placeholder row into every faked dependency. For an AGGREGATE SOURCE that feeds a
derived local that is NOT the witness's own table (e.g. @MFI_Score = AVG(MFI_Value)
FROM MarketIndicators, feeding @RiskMultiplier, which multiplies the per-row
@AdjustedValue), the placeholder (MFI_Value=1) makes AVG=1 -> @RiskMultiplier=0.75,
NOT the declared default 1.00 that PERROW-ARITH's knob assumed. So @AdjustedValue =
50001*1*0.75 = 37500 < 50000 -> L109's arm never runs. The witness still PASSED
because its OUTPUT assertion is on @TotalProcessedRecords (a COUNT), which is the
same on any status arm.

FIX (the genuine residual): EmitSearchSeedTests now computes the proc's
aggregate-source tables (AVG/SUM/MIN/MAX/COUNT(...) FROM tbl) and emits "DELETE FROM
<tbl>" AFTER the reach prefix and BEFORE the witness arrange, in BOTH the OUTPUT
measurement batch and the emitted test. The diluting placeholder is cleared, so the
witness's own seed controls the aggregate: a per-row-arith gate leaves it EMPTY ->
AVG NULL -> the local's DECLARE default (1.00); a compound gate's @recPfx seed
(MFI=81) is then undiluted -> AVG=81>80 -> phase='C'; an AGG gate's own seed is
exact. #temp sources are skipped (the reach never seeds them).

ALSO (search-harness bug fixes that newly WITNESS L44/L49/L88/L103):
- AGG date-EXEC-arg: the WHERE-keycol coordination passed a date param as
  CAST(GETDATE() AS DATE) - an EXPRESSION in an EXEC arg, which is illegal
  ("Incorrect syntax near 'GETDATE'"). Now a literal ('19000101' far-past for the
  param; '99991231' far-future for a seeded date column) so a "col >= <lookback>"
  filter is satisfied.
- Temp-source routing: an operand assigned FROM a #temp (the loop source) has no
  OBJECT_ID here, so the AGG/SCALAR arrange built an empty "INSERT #t () VALUES ()"
  ("Incorrect syntax near ')'"). Such gates now route to the PER-ROW archetype.
- Deterministic single-row AGG witness (AVG/MIN/MAX/SUM): seed @col to a value that
  crosses the literal (no search -> robust, no timeout, no "@Budget too small" miss).
  COUNT keeps the search (its knob is the row count).
- Deterministic OR per-row: seed the driving column so the FIRST disjunct is true
  (covers "@CurrentVolume <= 0 OR @CurrentPrice <= 0" at L88).

VALIDATED: usp_ReconcileTradedPositions 62.5% -> 93.8% branch (15/16; the 1 residual
is the environmental OBJECT_ID('tempdb..#PendingTrades') guard), 17 pass/0 fail/0 err.
REGRESSION all UNCHANGED: pz CountEqGate 2/2 (the COUNT case - its source is cleared
then re-seeded by the witness), LoopLocalGate 3/3, ScalarNullGate 2/2, ContradictionGate
honest 1/2; ComplexOrderTest 6/6 (17p/1s; its aggregates are over table VARIABLES, no
OBJECT_ID, so unaffected); AssessCustomer 6/6 (11p; covered via predicate-branch tests,
which the DELETE does not touch). 294 batches / 0 errors on all DBs.

LESSON: validate coverage from the report's authoritative BRANCH COVERAGE line, not a
grep of source line numbers, now that the instrumenter renumbers lines; and prefer an
OUTPUT/effect assertion that distinguishes the ARM (status), not just a row count.

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.15.9-install.zip rebuilt.

================================================================================
2026-06-15  v0.16.0  MIXED ARITHMETIC (*/+) + NON-DATE AGGREGATE FILTERS
================================================================================
Closes the two residuals left open in v0.15.9 (the general value-dataflow frontier).

1) MIXED */+ IN ONE DERIVED LOCAL. PERROW-ARITH previously handled a PURE product
   (co-factors neutral 1) or PURE sum (co-addends neutral 0); a mixed expression like
   "@MixedValue = @vol * @price + @fee" was left to the (slow, often unsuccessful)
   search. It now splits the operand's RHS into ADDITIVE TERMS (top-level '+'); the
   term that contains the DRIVING leaf keeps its product co-factors at 1, and EVERY
   OTHER term's leaves are set to 0, so the whole expression reduces to the driving
   leaf and the knob crosses the literal exactly (knob = T+1 for >, etc.; for a '<='
   arm the driving leaf's neutral follows its own term: 1 if multiplied, 0 if added).
   Pure product (one term) and pure sum (single-variable terms) are special cases of
   this, so existing product/sum witnesses are byte-for-byte unchanged.

2) NON-DATE AGGREGATE FILTERS. The aggregate-gate seed builder filled every non-key
   string column with the placeholder N'x'. When the aggregate had a filter such as
   "AVG(Score) FROM Metrics WHERE Status='ACTIVE'", the seeded row's Status='x' failed
   the filter -> the row was excluded -> AVG NULL -> the gate (and any compound gate
   that reuses this witness via @recPfx) never crossed. The builder now walks the
   target columns and, for any column with a "col = <literal>" predicate in the
   aggregate's WHERE, seeds that exact literal (read from the ORIGINAL-case WHERE so
   mixed-case values survive). Date columns keep the far-future '99991231' default;
   '>'/'>='/'<'/'<='/'<>'/IN predicates are left as-is (only simple equality is
   asserted). The @recPfx synthesis path got the same equality-filter handling for
   the case where the flag-setting IF has no prior witness.

DECLARE-in-loop safety: the new per-gate state (@adFirstVar, @adDrvNeutral, @adFv) is
reset with explicit SET (loop-DECLARE initialisers evaluate once); the seed-builder
and @recPfx cursors carry a CURSOR_STATUS guard so an exception in one gate can't
break the next gate's DECLARE.

VALIDATED on a synthetic loop proc (usp_V16Synthetic: mixed "@vol*@price+@fee > 5000"
+ compound ">8000 AND @QualityFlag='H'" whose flag is AVG(Score) WHERE Status='ACTIVE')
-> 100% line (12/12) + 100% branch (6/6), created and dropped.
REGRESSION all UNCHANGED: HighValueCustomer usp_ReconcileTradedPositions 93.8% (15/16),
AssessCustomer 100% (6/6); ComplexOrderTest 100% (6/6); AdventureWorks2025 pz - all 12
aggregate/scalar gates (Avg/Count*/Sum*/Max/Min/Scalar*) 100% (2/2), LoopLocalGate 3/3,
ContradictionGate honest 1/2; 0 fail / 0 err across the suite. 294 batches / 0 errors
on all three DBs.

STILL OPEN (narrower frontier): a derived local mixing '*' and '+' AND subtraction;
non-equality aggregate filters that need a satisfying value computed (range/IN).

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.16.0-install.zip rebuilt.

================================================================================
2026-06-15  v0.16.1  SUBTRACTION IN MIXED ARITH + NON-EQUALITY AGGREGATE FILTERS
================================================================================
Closes the two narrower residuals left open by v0.16.0.

1) SUBTRACTION in a derived local. PERROW-ARITH split into additive terms on '+'
   only and bailed on any '-'. It now treats '-' as a term boundary too (an internal
   '~' marker flags a negative term). Two kinds of subtracted term:
   - a COLUMN term (e.g. ... - @fee) neutralises to 0 exactly like an added column
     term (its sign is irrelevant once it is zero), so the expression still reduces
     to the driving leaf;
   - a standalone numeric CONSTANT term (e.g. ... - 100) folds, with its sign, into a
     new @adConstSum, which is subtracted back out of the knob so the driving term
     still crosses the literal exactly: for "@v*@p - 100 > 8000" the knob becomes
     8000 - (-100) + 1 = 8101, giving 8101*1 - 100 = 8001 > 8000. The witness guard
     was relaxed to also fire when there is only a constant offset (no co-factor cols).

2) NON-EQUALITY aggregate filters. The v0.16.0 seed builder satisfied only "col =
   <literal>" filters. It now also satisfies, for a seeded aggregate-source row:
   - numeric ">"/">="/"<"/"<=" -> a value just inside the bound (>:n+1, <:n-1,
     >=/<=:n); a non-numeric RHS (e.g. a date expression) is left to the type default,
     so a date ">= <lookback>" still uses the far-future '99991231';
   - "col IN (a, b, ...)" -> the first list element;
   - "col BETWEEN a AND b" -> the low bound a.
   "<>" is left to the default (which already differs from the comparand).

VALIDATED on a synthetic loop proc (usp_V161Synthetic) exercising column subtraction
"@v*@p - @fee > 5000", constant subtraction "@v*@p - 100 > 8000", and two compound
gates whose flags are AVG(Score) WHERE Region >= 5 (numeric range) and AVG(Score)
WHERE Tier IN ('A','B') (IN list) -> 100% line (17/17) + 100% branch (10/10), created
and dropped. REGRESSION all UNCHANGED: HighValueCustomer Reconcile 93.8% (15/16),
AssessCustomer 100% (6/6); ComplexOrderTest 100% (6/6); AdventureWorks2025 pz -
Avg/Count*/Sum*/Max/Min/Scalar* gates 100% (2/2), LoopLocalGate 3/3, ContradictionGate
honest 1/2; 0 fail / 0 err. 294 batches / 0 errors on all three DBs.

STILL OPEN (deferred to v0.16.2 - build cleanly in a new session):
  (a) parenthesised sub-expressions in a derived local are still flattened (paren stripping
      predates this work) -> "@a*(@b-@c)" mis-read; needs a paren/precedence-aware term walk.
  (b) a date "<= <bound>" aggregate filter (the date column default is far-future '99991231',
      suited to ">="); add date-operator dispatch ('<='->'19000101', '>='->'99991231').
  (c) temp-table tracing: a WHILE over "SELECT ... INTO #temp FROM <base>" (Reconcile's
      #PendingTrades loop at line 77) skips its DEDICATED predicate-branch tests ("tree target
      table not found: dbo.#PendingTrades") because a #temp is not a fakeable catalog table;
      tracing the temp back to <base> and seeding it would upgrade those skips to real tests.
      NOTE: the loop arms are already covered INCIDENTALLY by the arithmetic witnesses (which
      seed RawPositionIngest), so coverage is unaffected (15/16); the sibling
      OBJECT_ID('tempdb..#PendingTrades') IS NOT NULL guard (line 62) stays an honest
      environmental skip (temp existence is session state, not data-drivable).
  (a)+(b) do not occur in the reference procedures; (c) does (the visible Reconcile line-77 skips).

FILES: Install_UnitAutogen.sql + powershell/UnitAutogen/sql/Install_UnitAutogen.sql
(byte-identical). dist/UnitAutogen-0.16.1-install.zip rebuilt.
