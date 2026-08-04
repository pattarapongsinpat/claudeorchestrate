# Autonomous Claude and DeepSeek Pipeline

Claude Code uses Opus for intent, architectural judgment, review, and final
verification. DeepSeek runs as an API subprocess for planning, native test
generation, and bounded implementation steps.

## Automatic use

The personal `build` skill applies this workflow to implementation, bug fix,
refactor, and test-change requests in Git repositories. Explanation, inspection,
and planning-only requests do not trigger it.

Claude writing the change directly is the default. A pipeline run costs a plan, a
test-generation pass, a coder call per step, and several Opus stages, so the skill
escalates only on a named risk: more than roughly five files or 150 lines, a
public contract or schema other code depends on, security or concurrency or a
data migration, a dependency change, a decision the request does not carry, work
Claude cannot verify, or the user asking for it. Uncertainty alone is not one —
reading the code is cheaper than a run. Explicit `/build` and `/campaign` always
force the full pipeline.

The pipeline requires a clean worktree. It stops instead of committing or
overwriting pre-existing changes.

A request that does not fit one plan runs as a campaign instead: `/campaign`
splits it once into build-sized units and runs the full pipeline on each.

## Supported project adapters

| Language | Detection | Native runner | Test mode |
|---|---|---|---|
| Python | `pyproject.toml`, `setup.py`, or `requirements.txt` | pytest | Generated tests |
| JavaScript | `package.json` | Vitest, Jest, Node test, or npm test | Generated when supported |
| TypeScript | `package.json` and `tsconfig.json` | Vitest, Jest, or existing npm test | Generated when supported |
| Go | `go.mod` | `go test` | Generated tests |
| Rust | `Cargo.toml` | `cargo test` | Generated tests |
| Java | Maven or Gradle manifests | Maven or Gradle test | Generated tests |
| C# | solution or project files | `dotnet test` or `dotnet build` | Generated tests when a test project exists; compile plus Opus judgment otherwise |
| C | CMake, Meson, or Make | CTest, Meson test, or `make test` | Existing suite |
| C++ | CMake, Meson, or Make | CTest, Meson test, or `make test` | Existing suite |

`pipeline/detect.sh` writes `.pipeline/toolchain.json`. Every later stage uses
that artifact instead of hardcoded language commands.

C and C++ use the existing native suite because build and test registration
vary by project. C# falls back to an unambiguous project or solution build when
no test project exists, then requires Opus to judge behavior directly. Opus may
also select this fallback when meaningful tests require an unavailable host,
such as BepInEx, a game engine, hardware, or proprietary software. Missing tools
or a broken test suite do not justify the fallback. Unsupported or ambiguous
toolchains write `.pipeline/HALT` with the reason.

## Model roles

| Stage | Model |
|---|---|
| Intent | Claude Opus session |
| Assumption check | `deepseek-v4-flash` (`PIPELINE_ASSUMPTIONS_MODEL`), request only |
| Campaign split check | `deepseek-v4-flash` (`PIPELINE_BACKLOG_MODEL`), brief and units only |
| Plan | `deepseek-v4-pro` |
| Native tests | `deepseek-v4-pro`, unless Opus selects the judgment fallback |
| Plan gate | Claude Opus session |
| Code steps | `deepseek-v4-flash` or `deepseek-v4-pro`, one graded attempt (`PIPELINE_CODER_MODEL`) |
| Escalated step repair | Claude Opus session |
| Review | Claude Opus session when triggered or required by the judgment fallback |
| Final request check | Claude Opus session |

## Workflow

1. `pipeline/run.sh` records the base commit and detects the native toolchain.
2. Claude writes the original request and intent artifacts, asking the user up
   to three questions in one round when the request does not stand on its own.
3. `pipeline/check_assumptions.sh` has DeepSeek grade the intent's assumptions
   against the request alone, and enforces the verdict and revision budget.
4. DeepSeek creates the plan and native tests independently. If Opus recorded
   that behavioral tests are impossible in the available environment, the test
   stage records the reason and keeps only the detected mechanical check.
5. `pipeline/check_baseline.sh` establishes the pre-implementation baseline and
   classifies it. Red because an assertion does not hold yet is the point. Red
   because the generated tests cannot execute is a defect in the tests, and it
   HALTs instead of spending coder attempts on an unwinnable step.
6. Claude gates the plan, maps exact native test names to steps, and corrects test signature drift.
7. `pipeline/waves.sh` runs dependency-safe, file-disjoint steps in parallel worktrees.
8. Each step may write only its allowlisted files and may not edit tests or dependency manifests.
9. The native adapter runs mapped tests, or the fallback mechanical command,
   after every implementation attempt.
10. `pipeline/final_check.sh` runs the whole suite, or the fallback mechanical
    command. In test mode, regressions in untargeted tests surface only here.
11. On a step's ESCALATE, the Opus session repairs that one step, then `waves.sh`
    resumes the steps the stall blocked. When the mapped test is what is wrong,
    `restart_run.sh` regenerates instead and the workflow resumes from step 4.
12. Opus review is mandatory for judgment-fallback runs and for repaired runs.
13. A fresh Claude subagent receives only the original request and final diff,
    then returns the ACCEPT or DRIFT verdict.
14. `pipeline/collapse.sh` re-runs the verify gate itself, then collapses the
    accepted step commits into one implementation commit.

## Safety invariants

Each line is a rule and the mechanism that enforces it. The failure that
motivated a rule is in the commit that added it and in the script's own comment;
this list is the contract, not the history.

**Request and scope**

- Preserve the request verbatim in `.pipeline/request.txt`. Stop when intent
  writes `.pipeline/HALT` because the request needs a decision it does not carry.
- Make `request.txt` self-contained, out of the user's words. "do it" is a whole
  request, and the two stages that read this file and nothing else — the
  assumption check and the final verifier — would be grading the word "it".
  Intent asks one to three questions in one round, the only stage that may ask,
  and records the answers verbatim. They are multiple choice, in one
  `AskUserQuestion` call, each option naming what would be built if picked.
- Confirm the goal on every run. The first question is mandatory and settles what
  to build. Every later stage inherits the goal — assumptions are graded against
  it, tests are written from it, ACCEPT or DRIFT is rendered against it — so the
  stages agree with each other and a wrong goal is the one error none of them can
  catch. The two optional questions are for answers that change what gets built;
  a question with no plausible second option is one to assume instead. Unattended, it quotes the conversation turns
  the request points at instead. Never a paraphrase either way: a summary is the
  intent's reading, which is what those two stages exist to test.
- Do not let the intent stage grade its own confidence. The adjective was chosen
  by the session it was meant to check, nothing downstream contradicted it, and
  the only level with a cost was the one that stopped the run. `check_assumptions.sh`
  grades Assumptions against `request.txt` instead, and `validate_assumptions.sh`
  holds the verdict: `UNSOUND` is archived as `.pipeline/assumptions-N.md`, so the
  count is the budget (`PIPELINE_MAX_ASSUMPTION_REVISIONS`, default 1) and the
  second rejection HALTs rather than letting the session revise until the verdict
  agrees with it.
- Grade the assumptions with DeepSeek, not a Claude subagent. A fresh subagent is
  new context but the same reader, and the failure being caught is a misreading of
  English, so shared priors are exactly what must not be shared. The call is a
  request and a short list, so `flash` by default; `PIPELINE_ASSUMPTIONS_MODEL`
  takes `flash` or `pro`, and anything else is a configuration error.
- Withhold everything but the request from that call. The goal, non-goals,
  allowlist, and plan are all restatements of the reading under test, so
  supplying them grades the intent against itself. A chatty answer is a malformed
  verdict, not a rejection: only `UNSOUND: ` spends the budget.
- Reject overreach, not silence. An unstated parameter filled with an ordinary
  value is SOUND; a measured run had flash reject "retried three times" because
  the request named no count, which would spend the budget on nearly every
  request. The grading prompt says so, with worked examples on both sides.
- `.pipeline/intent.json` `allowed_files` is authoritative. Steps may not modify
  tests or dependency manifests.
- Keep tests independent of the generated plan.
- Never leave a step's `tests` array empty in generated-tests mode
  (`validate_plan.sh` rejects it): empty means "run the whole suite", so the step
  is graded against tests for files it may not write. Merge it into its consumer.
- Give the tester the spec. `tests.sh` includes `spec_files` from `intent.json`,
  falling back to tracked markdown referenced from `intent.md`. Without it the
  tester sees only files the run has yet to create and invents the domain.

**Stages nothing consumed**

- Refuse in the consumer, not in the prose. Three stages wrote an artifact no
  script ever read, so skipping them cost nothing and the failure was silent —
  and they are the three that exist to catch what the orchestrating session
  itself got wrong. `plan.sh` and `tests.sh` now require a `SOUND`
  `assumptions.md`, `waves.sh` requires a matching `baseline.sha`, and
  `collapse.sh` runs `validate_verify` itself.
- Stamp the baseline by content, never by mtime. The gate commits the generated
  test file immediately after re-running the baseline, a worktree copy or a
  checkout rewrites mtimes without changing a byte, and timestamp granularity is
  coarser than the gap between two writes. `baseline_stamp.sh` hashes the file
  with `\r` stripped, because with `core.autocrlf` a checkout rewrites every line
  ending and a stamp that moved on that would abort a legitimate resume.
- Existing-suite and judgment adapters stamp the literal `existing-suite`. The
  stamp's absence is the signal, so there is no mode in which it may be missing.
- `collapse.sh` performs the reset. Left as prose, "never collapse unless
  `validate_verify` exits 0" was a rule administered by the party doing the
  collapsing. It refuses on DRIFT, a malformed verdict, any HALT, ESCALATE, or
  REGRESSION marker, a dirty tree, and a HEAD still at the run base.

**Credentials**

- Redact by path AND by content. Read-only context: matching lines redacted. A
  file the step may rewrite: a match is fatal, as are binary and secret-bearing
  writable paths.
- `.pipeline-model-exclude` withholds whole files from every model; excluded files
  cannot be writable steps. `.pipeline-model-allow` clears a reviewed false
  positive per line, as `<sha256-of-line>  <repo-relative-path>` using the hash
  the refusal prints. `waves.sh` copies both into every step worktree.

**Coder bounds**

- One graded attempt per step. `PIPELINE_CODER_MODEL` picks `flash` (default) or
  `pro`; anything else is a configuration error. There is no flash-then-pro
  ladder: a failed assertion escalates to the Opus repair, which can read the
  mapped test the coder never sees and so solves failures no further DeepSeek
  sample would. The ladder's retries were reverted wholesale on escalation, so
  they bought a diagnosis the first failure already carried.
- Re-ask, do not escalate, when the output never reached a test. Truncated,
  malformed, empty, and out-of-scope responses are formatting failures with no
  assertion behind them, so `PIPELINE_MAX_FORMAT_RETRIES` (default 2) re-asks the
  same model. Exhausting them says the coder produced no usable output rather
  than blaming the code.
- Carry the failed attempt into `.pipeline/ESCALATE` as a diff. It is reverted
  from the tree, so nothing unverified can be committed, but it is the only
  artifact the failed call produced and the repair usually needs to change one
  line of it rather than rewrite from the original.
- `DS_MAX_TOKENS` (131072) and `DS_MAX_TIME` (1200s) in `ds.sh`. The contract is
  whole-file output, so the budget must cover the largest file the pipeline can
  rewrite plus any reasoning trace. On truncation `ds.sh` names the cause.
- Bound every test invocation with `test_timeout_seconds`
  (`PIPELINE_TEST_TIMEOUT` overrides), so a coder-introduced loop cannot hang a run.
- Give the coder a symbol index. `symbol_index.sh` lists non-test declarations as
  `path:line: declaration`; without it a step reimplements helpers it cannot see.
- Parse file blocks by keyword, not delimiter width. `apply_files.sh` accepts a
  4-12 character marker run and unwraps a single Markdown fence. `FILE` and
  `ENDFILE` identify a marker; a `<<<<<<< HEAD` sample stays body text.

**Do not charge a bad test to the coder**

- `check_baseline.sh` HALTs when generated tests raise `ReferenceError`,
  `NameError`, `SyntaxError`, `IndentationError`, or `Unexpected token` — the file
  does not execute, so no implementation can satisfy it.
  `PIPELINE_ALLOW_BROKEN_TESTS=1` overrides.
- Normalize generated test titles to identifiers in `tests.sh`. Selectors build one
  regex from mapped names, where a space or colon matches wrongly. Colliding titles
  get a numeric suffix.
- Scope the generated test path to the run. A previous run's tests are part of the
  suite, and `tests.sh` refuses to overwrite.

**Escalation**

- Opus repairs an escalated step in the main session — it already holds the
  request, intent, and plan — but does not grade itself. `repair_done.sh`
  re-checks the allowlist, manifests, test files, and mapped tests, then commits
  and marks the step done. It refuses rather than negotiating, and `done.json` is
  never hand-edited: a fake `done` entry makes `waves.sh` skip an unimplemented
  step.
- `repair_ctx.sh` puts the mapped test source in the brief. The coder never sees
  it, so it can fail on an error string it had to guess; Opus can read it. Files
  over 800 lines fall back to the mapped tests with 25 lines of context. The file
  stays read-only.
- `repair_ctx.sh` also writes `.claude/routing-ack` and adds it to `info/exclude`.
  The routing gate is off unless `ROUTING_GATE=strict`, but the ack still has to be
  written where the gate resolves it — against the project — so a hand-written one
  dirties the tree and reads as out-of-allowlist. `repair_done.sh` skips that one
  exact path.
- `PIPELINE_MAX_REPAIRS`, default 2, enforced in `repair_done.sh` by counting
  `repaired_by_opus` in `done.json`. Left as prose the stage becomes "Opus writes
  everything", and the verify subagent sees a diff, not authorship.
- `ever_escalated` survives a repair, so `review_trigger.sh` still demands the
  Opus review and the isolated verify subagent still gives the one independent
  verdict.
- When the test is what failed, `restart_run.sh` regenerates rather than editing
  it: reset to the run base, tag the abandoned commits, archive the failing tests
  and reason under `.pipeline/attempt-N`, clear plan and tests, keep request and
  intent. `PIPELINE_MAX_RESTARTS`, default 1 — a second bad test set points at the
  spec or intent. The new test path is stamped from a freshly detected toolchain,
  or stamps stack.

**Concurrency and state**

- One `waves` process at a time, via an atomic `mkdir` lock at
  `.pipeline/waves.lock`, cleared only when the holder's pid is gone. The same
  EXIT trap that removes worktrees releases the lock.
- Clear `.pipeline/ESCALATE` at the start of `waves.sh`: appended to within a run
  so parallel failures survive, stale across runs.
- Keep raw DeepSeek responses under the ignored `.pipeline/raw`.
- Preserve partial commits on drift or escalation.

## Campaigns

A request too large for one `/build` runs as a campaign: split once into
build-sized units, each unit a full pipeline run on the previous unit's commit.
The per-unit Opus work runs in a fresh subagent, so a long campaign does not
accumulate context — the coder was never Claude, and the orchestrator keeps a
backlog and one result line per unit.

1. `campaign_init.sh` requires a clean worktree and records the campaign base.
2. Claude asks the question round once, for the whole campaign, and writes
   `.campaign/brief.txt` under every rule that governs `request.txt`.
3. Claude decomposes the brief into `.campaign/backlog.json`.
   `validate_backlog.sh` checks its shape and builds `.campaign/state.json`, then
   `check_backlog.sh` has DeepSeek grade the split against the brief alone.
4. `campaign_next.sh` writes `.campaign/unit_request.txt` and prints the unit id.
   Exit 3 means the backlog is finished.
5. A fresh subagent runs `/build`. Intent finds the unit request and asks nothing.
6. `campaign_done.sh` records the unit, or `campaign_fail.sh` retries it.
7. A last isolated subagent renders ACCEPT or DRIFT on the whole campaign diff
   against the brief. Unit commits are never collapsed.

**Campaign invariants**

- Campaign state lives in `.campaign/`, never `.pipeline/`, which `run.sh`
  deletes at the start of every unit. That deletion is what makes units stack.
- Decompose once. A unit that uncovers new work fails the campaign rather than
  appending to the backlog: a scope that grows per unit has nothing checking it
  against the brief. `PIPELINE_MAX_CAMPAIGN_UNITS`, default 12 — a longer
  campaign is a request that was never narrowed.
- Ask once, before any unit runs. Per-unit questions would repeat the same round
  after the decomposition already committed to an answer, where no answer can
  still change the backlog.
- Mark the unit text as the pipeline's decomposition inside `unit_request.txt`,
  and carry the brief verbatim beside it. The assumption check and the final
  verifier read that file and nothing else, so an unmarked unit text is Claude's
  paraphrase being graded against itself — the laundering `intent.md` forbids.
- Grade the split before any unit runs, not after all of them. The decomposition
  is the highest-leverage reading in a campaign, and it was the only reading in
  the pipeline with no independent check: each unit agrees with the split, and
  the campaign verifier reads the diff after ten units are committed.
  `check_backlog.sh` is `check_assumptions.sh` at campaign scale — DeepSeek, the
  brief and the units and nothing else, `SOUND` or `UNSOUND`, the rejection count
  is the file count (`PIPELINE_MAX_BACKLOG_REVISIONS`, default 1).
- Reject scope, not division. How many units there are, where the lines fall, and
  what order they run in cannot be judged without the repository, so the grading
  prompt rejects only a unit the brief never asked for or a thing the brief asks
  for that no unit builds. Setup and migration units are SOUND unnamed.
- Retry a failed unit; do not repair it. `PIPELINE_MAX_UNIT_ATTEMPTS`, default 2.
  Escalation inside a unit is the build pipeline's own stage and already ran.
- Archive the failed attempt's `.pipeline/` to `.campaign/failed/<unit>-<attempt>/`
  before resetting. The subagent that ran the unit reports one line; the escalated
  step's diff, the coder log, the raw responses, and the regression output are all
  in `.pipeline`, and the next unit's `run.sh` deletes it. The retry's
  `unit_request.txt` carries an excerpt (`PIPELINE_FAILURE_EXCERPT_LINES`, default
  40) and the rest stays on disk, so a stopped campaign can be read and resumed
  deliberately rather than guessed at.
- Stop on the impossible, in the three forms a script can recognise: an intent
  HALT (the campaign is the stage that cannot ask, so the retry asks the same
  unanswerable question), the identical failure twice, and a spent budget.
- Reset a retry to the unit's base, not the campaign base, and tag what it
  abandons. Earlier units committed and are kept.
- `campaign_done.sh` refuses a unit that produced no commit or left the tree
  dirty. A reported success that changed nothing would walk the backlog to the
  end having built none of it.
- Verify the campaign against the brief at the end. Each unit's verifier judged
  that unit against its own text, which is the decomposition, not the request.

## Main artifacts

| Artifact | Purpose |
|---|---|
| `.pipeline/toolchain.json` | Language, framework, commands, selector mode, test path |
| `.pipeline/intent.md` | Human-readable intent |
| `.pipeline/intent.json` | Authoritative allowlist and structured intent |
| `.pipeline/assumptions.md` | SOUND or UNSOUND verdict on the intent's assumptions |
| `.pipeline/assumptions-N.md` | A rejected assumption verdict, one per spent revision |
| `.pipeline/plan.md` | DeepSeek plan |
| `.pipeline/tests_spec.md` | Generated tests, existing-suite context, or judgment-fallback reason |
| `.pipeline/plan_final.json` | Claude-gated steps, dependencies, exact test names |
| `.pipeline/repair_ctx.md` | Brief for the Opus repair of an escalated step |
| `.pipeline/attempt-N/` | Plan, tests, and reason of an abandoned attempt |
| `.pipeline/verify.md` | ACCEPT or DRIFT verdict, checked by `validate_verify.sh` |
| `.campaign/brief.txt` | The campaign request and its one round of answers, verbatim |
| `.campaign/backlog.json` | Ordered units, decomposed once |
| `.campaign/backlog_verdict.md` | SOUND or UNSOUND verdict on the split |
| `.campaign/backlog-N.md` | A rejected split verdict, one per spent revision |
| `.campaign/failed/<unit>-<attempt>/` | The whole `.pipeline/` of a failed attempt, kept for the retry and for reading afterward |
| `.campaign/state.json` | Unit status, attempts, commits, failures, stop reason |
| `.campaign/unit_request.txt` | Brief plus the current unit, read by intent in place of asking |
| `.campaign/verify.md` | ACCEPT or DRIFT on the whole campaign diff |

## Commands

- `/build <request>` runs the full workflow.
- `/campaign <request>` splits a large request into units and runs `/build` on each.
- `/intent`, `/gate`, `/review`, `/verify` expose individual Claude stages.

On Windows, `pipeline/invoke.ps1 <script> -Repo <project-root>` runs against an
explicit repository and restores the caller's working directory.

## Test suites

No API key required:

| Suite | Covers |
|---|---|
| `test_adapters.sh` | Toolchain detection and selector dispatch |
| `test_safety.sh` | Plan identifiers, dependency refs, traversal, symlink writes |
| `test_apply_files.sh` | Coder-output parsing: marker runs, fences, refusals |
| `test_validation.sh` | Plan and mapped-test validation |
| `test_hardening.sh` | Title normalization, baseline classification, single graded attempt, model choice, format re-asks, symbol index, run-scoped test path |
| `test_escalation.sh` | Escalation on a failed assertion, review triggering, scope rejection, resume after escalation |
| `test_repair.sh` | Repair brief, `repair_done.sh` refusals, accepted repair, resume without re-running |
| `test_restart.sh` | What restart resets and keeps, tag and archive, unstacked stamp, restart budget |
| `test_assumptions.sh` | SOUND, UNSOUND, rejection archiving, revision budget, malformed output |
| `test_verify.sh` | ACCEPT, DRIFT, malformed verifier output |
| `test_stage_gates.sh` | Baseline stamp by content, waves refusing a stale or missing baseline, plan and tests refusing an ungraded intent, every collapse refusal |
| `test_campaign.sh` | Backlog validation, state surviving `run.sh`, unit chaining, retry reset and tag, failure archive and retry excerpt, the three stop conditions, attempt budget |
| `test_backlog.sh` | Split grading: SOUND, UNSOUND, rejection archiving, revision budget, malformed output, what the prompt is and is not shown |
| `smoke_adapters.sh` | Each adapter's real toolchain against a hand-written test; skips uninstalled toolchains |

API key required:

| Suite | Covers |
|---|---|
| `test_api.sh` | DeepSeek API wrapper |
| `test_e2e_node.sh` | Real red-to-green Node loop through `code.sh` |
| `test_e2e_waves.sh` | Two file-disjoint steps in parallel worktrees, then full suite |
| `test_e2e_compiled.sh <lang>` | Real coding loop against java, csharp, c, or cpp |

Windows toolchain audits: `test_java.ps1` (portable JDK and Maven, checksum
verified, removed afterward), `test_java.ps1 -E2E` for the compiled e2e, and
`test_all_toolchains.ps1` for Go, Gradle, Meson, and GNU Make.

`validate_test_names.sh` checks generated mappings against native test source
before waves; existing-suite adapters use empty mappings and run the full suite.
Most runners exit 0 when a selector matches no test — verified for `node --test`,
Vitest, Jest, Go, Cargo, Maven, and `dotnet test` — which is why that check runs
before any coder call.
