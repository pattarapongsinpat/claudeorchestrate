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

# --- code.sh single graded attempt -------------------------------------------

# One graded attempt: the tests run once, and a failure escalates rather than
# re-asking. The reverted attempt travels to the repair in the marker, since it is
# the only artifact the failed call produced.
GRADED_REPO="$WORK/graded"
make_node_repo "$GRADED_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$GRADED_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
GRADED_COUNT="$WORK/graded.count"
cat > "$WORK/graded-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
printf '%s\n' "$((count + 1))" > "$PIPELINE_FAKE_COUNT"
printf '%s\n' "$3" >> "$PIPELINE_FAKE_COUNT.models"
printf '<<<<<<< FILE calculator.js\nfunction add(a, b) { return a - b; }\nmodule.exports = { add };\n>>>>>>> ENDFILE\n'
EOF
chmod +x "$WORK/graded-model.sh"
(
  cd "$GRADED_REPO"
  rc=0
  # The log goes outside the repository: code.sh refuses to start on a dirty tree,
  # and an untracked log file inside it counts.
  PIPELINE_DS_COMMAND="$WORK/graded-model.sh" PIPELINE_FAKE_COUNT="$GRADED_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/graded-code.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  # Exactly one call: a failed assertion is never re-asked.
  [[ "$(cat "$GRADED_COUNT")" == 1 ]]
  [[ "$(cat "$GRADED_COUNT.models")" == "deepseek-v4-flash" ]]
  grep -Fq 'failed its mapped tests' .pipeline/ESCALATE
  grep -Fq 'adds_numbers' .pipeline/ESCALATE
  # The attempt is reverted from the tree but preserved for the repair.
  grep -Fq "the coder's reverted attempt" .pipeline/ESCALATE
  grep -Fq 'return a - b' .pipeline/ESCALATE
  git diff --quiet
  [[ -z "$(git status --porcelain)" ]]
)

# The model is selectable, and an unknown name is a configuration error.
PICK_COUNT="$WORK/pick.count"
(
  cd "$GRADED_REPO"
  rc=0
  PIPELINE_CODER_MODEL=pro \
    PIPELINE_DS_COMMAND="$WORK/graded-model.sh" PIPELINE_FAKE_COUNT="$PICK_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/pick-code.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$PICK_COUNT.models")" == "deepseek-v4-pro" ]]
  grep -Fq 'on deepseek-v4-pro' .pipeline/ESCALATE

  rc=0
  PIPELINE_CODER_MODEL=turbo "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/pick-bad.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'PIPELINE_CODER_MODEL must be flash or pro' "$WORK/pick-bad.log"
)

# Output that never reached a test is a formatting failure, not a coding one, so
# it is re-asked rather than escalated. Here the first response has no file block
# and the second is usable.
FORMAT_REPO="$WORK/format"
make_node_repo "$FORMAT_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$FORMAT_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
FORMAT_COUNT="$WORK/format.count"
cat > "$WORK/format-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$PIPELINE_FAKE_COUNT"
if ((count == 1)); then
  printf 'here is the code you asked for\n'
else
  printf '<<<<<<< FILE calculator.js\nfunction add(a, b) { return a + b; }\nmodule.exports = { add };\n>>>>>>> ENDFILE\n'
fi
EOF
chmod +x "$WORK/format-model.sh"
(
  cd "$FORMAT_REPO"
  PIPELINE_DS_COMMAND="$WORK/format-model.sh" PIPELINE_FAKE_COUNT="$FORMAT_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/format-code.log" 2>&1
  [[ "$(cat "$FORMAT_COUNT")" == 2 ]]
  grep -Fq 'PASS s1' "$WORK/format-code.log"
)

# Re-asks are bounded, and exhausting them says so rather than blaming the code.
UNUSABLE_REPO="$WORK/unusable"
make_node_repo "$UNUSABLE_REPO" "$(cat <<'EOF'
const test = require('node:test');
const assert = require('node:assert/strict');
const { add } = require('../calculator');
test('adds_numbers', () => assert.equal(add(2, 3), 5));
EOF
)"
cat > "$UNUSABLE_REPO/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"fix addition","files_allowed":["calculator.js"],"context_files":[],"tests":["adds_numbers"],"deps":[],"done_when":"add returns the sum"}]}
EOF
UNUSABLE_COUNT="$WORK/unusable.count"
cat > "$WORK/unusable-model.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$PIPELINE_FAKE_COUNT" ]] && count=$(cat "$PIPELINE_FAKE_COUNT")
printf '%s\n' "$((count + 1))" > "$PIPELINE_FAKE_COUNT"
printf 'no blocks here\n'
EOF
chmod +x "$WORK/unusable-model.sh"
(
  cd "$UNUSABLE_REPO"
  rc=0
  PIPELINE_MAX_FORMAT_RETRIES=1 \
    PIPELINE_DS_COMMAND="$WORK/unusable-model.sh" PIPELINE_FAKE_COUNT="$UNUSABLE_COUNT" \
    "$PIPELINE_HOME/pipeline/code.sh" s1 > "$WORK/unusable-code.log" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$(cat "$UNUSABLE_COUNT")" == 2 ]]
  grep -Fq 'never produced usable output' .pipeline/ESCALATE
  git diff --quiet
)

echo "single graded attempt tests passed"

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
