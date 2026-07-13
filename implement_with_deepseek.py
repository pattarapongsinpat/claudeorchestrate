#!/usr/bin/env python3
"""DeepSeek implementation dispatcher: send a spec, return code (or a plan via --plan).

The escalation ladder lives in the Claude session, not here; this is just the dispatch.
DEEPSEEK_API_KEY resolves from the environment, then ~/.claude/.env, then ./.env.
See CLAUDE.md for usage and the full workflow.
"""

import os
import sys
import argparse

from openai import OpenAI  # DeepSeek is OpenAI-compatible

DEEPSEEK_MODEL = "deepseek-v4-pro"            # default
DEEPSEEK_FLASH = "deepseek-v4-flash"          # --flash
DEEPSEEK_BASE_URL = "https://api.deepseek.com"

SYSTEM = (
    "You are an implementation engineer. You are given a precise specification "
    "written by a senior engineer. Implement it exactly as specified. "
    "Do not redesign, do not add features beyond the spec, do not add commentary. "
    "Return only the code."
)

PLAN_SYSTEM = (
    "You are a senior engineer. Produce a precise implementation plan / spec with "
    "explicit acceptance criteria (interface, behavior, constraints, edge cases) for "
    "the request below. Do NOT write the implementation. Output only the plan."
)

CONTEXT_INSTRUCTION = (
    "Below are existing files provided ONLY as reference/context. "
    "Do NOT reproduce, echo, or re-output any of their contents unless the spec "
    "explicitly asks you to. Use them only to understand the current codebase."
)


def _load_env_file(path: str) -> dict[str, str]:
    """Parse simple KEY=VALUE lines from a .env file into a dict (no dependencies)."""
    values: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def _resolve_api_key() -> str | None:
    """Find DEEPSEEK_API_KEY: environment first, then ~/.claude/.env, then ./.env."""
    key = os.environ.get("DEEPSEEK_API_KEY")
    if key:
        return key
    for path in (
        os.path.join(os.path.expanduser("~"), ".claude", ".env"),
        os.path.join(os.getcwd(), ".env"),
    ):
        found = _load_env_file(path).get("DEEPSEEK_API_KEY")
        if found:
            return found
    return None


def _read_context_files(paths: list[str]) -> list[tuple[str, str]]:
    """Read context files, returning (path, content) for each. Exits on error."""
    results: list[tuple[str, str]] = []
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read()
        except OSError:
            sys.exit(f"Error: Cannot read context file: {path}")
        results.append((path, content))
    return results


def _build_message(spec: str, context_files: list[str] | None) -> str:
    """Build the user message, prepending context files if any."""
    if not context_files:
        return spec

    files = _read_context_files(context_files)
    parts = [CONTEXT_INSTRUCTION]
    for path, content in files:
        parts.append(f"\n### {path}\n\n{content}")
    parts.append("\n\n---\n\n" + spec)
    return "".join(parts)


def implement(
    spec: str,
    model: str = DEEPSEEK_MODEL,
    system: str = SYSTEM,
    context_files: list[str] | None = None,
    max_retries: int = 3,
) -> str:
    """Send a spec to DeepSeek and return the result (code by default, or a plan)."""
    api_key = _resolve_api_key()
    if not api_key:
        sys.exit("Error: DEEPSEEK_API_KEY not found. Set it in the environment, "
                 "in ~/.claude/.env, or in ./.env.")

    client = OpenAI(
        api_key=api_key,
        base_url=DEEPSEEK_BASE_URL,
        max_retries=max_retries,
    )
    try:
        resp = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": _build_message(spec, context_files)},
            ],
        )
    except Exception as e:
        # Clean message instead of a raw traceback on throttle/auth/network failures.
        sys.exit(f"DeepSeek call failed ({model}): {e}")

    return resp.choices[0].message.content


def _read_spec(arg: str | None) -> str:
    """Resolve the spec from a file path, an inline string, or stdin."""
    if arg is None:
        return sys.stdin.read()
    if os.path.isfile(arg):
        with open(arg, "r", encoding="utf-8") as f:
            return f.read()
    return arg  # inline spec text


def main() -> None:
    # Force UTF-8 stdout so non-ASCII output can't crash on a legacy console codepage.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description="Implement a spec via DeepSeek (Pro by default).")
    parser.add_argument("spec", nargs="?", help="Spec file path or inline text (omit to read stdin).")
    parser.add_argument("-o", "--out", help="Write the implementation to this file.")
    parser.add_argument("--flash", action="store_true",
                        help="Use deepseek-v4-flash instead of pro (cheaper).")
    parser.add_argument("--plan", action="store_true",
                        help="Draft a plan/spec for the request instead of writing code.")
    parser.add_argument("-c", "--context", action="append", default=None,
                        help="Context file (can be repeated). Contents are sent as reference before the spec.")
    parser.add_argument("--retries", type=int, default=3,
                        help="Number of retries for transient errors (default: 3).")
    args = parser.parse_args()

    spec = _read_spec(args.spec).strip()
    if not spec:
        parser.error("No spec provided (file, inline text, or stdin).")

    model = DEEPSEEK_FLASH if args.flash else DEEPSEEK_MODEL
    system = PLAN_SYSTEM if args.plan else SYSTEM
    context_files = args.context or []

    code = implement(
        spec,
        model=model,
        system=system,
        context_files=context_files,
        max_retries=args.retries,
    )

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(code)
        print(f"Wrote implementation to {args.out}", file=sys.stderr)
    else:
        print(code)


if __name__ == "__main__":
    main()
