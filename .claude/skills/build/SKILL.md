---
name: build
description: Route a software change either to Claude writing it directly, which is the default, or to the shared Opus and DeepSeek pipeline when the change is large, dangerous, or undecided. Invoke automatically whenever the user asks Claude to implement, modify, fix, refactor, add tests, or otherwise change code or project files in a Git repository. Do not invoke for explanation-only, inspection-only, planning-only, or non-Git requests.
---

# Autonomous Build

Use `$ARGUMENTS` when supplied. Otherwise use the current user request verbatim.

The shared runtime is `$HOME/.claudeorchestrate`.

## Route selection

Write it directly. That is the default.

The pipeline spends a plan, a test-generation pass, a coder call per step, and
several Opus stages on one request. It has to earn that on the change actually in
front of you, and on most changes it does not. An explicit `/build` or
`/campaign` always forces the full pipeline; nothing else does automatically.

Escalate to the pipeline only when one of these is true. Each names a risk, not a
feeling:

1. **Size.** More than roughly five files, or more than roughly 150 changed lines.
2. **Blast radius.** It changes a public interface, schema, data format, wire
   protocol, or persisted shape that code you are not editing depends on.
3. **Danger.** Authentication, authorization, secrets, payments, cryptography,
   concurrency, or a data migration.
4. **Dependencies.** It adds, removes, or upgrades one.
5. **Undecided.** The right behavior needs a choice from the user that the request
   does not carry. The pipeline's intent stage is the only stage that may ask.
6. **Unverifiable by you.** There is no check you can run and no output you can
   read to tell whether it worked.
7. **The user said so.** They called it a big change, asked for a plan, or asked
   for tests to be generated.

Uncertainty on its own is no longer a reason to escalate. Read the code until the
uncertainty resolves; that is cheaper than a pipeline run. Never escalate merely
because the change feels large before you have looked.

Never use the pipeline as a way to avoid verifying your own work, and never use
the direct path merely because the worktree is dirty or the pipeline is broken.

### Direct path

1. Do not call DeepSeek, create a subagent, or write `.pipeline` artifacts.
2. Read what you are changing and the tests around it. Check `git status` and
   preserve unrelated user changes; stop if your target overlaps pre-existing
   changes that cannot be separated safely.
3. Make the edit.
4. Run the narrowest real check, then the broader suite when it is cheap. A change
   you cannot check is condition 6, not a reason to skip verifying.
5. Report what changed and what you ran. Do not commit unless asked.

Typos, copy, constants, guards, a new function with an obvious contract, a
localized bug fix, a rename inside one module, a new test, a small refactor with
tests already covering it: all direct. A four-file feature behind an existing
interface is still direct. Reach for the pipeline when a condition above fires,
not when the work merely looks like real work.

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

   A campaign unit is the one exception: when `.campaign/unit_request.txt` exists
   and the campaign is running, intent copies it verbatim and asks nothing. The
   round was already spent, once, for the whole campaign.

3. Run pipeline script `check_assumptions`. Before anything else it counts this
   run against the per-request cap: three build attempts on the same request
   text, then it exits 3 and writes `.pipeline/HALT`. Stop there and report. A
   fourth run of a request that failed three times buys the diagnosis the third
   already gave; read `.pipeline/attempt-N` and the archived evidence, then
   change the request. An accepted `collapse` clears the count, and a unit inside
   a running campaign is exempt because `PIPELINE_MAX_UNIT_ATTEMPTS` bounds it.

   It then sends DeepSeek the whole of
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

12. Run pipeline script `collapse` with the intent goal as its one argument. It
   re-runs `validate_verify` itself and refuses on DRIFT, on a malformed verdict,
   on any HALT, ESCALATE, or REGRESSION marker, and on a dirty tree. Do not run
   `git reset --soft` by hand: the session asking for the verdict is the one that
   would be interpreting it.

   On `DRIFT` or an unrepaired `ESCALATE`, preserve the per-step commits for inspection.

13. Append the run result to `.pipeline/log.csv` and report token usage from pipeline script `usage`.

Report the final verdict, changed files, tests or judgment fallback, and commit hash. Keep the response concise.
