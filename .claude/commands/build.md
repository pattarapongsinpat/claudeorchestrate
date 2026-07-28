Run the pipeline for this command's arguments. Halt immediately if `.pipeline/HALT` appears.

On Windows, invoke every pipeline script through
`powershell -ExecutionPolicy Bypass -File "$HOME\.claudeochestrate\pipeline\invoke.ps1" <script-name>`.
Never use bare `bash` on Windows because it may resolve to WSL. On macOS and
Linux, use `bash "$HOME/.claudeochestrate/pipeline/<script-name>.sh"`.

0. Initialize the current project with pipeline script `run`.
   Treat `$ARGUMENTS` as the original request for all later checks.

1. /intent — write request.txt, intent.md, intent.json.
   Confidence low → stop, surface questions, do not continue.
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
   `.pipeline/ESCALATE`; do not continue.
5. Run pipeline script `final_check`. Steps only ran
   their own mapped tests, so this is the first time the whole suite runs. On
   failure it writes `.pipeline/REGRESSION`; stop there with the commits in place.

6. Run pipeline script `review_trigger`. It exits 0 when
   review is warranted (a step needed a retry, a step was not gated by its tests, a
   NOOP, or a repeat-touched file) and prints why. On exit 0, run pipeline script
   `review_ctx`, then /review.
   review_ctx.sh must run first — /review reads its output.
7. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse.
8. On ACCEPT: collapse the per-step commits into one —
   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`.
   On DRIFT or ESCALATE: leave the per-step commits in place for inspection.
9. Append one row to `.pipeline/log.csv`, and report token usage from pipeline
   script `usage`.
