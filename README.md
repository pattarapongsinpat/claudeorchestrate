# claudeochestrate

A small orchestration pipeline for [Claude Code](https://claude.com/claude-code) that
delegates spec-able **implementation** work to [DeepSeek](https://deepseek.com) while
keeping **design, spec-writing, and review** with Claude. The goal is to conserve Claude
Pro-plan rate-limit usage: DeepSeek does the heavy code generation you'd otherwise spend
Claude quota on, and Claude only writes code directly as the final fallback.

## How it works

```
guidelines ──▶ Claude writes a spec ──▶ DeepSeek implements ──▶ Claude reviews vs. spec
   (you)          (flat-rate)              (metered)               (flat-rate)
                                               │
                                    escalation ladder if it misses:
                        Flash ──▶ Pro (rewrite 1) ──▶ Pro (rewrite 2) ──▶ Opus writes it
```

Claude authors a precise spec (acceptance criteria: interface, behavior, constraints,
edge cases), dispatches it to DeepSeek, and reviews the returned code against that spec.
On a miss it climbs the ladder — a Flash pass, two Pro rewrites, then Opus writes it
directly as the terminal rung. DeepSeek dollars are billed to your own account and are
not the constraint; the constraint is Claude quota, so every chunk resolved before the
Opus rung is the real saving.

## Layout

| Path | What it is |
| --- | --- |
| `CLAUDE.md` | Condensed operating rules Claude Code loads per session. |
| `docs/deepseek-pipeline.md` | Full rationale and the subagent judging rules. |
| `implement_with_deepseek.py` | The dispatcher: sends a spec to DeepSeek, returns code. |
| `deepseek_agent.py` | Agentic coding loop: DeepSeek reads/writes files and runs a verify command, iterating until it passes. |
| `agents/deepseek-implementer.md` | Subagent def for fanning out parallel chunks. |
| `sample_spec.md` | Example of the spec format. |

## Setup

Requires Python 3.10+ and the `openai` package (DeepSeek is OpenAI-compatible):

```
pip install openai
```

Provide a DeepSeek API key one of three ways (checked in order): the `DEEPSEEK_API_KEY`
environment variable, `~/.claude/.env`, or a repo-root `.env`. Copy the example:

```
cp .env.example .env    # then paste your key
```

## Usage

```
python implement_with_deepseek.py spec.md            # Pro (default)
python implement_with_deepseek.py spec.md --flash    # Flash (cheaper tier)
python implement_with_deepseek.py req.md  --plan      # draft a plan/spec, not code
python implement_with_deepseek.py "spec text"        # inline spec
python implement_with_deepseek.py spec.md -o out.py  # write result to a file
python implement_with_deepseek.py spec.md -c a.py -c b.py  # attach reference files (repeatable)
python implement_with_deepseek.py spec.md --retries 5     # retry transient errors (default 3)
```

`-c/--context` (repeatable) attaches existing files as reference-only context ahead of the
spec — the model is told not to reproduce them — so a spec that builds on existing code can
stay lean instead of inlining it. `--retries` sets the OpenAI client's `max_retries`, so a
rate-limit/timeout/connection blip backs off and retries instead of failing the dispatch.

`--plan` swaps the system prompt so DeepSeek drafts an implementation plan with acceptance
criteria instead of writing code — use it only when the spec would otherwise be long enough
that writing it out (Opus output) is the real cost; for short specs, just write them.

The script is only the dispatch mechanism — the escalation ladder and review live in
`CLAUDE.md`, driven by Claude, not by the script.
