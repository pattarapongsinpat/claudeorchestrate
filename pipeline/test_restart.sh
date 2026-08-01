#!/usr/bin/env bash
# Covers restart_run.sh without the API: what it resets, what it keeps, what it
# archives, and the budget that stops a request from restarting forever.
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/restart"
mkdir -p "$REPO/test"
(
  cd "$REPO"
  git init -q
  git config user.name 'Pipeline Restart Test'
  git config user.email 'pipeline@example.invalid'
  printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"
  printf '%s\n' '{"name":"restart-fixture","version":"1.0.0","type":"commonjs"}' > package.json
  printf '%s\n' 'function add(a, b) { return 0; }' 'module.exports = { add };' > calculator.js
  git add -A
  git commit -qm baseline
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  git rev-parse HEAD > .pipeline/run_base

  # Stand in for a run that got as far as generated tests and one step commit.
  TESTFILE=test/pipeline_generated.20250101-000000.test.js
  tmp=$(mktemp)
  jq --arg f "$TESTFILE" '.generated_test_file = $f' .pipeline/toolchain.json > "$tmp" && mv "$tmp" .pipeline/toolchain.json
  printf '%s\n' "// a test that no implementation can satisfy" > "$TESTFILE"
  git add -A && git commit -qm 'generated tests'
  printf '%s\n' 'function add(a, b) { return a + b; }' 'module.exports = { add };' > calculator.js
  git add -A && git commit -qm 'step s1'
  printf '%s\n' '# plan' > .pipeline/plan.md
  printf '%s\n' '{"steps":[]}' > .pipeline/plan_final.json
  printf '%s\n' '# tests' > .pipeline/tests_spec.md
  printf '%s\n' '{"steps":{}}' > .pipeline/done.json
  printf '%s\n' 'step: s1' > .pipeline/ESCALATE
  printf '%s\n' 'the original request' > .pipeline/request.txt
  printf '%s\n' '{"goal":"x"}' > .pipeline/intent.json
)

BASE=$(cd "$REPO" && cat .pipeline/run_base)

(
  cd "$REPO"
  OLD_TEST=$(jq -r '.generated_test_file' .pipeline/toolchain.json)
  "$PIPELINE_HOME/pipeline/restart_run.sh" "mapped test asserts an unreachable value" > "$WORK/restart.out" 2>&1
  grep -Fq 'RESTART 1' "$WORK/restart.out"

  # Back at the base, with a clean tree.
  [[ "$(git rev-parse HEAD)" == "$BASE" ]]
  [[ -z "$(git status --porcelain)" ]]

  # Abandoned work is tagged, not discarded.
  tag=$(git tag --list 'pipeline-abandoned-*' | head -1)
  [[ -n "$tag" ]]
  git cat-file -e "$tag^{commit}"

  # Plan and tests are gone; request and intent survive.
  [[ ! -f .pipeline/plan.md ]]
  [[ ! -f .pipeline/plan_final.json ]]
  [[ ! -f .pipeline/tests_spec.md ]]
  [[ ! -f .pipeline/done.json ]]
  [[ ! -f .pipeline/ESCALATE ]]
  [[ -f .pipeline/request.txt ]]
  [[ -f .pipeline/intent.json ]]
  grep -Fq 'the original request' .pipeline/request.txt

  # The failing test file is archived with the reason, and the toolchain points at
  # a fresh path so tests.sh will not refuse to write.
  [[ -f ".pipeline/attempt-1/$(basename "$OLD_TEST")" ]]
  grep -Fq 'unreachable value' .pipeline/attempt-1/reason.txt
  NEW_TEST=$(jq -r '.generated_test_file' .pipeline/toolchain.json)
  [[ "$NEW_TEST" != "$OLD_TEST" ]]
  [[ "$NEW_TEST" == test/pipeline_generated.*.test.js ]]
  [[ ! -f "$NEW_TEST" ]]
  # Exactly one stamp. Restamping the already-stamped path stacked them, and every
  # restart made the name longer: pipeline_generated.r1-<new>.<old>.test.js
  [[ "$(basename "$NEW_TEST" | tr -cd '.' | wc -c)" == 3 ]]
  [[ "$NEW_TEST" != *20250101-000000* ]]
)

# --- budget ------------------------------------------------------------------

(
  cd "$REPO"
  rc=0
  "$PIPELINE_HOME/pipeline/restart_run.sh" "second try" > "$WORK/budget.out" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'already restarted 1 time(s)' "$WORK/budget.out"
  # A refused restart changes nothing.
  [[ "$(git rev-parse HEAD)" == "$BASE" ]]
  [[ "$(cat .pipeline/restarts)" == 1 ]]
)

# A raised limit is honoured, and the second attempt archives separately.
(
  cd "$REPO"
  PIPELINE_MAX_RESTARTS=2 "$PIPELINE_HOME/pipeline/restart_run.sh" "second try" > "$WORK/second.out" 2>&1
  grep -Fq 'RESTART 2' "$WORK/second.out"
  grep -Fq 'no commits to abandon' "$WORK/second.out"
  [[ -d .pipeline/attempt-2 ]]
  [[ "$(cat .pipeline/restarts)" == 2 ]]
  [[ "$(grep -c 'reason:' .pipeline/restart_log.txt)" == 2 ]]
)

echo "restart tests passed"
