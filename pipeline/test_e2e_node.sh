#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/test"
cd "$REPO"

git init -q
git config user.name 'Pipeline E2E Test'
git config user.email 'pipeline@example.invalid'
printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"

cat > package.json <<'EOF'
{"name":"pipeline-e2e","version":"1.0.0","type":"commonjs"}
EOF
cat > calculator.js <<'EOF'
function add(left, right) {
  return 0;
}

module.exports = { add };
EOF
cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');

test('adds_numbers', () => {
  assert.equal(add(2, 3), 5);
});
EOF
git add package.json calculator.js test/pipeline_generated.test.js
git commit -qm 'fixture baseline'

"$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
cat > .pipeline/plan_final.json <<'EOF'
{"steps":[{
  "id":"s1",
  "description":"Make add return the sum of its two numeric arguments.",
  "files_allowed":["calculator.js"],
  "context_files":[],
  "tests":["adds_numbers"],
  "deps":[],
  "done_when":"add(2, 3) returns 5"
}]}
EOF

if "$PIPELINE_HOME/pipeline/run_tests.sh" adds_numbers >/dev/null 2>&1; then
  echo "fixture test unexpectedly passed before implementation" >&2
  exit 1
fi

"$PIPELINE_HOME/pipeline/code.sh" s1
"$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null
node -e "const {add}=require('./calculator'); if(add(7,8)!==15) process.exit(1)"
git diff --quiet -- calculator.js && {
  echo "DeepSeek coder made no implementation change" >&2
  exit 1
}

echo "DeepSeek Node implementation loop passed"
