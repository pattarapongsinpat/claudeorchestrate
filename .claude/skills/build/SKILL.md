---
name: build
description: Route software changes either to a conservative direct Claude fast path or to the shared Opus and DeepSeek implementation pipeline. Invoke automatically whenever the user asks Claude to implement, modify, fix, refactor, add tests, or otherwise change code or project files in a Git repository. Do not invoke for explanation-only, inspection-only, planning-only, or non-Git requests.
---

# Autonomous Build

Use `$ARGUMENTS` when supplied. Otherwise use the current user request verbatim.

The shared runtime is `$HOME/.claudeorchestrate`.

## Route selection

An explicit `/build` command always uses the full pipeline. A normal change
request may use the direct fast path only when every condition below is true
after a read-only inspection:

1. The requested outcome is clear and needs no design choice.
2. The change is localized to one implementation file and is expected to stay
   under 20 changed lines. Documentation-only changes may touch two files.
3. It does not add or change dependencies, manifests, generated files, public
   interfaces, data formats, schemas, persistence, or migrations.
4. It does not affect authentication, authorization, secrets, payments,
   security boundaries, concurrency, networking, deployment, or build logic.
5. It is not a broad refactor and does not change a contract shared across files.
6. Existing focused verification can cover it, or it changes only documentation,
   comments, formatting, or user-facing copy.

When uncertain, use the full pipeline. Never use the direct path merely because
the pipeline is unavailable or the worktree is dirty.

### Direct fast path

1. Do not call DeepSeek, create a subagent, or write `.pipeline` artifacts.
2. Inspect `git status`, the target file, and its nearby tests. Preserve unrelated
   user changes. Stop if the target overlaps pre-existing changes that cannot be
   separated safely.
3. Make the smallest direct edit in the current session.
4. Run the narrowest relevant check, then the broader relevant suite when cheap.
5. Review the final diff for scope and regressions. Do not commit unless the user
   requested a commit.

Examples that may qualify include a typo, a localized copy change, an obvious
constant correction, or a one-line guard already covered by tests. New behavior,
new tests, multi-file fixes, and uncertain bug fixes use the full pipeline.

## Shell invocation

On Windows, never invoke bare `bash`; it may resolve to WSL. Record the project
root once, then run pipeline scripts with
`powershell -ExecutionPolicy Bypass -File "$HOME\.claudeorchestrate\pipeline\invoke.ps1" <script-name> -Repo "<project-root>"`.
On macOS and Linux, use `bash "$HOME/.claudeorchestrate/pipeline/<script-name>.sh"`.

## Preflight

1. Confirm the current directory is inside a Git repository.
2. Run `git status --porcelain`. Stop and report the paths if the worktree is dirty. Do not include pre-existing changes in pipeline commits.
3. Confirm `DEEPSEEK_API_KEY` is available from the environment or the shared runtime `.env`.
4. Halt immediately whenever `.pipeline/HALT` appears. `.pipeline/ESCALATE` is
   handled by the repair stage in step 8, not by halting on sight.

## Workflow

1. Initialize the current project:

   Run pipeline script `run` using the platform invocation above.

2. Read `$HOME/.claudeorchestrate/.claude/commands/intent.md`. Perform its
   instructions using the original user request. This stage asks the user one to
   three multiple-choice questions, in a single `AskUserQuestion` call, and
   records the answers verbatim in `request.txt`. The first one confirms what to
   build and is mandatory on every run, however clear the request looks: the goal
   is what every later stage inherits, so it is the one error none of them can
   catch. No later stage may ask:
   once the plan and the tests exist, a question arrives after the run has
   already committed to a reading.

3. Run pipeline script `check_assumptions`. It sends DeepSeek the whole of
   `request.txt` and the intent's Assumptions section, nothing else, and its exit
   code is authoritative: 0 continues, 2 means revise the named assumption in
   `intent.md` and `intent.json` and run the script again, 3 means the revision
   budget is spent and the script already wrote `.pipeline/HALT`, 1 means the
   verdict was malformed. Revising means changing or dropping the assumption. It
   does not mean arguing with the verdict or editing the Goal to fit it. No later
   stage reads the original request against the intent, so a misreading caught
   anywhere else is caught after it was built.

4. Run these independently without sharing their outputs:

   - Pipeline script `plan`
   - Pipeline script `tests`

   The Opus intent stage may select judgment mode only when behavioral tests
   require an unavailable host, hardware, or proprietary runtime. The test
   stage then retains available mechanical checks and skips test generation.

5. Run pipeline script `check_baseline` before implementation. It HALTs when the existing suite fails to load or when generated tests are already green. Stop on HALT rather than editing code to satisfy it.

6. Read `$HOME/.claudeorchestrate/.claude/commands/gate.md` and perform its instructions. Then re-run pipeline script `check_baseline`, because the gate may edit the generated test file, and run `git add -A; git diff --cached --quiet || git commit -qm "generated tests"`.

7. Run the implementation waves:

   Run pipeline script `waves`.

8. If `waves` wrote `.pipeline/ESCALATE`, repair the step yourself rather than
   stopping. You already hold the request, the intent, and the plan, so this
   costs one Opus turn instead of a fresh context.

   a. Run pipeline script `repair_ctx`. It prints the escalated step ids and
      writes `.pipeline/repair_ctx.md`.
   b. Read that file and write only the files under `files_allowed` for that
      step. Do not touch tests or dependency manifests. `repair_ctx` already
      wrote the routing-gate ack, so no separate step is needed; this is the one
      stage where Opus writes implementation code. If the write is blocked
      because the ack expired, re-run `repair_ctx`.
   c. Run pipeline script `repair_done` with the step id. It re-checks the
      allowlist, the manifests, the test files, and the step's mapped tests,
      then commits and marks the step done. On `REFUSED` fix the cause; do not
      edit `done.json` by hand.
   d. Re-run pipeline script `waves`. It resumes and runs the steps that never
      got their turn.

   `repair_done` enforces a limit of two repairs per run. When it refuses on the
   budget, stop and report: that many failures means the plan or the generated
   tests are wrong, and repairing them one by one hides it.

   e. If the brief shows the mapped test is what is wrong — it asserts something
      no implementation within `files_allowed` can satisfy — do not repair and do
      not edit the test. Run pipeline script `restart_run` with a one-line reason.
      It resets to the run base, tags the abandoned commits, archives the failing
      tests, and clears the plan and the tests while keeping the request and the
      intent. Then go back to step 4 and continue the workflow from there: the
      tester runs again from the request and the spec, independently of what
      failed. One restart per request; on refusal, stop and report.

9. Run pipeline script `final_check`. Steps only ran their own mapped tests, so this is the first full-suite execution of the run. On failure it writes `.pipeline/REGRESSION`; stop with the commits in place rather than patching around it.

10. Run pipeline script `review_trigger`. It exits 0 when review is warranted and prints the reasons. On exit 0, run pipeline script `review_ctx`, then read and perform `$HOME/.claudeorchestrate/.claude/commands/review.md`.

   Judgment mode always triggers this Opus review.

11. Always read and perform `$HOME/.claudeorchestrate/.claude/commands/verify.md` before collapsing history. The verdict must come from the fresh isolated subagent required there. Run pipeline script `validate_verify` afterward and never collapse unless it exits 0.

    A repaired step makes this more important, not less: the session that wrote
    the repair is the one asking for the verdict, so the isolated subagent is
    the only independent check left.

12. On `ACCEPT`, collapse pipeline commits:

   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`

   On `DRIFT` or an unrepaired `ESCALATE`, preserve the per-step commits for inspection.

13. Append the run result to `.pipeline/log.csv` and report token usage from pipeline script `usage`.

Report the final verdict, changed files, tests or judgment fallback, and commit hash. Keep the response concise.
