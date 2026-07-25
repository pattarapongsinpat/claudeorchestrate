# Autonomous Claude and DeepSeek Pipeline

Claude Code uses Opus for intent, architectural judgment, review, and final
verification. DeepSeek runs as an API subprocess for planning, native test
generation, and bounded implementation steps.

## Automatic use

The personal `build` skill applies this workflow to implementation, bug fix,
refactor, and test-change requests in Git repositories. Explanation, inspection,
and planning-only requests do not trigger it.

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
| C# | solution or project files | `dotnet test` | Generated tests in an existing test project |
| C | CMake, Meson, or Make | CTest, Meson test, or `make test` | Existing suite |
| C++ | CMake, Meson, or Make | CTest, Meson test, or `make test` | Existing suite |

`pipeline/detect.sh` writes `.pipeline/toolchain.json`. Every later stage uses
that artifact instead of hardcoded language commands.

C and C++ use the existing native suite because build and test registration
vary by project. C# requires an existing test project. Unsupported or ambiguous
toolchains write `.pipeline/HALT` with the reason.

## Model roles

| Stage | Model |
|---|---|
| Intent | Claude Opus session |
| Plan | `deepseek-v4-pro` |
| Native tests | `deepseek-v4-pro` |
| Plan gate | Claude Opus session |
| Code steps | `deepseek-v4-flash`, then `deepseek-v4-pro` on retries |
| Review | Claude Opus session when triggered |
| Final request check | Claude Opus session |

## Workflow

1. `pipeline/run.sh` records the base commit and detects the native toolchain.
2. Claude writes the original request and intent artifacts.
3. DeepSeek creates the plan and native tests independently.
4. `pipeline/run_tests.sh` establishes the pre-implementation baseline.
5. Claude gates the plan, maps exact native test names to steps, and corrects test signature drift.
6. `pipeline/waves.sh` runs dependency-safe, file-disjoint steps in parallel worktrees.
7. Each step may write only its allowlisted files and may not edit tests or dependency manifests.
8. The native adapter runs the mapped tests after every implementation attempt.
9. `pipeline/final_check.sh` runs the whole suite — steps only ran their own
   mapped tests, so a regression in untargeted tests surfaces only here.
10. Claude reviews triggered changes and compares the final diff with the original request.
11. Accepted step commits collapse into one implementation commit.

## Safety invariants

- Preserve the user's request verbatim in `.pipeline/request.txt`.
- Stop on low intent confidence.
- Keep tests independent from the generated plan.
- Treat `.pipeline/intent.json` `allowed_files` as authoritative.
- Prevent implementation steps from modifying tests or dependency manifests.
- Redact credentials from model context by path AND by content. In a read-only
  context the matching lines are redacted; for a file the step may rewrite,
  a match is fatal, because the coder reproduces whole files and would write
  the placeholder back over the real secret. `PIPELINE_ALLOW_SECRETS=1` overrides.
- Bound every test invocation with `test_timeout_seconds`, so a coder-introduced
  infinite loop cannot hang a run. `PIPELINE_TEST_TIMEOUT` overrides.
- Keep raw DeepSeek responses under the ignored `.pipeline/raw` directory.
- Preserve partial commits on drift or escalation for inspection.

## Main artifacts

| Artifact | Purpose |
|---|---|
| `.pipeline/toolchain.json` | Language, framework, commands, selector mode, and test path |
| `.pipeline/intent.md` | Human-readable intent |
| `.pipeline/intent.json` | Authoritative allowlist and structured intent |
| `.pipeline/plan.md` | DeepSeek plan |
| `.pipeline/tests_spec.md` | Generated native tests or existing-suite context |
| `.pipeline/plan_final.json` | Claude-gated steps, dependencies, and exact test names |
| `.pipeline/verify.md` | Final ACCEPT or DRIFT verdict |

## Commands

- `/build <request>` runs the full workflow.
- `/intent`, `/gate`, `/review`, and `/verify` expose individual Claude stages.

Run `pipeline/test_adapters.sh` to validate toolchain detection and selector
dispatch without calling the DeepSeek API.

Run `pipeline/smoke_adapters.sh` to drive each adapter's real toolchain against a
hand-written test file, also without the API. It checks that the runner discovers
a file at `generated_test_file` and that the selector resolves one named test,
and it skips adapters whose toolchain is not installed rather than passing them.

Most runners exit 0 when a selector matches no test — verified for `node --test`,
Vitest, Jest, cargo, and `dotnet test`. A wrong test name in `plan_final.json`
would otherwise run nothing and report a pass. `code.sh` resolves the mapped names
through `collect_command` before the coders start and escalates when they match
nothing; only the pytest adapter defines that command today, so on other adapters
the gate is responsible for emitting exact names.
