#!/usr/bin/env python3
"""
routing_gate.py - PreToolUse hook that enforces the Routing gate.

Wired on Write|Edit|MultiEdit. It blocks an edit to a *code* file unless a fresh
routing decision was recorded in `.claude/routing-ack` (project-relative). This turns the
"state your Routing first" rule from advisory prose into a mechanical precondition.

What it can and cannot do: it enforces that a routing decision was *recorded* before code is
written - a gesture, not a guarantee the decision was sound. A stale-but-fresh ack from the
previous task will still pass. The substance still lives in CLAUDE.md and the `Routing:` line
you emit in the transcript; this only raises the floor above "wrote code with zero routing step".

Contract (Claude Code hooks):
- Reads a JSON event on stdin: {"tool_name": ..., "tool_input": {"file_path": ...}, ...}.
- exit 0  -> allow the tool call.
- exit 2  -> block it; stderr is fed back to the model as the reason.

To record a decision, write the chosen route to `.claude/routing-ack` (edits under
`.claude/` are always allowed, so this never deadlocks):
    echo "Routing: deepseek-agent - multi-file, testable" > .claude/routing-ack
"""

import json
import os
import sys
import time

# How long a recorded routing decision stays valid, in seconds.
FRESH_SECONDS = int(os.environ.get("ROUTING_ACK_TTL", "900"))
MARKER = os.path.join(".claude", "routing-ack")

# Non-code files never require a routing decision (docs, config, lockfiles, the marker).
EXEMPT_EXTS = {
    ".md", ".mdx", ".txt", ".rst", ".json", ".jsonc", ".yml", ".yaml", ".toml",
    ".ini", ".cfg", ".conf", ".lock", ".gitignore", ".env", ".example", ".csv",
}


def _rel(path: str) -> str:
    try:
        return os.path.relpath(path, os.getcwd())
    except ValueError:
        return path  # different drive on Windows; treat as outside


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0  # never break the session on a malformed event

    file_path = (event.get("tool_input") or {}).get("file_path", "")
    if not file_path:
        return 0

    rel = _rel(file_path).replace("\\", "/")

    # Always-allowed targets: anything under .claude/ (incl. the marker) and non-code files.
    if rel.startswith(".claude/") or rel == ".claude":
        return 0
    _, ext = os.path.splitext(rel)
    if ext.lower() in EXEMPT_EXTS:
        return 0

    # Code file: require a fresh routing decision.
    if os.path.isfile(MARKER) and (time.time() - os.path.getmtime(MARKER)) <= FRESH_SECONDS:
        return 0

    sys.stderr.write(
        "Routing gate: no fresh routing decision on record before editing code.\n"
        f"Editing: {rel}\n"
        "State a `Routing:` line (direct | deepseek-oneshot | deepseek-agent | pipeline) per "
        "CLAUDE.md, then record it:\n"
        '    echo "Routing: <route> - <reason>" > .claude/routing-ack\n'
        "Then retry the edit. If the honest route is `direct`, record that too - the gate only "
        "checks that a decision was made, not which one.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
