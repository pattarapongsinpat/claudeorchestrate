#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="$1"
PLAN=.pipeline/plan_final.json

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ABORT: tree dirty at entry to $STEP." >&2
  git status --short >&2
  exit 1
fi
BASE=$(git rev-parse HEAD)

# Per-invocation scratch dir so parallel code.sh runs (waves.sh) never clobber
# each other's temp files.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# tr -d '\r': jq on Windows (and CRLF-checked-out plan files) emits trailing CR,
# which would make every allowlist and selector comparison silently miss.
mapfile -t ALLOWED < <(jq -r ".steps[]|select(.id==\"$STEP\")|.files_allowed[]" "$PLAN" | tr -d '\r')
mapfile -t CONTEXT_FILES < <(jq -r ".steps[]|select(.id==\"$STEP\")|.context_files[]?" "$PLAN" | tr -d '\r')
mapfile -t TEST_NAMES < <(jq -r ".steps[]|select(.id==\"$STEP\")|.tests // [] | if type == \"array\" then .[] else . end" "$PLAN" | tr -d '\r')
rm -f $WORK/feedback.md

run_tests() { "$PIPELINE_HOME/pipeline/run_tests.sh" "${TEST_NAMES[@]}"; }

# Red-before: a step whose tests already pass at BASE asserts nothing about it,
# so the loop's exit condition is satisfiable without real work. Non-fatal —
# a refactor step may legitimately keep tests green — but surfaced for review.
if ((${#TEST_NAMES[@]})) && run_tests > $WORK/redcheck.out 2>&1; then
  { echo "step: $STEP"
    echo "tests '${TEST_NAMES[*]}' already pass at BASE — step is not gated by its tests"
  } > ".pipeline/WARN_${STEP}"
  echo "WARN: $STEP tests green before implementation; loop exit is trivially satisfiable" >&2
fi

MODEL=deepseek-v4-flash
for i in 1 2 3; do
  git checkout "$BASE" -- .
  git clean -fdq 2>/dev/null || true   # entry guard guarantees a clean tree, so every untracked file here is this run's

  [[ $i -ge 2 ]] && MODEL=deepseek-v4-pro

  {
    echo "## Step"
    jq -r ".steps[]|select(.id==\"$STEP\")" "$PLAN"
    echo
    echo "## Files you may modify — current contents"
    "$PIPELINE_HOME/pipeline/ctx.sh" "${ALLOWED[@]}"
    echo
    echo "## Read-only context — do NOT modify these"
    "$PIPELINE_HOME/pipeline/ctx.sh" "${CONTEXT_FILES[@]}"
  } > $WORK/step.md
  [[ -f $WORK/feedback.md ]] && cat $WORK/feedback.md >> $WORK/step.md

  "$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/coder.txt" $WORK/step.md "$MODEL" > $WORK/coder.out

  grep -qx 'NOOP' $WORK/coder.out && { echo "NOOP $STEP"; exit 0; }
  if [[ ! -s $WORK/coder.out ]] || ! grep -q '^<<<<<<< FILE ' $WORK/coder.out; then
    { echo "NO FILE BLOCKS FOUND."
      echo "For each changed file emit its COMPLETE contents between"
      echo "  <<<<<<< FILE <path>"
      echo "  >>>>>>> ENDFILE"
      echo "Nothing outside the blocks. If already satisfied, output: NOOP"
    } > $WORK/feedback.md
    continue
  fi

  # apply_files.sh writes only allowlisted blocks and refuses the rest, so an
  # out-of-scope file never reaches disk. Non-zero => at least one violation.
  if ! "$PIPELINE_HOME/pipeline/apply_files.sh" $WORK/coder.out "${ALLOWED[@]}" > $WORK/viol.out 2>&1; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      echo "Files outside allowlist (not written): $(tr '\n' ' ' < $WORK/viol.out)"
      echo "Allowed only: ${ALLOWED[*]}"
    } > $WORK/feedback.md
    continue
  fi

  # Allowlist is enforced at write time above; these catch a dependency or test
  # file that IS in the allowlist but must still not be edited here.
  TOUCHED=$( { git diff "$BASE" --name-only; git ls-files --others --exclude-standard; } | sort -u )
  mapfile -t DEPENDENCY_FILES < <(jq -r '.dependency_files[]?' .pipeline/toolchain.json | tr -d '\r')
  DEPS=$(git diff "$BASE" -- "${DEPENDENCY_FILES[@]}" 2>/dev/null | grep '^+[^+]' || true)
  TESTS=$(printf '%s\n' "$TOUCHED" | grep -Ei '(^|/)(test|tests)/|src/test/|test_|_test\.|\.test\.|\.spec\.|Tests?\.cs$' || true)

  if [[ -n "$DEPS$TESTS" ]]; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      [[ -n "$DEPS"  ]] && echo "Dependencies added: $DEPS"
      [[ -n "$TESTS" ]] && echo "Test files modified: $TESTS"
      echo "Allowed only: ${ALLOWED[*]}"
    } > $WORK/feedback.md
    continue
  fi

  if run_tests > $WORK/test.out 2>&1; then
    echo "PASS $STEP (iteration $i)"
    exit 0
  fi
  { echo "TESTS FAILED — your changes were reverted."
    echo "The files you will see next are the ORIGINAL ones, not your attempt."
    echo "Re-output complete file blocks from scratch. Do not assume prior edits exist."
    tail -40 $WORK/test.out
  } > $WORK/feedback.md
done

git checkout "$BASE" -- .
git clean -fdq 2>/dev/null || true
{ echo "step: $STEP"
  echo "exhausted 3 iterations"
  echo "--- last feedback ---"
  cat $WORK/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
echo "ESCALATE: $STEP exhausted 3 iterations" >&2
exit 1
