<#
    mcp_powershell_server.ps1 - a zero-dependency MCP stdio server, written in
    PowerShell, that runs PowerShell / shell commands on this Windows machine.

    Use when no Python is available (the .py twin needs a real Python on PATH;
    the Microsoft Store 'python' alias does not work). Runs on Windows
    PowerShell 5.1 and PowerShell 7+. No modules required.

    Protocol: JSON-RPC 2.0 over newline-delimited stdio. Implements initialize,
    notifications/initialized, tools/list, tools/call, ping, shutdown/exit.

    Tools: run_powershell, run_powershell_file, run_shell. Each returns exit
    code + stdout + stderr. Commands run in CHILD processes so nothing they
    print can corrupt this server's stdout (which carries the protocol).

    SECURITY: runs arbitrary commands with the launching user's privileges and
    does no sandboxing. Enable only for trusted local development.

    Source is ASCII-only so encoding (BOM vs Windows-1252) is a non-issue.
#>

$ErrorActionPreference = 'Stop'

$ServerName    = 'powershell'
$ServerVersion = '0.2.0'
$ProtocolVersion = '2024-11-05'

$DefaultCwd = $env:UAG_MCP_CWD
if ([string]::IsNullOrWhiteSpace($DefaultCwd) -or -not (Test-Path $DefaultCwd)) {
    $DefaultCwd = Split-Path -Parent $PSScriptRoot   # repo root (tools\ -> repo)
    if ([string]::IsNullOrWhiteSpace($DefaultCwd)) { $DefaultCwd = (Get-Location).Path }
}
$MaxTimeoutSec = 600
if ($env:UAG_MCP_MAX_TIMEOUT) { [int]::TryParse($env:UAG_MCP_MAX_TIMEOUT, [ref]$MaxTimeoutSec) | Out-Null }

# ---------------------------------------------------------------------------
# stdout must carry ONLY JSON-RPC. Everything diagnostic goes to stderr.
# ---------------------------------------------------------------------------
function Write-Message($obj) {
    $json = $obj | ConvertTo-Json -Depth 25 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}
function Send-Result($id, $result) { Write-Message @{ jsonrpc = '2.0'; id = $id; result = $result } }
function Send-Error($id, $code, $message) { Write-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $message } } }

# ---------------------------------------------------------------------------
# Run a child process with stdout/stderr captured to temp files + a timeout.
# ---------------------------------------------------------------------------
function Invoke-Capture {
    param([string]$Exe, [string[]]$ArgList, [string]$Cwd, [int]$TimeoutSec)

    if ([string]::IsNullOrWhiteSpace($Cwd) -or -not (Test-Path $Cwd)) { $Cwd = $DefaultCwd }
    if ($TimeoutSec -le 0) { $TimeoutSec = 120 }
    if ($TimeoutSec -gt $MaxTimeoutSec) { $TimeoutSec = $MaxTimeoutSec }

    # Start-Process -ArgumentList joins array elements with spaces and does NOT
    # quote them, so any path containing a space (e.g. our repo "D:\Working
    # Files\...") would be split. Build a single, properly quoted arg string.
    $argString = ($ArgList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $argString -WorkingDirectory $Cwd `
                -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            return @{ text = "[TIMED OUT after $TimeoutSec s]  (cwd: $Cwd)"; isError = $true }
        }
        $p.WaitForExit()          # ensure ExitCode is populated (Start-Process -PassThru quirk)
        $out = (Get-Content -Raw -ErrorAction SilentlyContinue $outFile)
        $err = (Get-Content -Raw -ErrorAction SilentlyContinue $errFile)
        $code = $p.ExitCode
        if ($null -eq $code) { $code = 0 }
        $body = "[exit code: $code]  (cwd: $Cwd)`n--- STDOUT ---`n$out`n--- STDERR ---`n$err"
        return @{ text = $body; isError = ($code -ne 0) }
    }
    catch {
        return @{ text = "[execution error] $($_.Exception.Message)"; isError = $true }
    }
    finally {
        Remove-Item -ErrorAction SilentlyContinue $outFile, $errFile
    }
}

function Get-PwshExe {
    if ($env:UAG_MCP_PSH) { return $env:UAG_MCP_PSH }
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    return (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

# ---------------------------------------------------------------------------
# Tool handlers.
# ---------------------------------------------------------------------------
function Tool-RunPowerShell($ToolArgs) {
    $script = [string]$ToolArgs.script
    if ([string]::IsNullOrWhiteSpace($script)) { return @{ text = "[error] 'script' is required."; isError = $true } }
    $tmp = [System.IO.Path]::GetTempFileName() + '.ps1'
    Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
    try {
        $exe = Get-PwshExe
        $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tmp)
        return Invoke-Capture -Exe $exe -ArgList $a -Cwd ([string]$ToolArgs.cwd) -TimeoutSec ([int]$ToolArgs.timeout)
    }
    finally { Remove-Item -ErrorAction SilentlyContinue $tmp }
}

function Tool-RunPowerShellFile($ToolArgs) {
    $path = [string]$ToolArgs.path
    if ([string]::IsNullOrWhiteSpace($path)) { return @{ text = "[error] 'path' is required."; isError = $true } }
    $cwd = [string]$ToolArgs.cwd
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $base = if ([string]::IsNullOrWhiteSpace($cwd)) { $DefaultCwd } else { $cwd }
        $path = Join-Path $base $path
    }
    if (-not (Test-Path -LiteralPath $path)) { return @{ text = "[error] file not found: $path"; isError = $true } }
    $exe = Get-PwshExe
    $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $path)
    if ($ToolArgs.args) { foreach ($x in @($ToolArgs.args)) { $a += [string]$x } }
    return Invoke-Capture -Exe $exe -ArgList $a -Cwd $cwd -TimeoutSec ([int]$ToolArgs.timeout)
}

function Tool-RunShell($ToolArgs) {
    $command = [string]$ToolArgs.command
    if ([string]::IsNullOrWhiteSpace($command)) { return @{ text = "[error] 'command' is required."; isError = $true } }
    return Invoke-Capture -Exe 'cmd.exe' -ArgList @('/c', $command) -Cwd ([string]$ToolArgs.cwd) -TimeoutSec ([int]$ToolArgs.timeout)
}

$ToolSchemas = @(
    @{ name = 'run_powershell'
       description = 'Run an inline PowerShell script block on the host and return exit code, stdout and stderr. Use for quick iteration on PowerShell code (e.g. the ScriptDom predicate parser).'
       inputSchema = @{ type = 'object'; required = @('script')
           properties = @{
               script  = @{ type = 'string'; description = 'PowerShell code to execute.' }
               cwd     = @{ type = 'string'; description = 'Working directory (defaults to repo root).' }
               timeout = @{ type = 'integer'; description = 'Seconds before kill (default 120, max 600).' } } } },
    @{ name = 'run_powershell_file'
       description = 'Run a .ps1 file with optional positional arguments.'
       inputSchema = @{ type = 'object'; required = @('path')
           properties = @{
               path    = @{ type = 'string'; description = 'Path to the .ps1 (absolute, or relative to cwd).' }
               args    = @{ type = 'array'; items = @{ type = 'string' }; description = 'Arguments passed after -File.' }
               cwd     = @{ type = 'string'; description = 'Working directory (defaults to repo root).' }
               timeout = @{ type = 'integer'; description = 'Seconds before kill (default 120, max 600).' } } } },
    @{ name = 'run_shell'
       description = 'Run a raw command via cmd.exe. Escape hatch for non-PowerShell tasks.'
       inputSchema = @{ type = 'object'; required = @('command')
           properties = @{
               command = @{ type = 'string'; description = 'Command line to execute.' }
               cwd     = @{ type = 'string'; description = 'Working directory (defaults to repo root).' }
               timeout = @{ type = 'integer'; description = 'Seconds before kill (default 120, max 600).' } } } }
)

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
function Invoke-Tool($name, $arguments) {
    switch ($name) {
        'run_powershell'      { return Tool-RunPowerShell $arguments }
        'run_powershell_file' { return Tool-RunPowerShellFile $arguments }
        'run_shell'           { return Tool-RunShell $arguments }
        default               { return $null }
    }
}

function Handle-Request($req) {
    $method = [string]$req.method
    $id = $req.id
    $params = $req.params

    if ($method -eq 'notifications/initialized') { return }
    if ($method -eq 'initialize') {
        Send-Result $id @{ protocolVersion = $ProtocolVersion; capabilities = @{ tools = @{} };
                           serverInfo = @{ name = $ServerName; version = $ServerVersion } }
        return
    }
    if ($method -eq 'ping') { Send-Result $id @{}; return }
    if ($method -eq 'tools/list') { Send-Result $id @{ tools = $ToolSchemas }; return }
    if ($method -eq 'tools/call') {
        $name = [string]$params.name
        $arguments = $params.arguments
        $res = Invoke-Tool $name $arguments
        if ($null -eq $res) { Send-Error $id -32602 "Unknown tool: $name"; return }
        Send-Result $id @{ content = @( @{ type = 'text'; text = [string]$res.text } ); isError = [bool]$res.isError }
        return
    }
    if ($method -eq 'shutdown') { Send-Result $id @{}; return }
    if ($method -eq 'exit') { Send-Result $id @{}; exit 0 }

    if ($null -ne $id) { Send-Error $id -32601 "Method not found: $method" }
}

# ---------------------------------------------------------------------------
# Main loop: read newline-delimited JSON from stdin.
# ---------------------------------------------------------------------------
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }   # EOF
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }
    try {
        $req = $line | ConvertFrom-Json
    }
    catch { continue }
    try { Handle-Request $req }
    catch { [Console]::Error.WriteLine("[server] $($_.Exception.Message)") }
}
