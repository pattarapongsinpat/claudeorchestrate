# DeepSeek implementation pipeline — full reference

This is the full rationale behind the condensed pipeline rules in the repo-root
`CLAUDE.md`. Read this when you need the *why*; the CLAUDE.md summary is enough for
day-to-day use.

## Division of labor

This pipeline delegates *implementation* — and, for non-trivial tasks, *plan-drafting* — to
DeepSeek, and keeps *design, a short intent, and review* with Claude. The split:

- **Claude (you, flat-rate in Claude Code):** turn my ask into a short **intent** (a workable
  goal, not a spec), judge DeepSeek Pro's plan against that intent, judge the resulting diff
  against the plan, drive escalation, and write code directly only as the final fallback.
- **DeepSeek (metered, billed to my own account — cost is not a concern):** for non-trivial
  tasks, draft the plan from the short intent (Pro, `--plan`); then implement it. Invoked via
  the dispatcher / agent, never the arbiter of its own work.

I provide the ask. You crystallize it into a short intent; Pro plans; you judge; DeepSeek
implements; you judge again — everything except generation stays with you.

**Which model is "you"?** By default run the session on the current model and invoke **Opus only as a
subagent** for the two roles that need the strongest model: the `judge` subagent (both gates —
plan vs intent, diff vs plan) and the `author` subagent (the terminal stage, when DeepSeek is
exhausted). That holds Opus spend to the quality gates while the session runs on the current model;
the judge is also independent by construction (fresh context). Run the session directly on Opus
instead and those roles are simply you, no subagents. See CLAUDE.md's "Session model" section.

## The goal: minimize Claude limit usage

The point of this pipeline is to conserve *Claude usage* (my Pro-plan subscription usage limits),
not dollars. Writing implementation code is the most Claude-token-expensive thing
you do; DeepSeek generation is cheap and billed to my own account. So every chunk
DeepSeek implements is heavy generation you did NOT spend Claude quota on. The
pipeline wins whenever a chunk resolves at DeepSeek (Pro) instead of climbing to
the Opus stage — because on escalation you pay the spec + reviews *and* the full
Opus write, which is more Claude usage than just writing it directly. So: bias
every choice toward resolving at Pro and avoiding needless Opus escalation.

## When to use the pipeline vs. implement directly

The routing gate (see `CLAUDE.md`) decides this per task via a mandatory `Routing:` line.
**`deepseek-oneshot` is the floor: Claude does not write implementation code by size.** The only
two `inline` (Claude-writes-it) cases are context-triggered, never size-judged:

- **If I explicitly say "implement it directly," "you write it," "handle it yourself,"** — write
  the code inline. A direct instruction overrides the pipeline; do not dispatch to DeepSeek.
- **A trivial edit tightly coupled to a live diagnosis** stays inline (the debugging carve-out).
- **Everything else spec-able floors at a DeepSeek one-shot** and climbs from there (agent /
  pipeline) by testability and file count — even small changes go to DeepSeek, eating a round-trip
  on trivia rather than spending Claude output.
- **When in doubt, let it ride — default to delegating, don't stop to ask.** The plan gate, the
  verify command, and the diff gate catch misses; a wrong route just escalates. Minimize
  interruptions.

## Pre-flight — two leak checks before you dispatch

The overhead (spec + review + integration) only pays off when DeepSeek's generation is
the bulk of the work. Two task shapes lose that bet — catch them before dispatching.

1. **Delegatable-ratio gate.** If most of the task is design, integration, deploy,
   running things, and verification, with only a thin slice of fresh code generation,
   the pipeline saves little while you pay the full overhead — do the whole task inline.
   (A multi-file migration that's mostly a response-shape contract, glue edits, and
   deploy config is the classic trap: the few new modules are dwarfed by the Opus work
   around them.)

2. **Single / near-mechanical gate.**
   - **Single chunk → run the ladder inline; don't spawn a subagent.** One subagent has
     no parallelism to gain and just cold-starts an uncached context re-read. Subagents
     are for 3+ independent chunks at once (see Parallel work).
   - **Near-mechanical chunk → write it inline.** If your spec pins the code so tightly
     it's near-transcription, the spec already cost the code's worth of output; dispatch
     + judge + integrate is pure loss on top. Delegate only chunks with real freedom.

## Intent and planning: the current model writes a short intent, Pro writes the plan

The single most Claude-token-expensive thing you do is *output*, and an elaborate spec is the
worst of it. So the current model's front-end authoring is only a short **intent** — a workable
goal, not a spec — and the plan itself is DeepSeek Pro's job for anything non-trivial:

- **Intent → current model, kept short.** Turn my ask into a clear, workable goal in a few
  sentences. No acceptance criteria, no design write-up at this stage — the plan carries that.
  This short intent is the only up-front authoring the current model does.
- **Then the split is one question: is the task short and one-shottable?**
  - **Yes → a single `implement_with_deepseek.py` one-shot** (the floor for spec-able work). No
    separate plan step, no plan-judge; below this bar the draft-then-judge round-trip costs more
    than just dispatching it. Claude only writes it itself in the two `inline` cases (instructed,
    or a trivial edit coupled to a live diagnosis) — not because it's short.
  - **No → ALL planning goes to DeepSeek Pro** (`--plan` swaps the system prompt to a planning
    persona: "produce a plan with acceptance criteria, do NOT write code"). Pro expands the
    short intent into the plan. Opus does NOT author it.
- **Judge the plan against the intent** before implementing — this is where the acceptance
  criteria are born, so it's necessarily intent-based. Once it passes, those criteria are the
  contract the implementation is judged against.

**The judge stays on Opus — always.** DeepSeek never judges its own work (same model,
correlated blind spots → false passes), and judging is cheap Opus *input* anyway, so
there is nothing to save by moving it off. Keep whole-unit review; don't build diff
plumbing. Prompt caching is a *minor* tailwind here, not a cost pillar: inside Claude Code
the judge's caching is automatic, it only discounts the reused spec/prior-turn prefix (not
each fresh version under review), and it reliably cuts *dollar* cost — its effect on the
Pro-plan subscription usage limit specifically is smaller and less certain. The actionable part is just
discipline: keep the spec text stable and run the stages back-to-back so the cached prefix
stays warm.

## What Opus does directly — not via DeepSeek

The pipeline is only for spec-able *implementation*. The following stay with Opus in the
main session and are never specced out to DeepSeek:

- **All non-coding tasks** — GitHub Actions, deployment, running files/commands,
  environment setup, git operations, and the like. Use the current main model.
- **Debugging and error triage** — reading console output, stack traces, or the errors
  I paste. Opus diagnoses and root-causes first. Only the *resulting fix*, if it turns
  out to be a clean spec-able chunk, is then dispatched to DeepSeek; the diagnosis itself
  never is. Debugging is reasoning over concrete failing behavior — exactly the subtle
  work that stays with Opus.

Opus retains full tool access for all of this — it already has every tool available, so
there is nothing to enable; the pipeline never removes tools from the main session.

`implement_with_deepseek.py` is the dispatch mechanism. It sends a spec to DeepSeek and
returns the implementation. It does NOT contain any escalation logic — that logic is
yours and lives in these instructions. The key auto-loads from `~/.claude/.env` (or a
repo-root `.env`), so no per-project setup is needed.

```
python implement_with_deepseek.py spec.md            # DeepSeek Pro (default)
python implement_with_deepseek.py spec.md -o out.py  # write result to a file
python implement_with_deepseek.py spec.md -c a.py -c b.py  # attach reference files
```

## The workflow

For each unit of implementation work:

1. **Spec.** Turn my guidelines into a precise spec before dispatching anything.
   A good spec has explicit acceptance criteria — name the interface, the
   behavior, the constraints, and the specific things that would make it wrong
   (edge cases, concurrency hazards, error handling). See `sample_spec.md` for the
   format.

   **Spec for minimum Claude usage: precise enough to prevent escalation, lean
   enough not to rewrite the code in prose.** The spec is itself Claude output,
   so it costs quota too. Aim for the leanest spec that still lets Pro resolve the
   task — enough acceptance criteria to keep Pro on target and avoid the expensive
   Opus stage, without spelling out the implementation line by line (at which point
   you've spent as much Claude usage as just writing it). Precise on *what correct
   means*, sparse on *how to do it*.

   **Leanness is about prose, never about context — they are different budgets and
   only one is scarce.** The spec's *words* are Claude output (the constrained axis).
   The files you attach with `-c` are file reads billed to DeepSeek's metered input:
   they cost nothing on subscription usage and never count toward the routing tripwire.
   So **write leanly, attach generously.** Never paraphrase, summarize, or excerpt an
   existing file into the spec — attach the real file and let the spec refer to it.
   Under-attaching is the expensive mistake: a miss buys a critique cycle and can climb
   to Opus, which dwarfs whatever you "saved" by withholding a file. Unsure whether Pro
   needs it? Attach it.

   **The one-shot cannot fetch its own context.** `deepseek_agent.py` navigates the repo
   (`list_dir`, `grep`, read) and finds what it needs; `implement_with_deepseek.py` sees
   ONLY the spec plus whatever `-c` you attached, and gets exactly one shot at it. So
   before any one-shot dispatch, enumerate every existing file the task touches or depends
   on — the file being changed, its callers, the interface or types it must match, a
   sibling that sets the pattern — and attach them all. If you cannot enumerate the
   context up front, that is a routing signal: use the pipeline and let the agent find it.

2. **Dispatch.** Run the spec through `implement_with_deepseek.py`.

3. **Review against the spec.** Check the returned code against the acceptance
   criteria *you* wrote — not open-ended review, but "does this meet the spec."
   This subjective check is the escalation trigger; only you can make it.

4. **Escalate on failure** per the ladder below.

## The escalation ladder

The goal is to resolve at DeepSeek Pro and avoid the Opus stage (which costs the most
Claude usage). Bias toward getting it right at Pro, but don't loop forever — a task that
survives the ladder has a spec problem or genuinely needs you.

1. **Pro, first pass.** Dispatch; review.
2. **Pro, rewrite** — feed a specific critique back, re-dispatch on Pro. Review.
3. **Opus (you) writes it directly** — if DeepSeek hasn't hit the spec after the Pro
   pass and one rewrite, stop delegating and implement it yourself in-session. This is
   the final stage; don't loop past it.

Notes:
- The ladder runs Pro for both DeepSeek attempts, then climbs to Opus only when DeepSeek
  can't. DeepSeek dollar cost isn't the constraint, so the point of climbing is
  capability, not price — every stage resolved before Opus is the real Claude-usage saving.
- The cap is two Pro attempts before Opus. Do not exceed it — continuing to bounce a
  failing spec wastes round-trips and usually means the spec, not the model, is the
  problem. When you hit the Opus stage, say so.
- Announce which stage you're on as you go, so the ladder is visible.

## When a rewrite is needed

Give DeepSeek a *specific, actionable* critique, not "it's wrong." Name the
function, the line-level problem, and the expected behavior — concrete enough
that a weaker model can execute the fix. If the fix requires subtle reasoning
that's hard to spec, that's a signal to escalate to Opus rather than keep
bouncing.

## Parallel work (subagents)

Claude Code can dispatch multiple subagents concurrently, each running one
independent chunk's DeepSeek ladder — Pro → Pro — and judging the result
against its own spec on Opus. Parallelism works here because that judge loop is
self-contained per chunk, so the chunks don't have to funnel through a single
reviewer. The subagents do the DeepSeek stages; the Opus authorship stage stays with
the main session. So:

- **I (main session) initiate subagents.** Fan-out is my call — I decompose the
  job, write each chunk's spec, spawn the workers, and own integration. Subagents
  do not spawn further subagents.
- **Each subagent runs Pro → Pro on its chunk, judging on Opus.** A subagent
  judging DeepSeek's output is NOT self-review: DeepSeek wrote the code, the subagent
  grades it against the spec, so author and reviewer are different models. It does
  not reach the Opus authorship stage itself — that stays with me.
- **Every subagent reports back — pass or fail.** If its chunk passed at Pro, it
  returns the accepted code. If it exhausted the Pro pass and Pro rewrite without
  passing, it returns the *failed leg*: the best attempt plus a precise diagnosis of
  the remaining spec violations.
- **I wait on all subagents, then batch the Opus stage at the end.** Rather than
  writing each failure the moment it escalates, I let all the parallel DeepSeek work
  finish, collect every failed leg, and implement them all myself in one Opus pass
  at the end. Batching keeps the expensive stage to a single focused sitting instead
  of interleaving it with coordination.
- **Only parallelize genuinely independent chunks** — separate modules/functions,
  no shared state, no ordering dependency. If chunk B's spec depends on how chunk
  A turned out, they are sequential; do not fan them out.
- **Keep fan-out modest (a handful, ~3–5).** Enough to keep generation flowing in
  parallel without the main session losing track of coordination and integration.
- **Opus-authored code isn't self-reviewed in-session.** The failed legs I write at
  the end are un-judged — once the author is the top model, independent review is
  gone by construction, so the real final check is running it. If Opus-written code
  breaks, that surfaces when it's run and gets fixed in a following message.
- **Watch the batched Opus stage.** If most chunks fail through to me, that end-of-run
  batch becomes one large sequential Opus write — a signal the specs need tightening,
  not a reason to add more workers.

Decompose a large job into independent, well-spec'd units first; then fan out
the units that don't depend on each other, and sequence the ones that do.

## What stays with Claude, always

- All design and architecture decisions.
- The short intent (a workable goal, not a spec).
- Judging: the plan against the intent, and the diff against the plan.
- The escalation decision.
- Anything novel, tricky, or where correctness is subtle and hard to spec.

For non-trivial tasks DeepSeek Pro drafts the plan and DeepSeek implements against it; Claude
judges both but authors neither. Only short, one-shottable tasks are planned (or written) by
Claude directly.
