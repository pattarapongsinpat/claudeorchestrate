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
   HALTs instead of spending three coder attempts on an unwinnable step.
5. Claude gates the plan, maps exact native test names to steps, and corrects test signature drift.
6. `pipeline/waves.sh` runs dependency-safe, file-disjoint steps in parallel worktrees.
7. Each step may write only its allowlisted files and may not edit tests or dependency manifests.
8. The native adapter runs mapped tests, or the fallback mechanical command,
   after every implementation attempt.
9. `pipeline/final_check.sh` runs the whole suite, or the fallback mechanical
   command. In test mode, regressions in untargeted tests surface only here.
10. On a step's ESCALATE, the Opus session repairs that one step itself, then
    `waves.sh` resumes the steps the stall blocked. Two repairs per run maximum.
11. Opus review is mandatory for judgment-fallback runs and for repaired runs.
12. A fresh Claude subagent receives only the original request and final diff,
    then returns the ACCEPT or DRIFT verdict.
13. Accepted step commits collapse into one implementation commit.

## Safety invariants

- Preserve the user's request verbatim in `.pipeline/request.txt`.
- Stop on low intent confidence.
- Keep tests independent from the generated plan.
- Treat `.pipeline/intent.json` `allowed_files` as authoritative.
- Prevent implementation steps from modifying tests or dependency manifests.
- Redact credentials from model context by path AND by content. In a read-only
  context the matching lines are redacted; for a file the step may rewrite,
  a match is fatal. Binary and secret-bearing writable paths are also fatal.
  Add exact repository-relative paths to `.pipeline-model-exclude` to withhold
  complete files from every model. Excluded files cannot be writable steps.
  Clear a reviewed false positive per line, not per file: put
  `<sha256-of-the-line>  <repo-relative-path>` in `.pipeline-model-allow`, using
  the hash the refusal prints. `waves.sh` copies both files into every step
  worktree, so one recorded approval also holds for parallel steps.
- Bound every test invocation with `test_timeout_seconds`, so a coder-introduced
  infinite loop cannot hang a run. `PIPELINE_TEST_TIMEOUT` overrides.
- Do not charge a bad test to the coder. Three separate guards, because the
  failure looks identical from the exit code in every case:
  `check_baseline.sh` HALTs when the generated tests raise `ReferenceError`,
  `NameError`, `SyntaxError`, `IndentationError`, or `Unexpected token`, which
  mean the file does not execute rather than that the feature is missing — a
  helper declared inside one `describe` and used from four others fails this way
  no matter what the implementation does. `PIPELINE_ALLOW_BROKEN_TESTS=1`
  overrides for a test that legitimately asserts on those words. `code.sh` stops
  after two attempts when the failure signature repeats, since attempt 1 runs on
  flash and attempt 2 on pro, so an identical failure is already a cross-model
  result and the third call only reproduces it; the marker says to suspect the
  test. The signature strips digits and hex runs, so a random id in the message
  does not disguise a repeat.
- Cap coder calls per step at `PIPELINE_MAX_ATTEMPTS`, default 3, valid values 1
  to 3. A DeepSeek retry is far cheaper than the Opus turn it avoids, so an
  attempt-2 pass on pro costs a fraction of the repair it replaces. This was
  briefly 1, on the reasoning that the extra attempts were wasted whenever the
  step was unwinnable — true while an escalation ended the run and a human picked
  it up, and no longer true now that Opus repairs a step the coder got wrong and
  `restart_run.sh` regenerates tests that were wrong. The ladder is indexed by
  attempt, not by the cap: attempt 1 on flash, attempts 2 and 3 on pro, so
  lowering the cap truncates it rather than reassigning models. A value outside
  1-3 is a configuration error and stops the step. The repeated-signature guard
  below still cuts the ladder short when another sample will not help.
- Repair an escalated step in the main Opus session, and grade that repair with a
  script. The session already holds the request, the intent, and the plan, so a
  subagent would pay for that context again to know less. But it is also the
  session that decided to repair, so it does not get to grade itself:
  `repair_done.sh` re-checks the allowlist, the dependency manifests, the test
  files, and the step's own mapped tests against the working tree, and only then
  commits and marks the step done. It refuses rather than negotiating, and it
  never lets the session edit `done.json` directly, since a hand-written `done`
  entry makes `waves.sh` skip a step that was never implemented. `ever_escalated`
  survives the repair, so `review_trigger.sh` still demands the Opus review and
  the isolated verify subagent still gives the one independent verdict.
- Restart the run when the tests are what failed; never edit them to fit. The
  cheap way to make a test pass is to change what it asserts, so `restart_run.sh`
  regenerates instead: it resets to the run base, tags the abandoned commits,
  archives the failing tests and the reason under `.pipeline/attempt-N`, and
  clears the plan and the tests while keeping the request and the intent, which
  did not change. The tester then runs again from the request and the spec,
  independently of the plan and of whatever the last attempt wrote, so a bad
  assertion is redrawn rather than bent. One restart per request
  (`PIPELINE_MAX_RESTARTS`): a second bad test set points at the spec or the
  intent, and regenerating again will not find that. The new test path is stamped
  from a freshly detected toolchain, because restamping the current one appends to
  the previous stamp and every restart lengthens the name.
- Put the mapped test source in the repair brief. The coder never sees the test
  file, so it can fail a step for a reason no rewrite fixes: an exact error string
  it had to guess, a field name stated nowhere else. Opus can read that file, and
  that asymmetry is most of what the repair stage is for, so `repair_ctx.sh` hands
  it over instead of making the repair go looking. Oversized files fall back to
  the mapped tests with 25 lines of context, because the declaration line without
  its assertion answers nothing. The file stays read-only; `repair_done.sh`
  refuses a repair that edits its own grader.
- Enforce the repair budget in `repair_done.sh`, not in the instructions.
  `PIPELINE_MAX_REPAIRS`, default 2, counts `repaired_by_opus` entries in
  `done.json` and refuses beyond it. Left as prose the stage quietly becomes
  "Opus writes everything": the verify subagent sees only the request and the
  final diff, so a run repaired end to end is indistinguishable from one DeepSeek
  produced, and the cost the stage exists to bound goes unmeasured. Two failures
  are a bad step; three are a bad plan or a bad generated test.
- Let `repair_ctx.sh` write `.claude/routing-ack` and exclude it locally. The
  routing gate resolves that path against the working directory, which during a
  run is the project rather than the runtime, so a hand-written ack lands in the
  project, dirties the tree `waves.sh` refuses to start on, and reads to
  `repair_done.sh` as a file outside the step allowlist. `repair_done.sh` skips
  that one exact path and no other part of `.claude/`.
- Release the waves lock in the same trap that removes the worktrees. `waves.sh`
  sets an EXIT trap for the lock and then replaced it with the worktree cleanup,
  so every run ended still holding its own lock. It self-healed only because the
  next run found the recorded pid dead; a reused pid turns that into a clean
  repository refusing to start with "another waves run is already active".
- Give the coder a repository symbol index. `symbol_index.sh` lists declarations
  from non-test sources as `path:line: declaration`, and `code.sh` includes it in
  every step. A step sees only its allowlist and its context files, so without
  this it reimplements helpers that already exist elsewhere — duplication no
  single diff reveals and review catches late, if at all.
- Normalize generated test titles to identifiers in `tests.sh`. The tester writes
  prose, `validate_test_names.sh` requires `^[A-Za-z_][A-Za-z0-9_]*$`, and the
  runner selectors build one regex from the mapped names, where a space or colon
  matches wrongly. Colliding titles get a numeric suffix so no two tests share a
  selector.
- Scope the generated test path to the run. `run.sh` inserts a timestamp, so a
  second run never collides with the previous run's tests, which are now part of
  the suite. `tests.sh` still refuses to overwrite an existing path.
- Clear `.pipeline/ESCALATE` at the start of `waves.sh`. It is appended to within
  a run so parallel failures both survive; across runs a stale marker reports a
  step that has since passed.
- Bound the coder by output budget, not by hope: `DS_MAX_TOKENS` (default 131072)
  and `DS_MAX_TIME` (default 1200s) in `ds.sh`. The contract is whole-file
  output, so the budget must cover the largest file the pipeline can rewrite —
  and, on reasoning models, the reasoning that precedes it. A dense step once
  produced 276K characters of `reasoning_content` with empty `content` and hit
  the old 64000 ceiling, aborting before the retry that escalates to the stronger
  model. On truncation `ds.sh` now reports content and reasoning lengths and
  names the cause, because "split the step" is the wrong fix for a runaway
  reasoning trace.
- Parse the coder's file blocks by keyword, not by exact delimiter width.
  `apply_files.sh` accepts a 4-12 character marker run and unwraps a single
  Markdown fence around the body. A model that emitted six `<` instead of seven
  once produced a complete, correct 500-line file that parsed as zero blocks:
  nothing was written, the step consumed all three attempts, and the feedback
  said NO FILE BLOCKS FOUND, which reads like a coding failure rather than a
  formatting slip. `FILE` and `ENDFILE` are what identify a marker, so an exact
  run length bought no safety. Content that only resembles a marker, such as a
  `<<<<<<< HEAD` conflict sample, is still body text.
- Give the tester the specification. `tests.sh` includes every path in
  `spec_files` from `intent.json`; absent that, it falls back to tracked markdown
  paths referenced from `intent.md`. Without this the tester only sees the
  contents of `allowed_files`, which are the files the run has yet to create, so
  it invents the domain and emits tests that assert wrong field names and
  unsatisfiable values. Declare `spec_files` whenever a behavioral spec exists.
- Never leave a step's `tests` array empty in generated-tests mode.
  `validate_plan.sh` rejects it. An empty array does not mean "unverified", it
  means "run the whole suite", so the step is graded against tests for files it
  may not write and can never pass. Merge a step that has nothing to assert into
  the step that consumes it.
- Run one `waves` process at a time. `waves.sh` takes an atomic `mkdir` lock at
  `.pipeline/waves.lock` and refuses to start while a live holder exists, clearing
  the lock only when its pid is gone. Concurrent runners share `.pipeline/wt/` and
  `done.json`, delete each other's worktrees mid-step, and mark each other's
  completed steps as escalated; the symptom is a missing `code.log`, which reads
  like an API failure rather than a collision.
- Keep raw DeepSeek responses under the ignored `.pipeline/raw` directory.
- Preserve partial commits on drift or escalation for inspection.

## Main artifacts

| Artifact | Purpose |
|---|---|
| `.pipeline/toolchain.json` | Language, framework, commands, selector mode, and test path |
| `.pipeline/intent.md` | Human-readable intent |
| `.pipeline/intent.json` | Authoritative allowlist and structured intent |
| `.pipeline/plan.md` | DeepSeek plan |
| `.pipeline/tests_spec.md` | Generated tests, existing-suite context, or the judgment-fallback reason |
| `.pipeline/plan_final.json` | Claude-gated steps, dependencies, and exact test names |
| `.pipeline/repair_ctx.md` | Brief for the Opus repair of an escalated step |
| `.pipeline/attempt-N/` | Plan, tests, and reason of an abandoned attempt |
| `.pipeline/verify.md` | Final ACCEPT or DRIFT verdict, checked by `validate_verify.sh` |

## Commands

- `/build <request>` runs the full workflow.
- `/intent`, `/gate`, `/review`, and `/verify` expose individual Claude stages.

Run `pipeline/test_adapters.sh` to validate toolchain detection and selector
dispatch without calling the DeepSeek API.

Run `pipeline/test_safety.sh` to validate plan identifiers, dependency
references, traversal rejection, and symlink write protection.

Run `pipeline/test_apply_files.sh` to validate coder-output parsing without the
API: short, long, and mismatched marker runs, Markdown-fence unwrapping against
fences that are real content, and the unchanged refusals for an unterminated
block and an out-of-scope path.

With a configured API key, `pipeline/test_api.sh` verifies the DeepSeek API
wrapper and `pipeline/test_e2e_node.sh` runs a real red-to-green Node coding loop
through `code.sh`.

`pipeline/test_e2e_waves.sh` runs two file-disjoint DeepSeek implementation steps
in parallel worktrees, cherry-picks both commits, and runs the complete suite.

`pipeline/test_retry_escalation.sh` deterministically exercises a successful
second attempt, review triggering, scope rejection, and three-attempt escalation.

`pipeline/test_hardening.sh` covers the bad-test guards without the API: title
normalization and collision suffixing, HALT on a test file that cannot execute
against no HALT on an ordinary failing assertion, early escalation on a repeated
failure signature against a full three attempts when the failure changes, the
attempt cap and its model ladder, the symbol index, and the run-scoped generated
test path.
`pipeline/test_repair.sh` covers the escalated-step repair without the API: the
brief, the five refusals in `repair_done.sh` (nothing changed, out of allowlist,
test file edited, manifest edited, mapped tests still failing), the exhausted
repair budget, the accepted repair, and the `waves.sh` resume that does not
re-run the repaired step.

`pipeline/test_restart.sh` covers `restart_run.sh` without the API: what it
resets, what it keeps, the tag and archive of the abandoned attempt, the single
unstacked test-path stamp, and the one-restart budget.

`pipeline/test_verify.sh` checks ACCEPT, DRIFT, and malformed verifier outputs.

`pipeline/test_e2e_compiled.sh <java|csharp|c|cpp>` runs a real DeepSeek coding
loop against that compiled language. On Windows, use `test_java.ps1 -E2E` for a
temporary checksum-verified Java toolchain.

`pipeline/validate_test_names.sh` checks generated test mappings against their
native source before waves. Existing-suite C and C++ steps use empty mappings
and run the full suite.

On Windows, `pipeline/invoke.ps1 <script> -Repo <project-root>` runs against an
explicit repository and restores the caller's working directory.

Run `pipeline/smoke_adapters.sh` to drive each adapter's real toolchain against a
hand-written test file, also without the API. It checks that the runner discovers
a file at `generated_test_file` and that the selector resolves one named test,
and it skips adapters whose toolchain is not installed rather than passing them.

On Windows, `pipeline/test_java.ps1` downloads checksum-verified portable JDK and
Maven archives, runs the smoke suite with them, and removes the temporary
toolchain afterward.

`pipeline/test_all_toolchains.ps1` extends that audit with temporary Go, Gradle,
Meson, and GNU Make toolchains so every advertised adapter is exercised.

Most runners exit 0 when a selector matches no test — verified for `node --test`,
Vitest, Jest, Go, Cargo, Maven, and `dotnet test`. Before any coder call,
`validate_test_names.sh` checks generated mappings against native test source.
Existing-suite adapters use empty mappings and run the complete suite.
