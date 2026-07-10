# DeepSeek implementation pipeline

Delegate spec-able *implementation* to DeepSeek (metered, my own account — cost is not a
concern); keep *design, spec-writing, and review* with Claude. The point is to conserve
Claude rate-limit usage: DeepSeek does the heavy code generation you'd otherwise spend
Claude quota on. Bias every choice toward resolving at DeepSeek and avoiding the Opus rung.

## When to use it
- **A direct instruction wins.** If I say "implement it directly / you write it / handle
  it yourself," skip the pipeline and just write the code.
- Use it for open-ended, spec-able implementation work — especially bulk or
  parallelizable chunks — where DeepSeek is likely to succeed.
- When in doubt on hard/novel work, ask whether to delegate. Work that will likely
  escalate to Opus anyway is often cheaper (in Claude usage) done directly.

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

## Planning: draft on DeepSeek only when the spec would be long
Writing the spec is Opus *output* — the expensive part. Offload it to DeepSeek only when
it's actually big; otherwise the offload costs more than it saves.
- **Easy / near-mechanical → reword and relay, don't plan.** Sharpen the request wording
  and dispatch it straight to Pro to implement.
- **Would need a long spec → let Pro draft it** (`--plan`), then judge that draft against
  intent before implementing. You offload the writing but keep the design check.
- **Short spec → just write it.** Judging a drafted plan ≈ designing it anyway; below a
  few paragraphs the draft-then-judge round-trip costs more than it saves.

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
```

## The loop
Spec (explicit acceptance criteria; lean, precise on *what correct means*, sparse on
*how*) → dispatch → review against the spec → escalate on failure. See `sample_spec.md`
for the spec format. Judging stays with Opus (independent gate); DeepSeek never judges its
own work. To keep re-judges cheap, hold the spec text stable and run the rungs back-to-back
so Claude Code's automatic prompt caching stays warm — a minor tailwind on the reused
prefix only, not on each fresh version under review.

## Escalation ladder
1. **Flash, first pass** (`--flash`). Review.
2. **Pro, rewrite 1** — feed a specific, actionable critique back. Review.
3. **Pro, rewrite 2** — one more critique-and-rewrite. Review.
4. **Opus (you) writes it directly** — only after Flash + two Pro rewrites miss.

Cap: three DeepSeek attempts before Opus; don't loop past it. Announce the rung as you
go. A chunk that keeps failing usually has a spec problem, not a model problem.

## Parallel work
For genuinely independent chunks, fan out ~3–5 `deepseek-implementer` subagents (each
runs Flash → Pro → Pro and judges on Opus, escalating failed legs back to me). I
initiate them, wait on all, then batch the Opus rung at the end. Subagents don't spawn
subagents. Only parallelize chunks with no shared state or ordering dependency.

## Always Claude's
Design/architecture, spec authoring, review, the escalation decision, and anything
novel or subtle. DeepSeek only implements against a spec I wrote.

Full rationale and the subagent judging rules: `docs/deepseek-pipeline.md`.
