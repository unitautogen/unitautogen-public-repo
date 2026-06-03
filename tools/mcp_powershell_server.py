#!/usr/bin/env python3
"""
mcp_powershell_server.py - a tiny, zero-dependency MCP stdio server that runs
PowerShell on this Windows machine.

Why it exists
-------------
UnitAutogen's v0.10 predicate parser (powershell/UnitAutogen/Get-ParsedPredicates.ps1)
needs Windows + .NET + the ScriptDom assembly to run. The assistant's sandbox is
Linux and cannot execute it. This server exposes PowerShell as MCP tools so the
assistant can run and iterate on PowerShell (and any shell command) directly on
your box during development.

Protocol
--------
Implements just enough of MCP (JSON-RPC 2.0 over newline-delimited stdio):
  initialize, notifications/initialized, tools/list, tools/call, ping, shutdown.
No third-party packages required - standard library only. Works on Python 3.8+.

Tools
-----
  run_powershell        - run an inline PowerShell script block
  run_powershell_file   - run a .ps1 file with optional arguments
  run_shell             - run a raw command via cmd.exe (escape hatch)

SECURITY
--------
This server executes ARBITRARY PowerShell / shell commands on the host with the
privileges of whoever launched it. Only enable it for local development on a
machine you trust. It does no sandboxing. Set UAG_MCP_PSH to pin the shell.
"""

import json
import os
import shutil
import subprocess
import sys
import traceback

SERVER_NAME = "powershell"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"

# Default working directory: the repo root (two levels up from tools/).
DEFAULT_CWD = os.environ.get(
    "UAG_MCP_CWD",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
)

# Hard ceiling so a runaway script can't hang the session forever.
MAX_TIMEOUT = int(os.environ.get("UAG_MCP_MAX_TIMEOUT", "600"))


def _find_powershell():
    """Prefer PowerShell 7 (pwsh), fall back to Windows PowerShell 5.1."""
    override = os.environ.get("UAG_MCP_PSH")
    if override:
        return override
    for exe in ("pwsh", "pwsh.exe", "powershell", "powershell.exe"):
        found = shutil.which(exe)
        if found:
            return found
    return "powershell"  # last resort; let the OS resolve it


PSH = _find_powershell()


# --------------------------------------------------------------------------- #
# Command execution
# --------------------------------------------------------------------------- #
def _run(cmd_list, cwd, timeout):
    timeout = max(1, min(int(timeout or 120), MAX_TIMEOUT))
    cwd = cwd or DEFAULT_CWD
    if not os.path.isdir(cwd):
        cwd = DEFAULT_CWD
    try:
        proc = subprocess.run(
            cmd_list,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = proc.stdout or ""
        err = proc.stderr or ""
        body = (
            f"[exit code: {proc.returncode}]  (cwd: {cwd})\n"
            f"--- STDOUT ---\n{out}\n"
            f"--- STDERR ---\n{err}"
        )
        return body, proc.returncode != 0
    except subprocess.TimeoutExpired:
        return f"[TIMED OUT after {timeout}s]  (cwd: {cwd})", True
    except Exception as exc:  # noqa: BLE001
        return f"[execution error] {exc}\n{traceback.format_exc()}", True


def tool_run_powershell(args):
    script = args.get("script", "")
    if not script.strip():
        return "[error] 'script' is required and was empty.", True
    cmd = [
        PSH, "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-Command", script,
    ]
    return _run(cmd, args.get("cwd"), args.get("timeout"))


def tool_run_powershell_file(args):
    path = args.get("path", "")
    if not path.strip():
        return "[error] 'path' is required.", True
    if not os.path.isabs(path):
        path = os.path.join(args.get("cwd") or DEFAULT_CWD, path)
    if not os.path.isfile(path):
        return f"[error] file not found: {path}", True
    cmd = [
        PSH, "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", path,
    ]
    extra = args.get("args") or []
    if isinstance(extra, str):
        extra = [extra]
    cmd.extend(str(a) for a in extra)
    return _run(cmd, args.get("cwd"), args.get("timeout"))


def tool_run_shell(args):
    command = args.get("command", "")
    if not command.strip():
        return "[error] 'command' is required.", True
    cmd = ["cmd.exe", "/c", command] if os.name == "nt" else ["/bin/sh", "-c", command]
    return _run(cmd, args.get("cwd"), args.get("timeout"))


TOOLS = {
    "run_powershell": {
        "handler": tool_run_powershell,
        "schema": {
            "name": "run_powershell",
            "description": (
                "Run an inline PowerShell script block on the host and return "
                "exit code, stdout and stderr. Use for quick iteration on "
                "PowerShell code (e.g. the ScriptDom predicate parser)."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "script": {"type": "string", "description": "PowerShell code to execute."},
                    "cwd": {"type": "string", "description": "Working directory (defaults to repo root)."},
                    "timeout": {"type": "integer", "description": "Seconds before kill (default 120, max 600)."},
                },
                "required": ["script"],
            },
        },
    },
    "run_powershell_file": {
        "handler": tool_run_powershell_file,
        "schema": {
            "name": "run_powershell_file",
            "description": "Run a .ps1 file with optional positional arguments.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Path to the .ps1 (absolute, or relative to cwd)."},
                    "args": {"type": "array", "items": {"type": "string"}, "description": "Arguments passed after -File."},
                    "cwd": {"type": "string", "description": "Working directory (defaults to repo root)."},
                    "timeout": {"type": "integer", "description": "Seconds before kill (default 120, max 600)."},
                },
                "required": ["path"],
            },
        },
    },
    "run_shell": {
        "handler": tool_run_shell,
        "schema": {
            "name": "run_shell",
            "description": "Run a raw command via cmd.exe (Windows) or /bin/sh. Escape hatch for non-PowerShell tasks.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "Command line to execute."},
                    "cwd": {"type": "string", "description": "Working directory (defaults to repo root)."},
                    "timeout": {"type": "integer", "description": "Seconds before kill (default 120, max 600)."},
                },
                "required": ["command"],
            },
        },
    },
}


# --------------------------------------------------------------------------- #
# JSON-RPC plumbing (newline-delimited over stdio)
# --------------------------------------------------------------------------- #
def _send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def _result(req_id, result):
    _send({"jsonrpc": "2.0", "id": req_id, "result": result})


def _error(req_id, code, message):
    _send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def handle(req):
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    # Notifications (no id) require no response.
    if method == "notifications/initialized":
        return
    if method == "initialize":
        _result(req_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
        return
    if method == "ping":
        _result(req_id, {})
        return
    if method == "tools/list":
        _result(req_id, {"tools": [t["schema"] for t in TOOLS.values()]})
        return
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = TOOLS.get(name)
        if not tool:
            _error(req_id, -32602, f"Unknown tool: {name}")
            return
        try:
            text, is_error = tool["handler"](args)
        except Exception as exc:  # noqa: BLE001
            text, is_error = f"[handler crashed] {exc}\n{traceback.format_exc()}", True
        _result(req_id, {"content": [{"type": "text", "text": text}], "isError": bool(is_error)})
        return
    if method in ("shutdown", "exit"):
        _result(req_id, {})
        if method == "exit":
            sys.exit(0)
        return

    if req_id is not None:
        _error(req_id, -32601, f"Method not found: {method}")


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        try:
            handle(req)
        except Exception:  # noqa: BLE001
            # Never let a single bad message kill the server loop.
            traceback.print_exc(file=sys.stderr)


if __name__ == "__main__":
    main()
