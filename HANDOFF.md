# Claude Orchestrate Handoff

## Objective

Validate this repository through Claude Code using `/build` on a clean test
project. Claude should orchestrate intent, gating, review, and verification while
DeepSeek generates plans, tests, and implementation changes.

## Current status

The pipeline implementation and test harness are complete but uncommitted.
Do not run `/build` inside this repository while its worktree is dirty. Use a
separate clean Git repository for the Claude test, or commit these changes first.

Verified locally:

- Complete adapter matrix: 47 passed, 0 failed, 0 skipped.
- DeepSeek API health check passed.
- DeepSeek Node red-to-green implementation loop passed on its first attempt.
- Two parallel DeepSeek steps passed in isolated Git worktrees.
- Both step commits cherry-picked successfully.
- Final full-suite verification passed.
- Shell syntax, PowerShell syntax, safety, adapter detection, and baseline
  isolation tests passed.
- No temporary toolchain directories or background processes remained.

## Major changes

- Windows invokes Git Bash explicitly through `pipeline/invoke.ps1`.
- Plan IDs, dependencies, and repository paths are mechanically validated.
- Symlink and traversal writes are blocked.
- Existing generated-test paths cannot be overwritten.
- Existing suites are loaded or compiled independently from generated tests.
- Generated tests are isolated during baseline validation.
- Java, Go, Gradle, Meson, and GNU Make can be tested with temporary verified
  toolchains.
- Gradle tests include the required JUnit Platform launcher.
- Gradle daemons are stopped before temporary toolchain cleanup.

## Preflight on this machine

From PowerShell in this repository:

```powershell
git status --short
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_api
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_safety
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_adapters
```

Optional complete adapter audit. It downloads about 425 MB into a temporary
directory, verifies checksums, runs every adapter, then removes the toolchains:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_all_toolchains.ps1
```

Expected final line:

```text
RESULT pass=47 fail=0 skip=0
```

## Claude Code acceptance test

Create a separate clean Node project:

```powershell
$testRepo = Join-Path $env:TEMP ('claude-orchestrate-acceptance-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $testRepo | Out-Null
Set-Location $testRepo
git init
git config user.name 'Pipeline Acceptance'
git config user.email 'pipeline@example.invalid'
'{"name":"claude-orchestrate-acceptance","version":"1.0.0","type":"commonjs"}' | Set-Content package.json -Encoding ascii
@'
function add(left, right) {
  return 0;
}

module.exports = { add };
'@ | Set-Content calculator.js -Encoding ascii
git add package.json calculator.js
git commit -m 'acceptance baseline'
```

Open Claude Code in that repository and run:

```text
/build Fix calculator.add so it returns the sum of its two numeric arguments. Add native tests for positive, negative, and zero values. Do not add dependencies or change package.json.
```

## Expected Claude behavior

Claude should:

1. Detect JavaScript with the native Node test runner.
2. Preserve the request in `.pipeline/request.txt`.
3. Produce `intent.md`, `intent.json`, `plan.md`, and generated native tests.
4. Confirm the generated tests fail before implementation.
5. Gate the plan into `plan_final.json` with exact test names.
6. Run DeepSeek implementation steps in worktrees.
7. Pass each mapped test and the final full suite.
8. Review when mechanically triggered.
9. Verify the final diff against the original request.
10. Collapse accepted pipeline commits into one implementation commit.
11. Report the verdict, changed files, tests, commit hash, and DeepSeek usage.

Acceptance criteria:

- `calculator.js` returns `left + right`.
- The generated native tests remain in the final commit.
- `node --test` passes.
- `package.json` is unchanged.
- The worktree is clean after completion.
- No `wt/*` branches or pipeline worktrees remain.

## Useful direct tests

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_node
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_waves
powershell -ExecutionPolicy Bypass -File .\pipeline\test_java.ps1
powershell -ExecutionPolicy Bypass -File .\pipeline\test_go.ps1
powershell -ExecutionPolicy Bypass -File .\pipeline\test_gradle.ps1
powershell -ExecutionPolicy Bypass -File .\pipeline\test_meson.ps1
powershell -ExecutionPolicy Bypass -File .\pipeline\test_make.ps1
```

## Known limitations

- Claude CLI was not installed in the Codex environment. `/build` itself has not
  been invoked here. Its underlying DeepSeek API, implementation loop, parallel
  worktrees, commits, and test runners were exercised directly.
- Node, Vitest, Jest, Go, Cargo, Maven, and .NET may exit successfully when a
  selector matches no test. Claude's gate must emit exact test names. The final
  full-suite run remains the backstop for missed implementation behavior.
- npm-test, Meson, and Make use existing-suite mode and run the complete suite
  instead of individual test selectors.

## If the Claude test fails

Preserve these files before retrying:

- `.pipeline/HALT`
- `.pipeline/ESCALATE`
- `.pipeline/REGRESSION`
- `.pipeline/logs/`
- `.pipeline/raw/`
- `.pipeline/toolchain.json`
- `.pipeline/plan_final.json`
- `.pipeline/verify.md`

Also capture:

```powershell
git status --short
git log --oneline --decorate -10
git worktree list
```
