Run the pipeline for this command's arguments. Halt immediately if `.pipeline/HALT` appears.

On Windows, record the project root once and invoke every pipeline script through
`powershell -ExecutionPolicy Bypass -File "$HOME\.claudeorchestrate\pipeline\invoke.ps1" <script-name> -Repo "<project-root>"`.
Never use bare `bash` on Windows because it may resolve to WSL. On macOS and
Linux, use `bash "$HOME/.claudeorchestrate/pipeline/<script-name>.sh"`.

0. Initialize the current project with pipeline script `run`.
   Treat `$ARGUMENTS` as the original request for all later checks.

1. /intent — write request.txt, intent.md, intent.json.
   Confidence low → stop, surface questions, do not continue.
   Intent may choose judgment mode only when behavioral tests require an
   unavailable host, hardware, or proprietary runtime. Record the exact reason.
2. Run in ONE turn so outputs can't contaminate each other: pipeline scripts
   `plan` and `tests`. Then run pipeline script `check_baseline`. It writes
   `.pipeline/HALT` and fails when the suite does not load, or when generated tests
   are green before implementation. Stop on HALT — do not "fix" the baseline by
   editing code.
3. /gate — rewrite to plan_final.json (per-step `tests` selector and `deps`) and
   correct any test-signature drift in the configured generated test file. Then
   re-run pipeline script `check_baseline` (the gate edits tests) and
   `git add -A; git diff --cached --quiet || git commit -qm "generated tests"`.
4. Run pipeline script `waves`. It schedules the plan into dependency
   waves, runs dep-free file-disjoint steps in parallel git worktrees, commits
   and cherry-picks each success back, and appends to `.pipeline/touched.log`.
   On any step's ESCALATE it stops with the partial commits in place and writes
   `.pipeline/ESCALATE`.
5. On ESCALATE, repair the step in this session rather than stopping — it already
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
   `repair_done` enforces two repairs per run. When it refuses on the budget,
   stop and report — that many failures points at the plan or the generated
   tests, not at the coder.
6. Run pipeline script `final_check`. Steps only ran
   their own mapped tests, so this is the first time the whole suite runs. On
   failure it writes `.pipeline/REGRESSION`; stop there with the commits in place.

7. Run pipeline script `review_trigger`. It exits 0 when
   review is warranted (a step needed a retry, a step was not gated by its tests, a
   NOOP, or a repeat-touched file) and prints why. On exit 0, run pipeline script
   `review_ctx`, then /review.
   review_ctx.sh must run first — /review reads its output.
   Judgment mode always requires this Opus review.
8. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse. Then run pipeline script
   `validate_verify`; collapse only when it exits 0. After a repair this is the
   only independent check left, since the repairing session is the one asking.
9. On ACCEPT: collapse the per-step commits into one —
   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`.
   On DRIFT or an unrepaired ESCALATE: leave the per-step commits in place.
10. Append one row to `.pipeline/log.csv`, and report token usage from pipeline
   script `usage`.
