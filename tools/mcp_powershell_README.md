# PowerShell MCP server

A tiny, **zero-dependency** MCP stdio server that lets the assistant run
PowerShell on this Windows machine. Built so the v0.10 ScriptDom predicate
parser (`powershell/UnitAutogen/Get-ParsedPredicates.ps1`), which needs
Windows + .NET + ScriptDom, can be run and iterated on directly instead of only
static-checked.

Two interchangeable implementations are provided:

| File | Runtime | Use when |
| --- | --- | --- |
| `mcp_powershell_server.ps1` | Windows PowerShell 5.1 (built in) | **Recommended.** No Python needed. |
| `mcp_powershell_server.py`  | Python 3.8+ on PATH | Only if you prefer Python *and* have a real `python` (the Microsoft Store `python` alias does NOT work). |

`mcp_powershell_config.json` is preconfigured for the **PowerShell** variant.
Both expose identical tools and run commands in child processes so nothing they
print can corrupt the protocol stream.

## Tools exposed

| Tool | Purpose |
| --- | --- |
| `run_powershell` | Run an inline PowerShell script block. |
| `run_powershell_file` | Run a `.ps1` file with optional arguments. |
| `run_shell` | Run a raw `cmd.exe` command (escape hatch). |

Each returns exit code + stdout + stderr. Default working directory is the repo
root; default timeout 120s (cap 600s).

## Setup (Claude desktop / Cowork)

1. Open the Claude desktop config file:

   ```
   %APPDATA%\Claude\claude_desktop_config.json
   ```

   (Full path on this machine:
   `C:\Users\munaf\AppData\Roaming\Claude\claude_desktop_config.json`.)

2. Merge the `mcpServers` block from `mcp_powershell_config.json` (in this
   folder) into that file. If the file already has an `mcpServers` object, add
   the `"powershell"` key inside it rather than replacing the whole object. The
   shipped config uses `powershell.exe` and needs no Python.

3. **Fully quit and reopen** the Claude desktop app (not just the window).
   The `powershell` tools should then be available.

### Claude Code (CLI) alternative

If you drive this through Claude Code instead, register it once:

```
claude mcp add powershell -- python "D:\Working Files\ai\tsqlt Automation\tsqltAutoGen\unitautogen-public-repo\unitautogen-public-repo\tools\mcp_powershell_server.py"
```

## Quick self-test

From the repo root:

```
echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}} | python tools\mcp_powershell_server.py
```

You should get a JSON line back with `"serverInfo": {"name": "powershell" ...}`.

## Optional environment variables

| Var | Effect |
| --- | --- |
| `UAG_MCP_CWD` | Default working directory for commands. |
| `UAG_MCP_PSH` | Pin the shell (e.g. full path to `pwsh.exe`). Otherwise prefers `pwsh`, falls back to `powershell.exe`. |
| `UAG_MCP_MAX_TIMEOUT` | Hard ceiling (seconds) on any single command. |

## Security

This server runs **arbitrary** PowerShell / shell commands with your user's
privileges and does no sandboxing. Only enable it for local development on a
machine you trust. Remove the `powershell` block from the config (and restart)
to disable it.
