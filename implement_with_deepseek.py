#!/usr/bin/env python3
"""
implement_with_deepseek.py — send a spec to DeepSeek and print the implementation.

The DEEPSEEK_API_KEY is resolved from the environment, then ~/.claude/.env, then ./.env.
See CLAUDE.md for usage and the full workflow.
"""

import os
import sys
import argparse

from openai import OpenAI  # DeepSeek is OpenAI-compatible

DEEPSEEK_MODEL = "deepseek-v4-pro"            # default
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

# ---------------------------------------------------------------------------
# Pre-dispatch context-file scanner
# ---------------------------------------------------------------------------

# Symmetric punctuation pairs to strip from token boundaries.
_SYMMETRIC_PAIRS = [
    ("\u201c", "\u201d"),   # left/right double quotation marks
    ("\u2018", "\u2019"),   # left/right single quotation marks
    ("'",      "'"),        # straight single quotes
    ("(",      ")"),
    ("[",      "]"),
    ("{",      "}"),
    ("<",      ">"),
    ("\u00ab", "\u00bb"),   # guillemets «»
]

# Non-path punctuation stripped from both ends after pair removal.
_STRIP_CHARS = ".,;:!?'\"()[]{}<>*&|#@"

# Prefixes that mark a token as a URL (case-insensitive).
_URL_PREFIXES = ("http://", "https://", "ftp://", "file://", "mailto:")


def find_missing_context_files(
    spec_text: str,
    attached_files: list[str],
    no_check: bool = False,
) -> list[str]:
    """Return a sorted list of absolute paths to *existing, unattached* files
    referenced in *spec_text*.

    *attached_files* are raw paths supplied via ``-c``.  *no_check* skips all
    scanning and returns an empty list immediately.
    """
    if no_check:
        return []

    # Resolve attached files to canonical, case-normalised paths.
    attached_norm: set[str] = set()
    for p in attached_files:
        try:
            rp = os.path.realpath(p)
            attached_norm.add(os.path.normcase(rp))
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Tokenisation
    # ------------------------------------------------------------------
    tokens: list[str] = spec_text.split()  # split on any Unicode whitespace

    # ------------------------------------------------------------------
    # Candidate extraction
    # ------------------------------------------------------------------
    seen: set[str] = set()
    result: list[str] = []

    for token in tokens:
        token = token.strip()
        if not token:
            continue

        # 1. Strip symmetric punctuation pairs repeatedly.
        changed = True
        while changed and len(token) >= 2:
            changed = False
            for left, right in _SYMMETRIC_PAIRS:
                if token.startswith(left) and token.endswith(right):
                    token = token[len(left):-len(right)]
                    changed = True
                    break

        # 2. Strip individual leading/trailing non-path punctuation.
        token = token.strip(_STRIP_CHARS)

        if not token:
            continue

        # 3. Discard URLs / mailto.
        lower = token.lower()
        if lower.startswith(_URL_PREFIXES):
            continue

        # 4. Discard "www." domains.
        if lower.startswith("www.") and "." in lower[4:]:
            continue

        # 5. Discard exactly "." or "..".
        if lower in (".", ".."):
            continue

        # 6. Must contain a path separator or a file-extension dot.
        has_path_sep = "/" in token or "\\" in token
        has_ext_dot = False
        if "." in token:
            # a dot that is not at the very start or very end
            idx = token.find(".")
            while idx != -1:
                if 0 < idx < len(token) - 1:
                    has_ext_dot = True
                    break
                idx = token.find(".", idx + 1)

        if not (has_path_sep or has_ext_dot):
            continue

        # ------------------------------------------------------------------
        # Existence check
        # ------------------------------------------------------------------
        try:
            candidate = os.path.abspath(token)
        except Exception:
            continue

        if not os.path.isfile(candidate):
            continue

        try:
            real = os.path.realpath(candidate)
        except Exception:
            continue

        norm = os.path.normcase(real)

        if norm in attached_norm:
            continue

        if norm not in seen:
            seen.add(norm)
            result.append(real)

    result.sort()
    return result


# ---------------------------------------------------------------------------
# Original helpers (unchanged)
# ---------------------------------------------------------------------------


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
    parser.add_argument("--plan", action="store_true",
                        help="Draft a plan/spec for the request instead of writing code.")
    parser.add_argument("-c", "--context", action="append", default=None,
                        help="Context file (can be repeated). Contents are sent as reference before the spec.")
    parser.add_argument("--retries", type=int, default=3,
                        help="Number of retries for transient errors (default: 3).")
    parser.add_argument("--no-context-check", action="store_true", default=False,
                        help="Skip the pre-dispatch check for missing context files.")
    args = parser.parse_args()

    spec = _read_spec(args.spec).strip()
    if not spec:
        parser.error("No spec provided (file, inline text, or stdin).")

    model = DEEPSEEK_MODEL
    system = PLAN_SYSTEM if args.plan else SYSTEM
    context_files = args.context or []

    # ------------------------------------------------------------------
    # Pre-dispatch context check
    # ------------------------------------------------------------------
    attached_paths = [os.path.abspath(p) for p in context_files]
    missing = find_missing_context_files(spec, attached_paths, args.no_context_check)

    if missing:
        print(
            "Error: The specification references the following existing files "
            "that were not attached with -c:",
            file=sys.stderr,
        )
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        print(
            "Please attach them using -c /path/to/file or pass "
            "--no-context-check to skip this check.",
            file=sys.stderr,
        )
        sys.exit(1)

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
