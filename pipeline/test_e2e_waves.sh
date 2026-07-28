#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/test"
cd "$REPO"

git init -q
git config user.name 'Pipeline Wave Test'
git config user.email 'pipeline@example.invalid'
printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"

cat > package.json <<'EOF'
{"name":"pipeline-wave-e2e","version":"1.0.0","type":"commonjs"}
EOF
cat > alpha.js <<'EOF'
function increment(value) {
  return value;
}

module.exports = { increment };
EOF
cat > beta.js <<'EOF'
function double(value) {
  return value;
}

module.exports = { double };
EOF
cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { increment } = require('../alpha');
const { double } = require('../beta');

test('increments_value', () => {
  assert.equal(increment(4), 5);
});

test('doubles_value', () => {
  assert.equal(double(4), 8);
});
EOF
git add package.json alpha.js beta.js test/pipeline_generated.test.js
git commit -qm 'wave fixture baseline'

"$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
cat > .pipeline/plan_final.json <<'EOF'
{"steps":[
  {
    "id":"alpha",
    "description":"Make increment return its numeric argument plus one.",
    "files_allowed":["alpha.js"],
    "context_files":[],
    "tests":["increments_value"],
    "deps":[],
    "done_when":"increment(4) returns 5"
  },
  {
    "id":"beta",
    "description":"Make double return two times its numeric argument.",
    "files_allowed":["beta.js"],
    "context_files":[],
    "tests":["doubles_value"],
    "deps":[],
    "done_when":"double(4) returns 8"
  }
]}
EOF

if "$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null 2>&1; then
  echo "wave fixture unexpectedly passed before implementation" >&2
  exit 1
fi

base=$(git rev-parse HEAD)
"$PIPELINE_HOME/pipeline/waves.sh"
"$PIPELINE_HOME/pipeline/final_check.sh"
[[ "$(git rev-list --count "$base"..HEAD)" == 2 ]]
grep -Fxq alpha.js .pipeline/touched.log
grep -Fxq beta.js .pipeline/touched.log
[[ -z "$(git worktree list --porcelain | grep '^worktree ' | tail -n +2)" ]]
node -e "const {increment}=require('./alpha'); const {double}=require('./beta'); if(increment(9)!==10 || double(9)!==18) process.exit(1)"

echo "DeepSeek parallel wave loop passed"
