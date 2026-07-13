# claudeochestrate

A small orchestration pipeline for [Claude Code](https://claude.com/claude-code) that
delegates spec-able **implementation** and **plan-drafting** to [DeepSeek](https://deepseek.com)
while keeping **design, a short intent, and review** with Claude. The goal is to conserve Claude
Pro-plan subscription usage: DeepSeek does the heavy code generation (and the long plans) you'd
otherwise spend Claude quota on. **DeepSeek is the floor — Claude does not write implementation
code by size**; it writes code inline only when you say so or for a trivial edit tied to a live
diagnosis.

## How it works

```
you ─▶ intent+done-list ─▶ Pro plan ─▶ Opus judges plan ─▶ one-shot / agent ─▶ verify ─▶ Opus judges diff
       (Claude)            (DeepSeek)   (Claude)            (DeepSeek)          (tests)   (Claude)
                                                                 │
                                        escalation ladder if it misses:
                              Flash ─▶ Pro (rewrite 1) ─▶ Pro (rewrite 2) ─▶ Opus author
```

Each coding task opens with a `Routing:` line (inline / one-shot / agent / pipeline). Claude turns
your ask into a short intent plus a 2–4 bullet **definition of done**; for non-trivial work DeepSeek
Pro drafts the plan and an independent **Opus judge** checks it against that done-list before any
code. Implementation runs as a one-shot or a self-correcting agent gated by a **verify command**;
Opus judges the final diff. On a miss it climbs the ladder — Flash, two Pro rewrites, then an Opus
`author` subagent as the terminal stage. DeepSeek dollars are billed to your own account and are not
the constraint; Claude subscription usage is, so every chunk resolved before Opus is the real saving.
Full flow: [`docs/workflow.md`](docs/workflow.md).

## Layout

| Path | What it is |
| --- | --- |
| `CLAUDE.md` | Condensed operating rules Claude Code loads per session. |
| `docs/deepseek-pipeline.md` | Full rationale and the subagent judging rules. |
| `pipeline.py` | Staged entry point: `plan` / `run` / `auto` — intent to plan to agent, with Opus judge gates between stages. |
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
