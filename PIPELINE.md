# Autonomous Claude and DeepSeek Pipeline

Claude Code uses Opus for intent, architectural judgment, review, and final
verification. DeepSeek runs as an API subprocess for planning, native test
generation, and bounded implementation steps.

## Automatic use

The personal `build` skill applies this workflow to implementation, bug fix,
refactor, and test-change requests in Git repositories. Explanation, inspection,
and planning-only requests do not trigger it.

For normal requests, the skill first applies a conservative fast-path gate.
Clear changes limited to one implementation file and under 20 changed lines may
be handled directly by Claude when they avoid dependencies, public contracts,
state, security, concurrency, networking, build logic, and other high-risk areas.
The direct path uses no DeepSeek or subagent and still requires focused
verification. Any uncertainty routes to the full pipeline. Explicit `/build`
always forces the full pipeline.

The pipeline requires a clean worktree. It stops instead of committing or
overwriting pre-existing changes.

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
| Plan | `deepseek-v4-pro` |
| Native tests | `deepseek-v4-pro`, unless Opus selects the judgment fallback |
| Plan gate | Claude Opus session |
| Code steps | `deepseek-v4-flash`, then `deepseek-v4-pro` on retries |
| Escalated step repair | Claude Opus session |
| Review | Claude Opus session when triggered or required by the judgment fallback |
| Final request check | Claude Opus session |

## Workflow

1. `pipeline/run.sh` records the base commit and detects the native toolchain.
2. Claude writes the original request and intent artifacts.
3. DeepSeek creates the plan and native tests independently. If Opus recorded
   that behavioral tests are impossible in the available environment, the test
   stage records the reason and keeps only the detected mechanical check.
4. `pipeline/check_baseline.sh` establishes the pre-implementation baseline and
   classifies it. Red because an assertion does not hold yet is the point. Red
   because the generated tests cannot execute is a defect in the tests, and it
   HALTs instead of spending coder attempts on an unwinnable step.
5. Claude gates the plan, maps exact native test names to steps, and corrects test signature drift.
6. `pipeline/waves.sh` runs dependency-safe, file-disjoint steps in parallel worktrees.
7. Each step may write only its allowlisted files and may not edit tests or dependency manifests.
8. The native adapter runs mapped tests, or the fallback mechanical command,
   after every implementation attempt.
9. `pipeline/final_check.sh` runs the whole suite, or the fallback mechanical
   command. In test mode, regressions in untargeted tests surface only here.
10. On a step's ESCALATE, the Opus session repairs that one step, then `waves.sh`
    resumes the steps the stall blocked. When the mapped test is what is wrong,
    `restart_run.sh` regenerates instead and the workflow resumes from step 3.
11. Opus review is mandatory for judgment-fallback runs and for repaired runs.
12. A fresh Claude subagent receives only the original request and final diff,
    then returns the ACCEPT or DRIFT verdict.
13. Accepted step commits collapse into one implementation commit.

## Safety invariants

Each line is a rule and the mechanism that enforces it. The failure that
motivated a rule is in the commit that added it and in the script's own comment;
this list is the contract, not the history.

**Request and scope**

- Preserve the request verbatim in `.pipeline/request.txt`. Stop on low intent
  confidence.
- `.pipeline/intent.json` `allowed_files` is authoritative. Steps may not modify
  tests or dependency manifests.
- Keep tests independent of the generated plan.
- Never leave a step's `tests` array empty in generated-tests mode
  (`validate_plan.sh` rejects it): empty means "run the whole suite", so the step
  is graded against tests for files it may not write. Merge it into its consumer.
- Give the tester the spec. `tests.sh` includes `spec_files` from `intent.json`,
  falling back to tracked markdown referenced from `intent.md`. Without it the
  tester sees only files the run has yet to create and invents the domain.

**Credentials**

- Redact by path AND by content. Read-only context: matching lines redacted. A
  file the step may rewrite: a match is fatal, as are binary and secret-bearing
  writable paths.
- `.pipeline-model-exclude` withholds whole files from every model; excluded files
  cannot be writable steps. `.pipeline-model-allow` clears a reviewed false
  positive per line, as `<sha256-of-line>  <repo-relative-path>` using the hash
  the refusal prints. `waves.sh` copies both into every step worktree.

**Coder bounds**

- `PIPELINE_MAX_ATTEMPTS`, default 3, range 1-3. The ladder is by attempt index —
  flash, pro, pro — so a lower cap truncates it rather than reassigning models.
  Out of range is a configuration error.
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
- `code.sh` stops at two attempts when the failure signature repeats: attempt 1 is
  flash and attempt 2 is pro, so an identical failure is already a cross-model
  result. The signature strips digits and hex runs.
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
  The routing gate resolves that path against the project, so a hand-written ack
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

## Main artifacts

| Artifact | Purpose |
|---|---|
| `.pipeline/toolchain.json` | Language, framework, commands, selector mode, test path |
| `.pipeline/intent.md` | Human-readable intent |
| `.pipeline/intent.json` | Authoritative allowlist and structured intent |
| `.pipeline/plan.md` | DeepSeek plan |
| `.pipeline/tests_spec.md` | Generated tests, existing-suite context, or judgment-fallback reason |
| `.pipeline/plan_final.json` | Claude-gated steps, dependencies, exact test names |
| `.pipeline/repair_ctx.md` | Brief for the Opus repair of an escalated step |
| `.pipeline/attempt-N/` | Plan, tests, and reason of an abandoned attempt |
| `.pipeline/verify.md` | ACCEPT or DRIFT verdict, checked by `validate_verify.sh` |

## Commands

- `/build <request>` runs the full workflow.
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
| `test_hardening.sh` | Title normalization, baseline classification, early escalation, attempt cap and ladder, symbol index, run-scoped test path |
| `test_retry_escalation.sh` | Second-attempt success, review triggering, scope rejection, three-attempt escalation, resume |
| `test_repair.sh` | Repair brief, `repair_done.sh` refusals, accepted repair, resume without re-running |
| `test_restart.sh` | What restart resets and keeps, tag and archive, unstacked stamp, restart budget |
| `test_verify.sh` | ACCEPT, DRIFT, malformed verifier output |
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
