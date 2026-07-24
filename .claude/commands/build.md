Run the pipeline for this command's arguments. Halt immediately if `.pipeline/HALT` appears.

0. Initialize the current project with
   `bash "$HOME/.claudeochestrate/pipeline/run.sh"`.
   Treat `$ARGUMENTS` as the original request for all later checks.

1. /intent — write request.txt, intent.md, intent.json.
   Confidence low → stop, surface questions, do not continue.
2. Run in ONE turn so outputs can't contaminate each other:
   `bash "$HOME/.claudeochestrate/pipeline/plan.sh"` and
   `bash "$HOME/.claudeochestrate/pipeline/tests.sh"`
   Then run `bash "$HOME/.claudeochestrate/pipeline/run_tests.sh"`.
   When `.pipeline/toolchain.json` has `generated_tests: true`, the suite MUST
   be red. If green, write `.pipeline/HALT` (test spec is wrong) and stop.
   Existing-suite adapters may be green before implementation.
3. /gate — rewrite to plan_final.json (per-step `tests` selector and `deps`) and
   correct any test-signature drift in the configured generated test file. Then
   run `git add -A; git diff --cached --quiet || git commit -qm "generated tests"`.
4. Run the steps: `bash "$HOME/.claudeochestrate/pipeline/waves.sh"`. It schedules the plan into dependency
   waves, runs dep-free file-disjoint steps in parallel git worktrees, commits
   and cherry-picks each success back, and appends to `.pipeline/touched.log`.
   On any step's ESCALATE it stops with the partial commits in place and writes
   `.pipeline/ESCALATE`; do not continue.
5. If a trigger fired (including a repeat-touched file):
   run `bash "$HOME/.claudeochestrate/pipeline/review_ctx.sh"`, then /review.
   review_ctx.sh must run first — /review reads its output.
6. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse.
7. On ACCEPT: collapse the per-step commits into one —
   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`.
   On DRIFT or ESCALATE: leave the per-step commits in place for inspection.
8. Append one row to `.pipeline/log.csv`.
