<#
.SYNOPSIS
    v0.10 predicate parser. Walks the ScriptDom AST of one or more procedures
    and writes a TestGen.PredicateInbox row per IF / WHILE / CASE-WHEN gate.

.DESCRIPTION
    Production promotion of design/spike/Run-Spike.ps1. For each branch gate it
    classifies the predicate into the closed shape vocabulary agreed in
    DESIGN_v0_10_PredicateSeeding (EXISTS, NOT_EXISTS, COUNT_CMP, COUNT_IN,
    COUNT_BETWEEN, SUM/MIN/MAX/AVG_CMP, SCALAR_CMP, SCALAR_NULL) and extracts the
    target table(s), the WHERE conjuncts, comparator and comparand.

    Predicates outside the seedable grammar (OR composition, column-to-column
    WHERE, multi-table FROM, function calls in the predicate, etc.) are emitted
    with Shape = UNRECOGNISED and a reason; the T-SQL test generator turns those
    into NOT_TESTABLE placeholder tests (design sec 4.2).

    Rows are written by calling TestGen.AddParsedPredicate so the DB-side
    validation/normalisation runs. Use -WhatIf to print rows without writing.

.PARAMETER ServerInstance
    SQL Server instance, e.g. 'localhost\MSSQL17' or '(local)'.

.PARAMETER Database
    Database containing the procedures.

.PARAMETER Schema
    Schema of the target procedure(s). Default 'dbo'.

.PARAMETER ProcName
    A single procedure name to parse. Omit to parse every procedure in -Schema.

.PARAMETER ProcText
    Offline mode: parse this T-SQL text instead of reading from a database.
    No rows are written (implies -WhatIf). Used by the spike / unit tests.

.PARAMETER RunId
    GUID stamped on every row of this pass. A fresh GUID is generated if omitted.

.PARAMETER Clear
    Clear existing PredicateInbox rows for the target proc(s) before writing.

.PARAMETER WhatIf
    Emit ParsedPredicate objects to the pipeline; do not write to the database.

.PARAMETER ScriptDomAssemblyPath
    Explicit path to Microsoft.SqlServer.TransactSql.ScriptDom.dll. Auto-located
    (and NuGet-fetched to TEMP as a last resort) when omitted.

.PARAMETER ParserVersion
    TSql parser version (default 160 -> TSql160Parser).

.EXAMPLE
    PS> .\Get-ParsedPredicates.ps1 -ServerInstance '(local)' -Database AdventureWorks2025 -Schema dbo -ProcName uspV9ValidationTest

.EXAMPLE
    PS> .\Get-ParsedPredicates.ps1 -ProcText (Get-Content -Raw proc.sql) -WhatIf | Format-Table

.NOTES
    Windows PowerShell 5.1 or PowerShell 7+. Source is ASCII-only; save as
    UTF-8-with-BOM + CRLF (see feedback: PS5 reads BOM-less files as Win-1252).
#>
[CmdletBinding(DefaultParameterSetName = 'Db')]
param(
    [Parameter(ParameterSetName = 'Db', Mandatory = $true)]  [string]$ServerInstance,
    [Parameter(ParameterSetName = 'Db', Mandatory = $true)]  [string]$Database,
    [Parameter(ParameterSetName = 'Db')]                     [string]$Schema = 'dbo',
    [Parameter(ParameterSetName = 'Db')]                     [string]$ProcName,
    [Parameter(ParameterSetName = 'Db')]                     [string]$SqlUser,
    [Parameter(ParameterSetName = 'Db')]                     [string]$SqlPassword,
    [Parameter(ParameterSetName = 'Text', Mandatory = $true)][string]$ProcText,
    [Parameter(ParameterSetName = 'Text')]                   [string]$TextProcName = 'AdHocProc',
    [Parameter(ParameterSetName = 'Text')]                   [string]$TextSchema = 'dbo',
    [guid]$RunId = [guid]::NewGuid(),
    [switch]$Clear,
    [switch]$WhatIf,
    [string]$ScriptDomAssemblyPath,
    [int]$ParserVersion = 160
)

$ErrorActionPreference = 'Stop'
$ParserSignature = 'Get-ParsedPredicates/0.10.0'

# Pre-initialise script-scoped state so the parser is safe under a caller's
# Set-StrictMode (e.g. when invoked with & from the Invoke-UnitAutogen module,
# where reading a not-yet-set $script: variable would otherwise throw).
$script:ResolvedParserType = $null
$script:uagLocalDefs       = @{}
$script:uagLocalCond       = @{}
$script:uagPropCache       = @{}
$script:rows               = $null
$script:branchId           = 0

# ===========================================================================
# 1. Locate (or fetch) the ScriptDom assembly.  (Same strategy as the spike.)
# ===========================================================================
function Find-ScriptDom {
    # The SqlServer PowerShell module ships ScriptDom (net462 at root, coreclr
    # for PS7) - this is the most reliable source on a dev box, so probe it
    # first. $PSHOME-style and Program Files module dirs are checked too.
    $isCore = $PSVersionTable.PSEdition -eq 'Core'
    $candidates = @(
        "${env:USERPROFILE}\Documents\WindowsPowerShell\Modules\SqlServer\*\$(if($isCore){'coreclr\'})Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:USERPROFILE}\Documents\PowerShell\Modules\SqlServer\*\$(if($isCore){'coreclr\'})Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\WindowsPowerShell\Modules\SqlServer\*\$(if($isCore){'coreclr\'})Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\PowerShell\Modules\SqlServer\*\$(if($isCore){'coreclr\'})Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio*\Common7\IDE\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio*\Common7\IDE\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\Microsoft SQL Server\*\DAC\bin\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:ProgramFiles}\dotnet\sdk\*\Sdks\Microsoft.Build.Sql\tools\net6.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:USERPROFILE}\.nuget\packages\microsoft.sqlserver.transactsql.scriptdom\*\lib\net462\Microsoft.SqlServer.TransactSql.ScriptDom.dll",
        "${env:USERPROFILE}\.nuget\packages\microsoft.sqlserver.transactsql.scriptdom\*\lib\netstandard2.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll"
    )
    # "Latest, not just available": gather ALL matches and return the one with
    # the HIGHEST file version. An older ScriptDom lacks the newer TSqlNNNParser
    # classes and would under-parse current-SQL syntax, so version wins over
    # probe order.
    $all = @()
    foreach ($pattern in $candidates) {
        $all += Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
    }
    if (-not $all) { return $null }
    $best = $all |
        Sort-Object @{ Expression = { [version]([System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion) } } -Descending |
        Select-Object -First 1
    return $best.FullName
}

function Install-ScriptDomToTemp {
    Write-Verbose "ScriptDom not found locally. Fetching via NuGet to TEMP..."
    $tmp = Join-Path $env:TEMP "uag-scriptdom"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $nupkg = Join-Path $tmp "scriptdom.nupkg"
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.SqlServer.TransactSql.ScriptDom/161.9135.0" -OutFile $nupkg
    $extractDir = Join-Path $tmp "extracted"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extractDir)
    $dll = Get-ChildItem -Path "$extractDir\lib\net462\Microsoft.SqlServer.TransactSql.ScriptDom.dll" -ErrorAction SilentlyContinue
    if (-not $dll) { $dll = Get-ChildItem -Path "$extractDir\lib\netstandard2.0\Microsoft.SqlServer.TransactSql.ScriptDom.dll" -ErrorAction SilentlyContinue }
    if (-not $dll) { throw "ScriptDom DLL not found in extracted NuGet package." }
    return $dll.FullName
}

if (-not $ScriptDomAssemblyPath) {
    $ScriptDomAssemblyPath = Find-ScriptDom
    if (-not $ScriptDomAssemblyPath) { $ScriptDomAssemblyPath = Install-ScriptDomToTemp }
}
Write-Verbose "Using ScriptDom: $ScriptDomAssemblyPath"
Add-Type -Path $ScriptDomAssemblyPath

$sd = 'Microsoft.SqlServer.TransactSql.ScriptDom'

# ===========================================================================
# 2. AST helpers.
# ===========================================================================
$script:uagPropCache = @{}
function Get-FragmentChildProps {
    # The subset of a node's properties that can hold child fragments (a fragment,
    # or a collection of them), cached per CLR type. Skips value-type / string /
    # token-stream properties so the generic AST walks don't GetValue() them.
    param($node)
    $t = $node.GetType()
    $p = $script:uagPropCache[$t]
    if ($null -ne $p) { return $p }
    $fragT = [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]
    $enT   = [System.Collections.IEnumerable]
    $strT  = [string]
    $p = @($t.GetProperties() | Where-Object {
        $_.Name -ne 'ScriptTokenStream' -and (
            $fragT.IsAssignableFrom($_.PropertyType) -or
            ($enT.IsAssignableFrom($_.PropertyType) -and $_.PropertyType -ne $strT)
        )
    })
    $script:uagPropCache[$t] = $p
    return $p
}

function Get-FragmentText {
    param($fragment)
    if (-not $fragment) { return '' }
    $ts = $fragment.ScriptTokenStream    # cache the getter (re-reading it per token is costly)
    if (-not $ts) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = $fragment.FirstTokenIndex; $i -le $fragment.LastTokenIndex; $i++) {
        [void]$sb.Append($ts[$i].Text)
    }
    return $sb.ToString().Trim()
}

function Get-LiteralText {
    # Return a T-SQL literal for a scalar expression, or $null if it is not a
    # plain literal (parameter, variable, column, function, expression...).
    param($expr)
    while ($expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.ParenthesisExpression]) { $expr = $expr.Expression }
    if ($expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.StringLiteral]) {
        return "N'" + ($expr.Value -replace "'", "''") + "'"
    }
    if ($expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.IntegerLiteral] -or
        $expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.NumericLiteral] -or
        $expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.RealLiteral] -or
        $expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.MoneyLiteral]) {
        return $expr.Value
    }
    if ($expr -is [Microsoft.SqlServer.TransactSql.ScriptDom.UnaryExpression] -and
        $expr.Expression -is [Microsoft.SqlServer.TransactSql.ScriptDom.Literal]) {
        $sign = if ($expr.UnaryExpressionType.ToString() -eq 'Negative') { '-' } else { '' }
        return $sign + $expr.Expression.Value
    }
    return $null
}

function Get-TableRefInfo {
    # Single NamedTableReference -> @{schema; table; alias; raw}. $null otherwise
    # (join, derived table, TVF, etc. -> caller marks UNRECOGNISED).
    param($tableRef)
    if ($tableRef -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.NamedTableReference]) { return $null }
    $ident = $tableRef.SchemaObject
    $parts = @($ident.Identifiers | ForEach-Object { $_.Value })
    $tbl = $parts[$parts.Count - 1]
    # An unqualified table (FROM Orders) defaults to the dbo schema so the seeder
    # / renderer produce [dbo].[Orders], not a broken .[Orders].
    $sch = if ($parts.Count -ge 2) { $parts[$parts.Count - 2] } else { 'dbo' }
    $alias = $null
    if ($tableRef.Alias) { $alias = $tableRef.Alias.Value }
    return @{ schema = $sch; table = $tbl; alias = $alias; raw = (Get-FragmentText -fragment $tableRef) }
}

function Get-JoinEqualities {
    # Decompose an ON SearchCondition into AND-composed <colref> = <colref>
    # equalities. Returns @{ ok; reason; eqs=@(@{lAlias;lCol;rAlias;rCol}) }.
    param($boolExpr)
    $out = @{ ok = $true; reason = $null; eqs = @() }
    if (-not $boolExpr) { $out.ok = $false; $out.reason = 'join has no ON condition'; return $out }
    $stack = New-Object System.Collections.Stack
    $stack.Push($boolExpr)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanParenthesisExpression]) { $stack.Push($n.Expression); continue }
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanBinaryExpression]) {
            if ($n.BinaryExpressionType.ToString() -eq 'And') { $stack.Push($n.FirstExpression); $stack.Push($n.SecondExpression); continue }
            $out.ok = $false; $out.reason = 'join ON uses OR composition'; return $out
        }
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression] -and
            $n.ComparisonType.ToString() -eq 'Equals') {
            $l = $n.FirstExpression; $r = $n.SecondExpression
            if ($l -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression] -and
                $r -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression]) {
                $li = $l.MultiPartIdentifier.Identifiers; $ri = $r.MultiPartIdentifier.Identifiers
                $lAlias = $null; if ($li.Count -ge 2) { $lAlias = $li[$li.Count - 2].Value }
                $rAlias = $null; if ($ri.Count -ge 2) { $rAlias = $ri[$ri.Count - 2].Value }
                $out.eqs += ,@{ lAlias = $lAlias; lCol = $li[$li.Count - 1].Value
                                rAlias = $rAlias; rCol = $ri[$ri.Count - 1].Value }
                continue
            }
            $out.ok = $false; $out.reason = 'join ON is not column = column'; return $out
        }
        $out.ok = $false; $out.reason = 'join ON is not an equality (or AND of equalities)'; return $out
    }
    return $out
}

function Collect-JoinTables {
    # Recursively walk a TableReference. Returns
    # @{ ok; reason; tables=@(infos); joins=@(eqs) } using plain arrays
    # (PS 5.1 throws on @() around a generic List, so avoid List here).
    param($ref)
    if ($ref -is [Microsoft.SqlServer.TransactSql.ScriptDom.NamedTableReference]) {
        $info = Get-TableRefInfo -tableRef $ref
        if (-not $info) { return @{ ok = $false; reason = 'FROM table is not a plain named table'; tables = @(); joins = @() } }
        return @{ ok = $true; reason = $null; tables = @($info); joins = @() }
    }
    if ($ref -is [Microsoft.SqlServer.TransactSql.ScriptDom.QualifiedJoin]) {
        if ($ref.QualifiedJoinType.ToString() -ne 'Inner') { return @{ ok = $false; reason = 'only INNER joins are seedable in this cut'; tables = @(); joins = @() } }
        $a = Collect-JoinTables -ref $ref.FirstTableReference;  if (-not $a.ok) { return $a }
        $b = Collect-JoinTables -ref $ref.SecondTableReference; if (-not $b.ok) { return $b }
        $eq = Get-JoinEqualities -boolExpr $ref.SearchCondition; if (-not $eq.ok) { return @{ ok = $false; reason = $eq.reason; tables = @(); joins = @() } }
        return @{ ok = $true; reason = $null; tables = @(@($a.tables) + @($b.tables)); joins = @(@($a.joins) + @($b.joins) + @($eq.eqs)) }
    }
    return @{ ok = $false; reason = 'FROM is a derived table / TVF / APPLY (not a plain table or inner join)'; tables = @(); joins = @() }
}

function Get-FromTables {
    # Returns @{ tables=@(infos); joins=@(eqs); ok; reason }. Single named table
    # -> joins empty. INNER equi-join(s) -> tables + ON equality keys captured
    # (v0.11 join seeding). Anything else (outer/non-equi/derived/TVF) -> ok=$false.
    param($querySpec)
    $result = @{ tables = @(); joins = @(); ok = $true; reason = $null }
    if (-not $querySpec.FromClause) { $result.ok = $false; $result.reason = 'subquery has no FROM clause'; return $result }
    $refs = @($querySpec.FromClause.TableReferences)
    if ($refs.Count -ne 1) { $result.ok = $false; $result.reason = 'comma-separated FROM (old-style join) not supported'; return $result }
    $cj = Collect-JoinTables -ref $refs[0]
    if (-not $cj.ok) { $result.ok = $false; $result.reason = $cj.reason; return $result }
    $result.tables = @($cj.tables); $result.joins = @($cj.joins)
    return $result
}

function Get-WhereLeaf {
    # One comparison leaf -> @{ ok; reason; conj=@{col;op;val;valKind;tbl} }.
    # Supported: <ColumnRef> <comparison-op> <literal|@param> (either side).
    param($n)
    if ($n -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression]) {
        return @{ ok = $false; reason = 'WHERE contains an unsupported predicate construct (only column op literal/@param comparisons, AND/OR composed)' }
    }
    $opMap = @{ Equals='='; NotEqualToBrackets='<>'; NotEqualToExclamation='<>';
               LessThan='<'; GreaterThan='>'; LessThanOrEqualTo='<='; GreaterThanOrEqualTo='>=' }
    $opName = $n.ComparisonType.ToString()
    if (-not $opMap.ContainsKey($opName)) { return @{ ok = $false; reason = "WHERE comparator $opName not supported" } }
    $col = $null; $val = $null; $valKind = $null; $colTbl = $null
    foreach ($side in @($n.FirstExpression, $n.SecondExpression)) {
        if ($side -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression]) {
            $cids = $side.MultiPartIdentifier.Identifiers
            $col = $cids[$cids.Count - 1].Value
            if ($cids.Count -ge 2) { $colTbl = $cids[$cids.Count - 2].Value }
        } elseif ($side -is [Microsoft.SqlServer.TransactSql.ScriptDom.VariableReference]) {
            $val = $side.Name; $valKind = 'param'   # col = @param: seed in reverse from the test arg
        } else {
            $maybe = Get-LiteralText -expr $side
            if ($null -ne $maybe) { $val = $maybe; $valKind = 'literal' }
        }
    }
    if ($null -eq $col -or $null -eq $val) {
        return @{ ok = $false; reason = 'WHERE conjunct is not <column> <op> <literal|@param> (column-to-column or expression)' }
    }
    return @{ ok = $true; reason = $null; conj = @{ col = $col; op = $opMap[$opName]; val = $val; valKind = $valKind; tbl = $colTbl } }
}

function Get-WhereDnf {
    # Decompose a WHERE BooleanExpression into DISJUNCTIVE NORMAL FORM:
    # @{ ok; reason; terms=@( @(conj,...), ... ) } where the WHERE is satisfied
    # iff ANY term holds, and a term is satisfied iff ALL its conjuncts hold.
    # AND-only WHERE -> a single term; OR -> multiple terms; AND distributes over
    # OR (cross product). Caps at 16 terms to avoid blow-up on pathological input.
    param($boolExpr)
    if (-not $boolExpr) { return @{ ok = $true; reason = $null; terms = @() } }   # no WHERE
    $n = $boolExpr
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanParenthesisExpression]) {
        return (Get-WhereDnf -boolExpr $n.Expression)
    }
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanBinaryExpression]) {
        $bt = $n.BinaryExpressionType.ToString()
        $L = Get-WhereDnf -boolExpr $n.FirstExpression;  if (-not $L.ok) { return $L }
        $R = Get-WhereDnf -boolExpr $n.SecondExpression; if (-not $R.ok) { return $R }
        $terms = @()
        if ($bt -eq 'Or') {
            $terms = @($L.terms) + @($R.terms)
        } elseif ($bt -eq 'And') {
            if     ($L.terms.Count -eq 0) { $terms = @($R.terms) }
            elseif ($R.terms.Count -eq 0) { $terms = @($L.terms) }
            else {
                foreach ($lt in $L.terms) { foreach ($rt in $R.terms) { $terms += ,(@($lt) + @($rt)) } }
            }
        } else {
            return @{ ok = $false; reason = "WHERE uses unsupported boolean operator $bt" }
        }
        if ($terms.Count -gt 16) { return @{ ok = $false; reason = 'WHERE expands to too many DNF terms (>16)' } }
        return @{ ok = $true; reason = $null; terms = $terms }
    }
    $leaf = Get-WhereLeaf -n $n
    if (-not $leaf.ok) { return @{ ok = $false; reason = $leaf.reason } }
    return @{ ok = $true; reason = $null; terms = @(,@($leaf.conj)) }
}

function Get-AggregateInfo {
    # ScalarSubquery wrapping a single aggregate or a single column.
    param($scalarExpr)
    # Unwrap parentheses ( (SELECT ...) ) so an inlined local or hand-parenthesised
    # subquery still classifies.
    while ($scalarExpr -is [Microsoft.SqlServer.TransactSql.ScriptDom.ParenthesisExpression]) { $scalarExpr = $scalarExpr.Expression }
    if ($scalarExpr -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.ScalarSubquery]) { return $null }
    $qe = $scalarExpr.QueryExpression
    if ($qe -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.QuerySpecification]) { return $null }
    if ($qe.SelectElements.Count -ne 1) { return $null }
    $sel = $qe.SelectElements[0]
    if ($sel -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.SelectScalarExpression]) { return $null }
    $inner = $sel.Expression
    $info = @{ Aggregate=$null; ColumnText=$null; QuerySpec=$qe }
    if ($inner -is [Microsoft.SqlServer.TransactSql.ScriptDom.FunctionCall]) {
        $aggName = $inner.FunctionName.Value.ToUpperInvariant()
        if ($aggName -in @('COUNT','SUM','MIN','MAX','AVG')) {
            $info.Aggregate = $aggName; $info.ColumnText = (Get-FragmentText -fragment $inner); return $info
        }
        return $null
    }
    if ($inner -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression]) {
        $info.Aggregate = 'SCALAR'; $info.ColumnText = (Get-FragmentText -fragment $inner); return $info
    }
    return $null
}

# ===========================================================================
# 2b. v0.12 unified engine: build a predicate TREE + render it to SQL.
#     (design/DESIGN_v0_12_UnifiedReverseSeeder.md). Boolean nodes (and/or/not)
#     over data-shape ATOMS; each atom reads a QUERY (tables + general joins +
#     a boolean WHERE tree of column predicates). Truth-propagation / seed
#     plans are added in section 2c.
# ===========================================================================
$script:ScriptDomNS = 'Microsoft.SqlServer.TransactSql.ScriptDom'

function Quote-Ident { param($x) if ($null -eq $x) { return $null } return '[' + ($x -replace '\]', ']]') + ']' }

function Eval-LitCompare {
    # Evaluate <literal> <op> <literal> -> $true/$false (for folded constant
    # sub-predicates produced by inlining a local's branch values).
    param($l, $opName, $r)
    $lv = 0.0; $rv = 0.0
    if ([double]::TryParse($l, [ref]$lv) -and [double]::TryParse($r, [ref]$rv)) {
        switch ($opName) {
            'Equals'                 { return ($lv -eq $rv) }
            'NotEqualToBrackets'     { return ($lv -ne $rv) }
            'NotEqualToExclamation'  { return ($lv -ne $rv) }
            'LessThan'               { return ($lv -lt $rv) }
            'GreaterThan'            { return ($lv -gt $rv) }
            'LessThanOrEqualTo'      { return ($lv -le $rv) }
            'GreaterThanOrEqualTo'   { return ($lv -ge $rv) }
        }
    }
    $ls = (($l -replace "^N?'", '') -replace "'$", '')
    $rs = (($r -replace "^N?'", '') -replace "'$", '')
    switch ($opName) {
        'Equals'                { return ($ls -ceq $rs) }
        'NotEqualToBrackets'    { return ($ls -cne $rs) }
        'NotEqualToExclamation' { return ($ls -cne $rs) }
    }
    return $false
}

function Get-JoinPredicates {
    # ON -> AND-composed <colref> <cmp-op> <colref> predicates (equi or non-equi).
    param($onExpr)
    $out = @{ ok = $true; reason = $null; preds = @() }
    if (-not $onExpr) { return @{ ok = $false; reason = 'join has no ON condition'; preds = @() } }
    $opMap = @{ Equals='='; NotEqualToBrackets='<>'; NotEqualToExclamation='<>';
               LessThan='<'; GreaterThan='>'; LessThanOrEqualTo='<='; GreaterThanOrEqualTo='>=' }
    $stack = New-Object System.Collections.Stack
    $stack.Push($onExpr)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanParenthesisExpression]) { $stack.Push($n.Expression); continue }
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanBinaryExpression]) {
            if ($n.BinaryExpressionType.ToString() -eq 'And') { $stack.Push($n.FirstExpression); $stack.Push($n.SecondExpression); continue }
            return @{ ok = $false; reason = 'join ON uses OR composition'; preds = @() }
        }
        if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression]) {
            $op = $opMap[$n.ComparisonType.ToString()]
            if (-not $op) { return @{ ok = $false; reason = 'join ON has an unsupported comparator'; preds = @() } }
            $l = $n.FirstExpression; $r = $n.SecondExpression
            if ($l -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression] -and
                $r -is [Microsoft.SqlServer.TransactSql.ScriptDom.ColumnReferenceExpression]) {
                $li = $l.MultiPartIdentifier.Identifiers; $ri = $r.MultiPartIdentifier.Identifiers
                $la = $null; if ($li.Count -ge 2) { $la = $li[$li.Count - 2].Value }
                $ra = $null; if ($ri.Count -ge 2) { $ra = $ri[$ri.Count - 2].Value }
                $out.preds += ,@{ lAlias = $la; lCol = $li[$li.Count - 1].Value; op = $op
                                  rAlias = $ra; rCol = $ri[$ri.Count - 1].Value }
                continue
            }
            return @{ ok = $false; reason = 'join ON is not column <op> column'; preds = @() }
        }
        return @{ ok = $false; reason = 'join ON is not a comparison (or AND of comparisons)'; preds = @() }
    }
    return $out
}

function Collect-JoinTree {
    # Left-deep join chain -> @{ ok; reason; tables=@(info); steps=@(@{type;addAlias;on=@(preds)}) }.
    param($ref)
    if ($ref -is [Microsoft.SqlServer.TransactSql.ScriptDom.NamedTableReference]) {
        $info = Get-TableRefInfo -tableRef $ref
        if (-not $info) { return @{ ok = $false; reason = 'FROM table is not a plain named table'; tables = @(); steps = @() } }
        return @{ ok = $true; reason = $null; tables = @($info); steps = @() }
    }
    if ($ref -is [Microsoft.SqlServer.TransactSql.ScriptDom.QualifiedJoin]) {
        $typeMap = @{ Inner='INNER'; LeftOuter='LEFT'; RightOuter='RIGHT'; FullOuter='FULL' }
        $type = $typeMap[$ref.QualifiedJoinType.ToString()]
        if (-not $type) { return @{ ok = $false; reason = "join type $($ref.QualifiedJoinType) not supported"; tables = @(); steps = @() } }
        $left  = Collect-JoinTree -ref $ref.FirstTableReference;  if (-not $left.ok)  { return $left }
        $right = Collect-JoinTree -ref $ref.SecondTableReference; if (-not $right.ok) { return $right }
        if ($right.tables.Count -ne 1 -or $right.steps.Count -gt 0) {
            return @{ ok = $false; reason = 'only left-deep join chains are supported (right-nested join)'; tables = @(); steps = @() }
        }
        $on = Get-JoinPredicates -onExpr $ref.SearchCondition; if (-not $on.ok) { return @{ ok = $false; reason = $on.reason; tables = @(); steps = @() } }
        $addAlias = if ($right.tables[0].alias) { $right.tables[0].alias } else { $right.tables[0].table }
        $step = @{ type = $type; addAlias = $addAlias; on = @($on.preds) }
        return @{ ok = $true; reason = $null; tables = @(@($left.tables) + @($right.tables)); steps = @(@($left.steps) + @($step)) }
    }
    return @{ ok = $false; reason = 'FROM is a derived table / TVF / APPLY (not a plain table or join)'; tables = @(); steps = @() }
}

function Build-WhereTree {
    # WHERE BooleanExpression -> tree of colpred leaves (and/or/not). $null = no WHERE.
    param($boolExpr)
    if (-not $boolExpr) { return @{ ok = $true; reason = $null; node = $null } }
    $n = $boolExpr
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanParenthesisExpression]) { return (Build-WhereTree -boolExpr $n.Expression) }
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanBinaryExpression]) {
        $bt = $n.BinaryExpressionType.ToString()
        $k = if ($bt -eq 'And') { 'and' } elseif ($bt -eq 'Or') { 'or' } else { $null }
        if (-not $k) { return @{ ok = $false; reason = "WHERE uses unsupported boolean operator $bt" } }
        $L = Build-WhereTree -boolExpr $n.FirstExpression;  if (-not $L.ok) { return $L }
        $R = Build-WhereTree -boolExpr $n.SecondExpression; if (-not $R.ok) { return $R }
        $items = @()
        foreach ($c in @($L.node, $R.node)) { if ($c) { if ($c.k -eq $k) { $items += $c.items } else { $items += $c } } }
        return @{ ok = $true; reason = $null; node = @{ k = $k; items = @($items) } }
    }
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanNotExpression]) {
        $i = Build-WhereTree -boolExpr $n.Expression; if (-not $i.ok) { return $i }
        return @{ ok = $true; reason = $null; node = @{ k = 'not'; item = $i.node } }
    }
    $leaf = Get-WhereLeaf -n $n
    if (-not $leaf.ok) { return @{ ok = $false; reason = $leaf.reason } }
    $c = $leaf.conj
    return @{ ok = $true; reason = $null; node = @{ k = 'colpred'; tbl = $c.tbl; col = $c.col; op = $c.op; val = $c.val; valKind = $c.valKind } }
}

function Build-QueryNode {
    param($querySpec)
    if (-not $querySpec.FromClause) { return @{ ok = $false; reason = 'subquery has no FROM clause' } }
    $refs = @($querySpec.FromClause.TableReferences)
    if ($refs.Count -ne 1) { return @{ ok = $false; reason = 'comma-separated FROM (old-style join) not supported' } }
    $cj = Collect-JoinTree -ref $refs[0]; if (-not $cj.ok) { return @{ ok = $false; reason = $cj.reason } }
    $whereExpr = if ($querySpec.WhereClause) { $querySpec.WhereClause.SearchCondition } else { $null }
    $wt = Build-WhereTree -boolExpr $whereExpr; if (-not $wt.ok) { return @{ ok = $false; reason = $wt.reason } }
    $tables = @($cj.tables | ForEach-Object { @{ schema = $_.schema; table = $_.table; alias = $_.alias } })
    $joins  = @($cj.steps  | ForEach-Object { @{ type = $_.type; addAlias = $_.addAlias; on = @($_.on) } })
    return @{ ok = $true; reason = $null; node = @{ k = 'query'; tables = $tables; joins = $joins; where = $wt.node } }
}

function Build-AtomNode {
    # One non-boolean data-shape predicate -> atom node.
    param($p)
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExistsPredicate]) {
        $qe = $p.Subquery.QueryExpression
        if ($qe -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.QuerySpecification]) { return @{ ok = $false; reason = 'EXISTS subquery is not a simple query spec' } }
        $q = Build-QueryNode -querySpec $qe; if (-not $q.ok) { return $q }
        return @{ ok = $true; node = @{ k = 'atom'; agg = 'EXISTS'; selectExpr = '1'; op = 'exists'; comparand = $null; source = $q.node } }
    }
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression]) {
        $opMap = @{ Equals='='; NotEqualToBrackets='<>'; NotEqualToExclamation='<>';
                   LessThan='<'; GreaterThan='>'; LessThanOrEqualTo='<='; GreaterThanOrEqualTo='>=' }
        $op = $opMap[$p.ComparisonType.ToString()]
        # Both sides literal -> a constant truth (from an inlined local branch value).
        $lLit = Get-LiteralText -expr $p.FirstExpression
        $rLit = Get-LiteralText -expr $p.SecondExpression
        if ($null -ne $lLit -and $null -ne $rLit) {
            return @{ ok = $true; node = @{ k = 'const'; val = (Eval-LitCompare -l $lLit -opName $p.ComparisonType.ToString() -r $rLit) } }
        }
        $info = Get-AggregateInfo -scalarExpr $p.FirstExpression;  $cmpExpr = $p.SecondExpression
        if (-not $info) { $info = Get-AggregateInfo -scalarExpr $p.SecondExpression; $cmpExpr = $p.FirstExpression }
        if (-not $info) { return @{ ok = $false; reason = 'comparison does not involve an aggregate/scalar subquery' } }
        if (-not $op)   { return @{ ok = $false; reason = 'unsupported comparison operator' } }
        $lit = Get-LiteralText -expr $cmpExpr
        if ($null -eq $lit) {
            if ($cmpExpr -is [Microsoft.SqlServer.TransactSql.ScriptDom.VariableReference]) { $lit = $cmpExpr.Name }
            else { return @{ ok = $false; reason = 'comparand is not a literal or @parameter' } }
        }
        $q = Build-QueryNode -querySpec $info.QuerySpec; if (-not $q.ok) { return $q }
        return @{ ok = $true; node = @{ k = 'atom'; agg = $info.Aggregate; selectExpr = $info.ColumnText; op = $op; comparand = $lit; source = $q.node } }
    }
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.InPredicate]) {
        $info = Get-AggregateInfo -scalarExpr $p.Expression
        if (-not $info -or $info.Aggregate -ne 'COUNT') { return @{ ok = $false; reason = 'IN not over COUNT(...)' } }
        if ($p.Subquery) { return @{ ok = $false; reason = 'IN (subquery) not supported' } }
        $vals = @($p.Values | ForEach-Object { Get-LiteralText -expr $_ })
        if ($vals -contains $null) { return @{ ok = $false; reason = 'IN list has a non-literal value' } }
        $q = Build-QueryNode -querySpec $info.QuerySpec; if (-not $q.ok) { return $q }
        $op = if ($p.NotDefined) { 'notin' } else { 'in' }
        return @{ ok = $true; node = @{ k = 'atom'; agg = 'COUNT'; selectExpr = $info.ColumnText; op = $op; comparand = @($vals); source = $q.node } }
    }
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanTernaryExpression] -and
        $p.TernaryExpressionType.ToString().StartsWith('Between')) {
        $info = Get-AggregateInfo -scalarExpr $p.FirstExpression
        if (-not $info -or $info.Aggregate -ne 'COUNT') { return @{ ok = $false; reason = 'BETWEEN not over COUNT(...)' } }
        $a = Get-LiteralText -expr $p.SecondExpression; $b = Get-LiteralText -expr $p.ThirdExpression
        if ($null -eq $a -or $null -eq $b) { return @{ ok = $false; reason = 'BETWEEN bounds are not literals' } }
        $q = Build-QueryNode -querySpec $info.QuerySpec; if (-not $q.ok) { return $q }
        return @{ ok = $true; node = @{ k = 'atom'; agg = 'COUNT'; selectExpr = $info.ColumnText; op = 'between'; comparand = @($a, $b); source = $q.node } }
    }
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanIsNullExpression]) {
        $info = Get-AggregateInfo -scalarExpr $p.Expression
        if (-not $info -or $info.Aggregate -ne 'SCALAR') { return @{ ok = $false; reason = 'IS NULL not over a scalar subquery' } }
        $q = Build-QueryNode -querySpec $info.QuerySpec; if (-not $q.ok) { return $q }
        $op = if ($p.IsNot) { 'isnotnull' } else { 'isnull' }
        return @{ ok = $true; node = @{ k = 'atom'; agg = 'SCALAR'; selectExpr = $info.ColumnText; op = $op; comparand = $null; source = $q.node } }
    }
    return @{ ok = $false; reason = 'predicate shape not in the grammar' }
}

function Collect-TreeTables {
    # Union of every {schema;table;alias} across all atom sources in the tree.
    param($node)
    if (-not $node) { return @() }
    if ($node.k -eq 'atom') {
        return @(@($node.source.tables) | ForEach-Object { @{ schema = $_.schema; table = $_.table; alias = $_.alias } })
    }
    if ($node.k -eq 'not') { return (Collect-TreeTables -node $node.item) }
    if ($node.k -eq 'and' -or $node.k -eq 'or') {
        $acc = @(); foreach ($c in @($node.items)) { $acc += @(Collect-TreeTables -node $c) }
        return $acc
    }
    return @()
}

function Build-PredTree {
    # Top-level branch predicate -> boolean tree over data-shape atoms.
    param($predicate)
    $n = $predicate
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanParenthesisExpression]) { return (Build-PredTree -predicate $n.Expression) }
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanNotExpression]) {
        $i = Build-PredTree -predicate $n.Expression; if (-not $i.ok) { return $i }
        return @{ ok = $true; node = @{ k = 'not'; item = $i.node } }
    }
    if ($n -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanBinaryExpression]) {
        $bt = $n.BinaryExpressionType.ToString()
        $k = if ($bt -eq 'And') { 'and' } elseif ($bt -eq 'Or') { 'or' } else { $null }
        if (-not $k) { return @{ ok = $false; reason = "predicate uses unsupported boolean operator $bt" } }
        $L = Build-PredTree -predicate $n.FirstExpression;  if (-not $L.ok) { return $L }
        $R = Build-PredTree -predicate $n.SecondExpression; if (-not $R.ok) { return $R }
        $items = @()
        foreach ($c in @($L.node, $R.node)) { if ($c) { if ($c.k -eq $k) { $items += $c.items } else { $items += $c } } }
        return @{ ok = $true; node = @{ k = $k; items = @($items) } }
    }
    return (Build-AtomNode -p $n)
}

# --- render a tree back to SQL (for the strong assertion; params stay symbolic) ---
function Render-WhereNode {
    param($node)
    if (-not $node) { return $null }
    if ($node.k -eq 'and') { return '(' + ((@($node.items) | ForEach-Object { Render-WhereNode -node $_ }) -join ' AND ') + ')' }
    if ($node.k -eq 'or')  { return '(' + ((@($node.items) | ForEach-Object { Render-WhereNode -node $_ }) -join ' OR ')  + ')' }
    if ($node.k -eq 'not') { return 'NOT (' + (Render-WhereNode -node $node.item) + ')' }
    # colpred
    $c = if ($node.tbl) { (Quote-Ident $node.tbl) + '.' + (Quote-Ident $node.col) } else { (Quote-Ident $node.col) }
    return $c + ' ' + $node.op + ' ' + $node.val
}

function Render-QueryNode {
    param($node)
    $t0 = $node.tables[0]
    $from = (Quote-Ident $t0.schema) + '.' + (Quote-Ident $t0.table)
    if ($t0.alias) { $from += ' ' + (Quote-Ident $t0.alias) }
    for ($i = 0; $i -lt @($node.joins).Count; $i++) {
        $st = $node.joins[$i]; $tb = $node.tables[$i + 1]
        $on = (@($st.on) | ForEach-Object { (Quote-Ident $_.lAlias) + '.' + (Quote-Ident $_.lCol) + ' ' + $_.op + ' ' + (Quote-Ident $_.rAlias) + '.' + (Quote-Ident $_.rCol) }) -join ' AND '
        $from += ' ' + $st.type + ' JOIN ' + (Quote-Ident $tb.schema) + '.' + (Quote-Ident $tb.table)
        if ($tb.alias) { $from += ' ' + (Quote-Ident $tb.alias) }
        $from += ' ON ' + $on
    }
    $w = Render-WhereNode -node $node.where
    if ($w) { $from += ' WHERE ' + $w }
    return $from
}

function Render-PredNode {
    param($node)
    if ($node.k -eq 'const') { return $(if ($node.val) { '(1 = 1)' } else { '(1 = 0)' }) }
    if ($node.k -eq 'and') { return '(' + ((@($node.items) | ForEach-Object { Render-PredNode -node $_ }) -join ' AND ') + ')' }
    if ($node.k -eq 'or')  { return '(' + ((@($node.items) | ForEach-Object { Render-PredNode -node $_ }) -join ' OR ')  + ')' }
    if ($node.k -eq 'not') { return 'NOT (' + (Render-PredNode -node $node.item) + ')' }
    # atom
    $src = Render-QueryNode -node $node.source
    switch ($node.op) {
        'exists'    { return "EXISTS (SELECT 1 FROM $src)" }
        'isnull'    { return "(SELECT $($node.selectExpr) FROM $src) IS NULL" }
        'isnotnull' { return "(SELECT $($node.selectExpr) FROM $src) IS NOT NULL" }
        'in'        { return "(SELECT $($node.selectExpr) FROM $src) IN (" + ((@($node.comparand)) -join ', ') + ")" }
        'notin'     { return "(SELECT $($node.selectExpr) FROM $src) NOT IN (" + ((@($node.comparand)) -join ', ') + ")" }
        'between'   { return "(SELECT $($node.selectExpr) FROM $src) BETWEEN $($node.comparand[0]) AND $($node.comparand[1])" }
        default     { return "(SELECT $($node.selectExpr) FROM $src) $($node.op) $($node.comparand)" }
    }
}

# ===========================================================================
# 2c. v0.12 truth-propagation -> per-table seed plan (one per direction).
#     Boolean nodes propagate the target truth; atoms emit per-table demands;
#     demands are grouped by physical table. The T-SQL seeder resolves the
#     symbolic value specs (vspec) and computes row counts (kspec) via the
#     existing GetSampleValueLiteral / SatisfyingValue / case-analysis helpers.
# ===========================================================================
function Vspec-Comparand { param($c) if ($null -ne $c -and ("$c").StartsWith('@')) { return @{ param = "$c" } } else { return @{ lit = $c } } }

function Extract-InnerCol {
    param($selectExpr)
    return (Extract-InnerColRef -selectExpr $selectExpr).col
}

function Extract-InnerColRef {
    # "SUM([o].[Amount])" -> @{ alias='o'; col='Amount' };  "[Status]" -> @{ alias=$null; col='Status' }
    param($selectExpr)
    $s = "$selectExpr"
    $op = $s.IndexOf('(')
    if ($op -ge 0) { $cp = $s.LastIndexOf(')'); if ($cp -gt $op) { $s = $s.Substring($op + 1, $cp - $op - 1) } }
    $s = ($s.Trim() -replace '[\[\]]', '')
    $alias = $null
    if ($s.Contains('.')) { $alias = $s.Substring(0, $s.IndexOf('.')); $s = $s.Substring($s.LastIndexOf('.') + 1) }
    return @{ alias = $alias; col = $s }
}

function Drive-Where {
    # Overrides for a row that makes the WHERE tree evaluate to $want.
    param($node, [bool]$want)
    if (-not $node) { return @{ ok = $true; reason = $null; overrides = @() } }
    if ($node.k -eq 'colpred') {
        $vs = @{ satisfy = @{ op = $node.op; val = $node.val; valKind = $node.valKind; want = ([int]$want) } }
        return @{ ok = $true; reason = $null; overrides = @(@{ tbl = $node.tbl; col = $node.col; vspec = $vs }) }
    }
    if ($node.k -eq 'not') { return (Drive-Where -node $node.item -want (-not $want)) }
    if ($node.k -eq 'and') {
        if ($want) {
            $ov = @(); foreach ($c in @($node.items)) { $r = Drive-Where -node $c -want $true; if (-not $r.ok) { return $r }; $ov += $r.overrides }
            return @{ ok = $true; reason = $null; overrides = $ov }
        } else {
            foreach ($c in @($node.items)) { $r = Drive-Where -node $c -want $false; if ($r.ok) { return $r } }
            return @{ ok = $false; reason = 'cannot violate AND in WHERE' }
        }
    }
    if ($node.k -eq 'or') {
        if ($want) {
            foreach ($c in @($node.items)) { $r = Drive-Where -node $c -want $true; if ($r.ok) { return $r } }
            return @{ ok = $false; reason = 'no WHERE OR disjunct is seedable' }
        } else {
            $ov = @(); foreach ($c in @($node.items)) { $r = Drive-Where -node $c -want $false; if (-not $r.ok) { return $r }; $ov += $r.overrides }
            return @{ ok = $true; reason = $null; overrides = $ov }
        }
    }
    return @{ ok = $false; reason = "unexpected WHERE node '$($node.k)'" }
}

function Coordinate-Joins {
    # Force every join-key column to a typed sample so equi-joined columns (same
    # type) get the same literal and the join matches. Non-equi -> deferred.
    param($src)
    $overrides = @()
    foreach ($st in @($src.joins)) {
        foreach ($p in @($st.on)) {
            if ($p.op -eq '=') {
                # equi: both columns get the same typed sample -> equal -> join matches
                $overrides += ,@{ tbl = $p.lAlias; col = $p.lCol; vspec = @{ sample = $true } }
                $overrides += ,@{ tbl = $p.rAlias; col = $p.rCol; vspec = @{ sample = $true } }
            } else {
                # non-equi a.x <op> b.y: pin b.y to a sample, drive a.x to satisfy
                # <op> against the same-typed sample.
                $overrides += ,@{ tbl = $p.rAlias; col = $p.rCol; vspec = @{ sample = $true } }
                $overrides += ,@{ tbl = $p.lAlias; col = $p.lCol; vspec = @{ satisfysample = @{ op = $p.op; want = 1 } } }
            }
        }
    }
    return @{ ok = $true; reason = $null; overrides = $overrides }
}

function Get-AtomKspec {
    # Map an atom (agg+op) to the T-SQL seeder's (shape, comparator, comparand).
    param($atom, [bool]$want)
    $agg = $atom.agg; $op = $atom.op
    $shape = $null; $cmp = $null; $comparand = $atom.comparand
    if ($op -eq 'exists') { $shape = 'EXISTS'; $cmp = $null; $comparand = $null }
    elseif ($op -eq 'isnull')    { $shape = 'SCALAR_NULL'; $cmp = 'IS_NULL' }
    elseif ($op -eq 'isnotnull') { $shape = 'SCALAR_NULL'; $cmp = 'IS_NOT_NULL' }
    elseif ($op -eq 'in')    { $shape = 'COUNT_IN'; $cmp = 'IN';     $comparand = (@($atom.comparand) -join ', ') }
    elseif ($op -eq 'notin') { $shape = 'COUNT_IN'; $cmp = 'NOT_IN'; $comparand = (@($atom.comparand) -join ', ') }
    elseif ($op -eq 'between'){ $shape = 'COUNT_BETWEEN'; $cmp = 'BETWEEN'; $comparand = (@($atom.comparand)[0]).ToString() + ' AND ' + (@($atom.comparand)[1]).ToString() }
    else {
        $cmp = $op
        switch ($agg) {
            'COUNT' { $shape = 'COUNT_CMP' } 'SUM' { $shape = 'SUM_CMP' } 'MIN' { $shape = 'MIN_CMP' }
            'MAX'   { $shape = 'MAX_CMP' }  'AVG' { $shape = 'AVG_CMP' } 'SCALAR' { $shape = 'SCALAR_CMP' }
            default { $shape = 'COUNT_CMP' }
        }
    }
    return @{ shape = $shape; comparator = $cmp; comparand = $comparand; want = ([int]$want) }
}

function Plan-Atom {
    # One atom + target truth -> per-physical-table demands.
    param($atom, [bool]$want)
    $src = $atom.source
    $tables = @($src.tables)
    $aliasIdx = @{}
    for ($i = 0; $i -lt $tables.Count; $i++) {
        $a = if ($tables[$i].alias) { $tables[$i].alias } else { $tables[$i].table }
        $aliasIdx[$a] = $i
    }
    $wd = Drive-Where -node $src.where -want $true; if (-not $wd.ok) { return @{ ok = $false; reason = $wd.reason } }
    $jc = Coordinate-Joins -src $src;               if (-not $jc.ok) { return @{ ok = $false; reason = $jc.reason } }
    $allOv = @(@($wd.overrides) + @($jc.overrides))
    # aggregate / scalar inner-column override (SUM/MIN/MAX/AVG/SCALAR comparison)
    $isAggVal = ($atom.agg -in @('SUM','MIN','MAX','AVG')) -or ($atom.agg -eq 'SCALAR' -and $atom.op -notin @('isnull','isnotnull','exists'))
    if ($isAggVal) {
        # Inner column ref (alias-qualified for a join) -> route the value override
        # to the table that owns it. K=1 (one joined row) makes the single row's
        # value drive SUM/MIN/MAX/AVG/scalar over the join.
        $icr = Extract-InnerColRef -selectExpr $atom.selectExpr
        if ($icr.col -and $icr.col -ne '*') {
            $vk = if (("$($atom.comparand)").StartsWith('@')) { 'param' } else { 'literal' }
            $allOv += ,@{ tbl = $icr.alias; col = $icr.col; vspec = @{ satisfy = @{ op = $atom.op; val = $atom.comparand; valKind = $vk; want = ([int]$want) } } }
        }
    }
    # route overrides to tables by alias (null -> base table 0)
    $perTable = @{}
    for ($i = 0; $i -lt $tables.Count; $i++) { $perTable[$i] = @() }
    foreach ($o in $allOv) {
        $idx = if ($null -eq $o.tbl) { 0 } elseif ($aliasIdx.ContainsKey($o.tbl)) { $aliasIdx[$o.tbl] } else { -1 }
        if ($idx -lt 0) { return @{ ok = $false; reason = "override references unknown alias '$($o.tbl)'" } }
        $perTable[$idx] += ,@{ col = $o.col; vspec = $o.vspec }
    }
    $kspec = Get-AtomKspec -atom $atom -want $want
    $demands = @()
    for ($i = 0; $i -lt $tables.Count; $i++) {
        $t = $tables[$i]
        $d = @{ schema = $t.schema; table = $t.table; alias = $t.alias; overrides = @($perTable[$i]) }
        if ($i -eq 0) { $d.kspec = $kspec } else { $d.count = 1 }
        $demands += ,$d
    }
    return @{ ok = $true; reason = $null; demands = $demands }
}

function Propagate {
    param($node, [bool]$want)
    if ($node.k -eq 'const') {
        if ([bool]$node.val -eq $want) { return @{ ok = $true; demands = @() } }
        return @{ ok = $false; reason = 'constant sub-predicate has the opposite fixed truth value' }
    }
    if ($node.k -eq 'atom') { return (Plan-Atom -atom $node -want $want) }
    if ($node.k -eq 'not')  { return (Propagate -node $node.item -want (-not $want)) }
    if ($node.k -eq 'and') {
        if ($want) {
            $dem = @(); foreach ($c in @($node.items)) { $r = Propagate -node $c -want $true; if (-not $r.ok) { return $r }; $dem += $r.demands }
            return @{ ok = $true; demands = $dem }
        } else {
            # Drive ONE child false; prefer the one needing the FEWEST demands so a
            # const-false / already-false child is used for free, never an
            # expensive (and possibly conflicting) seed.
            return (Pick-Cheapest -items @($node.items) -want $false -failReason 'cannot drive AND false (no child falsifiable)')
        }
    }
    if ($node.k -eq 'or') {
        if ($want) {
            return (Pick-Cheapest -items @($node.items) -want $true -failReason 'no OR branch is satisfiable')
        } else {
            $dem = @(); foreach ($c in @($node.items)) { $r = Propagate -node $c -want $false; if (-not $r.ok) { return $r }; $dem += $r.demands }
            return @{ ok = $true; demands = $dem }
        }
    }
    return @{ ok = $false; reason = "unexpected node '$($node.k)'" }
}

function Pick-Cheapest {
    # Among children, return the satisfiable sub-plan with the fewest demands
    # (0 = a free/const choice). Used for AND-false and OR-true.
    param($items, [bool]$want, [string]$failReason)
    $best = $null
    foreach ($c in @($items)) {
        $r = Propagate -node $c -want $want
        if ($r.ok) {
            $n = @($r.demands).Count
            if ($null -eq $best -or $n -lt $best.n) { $best = @{ n = $n; demands = $r.demands } }
            if ($n -eq 0) { break }
        }
    }
    if ($best) { return @{ ok = $true; demands = $best.demands } }
    return @{ ok = $false; reason = $failReason }
}

function Get-SeedPlan {
    param($tree, [bool]$wantTrue)
    $predSql = Render-PredNode -node $tree
    $prop = Propagate -node $tree -want $wantTrue
    if (-not $prop.ok) { return @{ skip = $prop.reason; predSql = $predSql; expectedBit = ([int]$wantTrue); tables = @() } }
    # Group every demand by physical table. Two atoms (or a self-join's two
    # aliases) on one table become two demands the T-SQL reconciler merges into
    # one coherent row set (design/DESIGN_v0_12_UnifiedReverseSeeder.md s6).
    $byKey = [ordered]@{}
    $order = @()
    foreach ($d in @($prop.demands)) {
        $key = "$($d.schema).$($d.table)"
        if (-not $byKey.Contains($key)) { $byKey[$key] = @{ schema = $d.schema; table = $d.table; demands = @() }; $order += $key }
        $dem = @{ overrides = @($d.overrides) }
        if ($d.Contains('kspec')) { $dem.kspec = $d.kspec }
        if ($d.Contains('count')) { $dem.count = $d.count }
        $byKey[$key].demands += ,$dem
    }
    $tables = @($order | ForEach-Object { $byKey[$_] })
    return @{ skip = $null; predSql = $predSql; expectedBit = ([int]$wantTrue); tables = $tables }
}

# ===========================================================================
# 3. Classify one predicate into a ParsedPredicate hashtable.
# ===========================================================================
function Classify-Predicate {
    param($predicate, [int]$branchId, [string]$context, [string]$schema, [string]$proc, [int]$startLine = 0)

    $row = [ordered]@{
        SchemaName=$schema; ProcName=$proc; BranchId=$branchId; StartLine=$startLine; Context=$context;
        Shape='UNRECOGNISED'; AggregateColumn=$null; Comparator=$null; Comparand=$null;
        TargetTablesJson='[]'; JoinsJson=$null; WhereAstJson=$null;
        PredicateTreeJson=$null; SeedPlanTrueJson=$null; SeedPlanFalseJson=$null; PredicateTreeText=$null;
        PredicateText=(Get-FragmentText -fragment $predicate); UnsupportedReason=$null
    }

    # v0.12 unified engine: build the predicate tree in parallel with the flat
    # classification below. When the tree builds, the seeder prefers it; the flat
    # fields remain as a fallback for one release.
    # v0.12: inline single-assignment local variables referenced in the predicate
    # (a local-gated branch is an indirection; substituting its defining
    # expression turns it into an ordinary data-shape predicate).
    $uagWorkPred = $predicate
    $uagHaveLocals = (($script:uagLocalDefs -and $script:uagLocalDefs.Count -gt 0) -or ($script:uagLocalCond -and $script:uagLocalCond.Count -gt 0))
    if ($uagHaveLocals) {
        $uagDepth = 0
        while ($uagDepth -lt 12) {
            $uagRefs = New-Object System.Collections.ArrayList
            Get-FragmentVarRefs -node $uagWorkPred -acc $uagRefs
            $uagUniq = @($uagRefs | Select-Object -Unique)

            # 1. Path-conditioned expansion of a conditionally-assigned local:
            #    P(@x) with @x = v1 (when C) / v2 (else) becomes
            #    (C AND P(v1)) OR (NOT C AND P(v2)) - a boolean tree of atoms the
            #    engine seeds directly (the ancestor branch C is seeded too).
            $uagCondRef = $null
            if ($script:uagLocalCond -and $script:uagLocalCond.Count -gt 0) {
                $uagCondRef = @($uagUniq | Where-Object { $script:uagLocalCond.ContainsKey($_) }) | Select-Object -First 1
            }
            if ($uagCondRef) {
                $cc = $script:uagLocalCond[$uagCondRef]
                $ptext = Get-FragmentText -fragment $uagWorkPred
                $esc = [regex]::Escape($uagCondRef) + '\b'
                $thenP = $ptext -replace $esc, ('(' + $cc.thenVal + ')')
                $elseP = $ptext -replace $esc, ('(' + $cc.elseVal + ')')
                $expanded = '((' + $cc.cond + ') AND (' + $thenP + ')) OR ((NOT (' + $cc.cond + ')) AND (' + $elseP + '))'
                $uagRp = Reparse-BoolExpr -text $expanded
                if (-not $uagRp) { break }
                $uagWorkPred = $uagRp; $uagDepth++; continue
            }

            # 2. Inline single-assignment locals (textual substitution).
            $uagSub = @($uagUniq | Where-Object { $script:uagLocalDefs.ContainsKey($_) })
            if ($uagSub.Count -eq 0) { break }
            $uagTxt = Get-FragmentText -fragment $uagWorkPred
            foreach ($nm in ($uagSub | Sort-Object -Property Length -Descending)) {
                $uagTxt = $uagTxt -replace ([regex]::Escape($nm) + '\b'), ('(' + $script:uagLocalDefs[$nm] + ')')
            }
            $uagRp = Reparse-BoolExpr -text $uagTxt
            if (-not $uagRp) { break }
            $uagWorkPred = $uagRp
            $uagDepth++
        }
    }

    $uagTree = Build-PredTree -predicate $uagWorkPred
    if ($uagTree.ok) {
        $row.PredicateTreeJson = ($uagTree.node | ConvertTo-Json -Depth 40 -Compress)
        $row.PredicateTreeText = (Render-PredNode -node $uagTree.node)
        $planT = Get-SeedPlan -tree $uagTree.node -wantTrue $true
        $planF = Get-SeedPlan -tree $uagTree.node -wantTrue $false
        $row.SeedPlanTrueJson  = ($planT | ConvertTo-Json -Depth 40 -Compress)
        $row.SeedPlanFalseJson = ($planF | ConvertTo-Json -Depth 40 -Compress)
        # union of every table in the tree -> module 34 fakes them all (tree path)
        $uagTbls = @(Collect-TreeTables -node $uagTree.node)
        if ($uagTbls.Count -gt 0) {
            $row.TargetTablesJson = '[' + (($uagTbls | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
        }
        # Shape is forced to PREDTREE after the flat pass (in Parse-OneProc) so the
        # tree fields above survive and the seeder/test-gen route to the tree path.

        # PERF: when the tree built, the seeder uses it exclusively, so the legacy
        # flat classification below is pure dead weight - skip it. The flat path
        # runs only as the fallback when the tree could NOT be built.
        return $row
    }

    function Set-Unsupported($r, $why) { $r.Shape='UNRECOGNISED'; $r.UnsupportedReason=$why; return $r }

    function Apply-Subquery($r, $qspec, [bool]$needWhere, [bool]$allowJoin) {
        $ft = Get-FromTables -querySpec $qspec
        if (-not $ft.ok) { return (Set-Unsupported $r $ft.reason) }
        if ($ft.joins.Count -gt 0 -and -not $allowJoin) {
            return (Set-Unsupported $r 'join in subquery is only seedable for EXISTS / NOT EXISTS in this cut')
        }
        if ($ft.joins.Count -gt 0 -and $ft.tables.Count -ne 2) {
            return (Set-Unsupported $r 'only 2-table inner joins are seedable in this cut')
        }
        # TargetTablesJson is always an array of table objects (1 or 2 entries).
        $r.TargetTablesJson = '[' + (($ft.tables | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
        if ($ft.joins.Count -gt 0) {
            $r.JoinsJson = '[' + (($ft.joins | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
        }
        $whereExpr = if ($qspec.WhereClause) { $qspec.WhereClause.SearchCondition } else { $null }
        $wc = Get-WhereDnf -boolExpr $whereExpr
        if (-not $wc.ok) { return (Set-Unsupported $r $wc.reason) }
        if ($wc.terms.Count -gt 0) {
            # WhereAstJson is DNF: an array of TERMS, each term an array of
            # conjunct objects. AND-only WHERE -> a single term.
            $termsJson = @($wc.terms | ForEach-Object {
                '[' + ((@($_) | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join ',') + ']'
            })
            $r.WhereAstJson = '[' + ($termsJson -join ',') + ']'
        }
        return $r
    }

    # --- EXISTS / NOT EXISTS ---
    $negated = $null; $p = $predicate
    if ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExistsPredicate]) { $negated = $false }
    elseif ($p -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanNotExpression] -and
            $p.Expression -is [Microsoft.SqlServer.TransactSql.ScriptDom.ExistsPredicate]) {
        $negated = $true; $p = $p.Expression
    }
    if ($null -ne $negated) {
        $row.Shape = if ($negated) { 'NOT_EXISTS' } else { 'EXISTS' }
        $qe = $p.Subquery.QueryExpression
        if ($qe -isnot [Microsoft.SqlServer.TransactSql.ScriptDom.QuerySpecification]) { return (Set-Unsupported $row 'EXISTS subquery is not a simple query spec') }
        return (Apply-Subquery $row $qe $true $true)
    }

    # --- comparison: lhs <op> rhs, one side an aggregate/scalar subquery ---
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanComparisonExpression]) {
        $opMap = @{ Equals='='; NotEqualToBrackets='<>'; NotEqualToExclamation='<>';
                   LessThan='<'; GreaterThan='>'; LessThanOrEqualTo='<='; GreaterThanOrEqualTo='>=' }
        $cmp = $opMap[$predicate.ComparisonType.ToString()]
        $info = Get-AggregateInfo -scalarExpr $predicate.FirstExpression
        $comparandExpr = $predicate.SecondExpression
        if (-not $info) { $info = Get-AggregateInfo -scalarExpr $predicate.SecondExpression; $comparandExpr = $predicate.FirstExpression }
        if (-not $info) { return (Set-Unsupported $row 'comparison does not involve an aggregate/scalar subquery') }
        if (-not $cmp) { return (Set-Unsupported $row 'unsupported comparison operator') }
        $lit = Get-LiteralText -expr $comparandExpr
        if ($null -eq $lit) {
            # v0.11.1: a parameter comparand (e.g. COUNT(*) > @Threshold) is now
            # accepted - the seeder reverse-resolves @name to the proc-parameter
            # sample value the test passes (same as a WHERE col = @param).
            if ($comparandExpr -is [Microsoft.SqlServer.TransactSql.ScriptDom.VariableReference]) {
                $lit = $comparandExpr.Name   # includes the leading '@'
            } else {
                return (Set-Unsupported $row 'comparand is not a literal or @parameter (variable/expression)')
            }
        }
        $row.Shape = switch ($info.Aggregate) {
            'COUNT'  { 'COUNT_CMP' } 'SUM' { 'SUM_CMP' } 'MIN' { 'MIN_CMP' }
            'MAX'    { 'MAX_CMP' }  'AVG' { 'AVG_CMP' } 'SCALAR' { 'SCALAR_CMP' }
            default  { 'UNRECOGNISED' }
        }
        $row.AggregateColumn = $info.ColumnText
        $row.Comparator = $cmp
        $row.Comparand = $lit
        return (Apply-Subquery $row $info.QuerySpec $true $false)
    }

    # --- COUNT(...) IN (list) ---
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.InPredicate]) {
        $info = Get-AggregateInfo -scalarExpr $predicate.Expression
        if (-not $info -or $info.Aggregate -ne 'COUNT') { return (Set-Unsupported $row 'IN predicate not over COUNT(...) ') }
        if ($predicate.Subquery) { return (Set-Unsupported $row 'IN (subquery) not supported') }
        $vals = @($predicate.Values | ForEach-Object { Get-LiteralText -expr $_ })
        if ($vals -contains $null) { return (Set-Unsupported $row 'IN list has a non-literal value') }
        $row.Shape = 'COUNT_IN'; $row.AggregateColumn = $info.ColumnText
        $row.Comparator = if ($predicate.NotDefined) { 'NOT_IN' } else { 'IN' }
        $row.Comparand = ($vals -join ', ')
        return (Apply-Subquery $row $info.QuerySpec $true $false)
    }

    # --- COUNT(...) BETWEEN a AND b ---
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanTernaryExpression] -and
        $predicate.TernaryExpressionType.ToString().StartsWith('Between')) {
        $info = Get-AggregateInfo -scalarExpr $predicate.FirstExpression
        if (-not $info -or $info.Aggregate -ne 'COUNT') { return (Set-Unsupported $row 'BETWEEN not over COUNT(...) ') }
        $a = Get-LiteralText -expr $predicate.SecondExpression
        $b = Get-LiteralText -expr $predicate.ThirdExpression
        if ($null -eq $a -or $null -eq $b) { return (Set-Unsupported $row 'BETWEEN bounds are not literals') }
        $row.Shape = 'COUNT_BETWEEN'; $row.AggregateColumn = $info.ColumnText
        $row.Comparator = 'BETWEEN'; $row.Comparand = "$a AND $b"
        return (Apply-Subquery $row $info.QuerySpec $true $false)
    }

    # --- (SELECT col ...) IS [NOT] NULL ---
    if ($predicate -is [Microsoft.SqlServer.TransactSql.ScriptDom.BooleanIsNullExpression]) {
        $info = Get-AggregateInfo -scalarExpr $predicate.Expression
        if (-not $info -or $info.Aggregate -ne 'SCALAR') { return (Set-Unsupported $row 'IS NULL not over a scalar subquery') }
        $row.Shape = 'SCALAR_NULL'; $row.AggregateColumn = $info.ColumnText
        $row.Comparator = if ($predicate.IsNot) { 'IS_NOT_NULL' } else { 'IS_NULL' }
        return (Apply-Subquery $row $info.QuerySpec $false $false)
    }

    return (Set-Unsupported $row 'predicate shape not in the v0.10 grammar')
}

# ===========================================================================
# 4. Walk the AST collecting branch predicates (recursive property descent).
# ===========================================================================
$script:rows = New-Object System.Collections.Generic.List[object]
$script:branchId = 0

function Visit-Fragment {
    param($node, $context, $schema, $proc)
    if ($null -eq $node) { return }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.IfStatement]) {
        $script:branchId++
        $script:rows.Add((Classify-Predicate -predicate $node.Predicate -branchId $script:branchId -context 'IF' -schema $schema -proc $proc -startLine $node.StartLine))
        Visit-Fragment -node $node.ThenStatement -context 'IF' -schema $schema -proc $proc
        Visit-Fragment -node $node.ElseStatement -context 'IF' -schema $schema -proc $proc
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.WhileStatement]) {
        $script:branchId++
        $script:rows.Add((Classify-Predicate -predicate $node.Predicate -branchId $script:branchId -context 'WHILE' -schema $schema -proc $proc -startLine $node.StartLine))
        Visit-Fragment -node $node.Statement -context 'WHILE' -schema $schema -proc $proc
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.SearchedCaseExpression]) {
        foreach ($wc in $node.WhenClauses) {
            $script:branchId++
            $script:rows.Add((Classify-Predicate -predicate $wc.WhenExpression -branchId $script:branchId -context 'CASE_WHEN' -schema $schema -proc $proc -startLine $wc.StartLine))
        }
        return
    }
    foreach ($prop in (Get-FragmentChildProps -node $node)) {
        try { $val = $prop.GetValue($node) } catch { continue }
        if ($null -eq $val) { continue }
        if ($val -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
            Visit-Fragment -node $val -context $context -schema $schema -proc $proc
        } elseif ($val -is [System.Collections.IEnumerable] -and -not ($val -is [string])) {
            foreach ($child in $val) {
                if ($child -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) {
                    Visit-Fragment -node $child -context $context -schema $schema -proc $proc
                }
            }
        }
    }
}

function Resolve-ParserType {
    # Honor an explicitly supplied -ParserVersion if that parser exists in the
    # loaded DLL; otherwise pick the HIGHEST TSqlNNNParser the assembly exposes
    # (so a SQL 2025 / ScriptDom 17.x DLL uses TSql170Parser, not a stale 160).
    if ($script:ResolvedParserType) { return $script:ResolvedParserType }
    $asm = [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlParser].Assembly
    $avail = @($asm.GetTypes() |
        Where-Object { $_.Name -match '^TSql(\d+)Parser$' } |
        ForEach-Object { [int]($_.Name -replace '\D','') } | Sort-Object -Descending)
    $pick = $null
    if ($PSBoundParameters.ContainsKey('ParserVersion') -and ($avail -contains $ParserVersion)) {
        $pick = $ParserVersion
    } elseif ($avail.Count -gt 0) {
        $pick = $avail[0]
    } else {
        $pick = $ParserVersion   # last resort; let New-Object surface the error
    }
    Write-Verbose ("Available TSql parser versions: {0}; using {1}." -f ($avail -join ','), $pick)
    $script:ResolvedParserType = "Microsoft.SqlServer.TransactSql.ScriptDom.TSql${pick}Parser"
    return $script:ResolvedParserType
}

function Get-FragmentVarRefs {
    # Collect @variable names referenced anywhere under a fragment.
    param($node, $acc)
    if ($null -eq $node) { return }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.VariableReference]) { [void]$acc.Add($node.Name); return }
    foreach ($prop in (Get-FragmentChildProps -node $node)) {
        $v = $null; try { $v = $prop.GetValue($node) } catch { continue }
        if ($null -eq $v) { continue }
        if ($v -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { Get-FragmentVarRefs -node $v -acc $acc }
        elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            foreach ($c in $v) { if ($c -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { Get-FragmentVarRefs -node $c -acc $acc } }
        }
    }
}

function Collect-AssignNodes {
    # Recursively collect DECLARE-with-value and SET assignment statements.
    param($node, $acc)
    if ($null -eq $node) { return }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.DeclareVariableStatement] -or
        $node -is [Microsoft.SqlServer.TransactSql.ScriptDom.SetVariableStatement]) { [void]$acc.Add($node) }
    foreach ($prop in (Get-FragmentChildProps -node $node)) {
        $v = $null; try { $v = $prop.GetValue($node) } catch { continue }
        if ($null -eq $v) { continue }
        if ($v -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { Collect-AssignNodes -node $v -acc $acc }
        elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            foreach ($c in $v) { if ($c -is [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlFragment]) { Collect-AssignNodes -node $c -acc $acc } }
        }
    }
}

function Collect-ProcLocals {
    # Map @local -> defining expression TEXT, for locals with EXACTLY ONE
    # assignment (DECLARE @x = expr / SET @x = expr) anywhere in the proc. A
    # variable assigned more than once (e.g. in two branches) is omitted -
    # we cannot inline it deterministically.
    param($fragment)
    $defs = @{}; $counts = @{}
    $nodes = New-Object System.Collections.ArrayList
    Collect-AssignNodes -node $fragment -acc $nodes
    foreach ($st in $nodes) {
        if ($st -is [Microsoft.SqlServer.TransactSql.ScriptDom.DeclareVariableStatement]) {
            foreach ($d in $st.Declarations) {
                if ($d.Value) {
                    $n = $d.VariableName.Value
                    if (-not $counts.ContainsKey($n)) { $counts[$n] = 0 }
                    $counts[$n] = $counts[$n] + 1
                    $defs[$n] = (Get-FragmentText -fragment $d.Value)
                }
            }
        } elseif ($st -is [Microsoft.SqlServer.TransactSql.ScriptDom.SetVariableStatement]) {
            if ($st.Expression) {
                $n = $st.Variable.Name
                if (-not $counts.ContainsKey($n)) { $counts[$n] = 0 }
                $counts[$n] = $counts[$n] + 1
                $defs[$n] = (Get-FragmentText -fragment $st.Expression)
            }
        }
    }
    $out = @{}
    foreach ($k in @($defs.Keys)) { if ($counts[$k] -eq 1) { $out[$k] = $defs[$k] } }
    return $out
}

function Collect-ProcBodyStatements {
    param($fragment)
    foreach ($b in $fragment.Batches) {
        foreach ($st in $b.Statements) {
            if ($st.GetType().Name -match 'Procedure' -and $st.StatementList) { return @($st.StatementList.Statements) }
        }
    }
    return @()
}

function Collect-AssignWithGuards {
    # Walk straight-line + IF/ELSE statements, recording each @var assignment with
    # the guard (list of {cond; neg}) under which it executes.
    param($node, $guard, $acc)
    if ($null -eq $node) { return }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.IfStatement]) {
        # Store the condition FRAGMENT (object identity is enough to match THEN vs
        # ELSE of the same IF); render it to text lazily only for a qualifying
        # conditional local - rendering every guard eagerly is expensive.
        $c = $node.Predicate
        Collect-AssignWithGuards -node $node.ThenStatement -guard (@($guard) + @(@{ cond = $c; neg = $false })) -acc $acc
        if ($node.ElseStatement) { Collect-AssignWithGuards -node $node.ElseStatement -guard (@($guard) + @(@{ cond = $c; neg = $true })) -acc $acc }
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.BeginEndBlockStatement]) {
        foreach ($s in $node.StatementList.Statements) { Collect-AssignWithGuards -node $s -guard $guard -acc $acc }
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.DeclareVariableStatement]) {
        foreach ($d in $node.Declarations) { if ($d.Value) { [void]$acc.Add(@{ var = $d.VariableName.Value; val = (Get-FragmentText -fragment $d.Value); guard = @($guard) }) } }
        return
    }
    if ($node -is [Microsoft.SqlServer.TransactSql.ScriptDom.SetVariableStatement]) {
        if ($node.Expression) { [void]$acc.Add(@{ var = $node.Variable.Name; val = (Get-FragmentText -fragment $node.Expression); guard = @($guard) }) }
        return
    }
    # other statements: not straight-line assignment -> ignore (keeps it sound)
}

function Collect-ProcLocalConds {
    # @local -> @{ cond; thenVal; elseVal } for a local assigned in BOTH arms of a
    # single IF/ELSE (and nowhere else). Drives the path-conditioned expansion.
    param($fragment)
    $acc = New-Object System.Collections.ArrayList
    foreach ($s in (Collect-ProcBodyStatements -fragment $fragment)) { Collect-AssignWithGuards -node $s -guard @() -acc $acc }
    $out = @{}
    foreach ($v in (@($acc | ForEach-Object { $_.var }) | Select-Object -Unique)) {
        $as = @($acc | Where-Object { $_.var -eq $v })
        if ($as.Count -eq 2) {
            $g0 = @($as[0].guard); $g1 = @($as[1].guard)
            if ($g0.Count -eq 1 -and $g1.Count -eq 1 -and $g0[0].cond -eq $g1[0].cond -and $g0[0].neg -ne $g1[0].neg) {
                $thenA = if (-not $g0[0].neg) { $as[0] } else { $as[1] }
                $elseA = if ($g0[0].neg) { $as[0] } else { $as[1] }
                $out[$v] = @{ cond = (Get-FragmentText -fragment $g0[0].cond); thenVal = $thenA.val; elseVal = $elseA.val }
            }
        }
    }
    return $out
}

function Reparse-BoolExpr {
    # Parse a standalone boolean predicate text -> its AST (or $null on error).
    param($text)
    $pt = Resolve-ParserType
    $p2 = New-Object $pt($true)
    $rd = New-Object System.IO.StringReader("IF (" + $text + ") SET @uagz = 1;")
    $er = $null
    $fr = $p2.Parse($rd, [ref]$er)
    if ($er -and $er.Count -gt 0) { return $null }
    foreach ($b in $fr.Batches) { foreach ($st in $b.Statements) { if ($st -is [Microsoft.SqlServer.TransactSql.ScriptDom.IfStatement]) { return $st.Predicate } } }
    return $null
}

function Parse-OneProc {
    param([string]$schema, [string]$proc, [string]$body)
    $script:rows = New-Object System.Collections.Generic.List[object]
    $script:branchId = 0
    $parserType = Resolve-ParserType
    $parser = New-Object $parserType($true)
    $reader = New-Object System.IO.StringReader($body)
    $errors = $null
    $fragment = $parser.Parse($reader, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Warning "Parse error (line $($_.Line)): $($_.Message)" }
    }
    $script:uagLocalDefs = Collect-ProcLocals -fragment $fragment
    $script:uagLocalCond = Collect-ProcLocalConds -fragment $fragment
    Visit-Fragment -node $fragment -context 'root' -schema $schema -proc $proc
    # v0.12: a row whose tree built routes to the tree path; mark it PREDTREE so
    # the flat Shape set above doesn't send the seeder/test-gen down the old path.
    foreach ($r in $script:rows) { if ($r.PredicateTreeJson) { $r.Shape = 'PREDTREE' } }
    return $script:rows
}

# ===========================================================================
# 5. Drivers: offline text mode, or DB mode (read modules, write inbox).
# ===========================================================================
function ConvertTo-DbNull { param($v) if ($null -eq $v) { [DBNull]::Value } else { $v } }   # PS 5.1: no ?? operator

function Write-InboxRows {
    param($conn, [guid]$runId, $rows)
    foreach ($r in $rows) {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'TestGen.AddParsedPredicate'
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        $null = $cmd.Parameters.AddWithValue('@RunId', $runId)
        $null = $cmd.Parameters.AddWithValue('@SchemaName', $r.SchemaName)
        $null = $cmd.Parameters.AddWithValue('@ProcName', $r.ProcName)
        $null = $cmd.Parameters.AddWithValue('@BranchId', [int]$r.BranchId)
        $null = $cmd.Parameters.AddWithValue('@Shape', $r.Shape)
        $null = $cmd.Parameters.AddWithValue('@PredicateText', $r.PredicateText)
        $null = $cmd.Parameters.AddWithValue('@StartLine', (ConvertTo-DbNull $r.StartLine))
        $null = $cmd.Parameters.AddWithValue('@Context', $r.Context)
        $null = $cmd.Parameters.AddWithValue('@AggregateColumn', (ConvertTo-DbNull $r.AggregateColumn))
        $null = $cmd.Parameters.AddWithValue('@Comparator', (ConvertTo-DbNull $r.Comparator))
        $null = $cmd.Parameters.AddWithValue('@Comparand', (ConvertTo-DbNull $r.Comparand))
        $null = $cmd.Parameters.AddWithValue('@TargetTablesJson', $r.TargetTablesJson)
        $null = $cmd.Parameters.AddWithValue('@JoinsJson', (ConvertTo-DbNull $r.JoinsJson))
        $null = $cmd.Parameters.AddWithValue('@WhereAstJson', (ConvertTo-DbNull $r.WhereAstJson))
        $null = $cmd.Parameters.AddWithValue('@PredicateTreeJson', (ConvertTo-DbNull $r.PredicateTreeJson))
        $null = $cmd.Parameters.AddWithValue('@SeedPlanTrueJson', (ConvertTo-DbNull $r.SeedPlanTrueJson))
        $null = $cmd.Parameters.AddWithValue('@SeedPlanFalseJson', (ConvertTo-DbNull $r.SeedPlanFalseJson))
        $null = $cmd.Parameters.AddWithValue('@UnsupportedReason', (ConvertTo-DbNull $r.UnsupportedReason))
        $null = $cmd.Parameters.AddWithValue('@ParserVersion', $ParserSignature)
        $null = $cmd.ExecuteNonQuery()
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Text') {
    # @(...) so a single-branch proc stays an array, not an unwrapped dict.
    $rows = @(Parse-OneProc -schema $TextSchema -proc $TextProcName -body $ProcText)
    foreach ($r in $rows) { [pscustomobject]$r }
    return
}

# DB mode.
$authPart = if ($SqlUser) { "User ID=$SqlUser;Password=$SqlPassword" } else { 'Integrated Security=SSPI' }
$connStr = "Server=$ServerInstance;Database=$Database;$authPart;TrustServerCertificate=True;Application Name=$ParserSignature"
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
try {
    # Staleness guard: the loaded ScriptDom's highest parser should be >= the
    # database compatibility level, else new T-SQL syntax may silently fail to
    # parse. TSqlNNNParser version == compat level (160 = SQL 2022, 170 = 2025).
    $compatCmd = $conn.CreateCommand()
    $compatCmd.CommandText = "SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()"
    $compat = [int]$compatCmd.ExecuteScalar()
    $asm = [Microsoft.SqlServer.TransactSql.ScriptDom.TSqlParser].Assembly
    $maxParser = ($asm.GetTypes() |
        Where-Object { $_.Name -match '^TSql(\d+)Parser$' } |
        ForEach-Object { [int]($_.Name -replace '\D','') } | Measure-Object -Maximum).Maximum
    if ($maxParser -lt $compat) {
        Write-Warning ("ScriptDom is STALE: highest parser is TSql${maxParser}Parser but database '$Database' " +
            "is at compatibility level $compat. Newer T-SQL syntax may fail to parse. Install a newer " +
            "ScriptDom (e.g. Update-Module SqlServer, or bundle the latest DLL) and re-run.")
    } else {
        Write-Verbose "ScriptDom parser TSql${maxParser}Parser >= DB compat $compat (OK)."
    }

    # Resolve target procedures.
    $procCmd = $conn.CreateCommand()
    if ($ProcName) {
        $procCmd.CommandText = "SELECT s.name AS sch, o.name AS nm, m.definition
            FROM sys.sql_modules m JOIN sys.objects o ON o.object_id=m.object_id
            JOIN sys.schemas s ON s.schema_id=o.schema_id
            WHERE o.type='P' AND s.name=@s AND o.name=@p"
        $null = $procCmd.Parameters.AddWithValue('@s', $Schema)
        $null = $procCmd.Parameters.AddWithValue('@p', $ProcName)
    } else {
        # -Schema '*' parses EVERY user procedure in the database in ONE process
        # (so the PowerShell+ScriptDom cold start is paid once and amortised over
        # the whole sweep). A specific -Schema parses just that schema. Either way
        # the framework schemas and instrumentation copies are skipped.
        $procCmd.CommandText = "SELECT s.name AS sch, o.name AS nm, m.definition
            FROM sys.sql_modules m JOIN sys.objects o ON o.object_id=m.object_id
            JOIN sys.schemas s ON s.schema_id=o.schema_id
            WHERE o.type='P' AND o.is_ms_shipped=0
              AND (@s = '*' OR s.name = @s)
              AND s.name NOT IN ('sys','tSQLt','TestGen','TestGenLog')
              AND s.name NOT LIKE 'test[_]%'
              AND o.name NOT LIKE '%[_]cov' AND o.name NOT LIKE '%[_]covfn' AND o.name NOT LIKE '%[_]orig'
            ORDER BY s.name, o.name"
        $null = $procCmd.Parameters.AddWithValue('@s', $Schema)
    }
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($procCmd)
    $dt = New-Object System.Data.DataTable
    $null = $da.Fill($dt)
    if ($dt.Rows.Count -eq 0) { Write-Warning "No procedures matched."; return }

    if ($Clear) {
        $clr = $conn.CreateCommand(); $clr.CommandText = 'TestGen.ClearPredicateInbox'
        $clr.CommandType = [System.Data.CommandType]::StoredProcedure
        # '*' (whole DB) -> no SchemaName filter, clears the inbox for the database.
        if ($Schema -ne '*') { $null = $clr.Parameters.AddWithValue('@SchemaName', $Schema) }
        if ($ProcName) { $null = $clr.Parameters.AddWithValue('@ProcName', $ProcName) }
        $null = $clr.ExecuteNonQuery()
    }

    $grand = 0; $unrec = 0
    foreach ($prow in $dt.Rows) {
        # @(...) so a single-branch proc stays an array; otherwise PS unwraps the
        # 1-element list to the ordered dict and .Count returns its key count.
        $rows = @(Parse-OneProc -schema $prow.sch -proc $prow.nm -body $prow.definition)
        $grand += $rows.Count
        $unrec += @($rows | Where-Object { $_.Shape -eq 'UNRECOGNISED' }).Count
        if ($WhatIf) { foreach ($r in $rows) { [pscustomobject]$r } }
        else { Write-InboxRows -conn $conn -runId $RunId -rows $rows }
    }
    if (-not $WhatIf) {
        Write-Host ("Wrote {0} ParsedPredicate rows ({1} UNRECOGNISED) under RunId {2}." -f $grand, $unrec, $RunId)
    }
}
finally { $conn.Close() }
