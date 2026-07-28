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
    printf '%s\n' '{"name":"retry-fixture","version":"1.0.0","type":"commonjs"}' > package.json
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
  PIPELINE_DS_COMMAND="$WORK/retry-model.sh" PIPELINE_FAKE_COUNT="$RETRY_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 | tee .pipeline/logs/s1.log
  [[ "$(cat "$RETRY_COUNT")" == 2 ]]
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
  PIPELINE_DS_COMMAND="$WORK/escalate-model.sh" PIPELINE_FAKE_COUNT="$ESCALATE_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$ESCALATE_COUNT")" == 3 ]]
  [[ -f .pipeline/ESCALATE ]]
  grep -Fq 'exhausted 3 iterations' .pipeline/ESCALATE
  [[ ! -e outside.js ]]
  git diff --quiet
)

echo "retry and escalation tests passed"
