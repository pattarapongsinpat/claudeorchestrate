Run the pipeline. Halt immediately if `.pipeline/HALT` appears.

1. /intent — write request.txt, intent.md, intent.json.
   Confidence low → stop, surface questions, do not continue.
2. Run in ONE turn so outputs can't contaminate each other:
   `./pipeline/plan.sh` and `./pipeline/tests.sh`
   Then baseline the suite: `pytest -q`. It MUST be red. A suite that is all
   green before any code means the generated tests assert nothing about the
   change. If green, write `.pipeline/HALT` (test spec is wrong) and stop.
3. /gate — rewrite to plan_final.json (adds a per-step `tests` selector).
4. For each step in order:
   - Confirm the tree is clean. If not, STOP — a dirty tree means a
     previous step failed to commit and its work would be destroyed.
   - `git rev-parse HEAD > .pipeline/step_base` — pre-step SHA, so review
     scopes to this step and a NOOP contributes nothing.
   - `./pipeline/code.sh <id>`
   - On success: `git add -A && git commit -qm "step <id>"`
     Append this step's files:
     `git diff --name-only "$(cat .pipeline/step_base)" >> .pipeline/touched.log`.
   - On ESCALATE: stop. Do not attempt later steps, do not commit.
5. If a trigger fired (including a repeat-touched file):
   run `./pipeline/review_ctx.sh`, then /review.
   review_ctx.sh must run first — /review reads its output.
6. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse.
7. On ACCEPT: collapse the per-step commits into one —
   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`.
   On DRIFT or ESCALATE: leave the per-step commits in place for inspection.
8. Append one row to `.pipeline/log.csv`.
