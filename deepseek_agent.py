#!/usr/bin/env python3
"""DeepSeek agentic coding loop: read/write files, list directories, grep,
run a verify command, iterate until passing."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from openai import OpenAI
from openai.types.shared_params import FunctionDefinition

# Import constants and helper from the existing module.
from implement_with_deepseek import _resolve_api_key, DEEPSEEK_MODEL, DEEPSEEK_FLASH, DEEPSEEK_BASE_URL

# --------------------------------------------------------------------------- #
# Tool definitions (OpenAI function calling format)
# --------------------------------------------------------------------------- #

TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": FunctionDefinition(
            name="read_file",
            description="Read the contents of a file path relative to the repo root. Returns the file content or an error string.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path to the file from the repo root (e.g. 'src/main.py').",
                    }
                },
                "required": ["path"],
            },
        ),
    },
    {
        "type": "function",
        "function": FunctionDefinition(
            name="write_file",
            description="Write content to a file path relative to the repo root. Creates parent directories as needed. Returns 'ok' or an error string.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path to the file from the repo root (e.g. 'src/main.py').",
                    },
                    "content": {
                        "type": "string",
                        "description": "Full content to write to the file.",
                    },
                },
                "required": ["path", "content"],
            },
        ),
    },
    {
        "type": "function",
        "function": FunctionDefinition(
            name="list_dir",
            description="List entries directly under a repo‑relative directory. Empty string or '.' means repo root. Directories have a trailing '/'. Returns newline‑separated listing or an error string.",
            parameters={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative path to the directory from the repo root (e.g. 'src'). Empty or '.' for root.",
                    }
                },
                "required": ["path"],
            },
        ),
    },
    {
        "type": "function",
        "function": FunctionDefinition(
            name="grep",
            description="Search text files under a repo‑relative path for a pattern (regex, falls back to plain substring). Returns lines as 'relative/path:lineno: line', up to ~100 matches, truncated if more. Skips binary files. Path can be file or directory; empty or '.' means repo root.",
            parameters={
                "type": "object",
                "properties": {
                    "pattern": {
                        "type": "string",
                        "description": "Regex pattern to search for (will fall back to plain substring if invalid).",
                    },
                    "path": {
                        "type": "string",
                        "description": "Relative path to search in (file or directory). Empty or '.' for repo root.",
                    },
                },
                "required": ["pattern", "path"],
            },
        ),
    },
    {
        "type": "function",
        "function": FunctionDefinition(
            name="run_tests",
            description="Run the configured verify command in the repo root. Returns exit code and combined output.",
            parameters={
                "type": "object",
                "properties": {},
            },
        ),
    },
    {
        "type": "function",
        "function": FunctionDefinition(
            name="done",
            description="Call this when the task is complete and the verify command (if set) passes. Provide a short summary of what was changed.",
            parameters={
                "type": "object",
                "properties": {
                    "summary": {
                        "type": "string",
                        "description": "Brief summary of what the agent changed.",
                    }
                },
                "required": ["summary"],
            },
        ),
    },
]

SYSTEM_PROMPT = (
    "You are a coding agent implementing a given task on a local codebase. "
    "You have tools to read and write files, list directories, grep, and run a verification command. "
    "Work iteratively: read files, make changes, run the verification command, "
    "and fix any failures. Only call 'done' when the verification command passes "
    "(or if no verification command is set, when you are confident the task is complete). "
    "Do not call done prematurely. If a tool returns an error, fix it and retry."
)

MAX_TOOL_OUTPUT_CHARS = 6000


def _resolve_repo_path(repo_dir: str) -> Path:
    """Return resolved absolute repo path, ensure it's a clean git repo."""
    repo = Path(repo_dir).resolve()
    # Check is a git repo
    git_dir = repo / ".git"
    if not git_dir.is_dir():
        sys.exit(f"Error: {repo} is not a git repository (no .git directory).")
    # Check working tree is clean
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        sys.exit("Error: git status command timed out.")
    if result.returncode != 0:
        sys.exit(f"Error: failed to run git status in {repo}.")
    if result.stdout.strip():
        sys.exit(
            f"Error: working tree in {repo} is not clean. "
            "Please commit or stash changes before running the agent."
        )
    return repo


def _safe_path(repo_root: Path, user_path: str) -> str | None:
    """Resolve user_path under repo_root. Return the absolute path, or None if it escapes.

    repo_root must already be resolved. Containment is checked structurally (is repo_root
    the target or one of its parents), not by string prefix, so a sibling directory that
    merely shares a name prefix (e.g. '<repo>-evil') cannot slip through.
    """
    try:
        target = (repo_root / user_path).resolve()
    except (ValueError, OSError):
        return None
    if target == repo_root or repo_root in target.parents:
        return str(target)
    return None


def _truncate_output(text: str, max_chars: int = MAX_TOOL_OUTPUT_CHARS) -> str:
    """Truncate text to keep the tail (most recent output)."""
    if len(text) <= max_chars:
        return text
    snippet = text[-max_chars:]
    return f"... output truncated, showing last {max_chars} characters:\n{snippet}"


def _list_dir(repo_root: Path, user_path: str) -> str:
    """Return directory listing as newline‑separated string. Mark dirs with trailing '/'.
    Treat empty string or '.' as root. Returns error for invalid/outside paths."""
    if user_path == "" or user_path == ".":
        abs_path = str(repo_root)
    else:
        abs_path = _safe_path(repo_root, user_path)
        if abs_path is None:
            return f"Error: path '{user_path}' is outside the repo root."
    if not os.path.isdir(abs_path):
        return f"Error: path '{user_path}' is not a directory."
    try:
        entries = os.listdir(abs_path)
    except PermissionError:
        return f"Error: permission denied reading '{user_path}'."
    lines = []
    for e in sorted(entries):
        full = os.path.join(abs_path, e)
        if os.path.isdir(full):
            lines.append(e + "/")
        else:
            lines.append(e)
    return "\n".join(lines)


def _grep(repo_root: Path, pattern: str, user_path: str) -> str:
    """Search recursively under user_path for pattern. user_path can be file or dir.
    Return lines as 'relative/path:lineno: line', up to 100 matches, truncated if more.
    Silently skip binary/unreadable files. Fallback from regex to plain substring."""
    # Determine root path for search
    if user_path == "" or user_path == ".":
        abs_root = str(repo_root)
    else:
        abs_root = _safe_path(repo_root, user_path)
        if abs_root is None:
            return f"Error: path '{user_path}' is outside the repo root."
    if not os.path.exists(abs_root):
        return f"Error: path '{user_path}' does not exist."

    # Compile regex; fallback to plain substring
    try:
        regex = re.compile(pattern)
        use_regex = True
    except re.error:
        use_regex = False
        lower_pattern = pattern.lower()

    max_results = 100
    results: list[str] = []
    skipped_binary = 0
    skipped_decode = 0

    # Collect file paths
    if os.path.isfile(abs_root):
        files = [abs_root]
    else:
        files = []
        for dirpath, _, filenames in os.walk(abs_root):
            for fn in filenames:
                files.append(os.path.join(dirpath, fn))

    for fpath in files:
        # Check containment (should be inside repo)
        if _safe_path(repo_root, os.path.relpath(fpath, repo_root)) is None:
            continue
        relative = os.path.relpath(fpath, repo_root)
        # Try to read text
        try:
            with open(fpath, "r", encoding="utf-8", errors="strict") as f:
                lines = f.readlines()
        except (UnicodeDecodeError, PermissionError, OSError):
            skipped_binary += 1
            continue
        # Actually read lines for safety: open again? We already read lines.
        # But we already read them, so fine.
        for lineno, line in enumerate(lines, 1):
            if use_regex:
                if regex.search(line):
                    results.append(f"{relative}:{lineno}: {line.rstrip()}")
            else:
                if lower_pattern in line.lower():
                    results.append(f"{relative}:{lineno}: {line.rstrip()}")
            if len(results) >= max_results:
                break
        if len(results) >= max_results:
            break

    output = "\n".join(results)
    if len(results) >= max_results:
        output += f"\n... (truncated, showing first {max_results} matches)"
    # Append skipped info if any
    if skipped_binary > 0:
        output += f"\n(skipped {skipped_binary} binary/unreadable files)"
    return output


def main() -> None:
    # Model output (summaries, diffs, failed-leg reports) is UTF-8; force stdout so
    # non-ASCII (em dashes, arrows, box chars) can't crash printing on a legacy
    # Windows console codepage.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(
        description="DeepSeek agentic coding loop: implement a task by reading/writing files, listing directories, searching with grep, and running a verify command."
    )
    parser.add_argument("task", type=str, help="Task: file path or inline text")
    parser.add_argument("--verify", type=str, default=None, help="Verification command (e.g. 'pytest -q')")
    parser.add_argument("--repo", type=str, default=".", help="Working directory (default: cwd)")
    parser.add_argument("--flash", action="store_true", help="Use flash model instead of pro")
    parser.add_argument("--max-steps", type=int, default=25, help="Maximum iterations (default: 25)")
    args = parser.parse_args()

    # ---------------------------------------------------------------
    # Validate TASK
    # ---------------------------------------------------------------
    task_text: str
    task_path = Path(args.task)
    if task_path.is_file():
        task_text = task_path.read_text(encoding="utf-8")
    else:
        task_text = args.task.strip()
    if not task_text:
        sys.exit("Error: TASK is empty.")

    # ---------------------------------------------------------------
    # Validate repo
    # ---------------------------------------------------------------
    repo = _resolve_repo_path(args.repo)

    # ---------------------------------------------------------------
    # Setup OpenAI client with DeepSeek
    # ---------------------------------------------------------------
    api_key = _resolve_api_key()
    model = DEEPSEEK_FLASH if args.flash else DEEPSEEK_MODEL
    client = OpenAI(api_key=api_key, base_url=DEEPSEEK_BASE_URL)

    # ---------------------------------------------------------------
    # Build messages
    # ---------------------------------------------------------------
    if args.verify:
        verify_msg = f"Verification command: {args.verify}"
    else:
        verify_msg = "No verification command is configured. Complete the task without verification."

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": f"Task: {task_text}\n\n{verify_msg}"},
    ]

    # ---------------------------------------------------------------
    # Agent loop
    # ---------------------------------------------------------------
    step_count = 0
    finished = False
    done_summary: str | None = None

    while step_count < args.max_steps:
        step_count += 1
        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                tools=TOOLS,
                tool_choice="auto",
            )
        except Exception as e:
            sys.exit(f"Error calling DeepSeek API: {e}")

        assistant_msg = response.choices[0].message

        # If assistant message has no tool calls, we're done (plain text)
        if not assistant_msg.tool_calls:
            messages.append({"role": "assistant", "content": assistant_msg.content or ""})
            finished = True
            break

        # Append the assistant message with tool calls to history
        assistant_dict = {"role": "assistant", "content": assistant_msg.content or ""}
        # OpenAI expects tool_calls as list of dicts
        assistant_dict["tool_calls"] = [
            {
                "id": tc.id,
                "type": "function",
                "function": {"name": tc.function.name, "arguments": tc.function.arguments},
            }
            for tc in assistant_msg.tool_calls
        ]
        messages.append(assistant_dict)

        # Execute each tool call
        for tc in assistant_msg.tool_calls:
            func_name = tc.function.name
            func_args_str = tc.function.arguments
            try:
                func_args = json.loads(func_args_str)
            except json.JSONDecodeError:
                result = f"Error: invalid JSON arguments for {func_name}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )
                continue

            if func_name == "read_file":
                path_arg = func_args.get("path")
                if not path_arg:
                    result = "Error: missing path argument"
                else:
                    abs_path = _safe_path(repo, path_arg)
                    if abs_path is None:
                        result = f"Error: path '{path_arg}' is outside the repo root."
                    else:
                        try:
                            with open(abs_path, "r", encoding="utf-8") as f:
                                content = f.read()
                            result = _truncate_output(content)
                        except FileNotFoundError:
                            result = f"Error: file not found: {path_arg}"
                        except Exception as e:
                            result = f"Error reading file: {e}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

            elif func_name == "write_file":
                path_arg = func_args.get("path")
                content_arg = func_args.get("content")
                if not path_arg or content_arg is None:
                    result = "Error: missing path or content"
                else:
                    abs_path = _safe_path(repo, path_arg)
                    if abs_path is None:
                        result = f"Error: path '{path_arg}' is outside the repo root."
                    else:
                        try:
                            dir_path = os.path.dirname(abs_path)
                            if dir_path:
                                os.makedirs(dir_path, exist_ok=True)
                            with open(abs_path, "w", encoding="utf-8") as f:
                                f.write(content_arg)
                            result = "ok"
                        except Exception as e:
                            result = f"Error writing file: {e}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

            elif func_name == "list_dir":
                path_arg = func_args.get("path", "")
                result = _list_dir(repo, path_arg)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

            elif func_name == "grep":
                pattern_arg = func_args.get("pattern")
                path_arg = func_args.get("path", "")
                if not pattern_arg:
                    result = "Error: missing pattern argument"
                else:
                    result = _grep(repo, pattern_arg, path_arg)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

            elif func_name == "run_tests":
                if not args.verify:
                    result = "No verify command is configured, so no tests were run."
                else:
                    try:
                        proc = subprocess.run(
                            args.verify,
                            shell=True,
                            cwd=repo,
                            capture_output=True,
                            text=True,
                            timeout=120,
                        )
                        output = proc.stdout + proc.stderr
                        exit_code = proc.returncode
                        result = f"Exit code: {exit_code}\n\n{_truncate_output(output)}"
                    except subprocess.TimeoutExpired:
                        result = "Error: verify command timed out (120s)."
                    except Exception as e:
                        result = f"Error running verify command: {e}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

            elif func_name == "done":
                done_summary = func_args.get("summary", "No summary provided.")
                finished = True
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": f"done called with summary: {done_summary}",
                    }
                )
                break

            else:
                result = f"Error: unknown tool {func_name}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": result,
                    }
                )

        # If done was called, break the outer loop
        if finished:
            break

    # ---------------------------------------------------------------
    # Determine final status
    # ---------------------------------------------------------------
    if finished and done_summary is not None:
        status = f"FINISHED after {step_count} step(s)."
    elif finished:
        # assistant plain text, no done call
        status = f"FINISHED (no done call) after {step_count} step(s)."
    else:
        status = f"UNFINISHED (hit step cap of {args.max_steps}) after {step_count} step(s)."

    # ---------------------------------------------------------------
    # Final output
    # ---------------------------------------------------------------
    print(status)
    if done_summary:
        print(f"Agent summary: {done_summary}")

    # Re-run verify if configured
    if args.verify:
        try:
            proc = subprocess.run(
                args.verify,
                shell=True,
                cwd=repo,
                capture_output=True,
                text=True,
                timeout=120,
            )
            final_exit = proc.returncode
            if final_exit == 0:
                verdict = "PASS"
            else:
                verdict = "FAIL"
            print(f"Final verify command ({args.verify}): {verdict}")
            print(proc.stdout + proc.stderr)
        except subprocess.TimeoutExpired:
            print("Final verify command timed out.")
        except Exception as e:
            print(f"Error running final verify command: {e}")

    # ---------------------------------------------------------------
    # Failed-leg report (only on UNFINISHED)
    # ---------------------------------------------------------------
    if not finished:
        # Make one additional model call asking for a failure report
        try:
            fail_messages = messages.copy()
            fail_messages.append({
                "role": "user",
                "content": (
                    "You have hit the step limit. In plain prose, summarize what you changed, "
                    "what is still failing, and your best diagnosis of why you could not finish."
                )
            })
            fail_response = client.chat.completions.create(
                model=model,
                messages=fail_messages,
                # No tools – just produce a plain text response
            )
            fail_text = fail_response.choices[0].message.content or ""
            print("\n--- Failed-leg report ---")
            print(fail_text)
        except Exception as e:
            print(f"\n--- Failed-leg report (could not generate: {e}) ---")

    # Git diff of tracked changes
    try:
        diff_result = subprocess.run(
            ["git", "diff"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=30,
        )
        diff_text = diff_result.stdout.strip()
        if diff_text:
            print("--- Git diff (tracked changes) ---")
            print(diff_text)
        else:
            print("No tracked file changes (git diff is empty).")
    except Exception as e:
        print(f"Error getting git diff: {e}")

    # List untracked new files
    try:
        untracked_result = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            cwd=repo,
            capture_output=True,
            text=True,
            timeout=30,
        )
        untracked_files = untracked_result.stdout.strip().split("\n") if untracked_result.stdout.strip() else []
        if untracked_files:
            print("--- Untracked new files ---")
            for f in untracked_files:
                print(f)
        else:
            print("No untracked files.")
    except Exception as e:
        print(f"Error listing untracked files: {e}")


if __name__ == "__main__":
    main()
