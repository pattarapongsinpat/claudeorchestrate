#!/usr/bin/env bash
# Covers the escalated-step repair stage without the API: the brief, every bound
# repair_done.sh re-checks, and the waves resume that follows an accepted repair.
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repair"
mkdir -p "$REPO/test" "$REPO/.pipeline"
(
  cd "$REPO"
  git init -q
  git config user.name 'Pipeline Repair Test'
  git config user.email 'pipeline@example.invalid'
  printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"
  printf '%s\n' '{"name":"repair-fixture","version":"1.0.0","type":"commonjs","dependencies":{"left-pad":"1.3.0"}}' > package.json
  printf '%s\n' 'function add(left, right) { return 0; }' 'module.exports = { add };' > calculator.js
  printf '%s\n' 'function multiply(left, right) { return 0; }' 'module.exports = { multiply };' > multiplier.js
  cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
const { multiply } = require('../multiplier');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
test('multiplies_numbers', () => assert.equal(multiply(2, 3), 6));
EOF
  git add .
  git commit -qm baseline
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  # waves.sh refuses without a baseline, which check_baseline records in a real run.
  "$PIPELINE_HOME/pipeline/baseline_stamp.sh" > .pipeline/baseline.sha
  git rev-parse HEAD > .pipeline/run_base
  cat > .pipeline/plan_final.json <<'EOF'
{"steps":[
  {"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"},
  {"id":"s2","description":"fix multiplication","files_allowed":["multiplier.js"],"context_files":[],"tests":["multiplies_numbers"],"deps":["s1"],"done_when":"multiply returns the product"}
]}
EOF
)

# s1 always writes outside its allowlist, so it exhausts its attempts and escalates.
# s2 depends on s1 and therefore never runs — which is the stall the repair fixes.
cat > "$WORK/model.sh" <<'EOF'
#!/usr/bin/env bash
if grep -q '"id": "s2"' "$2"; then
  printf '%s\n' '<<<<<<< FILE multiplier.js' 'function multiply(left, right) { return left * right; }' 'module.exports = { multiply };' '>>>>>>> ENDFILE'
  exit 0
fi
printf '%s\n' '<<<<<<< FILE outside.js' 'bad' '>>>>>>> ENDFILE'
EOF
chmod +x "$WORK/model.sh"

(
  cd "$REPO"
  rc=0
  PIPELINE_DS_COMMAND="$WORK/model.sh" "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ -f .pipeline/ESCALATE ]]
  jq -e '.steps.s1.status == "escalated"' .pipeline/done.json >/dev/null
  jq -e '.steps.s2 == null' .pipeline/done.json >/dev/null
  # The escalation exit still has to release the lock. It did not once, and the
  # next run only recovered because the recorded pid happened to be dead.
  [[ ! -e .pipeline/waves.lock ]]
)

# --- repair_ctx.sh -----------------------------------------------------------

(
  cd "$REPO"
  "$PIPELINE_HOME/pipeline/repair_ctx.sh" > "$WORK/ctx.out"
  [[ "$(cat "$WORK/ctx.out")" == "s1" ]]
  grep -Fq 'files_allowed' .pipeline/repair_ctx.md
  grep -Fq 'function add(left, right) { return 0; }' .pipeline/repair_ctx.md
  grep -Fq 'Why the coder gave up' .pipeline/repair_ctx.md
  # The coder never sees the test file, so the repair must be handed it.
  grep -Fq 'READ ONLY' .pipeline/repair_ctx.md
  grep -Fq "assert.equal(add(2, 3), 5)" .pipeline/repair_ctx.md
  # The brief covers the failed step only.
  ! grep -Fq '## Step s2' .pipeline/repair_ctx.md
  # The routing gate resolves the ack against the project, so repair_ctx writes it
  # there and excludes it — otherwise the repair dirties the tree it must commit.
  [[ -f .claude/routing-ack ]]
  [[ -z "$(git status --porcelain)" ]]
)

# --- repair_done.sh refusals -------------------------------------------------

refuses() {
  local expect="$1"
  local rc=0
  "$PIPELINE_HOME/pipeline/repair_done.sh" s1 > "$WORK/refuse.out" 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "expected refusal ($expect), got exit $rc" >&2; cat "$WORK/refuse.out" >&2; return 1; }
  grep -Fq "$expect" "$WORK/refuse.out" || { echo "missing '$expect'" >&2; cat "$WORK/refuse.out" >&2; return 1; }
  git checkout -- . 2>/dev/null || true
  git clean -fdq 2>/dev/null || true
}

(
  cd "$REPO"
  refuses "nothing changed for s1"

  # A file the step may not write.
  printf '%s\n' 'const x = 1;' > outside.js
  refuses "files outside the step allowlist"

  # The grader is off limits, exactly as it is for the coder.
  printf '%s\n' '// tampered' >> test/pipeline_generated.test.js
  refuses "test files modified"

  # A manifest edit is off limits too.
  printf '%s\n' '{"name":"repair-fixture","version":"1.0.0","type":"commonjs"}' > package.json
  refuses "dependency manifest modified"

  # In scope, but still wrong: the mapped test decides, not the session.
  printf '%s\n' 'function add(left, right) { return left - right; }' 'module.exports = { add };' > calculator.js
  refuses "mapped tests still fail"

  jq -e '.steps.s1.status == "escalated"' .pipeline/done.json >/dev/null
  [[ -f .pipeline/ESCALATE ]]
)

# The budget is checked before anything else, so an exhausted one refuses even a
# repair that would otherwise be perfect.
(
  cd "$REPO"
  printf '%s\n' 'function add(left, right) { return left + right; }' 'module.exports = { add };' > calculator.js
  rc=0
  PIPELINE_MAX_REPAIRS=0 "$PIPELINE_HOME/pipeline/repair_done.sh" s1 > "$WORK/budget.out" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'already repaired this run (limit 0)' "$WORK/budget.out"
  jq -e '.steps.s1.status == "escalated"' .pipeline/done.json >/dev/null
  git checkout -- .
)

# --- repair_done.sh acceptance ----------------------------------------------

(
  cd "$REPO"
  before=$(git rev-parse HEAD)
  printf '%s\n' 'function add(left, right) { return left + right; }' 'module.exports = { add };' > calculator.js
  "$PIPELINE_HOME/pipeline/repair_done.sh" s1 > "$WORK/repair.out" 2>&1
  grep -Fq 'REPAIRED s1' "$WORK/repair.out"
  [[ "$(git rev-parse HEAD)" != "$before" ]]
  git diff --quiet
  [[ ! -f .pipeline/ESCALATE ]]
  jq -e '.steps.s1.status == "done" and .steps.s1.ever_escalated == true and .steps.s1.repaired_by_opus == true' .pipeline/done.json >/dev/null
  # The flag the budget counts, so a later repair in the same run sees this one.
  jq -e '[.steps[] | select(.repaired_by_opus == true)] | length == 1' .pipeline/done.json >/dev/null
  # ever_escalated survives the repair, so the run still earns an Opus review.
  "$PIPELINE_HOME/pipeline/review_trigger.sh" | grep -Fq 's1 escalated during this run'
)

# --- resume after repair -----------------------------------------------------

(
  cd "$REPO"
  PIPELINE_DS_COMMAND="$WORK/model.sh" "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1
  jq -e '.steps.s1.status == "done" and .steps.s2.status == "done"' .pipeline/done.json >/dev/null
  # s1 was not re-run: the repair commit is still what implements it.
  grep -Fq 'return left + right' calculator.js
  "$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null
)

echo "repair stage tests passed"
