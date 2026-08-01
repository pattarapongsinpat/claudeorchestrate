#!/usr/bin/env bash
# Covers the guards that keep a bad generated test from being charged to the coder:
# title normalization, broken-test classification at the baseline, early escalation
# on an unsatisfiable assertion, and the repository symbol index.
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- normalize_test_names.sh -------------------------------------------------

cat > "$WORK/titles.test.ts" <<'EOF'
import { describe, it, test } from 'vitest'
describe('a suite', () => {
  it('reuses the seed: retry case', async () => {})
  it(
    'writes a pending attempt, then fails',
    async () => {},
  )
  test("reuses the seed: retry case", () => {})
})
EOF
bash "$PIPELINE_HOME/pipeline/normalize_test_names.sh" "$WORK/titles.test.ts" typescript 2>/dev/null
grep -Fq "it('reuses_the_seed_retry_case'" "$WORK/titles.test.ts"
grep -Fq "it('writes_a_pending_attempt_then_fails'" "$WORK/titles.test.ts"
# A colliding title must not produce two tests with the same selector name.
grep -Fq 'test("reuses_the_seed_retry_case_2"' "$WORK/titles.test.ts"
# describe() titles are prose for humans and are left alone.
grep -Fq "describe('a suite'" "$WORK/titles.test.ts"

cat > "$WORK/keep.py" <<'EOF'
def test_reads_well(): pass
EOF
bash "$PIPELINE_HOME/pipeline/normalize_test_names.sh" "$WORK/keep.py" python
grep -Fq 'def test_reads_well' "$WORK/keep.py"

echo "normalization tests passed"

# --- check_baseline.sh classification ---------------------------------------

make_node_repo() {
  local repo="$1" test_body="$2"
  mkdir -p "$repo/test"
  (
    cd "$repo"
    git init -q
    git config user.name 'Pipeline Hardening Test'
    git config user.email 'pipeline@example.invalid'
    printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"
    printf '%s\n' '{"name":"hardening-fixture","version":"1.0.0","type":"commonjs"}' > package.json
    printf '%s\n' 'function add(a, b) { return 0; }' 'module.exports = { add };' > calculator.js
    printf '%s\n' "$test_body" > test/pipeline_generated.test.js
    git add .
    git commit -qm baseline
    "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  )
}

# An assertion that does not hold yet is the expected red baseline.
ASSERT_REPO="$WORK/assert"
make_node_repo "$ASSERT_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
(
  cd "$ASSERT_REPO"
  "$PIPELINE_HOME/pipeline/check_baseline.sh" > "$WORK/baseline.log" 2>&1
  grep -Fq "baseline red — proceeding" "$WORK/baseline.log"
  [[ ! -f .pipeline/HALT ]]
)

# A test file that cannot execute is a defect in the test, and must stop the run.
BROKEN_REPO="$WORK/broken"
make_node_repo "$BROKEN_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), missingHelper()));
EOF
)"
(
  cd "$BROKEN_REPO"
  rc=0
  "$PIPELINE_HOME/pipeline/check_baseline.sh" > "$WORK/baseline.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ -f .pipeline/HALT ]]
  grep -Fq 'the generated tests do not execute' .pipeline/HALT
  grep -Fq 'ReferenceError' .pipeline/HALT
)

# The override exists for a test that legitimately asserts on one of the patterns.
(
  cd "$BROKEN_REPO"
  rm -f .pipeline/HALT
  PIPELINE_ALLOW_BROKEN_TESTS=1 "$PIPELINE_HOME/pipeline/check_baseline.sh" > "$WORK/baseline.log" 2>&1
  [[ ! -f .pipeline/HALT ]]
)

echo "baseline classification tests passed"

# --- code.sh early escalation ------------------------------------------------

# Both attempts change the file and both fail the same way. Nothing the coder can
# write satisfies this assertion, so the loop must stop at two rather than three.
SAME_REPO="$WORK/same"
make_node_repo "$SAME_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$SAME_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
SAME_COUNT="$WORK/same.count"
cat > "$WORK/same-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$PIPELINE_FAKE_COUNT"
# A different wrong answer each time: the failure text differs only in the digits,
# which the signature strips, so the two attempts hash alike.
printf '<<<<<<< FILE calculator.js\nfunction add(a, b) { return %s; }\nmodule.exports = { add };\n>>>>>>> ENDFILE\n' "$count"
EOF
chmod +x "$WORK/same-model.sh"
(
  cd "$SAME_REPO"
  rc=0
  # The log goes outside the repository: code.sh refuses to start on a dirty tree,
  # and an untracked log file inside it counts.
  # The point is that the loop stops at two of three, so the cap is pinned.
  PIPELINE_MAX_ATTEMPTS=3 \
    PIPELINE_DS_COMMAND="$WORK/same-model.sh" PIPELINE_FAKE_COUNT="$SAME_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/same-code.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$SAME_COUNT")" == 2 ]]
  grep -Fq 'suspect the test, not the code' .pipeline/ESCALATE
  grep -Fq 'adds_numbers' .pipeline/ESCALATE
  # The step still reverts cleanly; an early exit must not leave the tree dirty.
  git diff --quiet
)

# A genuinely different failure on the second attempt still gets its third try.
PROGRESS_REPO="$WORK/progress"
make_node_repo "$PROGRESS_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$PROGRESS_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
PROGRESS_COUNT="$WORK/progress.count"
cat > "$WORK/progress-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$PIPELINE_FAKE_COUNT"
case "$count" in
  1) body='throw new Error("boom")' ;;
  2) body='return a - b' ;;
  *) body='return a + b' ;;
esac
printf '<<<<<<< FILE calculator.js\nfunction add(a, b) { %s; }\nmodule.exports = { add };\n>>>>>>> ENDFILE\n' "$body"
EOF
chmod +x "$WORK/progress-model.sh"
(
  cd "$PROGRESS_REPO"
  PIPELINE_MAX_ATTEMPTS=3 \
    PIPELINE_DS_COMMAND="$WORK/progress-model.sh" PIPELINE_FAKE_COUNT="$PROGRESS_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/progress-code.log" 2>&1
  [[ "$(cat "$PROGRESS_COUNT")" == 3 ]]
  grep -Fq 'PASS s1' "$WORK/progress-code.log"
)

echo "early escalation tests passed"

# --- attempt cap -------------------------------------------------------------

# The default is one attempt. The cap truncates the ladder without changing it, so
# that attempt is still the flash one.
CAP_REPO="$WORK/cap"
make_node_repo "$CAP_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$CAP_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
CAP_COUNT="$WORK/cap.count"
cat > "$WORK/cap-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
printf '%s\n' "$((count + 1))" > "$PIPELINE_FAKE_COUNT"
printf '%s\n' "$3" >> "$PIPELINE_FAKE_COUNT.models"
printf '<<<<<<< FILE calculator.js\nfunction add(a, b) { return a - b; }\nmodule.exports = { add };\n>>>>>>> ENDFILE\n'
EOF
chmod +x "$WORK/cap-model.sh"
(
  cd "$CAP_REPO"
  rc=0
  PIPELINE_DS_COMMAND="$WORK/cap-model.sh" PIPELINE_FAKE_COUNT="$CAP_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/cap-code.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$CAP_COUNT")" == 1 ]]
  [[ "$(cat "$CAP_COUNT.models")" == "deepseek-v4-flash" ]]
  grep -Fq 'exhausted 1 iterations' .pipeline/ESCALATE
  git diff --quiet
)

# An out-of-range cap is a configuration error, not a silent fallback.
(
  cd "$CAP_REPO"
  rc=0
  PIPELINE_MAX_ATTEMPTS=9 "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/cap-bad.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'PIPELINE_MAX_ATTEMPTS must be 1, 2, or 3' "$WORK/cap-bad.log"
)

echo "attempt cap tests passed"

# --- symbol_index.sh ---------------------------------------------------------

SYMBOL_REPO="$WORK/symbols"
make_node_repo "$SYMBOL_REPO" "$(cat <<'EOF'
const test = require('node:test');
test('placeholder', () => {});
EOF
)"
(
  cd "$SYMBOL_REPO"
  printf '%s\n' 'function readAll(db, storeName) { return null; }' 'module.exports = { readAll };' > memory.js
  "$PIPELINE_HOME/pipeline/symbol_index.sh" > "$WORK/index.out"
  grep -Fq 'memory.js' "$WORK/index.out"
  grep -Fq 'readAll' "$WORK/index.out"
  # Test files are excluded: their fixtures are noise the coder cannot call anyway.
  ! grep -Fq 'pipeline_generated.test.js' "$WORK/index.out"
  [[ "$("$PIPELINE_HOME/pipeline/symbol_index.sh" --declaration)" == *function* ]]
)

echo "symbol index tests passed"

# --- run.sh scopes the generated test path -----------------------------------

RUN_REPO="$WORK/runscope"
make_node_repo "$RUN_REPO" "$(cat <<'EOF'
const test = require('node:test');
test('placeholder', () => {});
EOF
)"
(
  cd "$RUN_REPO"
  "$PIPELINE_HOME/pipeline/run.sh" >/dev/null
  path=$(jq -r '.generated_test_file' .pipeline/toolchain.json)
  [[ "$path" =~ ^test/pipeline_generated\.[0-9]{8}-[0-9]{6}\.test\.js$ ]] || {
    echo "unexpected generated test path: $path" >&2
    exit 1
  }
)

echo "run-scoped test path tests passed"
echo "hardening tests passed"
