Run the pipeline for this command's arguments. Halt immediately if `.pipeline/HALT` appears.

On Windows, record the project root once and invoke every pipeline script through
`powershell -ExecutionPolicy Bypass -File "$HOME\.claudeorchestrate\pipeline\invoke.ps1" <script-name> -Repo "<project-root>"`.
Never use bare `bash` on Windows because it may resolve to WSL. On macOS and
Linux, use `bash "$HOME/.claudeorchestrate/pipeline/<script-name>.sh"`.

0. Initialize the current project with pipeline script `run`.
   Treat `$ARGUMENTS` as the original request for all later checks.

1. /intent — write request.txt, intent.md, intent.json.
   It asks one to three multiple-choice questions in one `AskUserQuestion` call
   and records the answers verbatim in request.txt. The first, confirming what
   to build, is mandatory. Only stage that asks.
   Exception: a campaign unit. When `.campaign/unit_request.txt` exists and the
   campaign is running, copy it verbatim and ask nothing.
   Stop on `.pipeline/HALT`: the request needs a decision no answer supplied.
   Intent may choose judgment mode only when behavioral tests require an
   unavailable host, hardware, or proprietary runtime. Record the exact reason.
2. Run pipeline script `check_assumptions`. It first counts this run against the
   per-request cap of three build attempts and exits 3 with a HALT when they are
   spent; a fourth run on the same request text is refused, and the remedy is to
   read the archived attempts and change the request, not to re-run it. An
   accepted `collapse` returns the budget, and a campaign unit is exempt because
   the campaign bounds it.
   Then DeepSeek grades Assumptions against
   request.txt alone and the exit code is authoritative: 0 continue, 2 revise
   the named assumption in intent.md and intent.json then run it again,
   3 budget spent and HALT already written, 1 malformed verdict. Do not argue
   with the verdict and do not edit the Goal to fit it. Nothing downstream
   re-reads the request against the intent, so this is the only stage that
   catches a misreading before it is built.
3. Run in ONE turn so outputs can't contaminate each other: pipeline scripts
   `plan` and `tests`. Then run pipeline script `check_baseline`. It writes
   `.pipeline/HALT` and fails when the suite does not load, or when generated tests
   are green before implementation. Stop on HALT — do not "fix" the baseline by
   editing code.
4. /gate — rewrite to plan_final.json (per-step `tests` selector and `deps`) and
   correct any test-signature drift in the configured generated test file. Then
   re-run pipeline script `check_baseline` (the gate edits tests) and
   `git add -A; git diff --cached --quiet || git commit -qm "generated tests"`.
5. Run pipeline script `waves`. It schedules the plan into dependency
   waves, runs dep-free file-disjoint steps in parallel git worktrees, commits
   and cherry-picks each success back, and appends to `.pipeline/touched.log`.
   On any step's ESCALATE it stops with the partial commits in place and writes
   `.pipeline/ESCALATE`.
6. On ESCALATE, repair the step in this session rather than stopping — it already
   holds the request, the intent, and the plan.
   a. Run pipeline script `repair_ctx` for the step ids and
      `.pipeline/repair_ctx.md`.
   b. Write only that step's `files_allowed`. No tests, no dependency manifests.
      `repair_ctx` already wrote the routing-gate ack. This is the one stage
      where Opus writes implementation code. If the write is blocked because the
      ack expired, re-run `repair_ctx`.
   c. Run pipeline script `repair_done` with the step id. It re-checks the
      allowlist, manifests, test files, and mapped tests, then commits and marks
      the step done. On REFUSED, fix the cause; never hand-edit `done.json`.
   d. Re-run pipeline script `waves` to resume the remaining steps.
   e. If the mapped test is the thing that is wrong — no implementation within
      `files_allowed` can satisfy it — do not repair and do not edit it. Run
      pipeline script `restart_run` with a one-line reason, then resume from
      step 3 (plan and tests). It resets to the run base, tags the abandoned
      commits, archives the failing tests, and keeps the request and intent.
      One restart per request.
   `repair_done` enforces two repairs per run. When it refuses on the budget,
   stop and report — that many failures points at the plan or the generated
   tests, not at the coder.
7. Run pipeline script `final_check`. Steps only ran
   their own mapped tests, so this is the first time the whole suite runs. On
   failure it writes `.pipeline/REGRESSION`; stop there with the commits in place.

8. Run pipeline script `review_trigger`. It exits 0 when
   review is warranted (a step needed a retry, a step was not gated by its tests, a
   NOOP, or a repeat-touched file) and prints why. On exit 0, run pipeline script
   `review_ctx`, then /review.
   review_ctx.sh must run first — /review reads its output.
   Judgment mode always requires this Opus review.
9. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse. Then run pipeline script
   `validate_verify`; collapse only when it exits 0. After a repair this is the
   only independent check left, since the repairing session is the one asking.
10. Run pipeline script `collapse` with the intent goal as its argument. It
   re-runs validate_verify and refuses on DRIFT, a malformed verdict, any HALT /
   ESCALATE / REGRESSION marker, or a dirty tree. Never `git reset --soft` by hand.
   On DRIFT or an unrepaired ESCALATE: leave the per-step commits in place.
11. Append one row to `.pipeline/log.csv`, and report token usage from pipeline
   script `usage`.
