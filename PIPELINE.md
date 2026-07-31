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
4. `pipeline/run_tests.sh` establishes the pre-implementation baseline.
5. Claude gates the plan, maps exact native test names to steps, and corrects test signature drift.
6. `pipeline/waves.sh` runs dependency-safe, file-disjoint steps in parallel worktrees.
7. Each step may write only its allowlisted files and may not edit tests or dependency manifests.
8. The native adapter runs mapped tests, or the fallback mechanical command,
   after every implementation attempt.
9. `pipeline/final_check.sh` runs the whole suite, or the fallback mechanical
   command. In test mode, regressions in untargeted tests surface only here.
10. Opus review is mandatory for judgment-fallback runs.
11. A fresh Claude subagent receives only the original request and final diff,
    then returns the ACCEPT or DRIFT verdict.
12. Accepted step commits collapse into one implementation commit.

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
- Bound the coder by output budget, not by hope: `DS_MAX_TOKENS` (default 131072)
  and `DS_MAX_TIME` (default 1200s) in `ds.sh`. The contract is whole-file
  output, so the budget must cover the largest file the pipeline can rewrite —
  and, on reasoning models, the reasoning that precedes it. A dense step once
  produced 276K characters of `reasoning_content` with empty `content` and hit
  the old 64000 ceiling, aborting before the retry that escalates to the stronger
  model. On truncation `ds.sh` now reports content and reasoning lengths and
  names the cause, because "split the step" is the wrong fix for a runaway
  reasoning trace.
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
| `.pipeline/verify.md` | Final ACCEPT or DRIFT verdict, checked by `validate_verify.sh` |

## Commands

- `/build <request>` runs the full workflow.
- `/intent`, `/gate`, `/review`, and `/verify` expose individual Claude stages.

Run `pipeline/test_adapters.sh` to validate toolchain detection and selector
dispatch without calling the DeepSeek API.

Run `pipeline/test_safety.sh` to validate plan identifiers, dependency
references, traversal rejection, and symlink write protection.

With a configured API key, `pipeline/test_api.sh` verifies the DeepSeek API
wrapper and `pipeline/test_e2e_node.sh` runs a real red-to-green Node coding loop
through `code.sh`.

`pipeline/test_e2e_waves.sh` runs two file-disjoint DeepSeek implementation steps
in parallel worktrees, cherry-picks both commits, and runs the complete suite.

`pipeline/test_retry_escalation.sh` deterministically exercises a successful
second attempt, review triggering, scope rejection, and three-attempt escalation.
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
