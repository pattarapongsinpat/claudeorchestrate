#!/usr/bin/env python3
"""
pipeline.py - one entry point for the DeepSeek implementation pipeline.

The flow, end to end:

    intent --> DeepSeek plan --> [Opus judges plan] --> DeepSeek agent --> [Opus judges diff]
    (you)       (Pro --plan)      (you, Claude Code)      (deepseek_agent)    (you)

The two judge gates belong to Opus and live in Claude Code, not in this script. So the
pipeline is staged: each DeepSeek step emits an artifact you review before continuing.
That is deliberate - a fully automated run would delete the independent review the whole
pipeline exists to keep.

Subcommands
-----------
  plan   Expand a short intent into a plan (DeepSeek Pro). The intent is a workable goal
         in a few sentences, NOT a spec - Pro writes the spec-level plan; you judge it.
         (Short, one-shottable tasks skip this entirely - just do them on the current model.)
             python pipeline.py plan "INTENT or intent.md" [-o plan.md] [--flash]

  run    Run the agentic loop against an APPROVED plan file. Everything after the plan
         path is forwarded verbatim to deepseek_agent.py (--verify, --repo, --flash,
         --escalate, --allow-dirty, --max-steps, --max-output).
             python pipeline.py run plan.md --verify "pytest -q" --repo .

  auto   intent --> plan --> agent in one shot, SKIPPING the plan-review gate. Prints the
         plan it used (to stderr) so the diff stays clean on stdout. The plan is always
         drafted on Pro; args after the intent are forwarded to the agent. Use for small
         or trusted tasks - you still review the final diff.
             python pipeline.py auto "INTENT" --verify "pytest -q" --repo . --flash
"""

import argparse
import os
import subprocess
import sys
import tempfile

from implement_with_deepseek import implement, PLAN_SYSTEM, DEEPSEEK_MODEL, DEEPSEEK_FLASH


def _read_intent(arg: str) -> str:
    """Intent from a file path or inline text."""
    if os.path.isfile(arg):
        with open(arg, "r", encoding="utf-8") as f:
            return f.read().strip()
    return arg.strip()


def _strip_fences(text: str) -> str:
    """Drop a leading ```lang / trailing ``` fence if the model wrapped its output."""
    lines = text.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    return "\n".join(lines).strip()


def _agent_path() -> str:
    """deepseek_agent.py sits next to this script."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "deepseek_agent.py")


def _draft_plan(intent: str, flash: bool) -> str:
    model = DEEPSEEK_FLASH if flash else DEEPSEEK_MODEL
    return _strip_fences(implement(intent, model=model, system=PLAN_SYSTEM).strip())


def _run_agent(plan_file: str, agent_args: list[str]) -> int:
    """Invoke deepseek_agent.py on a plan file, streaming its output through."""
    if not os.path.isfile(plan_file):
        sys.exit(f"Error: plan file not found: {plan_file}")
    cmd = [sys.executable, _agent_path(), plan_file] + agent_args
    print(f"[pipeline] agent: {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(cmd).returncode


def cmd_plan(args: argparse.Namespace) -> int:
    plan = _draft_plan(_read_intent(args.intent), args.flash)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(plan)
        print(f"[pipeline] plan written to {args.out}", file=sys.stderr)
    print(plan)
    print(
        "\n[pipeline] Judge this plan against your intent before running it. When it's right:\n"
        "           python pipeline.py run <plan.md> --verify \"...\" --repo .",
        file=sys.stderr,
    )
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    return _run_agent(args.plan, args.agent_args)


def cmd_auto(args: argparse.Namespace) -> int:
    plan = _draft_plan(_read_intent(args.intent), flash=False)  # plan quality matters; always Pro
    print("=== PLAN (auto mode - plan-review gate SKIPPED) ===", file=sys.stderr)
    print(plan, file=sys.stderr)
    print("=== running agent against the above plan ===", file=sys.stderr)
    tmp = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8")
    try:
        tmp.write(plan)
        tmp.close()
        return _run_agent(tmp.name, args.agent_args)
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


def main() -> None:
    # Plan text / agent output is UTF-8; force stdout so non-ASCII can't crash printing
    # on a legacy Windows console codepage.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(
        description="Staged DeepSeek pipeline: intent -> plan -> agent, with Opus judge gates between stages.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_plan = sub.add_parser("plan", help="Draft a plan from an intent (review before running).")
    p_plan.add_argument("intent", help="Intent: file path or inline text.")
    p_plan.add_argument("-o", "--out", help="Write the plan to this file.")
    p_plan.add_argument("--flash", action="store_true", help="Draft on Flash instead of Pro.")
    p_plan.set_defaults(func=cmd_plan)

    p_run = sub.add_parser("run", help="Run the agent against an approved plan file.")
    p_run.add_argument("plan", help="Approved plan file.")
    p_run.add_argument("agent_args", nargs=argparse.REMAINDER,
                       help="Args forwarded to deepseek_agent.py (--verify, --repo, --flash, ...).")
    p_run.set_defaults(func=cmd_run)

    p_auto = sub.add_parser("auto", help="intent -> plan -> agent in one shot (skips the plan gate).")
    p_auto.add_argument("intent", help="Intent: file path or inline text.")
    p_auto.add_argument("agent_args", nargs=argparse.REMAINDER,
                        help="Args forwarded to deepseek_agent.py.")
    p_auto.set_defaults(func=cmd_auto)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
