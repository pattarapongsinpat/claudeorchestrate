---
name: build
description: Run the shared autonomous Opus and DeepSeek implementation pipeline. Invoke automatically whenever the user asks Claude to implement, modify, fix, refactor, add tests, or otherwise change code or project files in a Git repository. Do not invoke for explanation-only, inspection-only, planning-only, or non-Git requests.
---

# Autonomous Build

Use `$ARGUMENTS` when supplied. Otherwise use the current user request verbatim.

The shared runtime is `$HOME/.claudeochestrate`.

## Preflight

1. Confirm the current directory is inside a Git repository.
2. Run `git status --porcelain`. Stop and report the paths if the worktree is dirty. Do not include pre-existing changes in pipeline commits.
3. Confirm `DEEPSEEK_API_KEY` is available from the environment or the shared runtime `.env`.
4. Halt immediately whenever `.pipeline/HALT` or `.pipeline/ESCALATE` appears.

## Workflow

1. Initialize the current project:

   `bash "$HOME/.claudeochestrate/pipeline/run.sh"`

2. Read `$HOME/.claudeochestrate/.claude/commands/intent.md`. Perform its instructions using the original user request.

3. Run these independently without sharing their outputs:

   - `bash "$HOME/.claudeochestrate/pipeline/plan.sh"`
   - `bash "$HOME/.claudeochestrate/pipeline/tests.sh"`

4. Run `bash "$HOME/.claudeochestrate/pipeline/check_baseline.sh"` before implementation. It HALTs when the suite fails to load (a collection or compile error means no step can ever pass, and it exits non-zero exactly like a healthy red baseline) or when generated tests are already green. Stop on HALT rather than editing code to satisfy it.

5. Read `$HOME/.claudeochestrate/.claude/commands/gate.md` and perform its instructions. Then re-run `check_baseline.sh`, because the gate may edit the generated test file, and run `git add -A; git diff --cached --quiet || git commit -qm "generated tests"`.

6. Run the implementation waves:

   `bash "$HOME/.claudeochestrate/pipeline/waves.sh"`

7. Run `bash "$HOME/.claudeochestrate/pipeline/review_trigger.sh"`. It exits 0 when review is warranted and prints the reasons. On exit 0, run `bash "$HOME/.claudeochestrate/pipeline/review_ctx.sh"`, then read and perform `$HOME/.claudeochestrate/.claude/commands/review.md`.

8. Always read and perform `$HOME/.claudeochestrate/.claude/commands/verify.md` before collapsing history.

9. On `ACCEPT`, collapse pipeline commits:

   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`

   On `DRIFT` or `ESCALATE`, preserve the per-step commits for inspection.

10. Append the run result to `.pipeline/log.csv` and report token usage from `bash "$HOME/.claudeochestrate/pipeline/usage.sh"`.

Report the final verdict, changed files, tests, and commit hash. Keep the response concise.
