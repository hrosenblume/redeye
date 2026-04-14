#!/usr/bin/env python3
"""Redeye MCP server — control Redeye tmux sessions from any Claude Code session."""

import json
import os
import plistlib
import subprocess
from typing import Optional

from fastmcp import FastMCP

BUNDLE_ID = "com.hrosenblume.redeye"
SCRIPT_PATH = "/Applications/Redeye.app/Contents/Resources/claude-ordo-keepalive.sh"
TIMEOUT = 10


# -- Helpers ------------------------------------------------------------------

def _run_script(action: str, session: str, *args: str) -> str:
    """Call the keepalive shell script and return stdout."""
    cmd = ["/bin/bash", SCRIPT_PATH, action, session, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    return result.stdout.strip()


def _session_prefix(path: str) -> str:
    """Replicate Swift's Project.sessionPrefix (FNV-1a hash)."""
    name = os.path.basename(path)
    safe = name.lower().replace(" ", "-")
    safe = "".join(c for c in safe if c.isalpha() or c.isdigit() or c == "-")
    h = 2166136261
    for byte in path.encode("utf-8"):
        h ^= byte
        h = (h * 16777619) & 0xFFFFFFFF
    return f"redeye-{safe}-{h % 0xFFFFFF:x}"


def _display_name(path: str, session_name: str) -> str:
    """Replicate Swift's displayName(session:project:)."""
    name = os.path.basename(path)
    safe = name.lower().replace(" ", "-")
    safe = "".join(c for c in safe if c.isalpha() or c.isdigit() or c == "-")
    idx = session_name.rsplit("-", 1)[-1]
    return f"redeye-{safe}-{idx}"


def _read_projects() -> list[dict]:
    """Read the project list from Redeye's UserDefaults."""
    result = subprocess.run(
        ["defaults", "export", BUNDLE_ID, "-"],
        capture_output=True, timeout=TIMEOUT,
    )
    if result.returncode != 0:
        return []
    plist = plistlib.loads(result.stdout)
    raw = plist.get("projects")
    if raw is None:
        return []
    data = raw if isinstance(raw, str) else raw.decode("utf-8")
    return json.loads(data)


def _list_tmux_sessions(prefix: str) -> list[dict]:
    """List tmux sessions matching a prefix, with status."""
    raw = _run_script("list", prefix)
    sessions = []
    for line in raw.splitlines():
        if ":" not in line:
            continue
        name, attached = line.split(":", 1)
        status = "attached" if int(attached or 0) > 0 else "running"
        sessions.append({"session_name": name, "status": status})
    return sessions


def _session_status(session_name: str) -> str:
    return _run_script("status", session_name)


def _next_session_name(prefix: str) -> str:
    """Find the lowest available -NN slot, matching Swift's nextSessionName."""
    alive = _list_tmux_sessions(prefix)
    taken = set()
    for s in alive:
        parts = s["session_name"].rsplit("-", 1)
        if len(parts) == 2:
            try:
                taken.add(int(parts[1]))
            except ValueError:
                pass
    n = 1
    while n in taken:
        n += 1
    return f"{prefix}-{n:02d}"


# -- MCP Server --------------------------------------------------------------

mcp = FastMCP(
    name="redeye",
    instructions=(
        "Redeye manages Claude Code tmux sessions in the background. "
        "Use these tools to list projects, start/stop sessions, read output, "
        "and send input — all without touching the Redeye menu bar."
    ),
)


@mcp.tool()
def redeye_list_projects() -> list[dict]:
    """List all projects configured in Redeye with their status."""
    projects = _read_projects()
    result = []
    for p in projects:
        path = p["path"]
        prefix = _session_prefix(path)
        result.append({
            "path": path,
            "name": os.path.basename(path),
            "enabled": p.get("enabled", False),
            "permissionMode": p.get("permissionMode"),
            "sessionPrefix": prefix,
            "folderExists": os.path.isdir(path),
        })
    return result


@mcp.tool()
def redeye_list_sessions(project_path: Optional[str] = None) -> list[dict]:
    """List running Redeye sessions. Optionally filter by project path."""
    if project_path:
        prefix = _session_prefix(project_path)
    else:
        prefix = "redeye-"
    sessions = _list_tmux_sessions(prefix)
    # Refine status with per-session check (list only gives attached count)
    for s in sessions:
        s["status"] = _session_status(s["session_name"])
    return sessions


@mcp.tool()
def redeye_start_session(
    project_path: str,
    permission_mode: Optional[str] = None,
) -> dict:
    """Start a new Claude Code session for a project.

    Args:
        project_path: Full path to the project directory.
        permission_mode: Optional. "dangerously-skip-permissions" to skip, or omit for default.
    """
    if not os.path.isdir(project_path):
        return {"error": f"directory does not exist: {project_path}"}

    prefix = _session_prefix(project_path)
    session = _next_session_name(prefix)
    dname = _display_name(project_path, session)

    args = [project_path, dname]
    if permission_mode and permission_mode != "default":
        args.append(permission_mode)

    result = _run_script("start", session, *args)
    return {"session_name": session, "result": result}


@mcp.tool()
def redeye_stop_session(session_name: str) -> dict:
    """Stop a running Redeye session.

    Args:
        session_name: The tmux session name (e.g. redeye-myproject-a1b2c3-01).
    """
    result = _run_script("stop", session_name)
    return {"session_name": session_name, "result": result}


@mcp.tool()
def redeye_capture_output(session_name: str) -> dict:
    """Capture the last ~10 lines of output from a session.

    Args:
        session_name: The tmux session name.
    """
    output = _run_script("capture", session_name)
    return {"session_name": session_name, "output": output}


@mcp.tool()
def redeye_send_keys(session_name: str, keys: str) -> dict:
    """Send keyboard input to a session.

    Args:
        session_name: The tmux session name.
        keys: tmux key notation — literal text, or special keys like "Enter", "Escape".
    """
    result = _run_script("send", session_name, keys)
    return {"session_name": session_name, "result": result}


if __name__ == "__main__":
    mcp.run()
