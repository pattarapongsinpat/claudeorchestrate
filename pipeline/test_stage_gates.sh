#!/usr/bin/env bash
# The three stages whose output nothing used to consume, so skipping them was
# silent: check_assumptions, check_baseline, and the verify gate on the collapse.
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

new_repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo/test"
  cd "$WORK/repo"
  git init -q
  git config user.email t@t; git config user.name t
  printf '%s\n' '{"name":"f","version":"1.0.0","type":"commonjs"}' > package.json
  cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
test('adds_numbers', () => {});
EOF
  echo 'module.exports = {};' > calculator.js
  git add -A; git commit -qm base
  printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  git rev-parse HEAD > .pipeline/run_base
  cat > .pipeline/plan_final.json <<'EOF'
{"steps":[{"id":"s1","description":"fix","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"it works"}]}
EOF
}

# ---- the baseline stamp is content, not time ----
new_repo
S1=$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")
touch test/pipeline_generated.test.js          # mtime moves, content does not
S2=$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")
[[ "$S1" == "$S2" ]] || { echo "stamp changed on touch alone" >&2; exit 1; }
# Line endings are not content. With core.autocrlf a checkout rewrites every line
# in the file, and a stamp that moved on that would abort a legitimate resume.
sed -i 's/$/\r/' test/pipeline_generated.test.js
[[ "$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")" == "$S1" ]] || {
  echo "stamp moved on a line-ending rewrite" >&2; exit 1; }
sed -i 's/\r$//' test/pipeline_generated.test.js

echo "// gate edit" >> test/pipeline_generated.test.js
S3=$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")
[[ "$S1" != "$S3" ]] || { echo "stamp survived a content change" >&2; exit 1; }

# A commit does not change the stamp: the gate commits the test file right after
# re-running the baseline, and that must not invalidate it.
git add -A; git commit -qm "generated tests"
[[ "$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")" == "$S3" ]]

# Existing-suite adapters still stamp, because a missing stamp is the signal.
jq '.generated_tests = false | .generated_test_file = ""' .pipeline/toolchain.json > "$WORK/t" && mv "$WORK/t" .pipeline/toolchain.json
[[ "$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")" == existing-suite ]]

# ---- waves refuses without a matching baseline ----
new_repo
rc=0; "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || { echo "waves ran with no baseline" >&2; exit 1; }

"$PIPELINE_HOME/pipeline/baseline_stamp.sh" > .pipeline/baseline.sha
echo "// edited after the baseline" >> test/pipeline_generated.test.js
git add -A; git commit -qm edit
rc=0; "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || { echo "waves ran against tests the baseline never saw" >&2; exit 1; }

# check_baseline records the stamp on the red path, which is the normal one.
new_repo
cat > test/pipeline_generated.test.js <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
test('adds_numbers', () => assert.equal(1, 2));
EOF
git add -A; git commit -qm red
rc=0; "$PIPELINE_HOME/pipeline/check_baseline.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]]
[[ -f .pipeline/baseline.sha ]]
[[ "$(cat .pipeline/baseline.sha)" == "$("$PIPELINE_HOME/pipeline/baseline_stamp.sh")" ]]

# ---- plan and tests refuse an ungraded intent ----
new_repo
printf '{"allowed_files":["calculator.js"],"verification":{"mode":"tests"}}\n' > .pipeline/intent.json
printf '# Goal\nx\n' > .pipeline/intent.md
for s in plan tests; do
  rc=0; "$PIPELINE_HOME/pipeline/$s.sh" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "$s ran with no assumption verdict" >&2; exit 1; }
done
printf 'UNSOUND: assumes a cache\n' > .pipeline/assumptions.md
for s in plan tests; do
  rc=0; "$PIPELINE_HOME/pipeline/$s.sh" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "$s ran on an UNSOUND verdict" >&2; exit 1; }
done

# ---- collapse holds the verify gate ----
new_repo
echo 'module.exports = {a:1};' > calculator.js
git add -A; git commit -qm "step s1"
COLLAPSE="$PIPELINE_HOME/pipeline/collapse.sh"

rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?      # no verdict at all
[[ "$rc" == 1 ]]

printf 'DRIFT: built the wrong thing\n' > .pipeline/verify.md
rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || { echo "collapse ignored DRIFT" >&2; exit 1; }
[[ "$(git rev-list --count "$(cat .pipeline/run_base)"..HEAD)" == 1 ]]

printf 'ACCEPT extra\n' > .pipeline/verify.md
rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || { echo "collapse accepted a malformed verdict" >&2; exit 1; }

# A marker means the run stopped on purpose and the step commits are the evidence.
printf 'ACCEPT\n' > .pipeline/verify.md
for marker in HALT ESCALATE REGRESSION; do
  : > ".pipeline/$marker"
  rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "collapse ignored $marker" >&2; exit 1; }
  rm -f ".pipeline/$marker"
done

echo stray > calculator.js
rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || { echo "collapse ran on a dirty tree" >&2; exit 1; }
git checkout -q -- calculator.js

"$COLLAPSE" "the goal" >/dev/null
[[ "$(git rev-list --count "$(cat .pipeline/run_base)"..HEAD)" == 1 ]]
[[ "$(git log -1 --pretty=%s)" == "the goal" ]]

# Running it twice is idempotent rather than stacking a second commit.
"$COLLAPSE" "the goal" >/dev/null
[[ "$(git rev-list --count "$(cat .pipeline/run_base)"..HEAD)" == 1 ]]

# With nothing above the base there is nothing to collapse, and saying so beats
# committing an empty change.
new_repo
printf 'ACCEPT\n' > .pipeline/verify.md
rc=0; "$COLLAPSE" msg >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

cd /
echo "stage gate tests passed"
