<#
.SYNOPSIS
    v0.10 ScriptDom feasibility spike.

.DESCRIPTION
    Parses design/spike/TestProcedure.sql via Microsoft.SqlServer.TransactSql.ScriptDom
    and walks the AST to extract one ParsedPredicate row per IF / WHILE / CASE-WHEN
    predicate.  Pass criterion: 12 of 16 predicate shapes classified correctly.

    The classification matches DESIGN_v0_10_PredicateSeeding section 3.2.  See
    Expected-Output.md for the per-shape expected result.

.PARAMETER ScriptDomAssemblyPath
    Path to Microsoft.SqlServer.TransactSql.ScriptDom.dll.  If omitted, the
    script attempts to find it via well-known locations (SSMS, sqlpackage,
    dotnet tool install) and falls back to NuGet-installing it into a temp folder.

.EXAMPLE
    PS> .\Run-Spike.ps1

.EXAMPLE
    PS> .\Run-Spike.ps1 -ScriptDomAssemblyPath "C:\path\to\Microsoft.SqlServer.TransactSql.ScriptDom.dll"

.NOTES
    Runs on Windows PowerShell 5.1 or PowerShell 7+.  Requires .NET Framework 4.7.2+
    or .NET 6+ and the ScriptDom DLL.
#>
[CmdletBinding()]
param(
    [string]$ScriptDomAssemblyPath
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# 1.  Locate (or fetch) the ScriptDom assembly.
# ---------------------------------------------------------------------------
function Find-ScriptDom {
    $candidates = @(
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio*\Common7\IDE\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*\Common7\IDE\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\dotnet\sdk\*\Sdks\Microsoft.Build.Sql\tools\net6.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:USERPROFILE}\.nuget\packages\microsoft.sqlserver.transactsql.scriptdom\*\lib\net462\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:USERPROFILE}\.nuget\packages\microsoft.sqlserver.transactsql.scriptdom\*\lib\netstandard2.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll"
    )
    foreach ($pattern in $candidates) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-ScriptDomToTemp {
    Write-Host "ScriptDom not found in standard locations.  Installing via NuGet to TEMP..."
    $tmp = Join-Path $env:TEMP "uag-spike-scriptdom"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $nupkg = Join-Path $tmp "scriptdom.nupkg"
    $url = "https://www.nuget.org/api/v2/package/Microsoft.SqlServer.TransactSql.ScriptDom/161.9135.0"
    Invoke-WebRequest -Uri $url -OutFile $nupkg
    $extractDir = Join-Path $tmp "extracted"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extractDir)
    $dll = Get-ChildItem -Path "$extractDir\lib\net462\Microsoft.SqlServer.TransactSql.ScriptDom.dll" -ErrorAction SilentlyContinue
    if (-not $dll) {
        $dll = Get-ChildItem -Path "$extractDir\lib\netstandard2.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll" -ErrorAction SilentlyContinue
    }
    if (-not $dll) { throw "ScriptDom DLL not found in extracted NuGet package." }
    return $dll.FullName
}

if (-not $ScriptDomAssemblyPath) {
    $ScriptDomAssemblyPath = Find-ScriptDom
    if (-not $ScriptDomAssemblyPath) {
        $ScriptDomAssemblyPath = Install-ScriptDomToTemp
    }
}

Write-Host "Using ScriptDom: $ScriptDomAssemblyPath"
Add-Type -Path $ScriptDomAssemblyPath

# ---------------------------------------------------------------------------
# 2.  Parse the test procedure into a TSqlFragment AST.
# ---------------------------------------------------------------------------
$procFile = Join-Path $here "TestProcedure.sql"
if (-not (Test-Path $procFile)) { throw "TestProcedure.sql not found in $here" }
$procText = Get-Content -Raw -Path $procFile

$parser = New-Object Microsoft.SqlServer.TransactSql.ScriptDom.TSql160Parser($true)
$reader = New-Object System.IO.StringReader($procText)
$errors = $null
$fragment = $parser.Parse($reader, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    Write-Warning "Parser reported $($errors.Count) error(s):"
    $errors | ForEach-Object { Write-Warning "  Line $($_.Line): $($_.Message)" }
}

# ---------------------------------------------------------------------------
# 3.  Visit IfStatement / WhileStatement / SearchedCaseExpression, extract
#     the predicate for each, and classify into one of the 16 ParsedPredicate
#     shapes.
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$branchId = 0

function Get-FragmentText {
    param($fragment)
    if (-not $fragment) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = $fragment.FirstTokenIndex; $i -le $fragment.LastTokenIndex; $i++) {
        [void]$sb.Append($fragment.ScriptTokenStream[$i].Text)
    }
    return $sb.ToString().Trim()
}

function Get-AggregateInfo {
    param($scalarExpr)
    # Returns @{ Aggregate; Column; SubqueryText; Tables[] } if scalarExpr is a
    # ScalarSubquery wrapping a single-row aggregate.  Otherwise $null.
    if ($scalarExpr -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ScalarSubquery]) { return $null }
    $qe = $scalarExpr.QueryExpression
    if ($qe -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.QuerySpecification]) { return $null }
    if ($qe.SelectElements.Count -ne 1) { return $null }
    $sel = $qe.SelectElements[0]
    if ($sel -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.SelectScalarExpression]) { return $null }
    $inner = $sel.Expression
    if ($inner -is [Microsoft.SqlServer.TransactSql.ScriptDom.FunctionCall]) {
        $aggName = $inner.FunctionName.Value.ToUpperInvariant()
        if ($aggName -in @('COUNT','SUM','MIN','MAX','AVG')) {
            $tables = @()
            if ($qe.FromClause) {
                foreach ($tr in $qe.FromClause.TableReferences) {
                    $tables += Get-FragmentText -fragment $tr
                }
            }
            return @{
                Aggregate    = $aggName
                ColumnText   = Get-FragmentText -fragment $inner
                SubqueryText = Get-FragmentText -fragment $qe
                Tables       = $tables
            }
        }
    }
    # Scalar lookup: SELECT <col> FROM ... -- non-aggregate scalar subquery
    if ($inner -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression]) {
        $tables = @()
        if ($qe.FromClause) {
            foreach ($tr in $qe.FromClause.TableReferences) {
                $tables += Get-FragmentText -fragment $tr
            }
        }
        return @{
            Aggregate    = 'SCALAR'
            ColumnText   = Get-FragmentText -fragment $inner
            SubqueryText = Get-FragmentText -fragment $qe
            Tables       = $tables
        }
    }
    return $null
}

function Classify-Predicate {
    param($predicate, $branchId, $context)

    $row = [ordered]@{
        BranchId      = $branchId
        Context       = $context
        Shape         = 'UNRECOGNISED'
        Aggregate     = $null
        Comparator    = $null
        Comparand     = $null
        Tables        = ''
        PredicateText = Get-FragmentText -fragment $predicate
    }

    # EXISTS / NOT EXISTS
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExistsPredicate]) {
        $negated = $false
    } elseif ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanNotExpression] -and
              $predicate.Expression -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExistsPredicate]) {
        $negated = $true
        $predicate = $predicate.Expression
    } else {
        $negated = $null
    }

    if ($null -ne $negated) {
        $row.Shape = if ($negated) { 'NOT_EXISTS' } else { 'EXISTS' }
        $qe = $predicate.Subquery.QueryExpression
        if ($qe -is [Microsoft.SqlServer.TransactSql.ScriptDom.QuerySpecification] -and $qe.FromClause) {
            $tables = @()
            foreach ($tr in $qe.FromClause.TableReferences) {
                $tables += Get-FragmentText -fragment $tr
            }
            $row.Tables = ($tables -join ' | ')
        }
        return [pscustomobject]$row
    }

    # BooleanComparisonExpression: lhs <op> rhs
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression]) {
        $cmp = $predicate.ComparisonType.ToString()
        $info = Get-AggregateInfo -scalarExpr $predicate.FirstExpression
        if (-not $info) { $info = Get-AggregateInfo -scalarExpr $predicate.SecondExpression }
        if ($info) {
            $row.Aggregate  = $info.Aggregate
            $row.Comparator = $cmp
            $row.Comparand  = Get-FragmentText -fragment $predicate.SecondExpression
            $row.Tables     = ($info.Tables -join ' | ')
            $row.Shape = switch ($info.Aggregate) {
                'COUNT'  { 'COUNT_CMP' ; break }
                'SUM'    { 'SUM_CMP'   ; break }
                'MIN'    { 'MIN_CMP'   ; break }
                'MAX'    { 'MAX_CMP'   ; break }
                'AVG'    { 'AVG_CMP'   ; break }
                'SCALAR' { 'SCALAR_CMP'; break }
                default  { 'UNRECOGNISED' }
            }
        }
        return [pscustomobject]$row
    }

    # IN list
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.InPredicate]) {
        $info = Get-AggregateInfo -scalarExpr $predicate.Expression
        if ($info -and $info.Aggregate -eq 'COUNT') {
            $row.Shape      = 'COUNT_IN'
            $row.Aggregate  = 'COUNT'
            $row.Comparator = if ($predicate.NotDefined) { 'NOT_IN' } else { 'IN' }
            $row.Comparand  = ($predicate.Values | ForEach-Object { Get-FragmentText -fragment $_ }) -join ', '
            $row.Tables     = ($info.Tables -join ' | ')
        }
        return [pscustomobject]$row
    }

    # BETWEEN
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanTernaryExpression] -and
        $predicate.TernaryExpressionType.ToString().StartsWith('Between')) {
        $info = Get-AggregateInfo -scalarExpr $predicate.FirstExpression
        if ($info -and $info.Aggregate -eq 'COUNT') {
            $row.Shape      = 'COUNT_BETWEEN'
            $row.Aggregate  = 'COUNT'
            $row.Comparator = $predicate.TernaryExpressionType.ToString()
            $row.Comparand  = "$(Get-FragmentText -fragment $predicate.SecondExpression) AND $(Get-FragmentText -fragment $predicate.ThirdExpression)"
            $row.Tables     = ($info.Tables -join ' | ')
        }
        return [pscustomobject]$row
    }

    # IS NULL / IS NOT NULL
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanIsNullExpression]) {
        $info = Get-AggregateInfo -scalarExpr $predicate.Expression
        if ($info -and $info.Aggregate -eq 'SCALAR') {
            $row.Shape      = 'SCALAR_NULL'
            $row.Aggregate  = 'SCALAR'
            $row.Comparator = if ($predicate.IsNot) { 'IS_NOT_NULL' } else { 'IS_NULL' }
            $row.Tables     = ($info.Tables -join ' | ')
        }
        return [pscustomobject]$row
    }

    return [pscustomobject]$row
}

# Walk: simple recursive descent.  We don't need a full TSqlFragmentVisitor for
# the spike -- recursive property walk is enough.
function Visit-Fragment {
    param($node, $context)

    if ($null -eq $node) { return }

    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.IfStatement]) {
        $script:branchId++
        $row = Classify-Predicate -predicate $node.Predicate -branchId $script:branchId -context 'IF'
        $script:results.Add($row)
        Visit-Fragment -node $node.ThenStatement -context 'IF.Then'
        Visit-Fragment -node $node.ElseStatement -context 'IF.Else'
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.WhileStatement]) {
        $script:branchId++
        $row = Classify-Predicate -predicate $node.Predicate -branchId $script:branchId -context 'WHILE'
        $script:results.Add($row)
        Visit-Fragment -node $node.Statement -context 'WHILE.Body'
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.SearchedCaseExpression]) {
        foreach ($wc in $node.WhenClauses) {
            $script:branchId++
            $row = Classify-Predicate -predicate $wc.WhenExpression -branchId $script:branchId -context 'CASE.WHEN'
            $script:results.Add($row)
        }
        return
    }

    # Recurse over children via reflection on public properties.
    foreach ($prop in $node.GetType().GetProperties()) {
        if ($prop.Name -in @('ScriptTokenStream','StartOffset','FragmentLength','StartLine','StartColumn','FirstTokenIndex','LastTokenIndex')) { continue }
        try {
            $val = $prop.GetValue($node)
        } catch { continue }
        if ($null -eq $val) { continue }
        if ($val -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
            Visit-Fragment -node $val -context $context
        } elseif ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            foreach ($child in $val) {
                if ($child -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
                    Visit-Fragment -node $child -context $context
                }
            }
        }
    }
}

Visit-Fragment -node $fragment -context 'root'

# ---------------------------------------------------------------------------
# 4.  Report.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== ParsedPredicate rows ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize BranchId, Context, Shape, Aggregate, Comparator, Comparand, Tables

Write-Host ""
Write-Host "=== Shape coverage ===" -ForegroundColor Cyan
$shapes = $results | Group-Object Shape | Sort-Object Count -Descending
$shapes | Format-Table -AutoSize Count, Name

$expectedShapes = @(
    'EXISTS', 'NOT_EXISTS',
    'COUNT_CMP', 'COUNT_IN', 'COUNT_BETWEEN',
    'SUM_CMP', 'MIN_CMP', 'MAX_CMP', 'AVG_CMP',
    'SCALAR_CMP', 'SCALAR_NULL'
)
$found = ($results.Shape | Select-Object -Unique) | Where-Object { $_ -in $expectedShapes }
$total = $expectedShapes.Count
$ratio = $found.Count / $total

Write-Host ""
Write-Host "=== Verdict ===" -ForegroundColor Cyan
Write-Host "Distinct shapes correctly classified: $($found.Count) of $total"
Write-Host "Total predicate rows extracted:        $($results.Count) (expected ~17 -- 14 IFs + 2 CASE arms + 1 WHILE)"
Write-Host "UNRECOGNISED rows:                     $(($results | Where-Object Shape -eq 'UNRECOGNISED').Count)"

if ($found.Count -ge 9) {
    Write-Host ""
    Write-Host "PASS: ScriptDom is feasible for v0.10.  Proceed with Option B (DECISION_v0_10_Parser_Choice.md)." -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "FAIL: ScriptDom exposed only $($found.Count) of $total target shapes.  Reopen DECISION_v0_10_Parser_Choice.md and consider Option A (hand-roll, +1.5 weeks)." -ForegroundColor Red
    exit 1
}
