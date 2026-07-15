# Full workflow

The end-to-end flow the orchestrator runs, from a request to a merged change. Session runs on
the **current model**; **Opus** is spent only as the `judge` and `author` subagents; **DeepSeek**
(Pro) does the plan-drafting and code generation.

```
you ──▶ [1] Routing ──▶ [2] Intent ──▶ [3] Plan ──▶ [4] Plan gate ──▶ [5] Implement ──▶ [6] Verify ──▶ [7] Diff gate ──▶ [8] Integrate
       (session)        (session)      (Pro)        (Opus judge)      (DeepSeek)         (tests)        (Opus judge)     (session)
                                          │                                  ▲
                                    short/one-shot?                    escalation ladder
                                    yes → skip 3–4                     Pro→Pro→Opus author
```

## Roles

| Actor | Does | Cost |
| --- | --- | --- |
| **Current model** (session) | routing, intent, orchestration, integration, git | subscription usage |
| **Opus `judge`** (subagent) | plan gate + diff gate — independent | subscription usage (kept minimal) |
| **Opus `author`** (subagent) | terminal authorship when the ladder is exhausted | subscription usage (rare) |
| **DeepSeek Pro** | plan drafting + code generation + self-correction | metered (own account) |
| **verify command** | objective pass/fail gate | free |

---

## [1] Routing — current model

**Default is delegate.** A few things sit outside the gate: `inline` (Claude writes it — ONLY when
instructed or for a diagnosis-coupled trivial edit; the explicit exception, not a shape);
**dangerous/destructive commands** (`rm -rf`, `git reset --hard`, `push --force`, `DROP`, `oc
delete`, deploys, overwriting data — Opus-only, never delegated, confirmed first); and
non-coding/operational tasks (git, commands, env — not routed, stay with the session).
Everything else emits one line choosing the shape:

```
Routing: <deepseek-oneshot | pipeline> — <one-clause reason>
```

**Tripwire (hard)** — forbids `oneshot` so it can't absorb pipeline-scale work. "Files" = files
**edited**; reference reads (`-c`) never count. ≥3 files edited OR ≥2 languages OR >~120 net-new
logic lines OR testable/needs a verify loop → **pipeline**. **Testability is the hard
discriminator** — has/needs tests → pipeline, never oneshot. **Default upward on ambiguity** →
pipeline.

| Route | When | Tool |
| --- | --- | --- |
| **inline** (exception) | ONLY "you write it" OR a trivial edit coupled to a live diagnosis | current model writes it |
| **deepseek-oneshot** (floor) | one–two files edited, no test loop, up to ~120 new lines, reads any context via `-c` | `implement_with_deepseek.py` |
| **pipeline** | anything larger or testable; drafts+judges a plan, then runs the agent | `pipeline.py` |

The **agent** is not a start-phase route — it's pipeline's back half, run automatically after the
plan gate. Bare `deepseek_agent.py` is used only to re-run an already-judged plan.

Enforcement: a PreToolUse hook (`hooks/routing_gate.py`) blocks a code Write/Edit until a routing
decision is recorded in `.claude/routing-ack`.

## [2] Intent — current model

Turn the request into a short workable goal **plus a 2–4 bullet definition of done** — observable,
falsifiable outcomes (e.g. `retries on 429/timeout`, `caps at N`, `existing calls unchanged`). Not a
spec; it's the concrete target every downstream gate checks against. **If you can't write the
done-list, the intent isn't ready — tighten it first.** For `inline`/`oneshot`, the done-list *is*
the mini-spec and steps 3–4 are skipped.

## [3] Plan — DeepSeek Pro

Non-trivial tasks only. Pro (`--plan`) expands the intent into the plan, which MUST:
- state its own **acceptance criteria** (interface, behavior, edge cases, error handling), and
- name a **runnable verify command**.

Claude does not author this plan.

## [4] Plan gate — Opus `judge` (ALWAYS Opus, never DeepSeek)

The one independent check that catches "Pro built the wrong thing" before any code burns — and the
cheapest Opus touch (short plan vs short intent). The judge grades the plan's acceptance criteria
against the intent's done-list on three yes/no questions:

- **Coverage** — every done-bullet covered? (missing one → FAIL)
- **Soundness** — edge cases and error handling right? (design mistake/misread → FAIL)
- **Testability** — names a verify command that actually checks them? (no runnable check → FAIL)

FAIL → specific critique back to Pro (or fix the intent if the done-list was the problem). PASS →
implement.

## [5] Implement — DeepSeek

- **oneshot** → `implement_with_deepseek.py` (single dispatch). It sees ONLY the spec plus what
  you attach with `-c`, and cannot fetch its own context — so enumerate every existing file the
  task touches or depends on and attach them all. `-c` reads are DeepSeek input (metered, not the
  constraint) and never count toward the tripwire: **write leanly, attach generously.** Can't
  enumerate the context up front? That's a routing signal → pipeline.
- **agent** → `deepseek_agent.py --verify "<cmd>" --repo .` — navigates the repo, edits, runs the
  verify command, and self-corrects against it until it passes or a step cap hits. Clean-tree
  precondition; `--allow-dirty` auto-stashes.
- **parallel** → fan out 3–5 `deepseek-implementer` subagents on independent chunks (no shared
  state/ordering). Each runs its own Pro→Pro and returns accepted code or a failed leg.

## [6] Verify — the load-bearing gate (free, model-independent)

The verify command is the objective check that costs zero subscription usage. The agent self-corrects
against it in-loop, so the diff that reaches Opus is usually already test-passing — Opus judges design
conformance, not mechanical bugs the tests already caught. **No verify signal → the agent collapses
to a blind shot; always name one in the plan.**

Verify is a signal, not an absolute veto. A test can be mechanically unpassable — flaky,
environment-specific, or a fixture the sandbox can't satisfy — leaving a *correct* diff red. So the
**judge**, not verify alone, owns the escalation call: a red diff the judge confirms meets the plan
PASSES and integrates, instead of burning the Opus `author` stage on code that was already right.

## [7] Diff gate — Opus `judge`

Judge the final diff against the plan: every acceptance criterion met, nothing missing/wrong, no
correctness hazards (reads surrounding files as needed). Conformance is the bar, not taste. PASS →
integrate. FAIL → escalate. A failing verify does not force FAIL: if the diff meets the plan and the
red is a mechanically-unpassable test rather than a real defect, that's a PASS — the judge's call,
not the test's.

## [8] Escalation ladder (on a miss at [5]/[7])

Report each failed attempt in one line; explain the outcome only at the end.

1. **Pro** first pass.
2. **Pro** rewrite — specific critique fed back.
3. **Opus `author`** writes it directly and verifies — terminal stage, no independent review after,
   so the check is that it runs.

Cap: two Pro attempts before Opus. A chunk that keeps failing usually has a spec problem, not
a model problem.

## [9] Integrate — current model

Integrate accepted code, run the full verify once more, commit. For parallel work, collect every
failed leg and batch them into a single Opus `author` pass at the end.

---

## What lands where

- **Opus (subscription usage):** intent, plan gate, diff gate, rare terminal authorship. Two small
  judge touches carry the quality; the rest is delegated.
- **DeepSeek (metered):** the plan, all generation, in-loop self-correction.
- **Free:** the verify command — the real independent gate wherever tests exist.

The single rule behind it all: **Claude designs, judges, and integrates; DeepSeek plans and writes;
tests decide.**
