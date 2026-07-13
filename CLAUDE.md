# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository orientation

This repo **is** the DeepSeek orchestration tooling itself — not a product that uses it. It
ships a few small Python tools plus the prose rules (this file, `docs/`, `agents/`) that tell a
Claude Code session how to drive the pipeline. Editing here means editing the pipeline's own
tools and its operating rules.

- **`implement_with_deepseek.py`** — the dispatcher. A thin, dependency-light one-shot: reads
  a spec (file path, inline string, or stdin), sends it to DeepSeek via the OpenAI-compatible
  client, prints the result. It holds **no escalation logic** — the ladder, review, and judging
  are the Claude session's job, described in the rules below. Two system prompts: implementation
  (default) and planning (`--plan`). Model is Pro by default, Flash via `--flash`.
- **`deepseek_agent.py`** — the agentic loop: DeepSeek reads/writes files, greps, and runs a
  verify command, iterating until it passes or a step cap hits (`--allow-dirty`, `--escalate`).
- **`pipeline.py`** — staged front door (`plan` / `run` / `auto`) over the two tools above.
- **`hooks/routing_gate.py`** — PreToolUse hook that blocks a code Write/Edit until a routing
  decision is recorded in `.claude/routing-ack`.
- **`docs/deepseek-pipeline.md`** / **`docs/workflow.md`** — full rationale and the end-to-end
  flow; this file is the condensed version.
- **`agents/deepseek-implementer.md`**, **`agents/judge.md`**, **`agents/author.md`** — subagent
  definitions for parallel fan-out, the judge gates, and terminal authorship.
- **`sample_spec.md`** — the spec format to imitate when authoring specs.

### Running it

Requires Python 3.10+ and the `openai` package (`pip install openai`). On this machine the
interpreter is `python` (Python 3.13); `python3` is not on PATH.

```
python implement_with_deepseek.py spec.md            # Pro (default)
python implement_with_deepseek.py spec.md --flash    # Flash (cheaper)
python implement_with_deepseek.py req.md  --plan      # draft a plan, not code
python implement_with_deepseek.py spec.md -o out.py  # write result to a file
```

`DEEPSEEK_API_KEY` resolves in order: environment → `~/.claude/.env` → repo-root `.env`. Copy
`.env.example` to `.env` to set it locally (`.env` is gitignored).

There is **no test suite, build step, or linter** — don't look for one. Verify a change to the
dispatcher by running it against `sample_spec.md` (or `--plan`) and checking the output; verify
`deepseek_agent.py` / `pipeline.py` against a throwaway git repo with a real `--verify` command;
a missing key exits with a clean message rather than a traceback.

---

# DeepSeek implementation pipeline

Delegate spec-able *implementation* — and, for non-trivial tasks, *plan-drafting* — to DeepSeek
(metered, my own account — cost is not a concern); keep *design, a short intent, and review*
with Claude. The point is to conserve Claude subscription usage: DeepSeek does the heavy code
generation (and the long plans) you'd otherwise spend Claude quota on. Bias every choice toward
resolving at DeepSeek and avoiding the Opus stage.

## Routing gate — pick the DeepSeek shape (default: delegate)
**Every coding task delegates to DeepSeek by default.** A few things sit outside the gate:

- **`inline` — the explicit exception, not a shape.** Claude writes the code itself ONLY when (a) I
  said "you write it," or (b) it's a trivial edit tightly coupled to a live diagnosis. This is the
  only case Claude authors code, and it's never chosen because a change *looks* small. Record it as
  `Routing: inline — <which trigger>` (the hook and audit trail still want the line).
- **Dangerous/destructive commands are Opus-only — never delegated.** Anything irreversible
  (`rm -rf`, `git reset --hard`, `git push --force`, `DROP`/`DELETE`, `kubectl`/`oc delete`, prune,
  deploys, overwriting data) is executed by the current model (Opus) directly, and confirmed first
  per the usual norms. DeepSeek's agent can't run arbitrary shell anyway (only the verify command),
  so this is a hard boundary, not just a preference.
- **Non-coding/operational tasks** — running git, commands, deploys, env — aren't routed at all;
  they stay with the session.

Everything else delegates. Emit one line before any implementation code, choosing the shape:

```
Routing: <deepseek-oneshot | pipeline> — <one-clause reason>
```

- **deepseek-oneshot** — the floor: one or two files edited, no test loop, up to ~120 net-new lines;
  reads any needed context via `-c` → `implement_with_deepseek.py`.
- **pipeline** — anything larger or testable → `pipeline.py`: intent → Pro plan → **Opus judges the
  plan** → agent → verify → **Opus judges the diff**. The agent stage runs **automatically after the
  plan gate** — you do not route to it separately.

**Tripwire (hard)** — forbids the light route so oneshot can't absorb pipeline-scale work. **"Files"
means files EDITED/written; reference reads (e.g. `-c`) never count.** ≥3 files edited OR ≥2 languages
OR >~120 net-new logic lines OR the task is testable / needs a verify loop → **pipeline**.
**Testability is the hard discriminator:** has or needs tests → pipeline, never oneshot. **Default
upward on ambiguity:** unsure → pipeline.

A missing Routing line before code is a process error. (`deepseek-agent` alone is just pipeline's
execute stage — use it only to re-run an already-judged plan: `Routing: deepseek-agent — re-run
approved plan`. A repo hook may enforce that the Routing decision was recorded before a code
Write/Edit — see `docs/deepseek-pipeline.md`.)

## Session model: the current model runs the session, Opus judges and authors
Run the Claude Code session on the current model and spend Opus only where the strongest model
pays off. The current model handles the chat, the short intent, orchestration, delegation
decisions, and running the pipeline. Opus is invoked *as a subagent* only for two roles:
- **Judging → the `judge` subagent** (Opus, read-only). Delegate BOTH gates to it — the plan
  against the intent, and the diff against the plan. It returns PASS/FAIL with specific
  reasons and is independent by construction (fresh context, no anchoring on the session).
- **Terminal authorship → the `author` subagent** (Opus). When DeepSeek exhausts the ladder,
  the failed leg goes to `author`, which writes the last stage directly and verifies it — not
  the session model.

This holds Opus usage to the high-value gates while the bulk of the session runs on the current
model. Everywhere below, "the current model" is whatever runs this session and "the Opus stage" is
the `author` subagent. If the current model is itself Opus, these are just you —
no subagents needed.

## When to use it
- **A direct instruction wins.** If I say "implement it directly / you write it / handle
  it yourself," skip the pipeline and just write the code.
- Use it for open-ended, spec-able implementation work — especially bulk or
  parallelizable chunks — where DeepSeek is likely to succeed.
- When in doubt, let it ride — default to delegating, don't stop to ask. The gates
  (plan judge, verify, diff judge) catch misses; a wrong route just escalates.

## Pre-flight — two leak checks before dispatching
The spec + review + integration overhead only pays off when DeepSeek's generation is
the bulk of the work. Two shapes lose that bet:

1. **Delegatable-ratio gate.** Mostly design, integration, deploy, running, and
   verification with only a thin slice of code generation → do it all inline; the
   overhead outweighs what's delegated. (A multi-file migration that's mostly a
   response-shape contract, glue, and deploy config is the classic trap.)
2. **Single / near-mechanical gate.** One chunk → run the ladder inline, don't spawn a
   subagent (no parallelism to gain, just an uncached cold-start); subagents are for 3+
   independent chunks at once. A chunk your spec pins to near-transcription → write it
   inline; the spec already cost the code's worth of output.

## Intent and planning: the current model writes a short intent, Pro writes the plan
"The current model" = whatever model runs this Claude Code session (Opus by default; it's the
one that does every non-generation step). Its *output* is the expensive part, so keep its
front-end authoring to a short **intent** and push the plan itself onto DeepSeek Pro.
- **Intent → current model, kept short.** Turn what I want into a clear, workable goal — a few
  sentences — **plus a 2–4 bullet definition of done**: observable, falsifiable outcomes (e.g.
  `retries on 429/timeout`, `existing calls unchanged`). This is NOT a spec and NOT the detailed
  acceptance criteria (that's the plan's job) — it's the concrete target the plan gate checks
  against, so the judge grades coverage instead of a vibe. If the intent is too vague to write a
  done-list, it isn't ready — tighten it before spending a plan on it. This is the only up-front
  authoring the current model does.
- **Planning splits on one question — is the task short and one-shottable?**
  - **Yes → no separate plan step.** Small enough to do in a single shot: dispatch it as a
    **DeepSeek one-shot** (the floor). Claude only writes it itself in the two `inline` cases
    (instructed, or diagnosis-coupled) — not because it's short.
  - **No → ALL planning goes to DeepSeek Pro** (`--plan`). Pro expands the short intent into the
    actual plan (the spec-equivalent), which MUST state its own acceptance criteria (interface,
    behavior, edge cases) and name a runnable verify command. The current model does NOT author
    this plan.
- **The Opus `judge` subagent judges every Pro plan — always, never DeepSeek.** DeepSeek grading
  its own plan is self-review; the plan gate is the one independent check that catches "Pro
  misread the intent" before any code is generated, and it's the cheapest Opus touch (short plan
  vs short intent). The judge grades the plan's **acceptance criteria** against the intent's
  done-list on three concrete questions: **coverage** (every done-bullet covered?), **soundness**
  (edge cases and error handling present and correct?), **testability** (does it name a verify
  command that actually checks them?). Any miss → FAIL back to Pro. Then Opus judges the diff
  against the plan after. Every step except generation (intent, both judgments, the escalation
  decision) runs on Opus.

## Opus handles these directly — never DeepSeek
- **All non-coding tasks use the current main model** — GitHub Actions, deployment,
  running files/commands, env setup, git. Do not spec these out to DeepSeek.
- **Debugging and error triage stay with Opus** — reading console output, stack traces,
  or errors I paste. Opus diagnoses and root-causes first; only the *resulting fix*, if
  it's a clean spec-able chunk, then goes to DeepSeek. The diagnosis itself never does.
  At the moment diagnosis ends and before writing any fix, classify **each resulting fix
  chunk separately**: trivial-inline vs. spec-able-chunk. A new self-contained
  script/module is spec-able and goes through the ladder even though it came out of a
  "debugging" task; trivial edits tightly coupled to the diagnosis stay inline.

## The tool
`implement_with_deepseek.py` dispatches a spec to DeepSeek and returns code. The key
auto-loads from `~/.claude/.env` or a repo-root `.env` — no per-project setup.

```
python implement_with_deepseek.py spec.md            # Pro (default)
python implement_with_deepseek.py spec.md --flash    # Flash (cheaper)
python implement_with_deepseek.py req.md  --plan      # draft a plan, not code
python implement_with_deepseek.py spec.md -o out.py  # write to a file
python implement_with_deepseek.py spec.md -c a.py -c b.py  # attach reference files
python implement_with_deepseek.py spec.md --retries 5     # transient-error retries (default 3)
```

Use `-c/--context` (repeatable) whenever the spec needs to reference existing code — pass
the real files instead of pasting them into the spec text; they're sent as reference-only
context (the model is told not to reproduce them), keeping the spec itself lean. `--retries`
wires the OpenAI client's `max_retries` so a throttle/network blip retries with backoff
instead of failing the dispatch.

## The agentic loop (`deepseek_agent.py`)
For multi-file, *testable* work, `deepseek_agent.py` drives DeepSeek as a coding agent: it
navigates a target repo (`list_dir`, `grep`), reads/writes files, and runs a declared verify
command, iterating until it passes or a step cap hits. It self-corrects against the tests
(cheap DeepSeek calls), so Opus judges only the final diff — not every mechanical bug the tests
already caught. On UNFINISHED (cap hit) it emits a failed-leg report diagnosing what's still
broken, as the handoff to Opus.

```
python deepseek_agent.py plan.md --verify "pytest -q" --repo . --flash
```

- Requires a git repo with a CLEAN working tree; emits `git diff` at the end for review.
  `--allow-dirty` auto-stashes your uncommitted work first and restores it after, keeping the
  diff purely the agent's own changes.
- `--escalate` (with `--flash`) auto-climbs Flash→Pro: on a Flash UNFINISHED it resets the repo
  to pristine and retries once on Pro. `--max-output N` tunes how much verify output the agent
  sees (head+tail retained, default 8000 chars) so a big test log's failures aren't truncated away.
- `--verify CMD` is the load-bearing signal — and the agent's ONLY runnable command (no
  arbitrary shell). No verify command → no self-correction, so it collapses to one blind shot;
  always pass one, and have the plan name it.
- Outer ladder: `--flash` first → escalate to Pro (drop `--flash`) with a critique if the loop
  stalls or the diff misses intent → Opus authors only if both miss.
- Use the one-shot `implement_with_deepseek.py` for small single-file chunks — spinning up an
  agent for a 20-line function is wasted overhead (the single/near-mechanical gate).

## The pipeline entry point (`pipeline.py`)
One staged front door over the two tools, for the full intent → plan → agent flow:

```
python pipeline.py plan "INTENT"                              # DeepSeek drafts a plan; you judge it
python pipeline.py run plan.md --verify "pytest -q" --repo .  # agent implements the approved plan
python pipeline.py auto "INTENT" --verify "pytest -q" --repo . --flash   # one shot, SKIPS the plan gate
```

`plan` and `run` are two stages with an Opus judge gate between them (you review the plan
before running it); the gates are yours, in Claude Code, not in the script — a fully automated
run would delete the independent review the pipeline exists to keep. `auto` chains both and is
for small/trusted tasks only; you still review the final diff. Args after the plan/intent in
`run`/`auto` forward straight to `deepseek_agent.py`.

## The loop
Spec (explicit acceptance criteria; lean, precise on *what correct means*, sparse on
*how*) → dispatch → review against the spec → escalate on failure. See `sample_spec.md`
for the spec format. Judging stays with Opus (independent gate); DeepSeek never judges its
own work. To keep re-judges cheap, hold the spec text stable and run the stages back-to-back
so Claude Code's automatic prompt caching stays warm — a minor tailwind on the reused
prefix only, not on each fresh version under review.

## Escalation ladder
1. **Flash, first pass** (`--flash`). Review.
2. **Pro, rewrite 1** — feed a specific, actionable critique back. Review.
3. **Pro, rewrite 2** — one more critique-and-rewrite. Review.
4. **Opus writes it directly** — only after Flash + two Pro rewrites miss. When the current model
   isn't Opus this is the `author` subagent; when the session already runs on Opus it's you.

Cap: three DeepSeek attempts before Opus; don't loop past it. Announce the stage as you
go. A chunk that keeps failing usually has a spec problem, not a model problem.

## Parallel work
For genuinely independent chunks, fan out ~3–5 `deepseek-implementer` subagents (each
runs Flash → Pro → Pro and judges on Opus, escalating failed legs back to me). I
initiate them, wait on all, then batch the Opus stage at the end. Subagents don't spawn
subagents. Only parallelize chunks with no shared state or ordering dependency.

## Always Claude's
Design/architecture, the short intent, judging (the plan against the intent and the diff
against the plan), the escalation decision, and anything novel or subtle. For non-trivial
tasks DeepSeek Pro drafts the plan and DeepSeek implements against it — Claude judges both,
but authors neither.

Full rationale and the subagent judging rules: `docs/deepseek-pipeline.md`.
