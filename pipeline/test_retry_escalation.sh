#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_repo() {
  local repo="$1"
  mkdir -p "$repo/test" "$repo/.pipeline"
  (
    cd "$repo"
    git init -q
    git config user.name 'Pipeline Retry Test'
    git config user.email 'pipeline@example.invalid'
    printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"
    printf '%s\n' '{"name":"retry-fixture","version":"1.0.0","type":"commonjs","dependencies":{"left-pad":"1.3.0"}}' > package.json
    cat > calculator.js <<'EOF'
function add(left, right) { return 0; }
module.exports = { add };
EOF
    cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
    git add .
    git commit -qm baseline
    "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
    cat > .pipeline/plan_final.json <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
  )
}

RETRY_REPO="$WORK/retry"
make_repo "$RETRY_REPO"
RETRY_COUNT="$WORK/retry.count"
cat > "$WORK/retry-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$PIPELINE_FAKE_COUNT"
if ((count == 1)); then body='function add(left, right) { return left - right; }'; else body='function add(left, right) { return left + right; }'; fi
printf '<<<<<<< FILE calculator.js\n%s\nmodule.exports = { add };\n>>>>>>> ENDFILE\n' "$body"
EOF
chmod +x "$WORK/retry-model.sh"
(
  cd "$RETRY_REPO"
  mkdir -p .pipeline/logs
  # This case is about the retry ladder, so it pins the cap rather than inheriting
  # the single-attempt default.
  PIPELINE_MAX_ATTEMPTS=3 \
    PIPELINE_DS_COMMAND="$WORK/retry-model.sh" PIPELINE_FAKE_COUNT="$RETRY_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 | tee .pipeline/logs/s1.log
  [[ "$(cat "$RETRY_COUNT")" == 2 ]]
  grep -Fq -- '--- test output: attempt 1 ---' .pipeline/logs/s1.log
  grep -Fq 'Expected values to be strictly equal' .pipeline/logs/s1.log
  "$PIPELINE_HOME/pipeline/run_tests.sh" adds_numbers >/dev/null
  "$PIPELINE_HOME/pipeline/review_trigger.sh" | grep -Fq 'needed more than one attempt'
)

ESCALATE_REPO="$WORK/escalate"
make_repo "$ESCALATE_REPO"
ESCALATE_COUNT="$WORK/escalate.count"
cat > "$WORK/escalate-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
printf '%s\n' "$((count + 1))" > "$PIPELINE_FAKE_COUNT"
printf '<<<<<<< FILE outside.js\nmalicious\n>>>>>>> ENDFILE\n'
EOF
chmod +x "$WORK/escalate-model.sh"
(
  cd "$ESCALATE_REPO"
  rc=0
  PIPELINE_MAX_ATTEMPTS=3 \
    PIPELINE_DS_COMMAND="$WORK/escalate-model.sh" PIPELINE_FAKE_COUNT="$ESCALATE_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$ESCALATE_COUNT")" == 3 ]]
  [[ -f .pipeline/ESCALATE ]]
  grep -Fq 'exhausted 3 iterations' .pipeline/ESCALATE
  [[ ! -e outside.js ]]
  git diff --quiet
)

MANIFEST_REPO="$WORK/manifest"
make_repo "$MANIFEST_REPO"
cat > "$WORK/manifest-model.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  '<<<<<<< FILE package.json' \
  '{"name":"retry-fixture","version":"1.0.0","type":"commonjs"}' \
  '>>>>>>> ENDFILE'
EOF
chmod +x "$WORK/manifest-model.sh"
(
  cd "$MANIFEST_REPO"
  cat > .pipeline/plan_final.json <<'EOF'
{"steps":[{"id":"s1","description":"rewrite manifest","files_allowed":["package.json"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"manifest remains valid"}]}
EOF
  rc=0
  PIPELINE_DS_COMMAND="$WORK/manifest-model.sh" "$PIPELINE_HOME/pipeline/code.sh" s1 >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'left-pad' package.json
  git diff --quiet
)

CONTEST_REPO="$WORK/contest"
make_repo "$CONTEST_REPO"
cat > "$WORK/contest-model.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '<<<<<<< FILE Contest.cs' 'internal class Contest { }' '>>>>>>> ENDFILE'
EOF
chmod +x "$WORK/contest-model.sh"
(
  cd "$CONTEST_REPO"
  printf '%s\n' 'internal class Contest { }' > Contest.cs
  printf '%s\n' 'function add(left, right) { return left + right; }' 'module.exports = { add };' > calculator.js
  git add Contest.cs calculator.js
  git commit -qm 'add production Contest class'
  cat > .pipeline/plan_final.json <<'EOF'
{"steps":[{"id":"s1","description":"update production class","files_allowed":["Contest.cs"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"production class is updated"}]}
EOF
  PIPELINE_DS_COMMAND="$WORK/contest-model.sh" "$PIPELINE_HOME/pipeline/code.sh" s1 >/dev/null
  git diff --quiet -- Contest.cs
)

RESUME_REPO="$WORK/resume"
make_repo "$RESUME_REPO"
cat > "$RESUME_REPO/multiplier.js" <<'EOF'
function multiply(left, right) { return 0; }
module.exports = { multiply };
EOF
cat >> "$RESUME_REPO/test/pipeline_generated.test.js" <<'EOF'
const { multiply } = require('../multiplier');
test('multiplies_numbers', () => assert.equal(multiply(2, 3), 6));
EOF
(
  cd "$RESUME_REPO"
  git add multiplier.js test/pipeline_generated.test.js
  git commit -qm 'add second failing step'
  git rev-parse HEAD > .pipeline/run_base
  cat > .pipeline/plan_final.json <<'EOF'
{"steps":[
  {"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"},
  {"id":"s2","description":"fix multiplication","files_allowed":["multiplier.js"],"context_files":[],"tests":["multiplies_numbers"],"deps":[],"done_when":"multiply returns the product"}
]}
EOF
)
cat > "$WORK/resume-model.sh" <<'EOF'
#!/usr/bin/env bash
if grep -q '"id": "s2"' "$2"; then
  count=0; [[ -f "$PIPELINE_S2_COUNT" ]] && count=$(cat "$PIPELINE_S2_COUNT")
  printf '%s\n' "$((count + 1))" > "$PIPELINE_S2_COUNT"
  printf '%s\n' '<<<<<<< FILE multiplier.js' 'function multiply(left, right) { return left * right; }' 'module.exports = { multiply };' '>>>>>>> ENDFILE'
  exit 0
fi
count=0; [[ -f "$PIPELINE_S1_COUNT" ]] && count=$(cat "$PIPELINE_S1_COUNT")
count=$((count + 1)); printf '%s\n' "$count" > "$PIPELINE_S1_COUNT"
if ((count <= 3)); then
  printf '%s\n' '<<<<<<< FILE outside.js' 'bad' '>>>>>>> ENDFILE'
else
  printf '%s\n' '<<<<<<< FILE calculator.js' 'function add(left, right) { return left + right; }' 'module.exports = { add };' '>>>>>>> ENDFILE'
fi
EOF
chmod +x "$WORK/resume-model.sh"
(
  cd "$RESUME_REPO"
  rc=0
  # s1 is meant to exhaust the full ladder here, so the cap is pinned rather than
  # inherited from the single-attempt default.
  PIPELINE_MAX_ATTEMPTS=3 \
    PIPELINE_DS_COMMAND="$WORK/resume-model.sh" PIPELINE_S1_COUNT="$WORK/s1.count" PIPELINE_S2_COUNT="$WORK/s2.count" \
    "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$WORK/s1.count")" == 3 ]]
  [[ "$(cat "$WORK/s2.count")" == 1 ]]
  jq -e '.steps.s1.status == "escalated" and .steps.s2.status == "done"' .pipeline/done.json >/dev/null

  PIPELINE_DS_COMMAND="$WORK/resume-model.sh" PIPELINE_S1_COUNT="$WORK/s1.count" PIPELINE_S2_COUNT="$WORK/s2.count" \
    "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null
  [[ "$(cat "$WORK/s1.count")" == 4 ]]
  [[ "$(cat "$WORK/s2.count")" == 1 ]]
  jq -e '.steps.s1.status == "done" and .steps.s1.ever_escalated == true and .steps.s1.attempts == 4' .pipeline/done.json >/dev/null
  "$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null
  "$PIPELINE_HOME/pipeline/review_trigger.sh" | grep -Fq 's1 escalated during this run'
)

echo "retry and escalation tests passed"
