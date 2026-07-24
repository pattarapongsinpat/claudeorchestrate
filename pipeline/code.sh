#!/usr/bin/env bash
set -euo pipefail
STEP="$1"
PLAN=.pipeline/plan_final.json

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ABORT: tree dirty at entry to $STEP." >&2
  git status --short >&2
  exit 1
fi
BASE=$(git rev-parse HEAD)

# tr -d '\r': jq on Windows (and CRLF-checked-out plan files) emits trailing CR,
# which would make every allowlist and selector comparison silently miss.
mapfile -t ALLOWED < <(jq -r ".steps[]|select(.id==\"$STEP\")|.files_allowed[]" "$PLAN" | tr -d '\r')
TESTSEL=$(jq -r ".steps[]|select(.id==\"$STEP\")|.tests // empty" "$PLAN" | tr -d '\r')
rm -f /tmp/feedback.md

# A selector that matches no test would make every iteration exit 5 and escalate.
# Fall back to the full suite in that case.
if [[ -n "$TESTSEL" ]] && ! pytest -k "$TESTSEL" --collect-only -q >/dev/null 2>&1; then
  echo "WARN: test selector '$TESTSEL' for $STEP matched nothing; using full suite" >&2
  TESTSEL=""
fi

run_tests() {                       # scoped to the step when the gate assigned a selector
  if [[ -n "$TESTSEL" ]]; then
    pytest -q -k "$TESTSEL" "$@"
  else
    pytest -q "$@"
  fi
}

# Red-before: a step whose tests already pass at BASE asserts nothing about it,
# so the loop's exit condition is satisfiable without real work. Non-fatal —
# a refactor step may legitimately keep tests green — but surfaced for review.
if [[ -n "$TESTSEL" ]] && run_tests > /tmp/redcheck.out 2>&1; then
  { echo "step: $STEP"
    echo "tests '$TESTSEL' already pass at BASE — step is not gated by its tests"
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
    ./pipeline/ctx.sh "${ALLOWED[@]}"
    echo
    echo "## Read-only context — do NOT modify these"
    ./pipeline/ctx.sh $(jq -r ".steps[]|select(.id==\"$STEP\")|.context_files[]?" "$PLAN" | tr -d '\r')
  } > /tmp/step.md
  [[ -f /tmp/feedback.md ]] && cat /tmp/feedback.md >> /tmp/step.md

  ./pipeline/ds.sh prompts/coder.txt /tmp/step.md "$MODEL" > /tmp/coder.out

  grep -qx 'NOOP' /tmp/coder.out && { echo "NOOP $STEP"; exit 0; }
  if [[ ! -s /tmp/coder.out ]] || ! grep -q '^<<<<<<< FILE ' /tmp/coder.out; then
    { echo "NO FILE BLOCKS FOUND."
      echo "For each changed file emit its COMPLETE contents between"
      echo "  <<<<<<< FILE <path>"
      echo "  >>>>>>> ENDFILE"
      echo "Nothing outside the blocks. If already satisfied, output: NOOP"
    } > /tmp/feedback.md
    continue
  fi

  # apply_files.sh writes only allowlisted blocks and refuses the rest, so an
  # out-of-scope file never reaches disk. Non-zero => at least one violation.
  if ! ./pipeline/apply_files.sh /tmp/coder.out "${ALLOWED[@]}" > /tmp/viol.out 2>&1; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      echo "Files outside allowlist (not written): $(tr '\n' ' ' < /tmp/viol.out)"
      echo "Allowed only: ${ALLOWED[*]}"
    } > /tmp/feedback.md
    continue
  fi

  # Allowlist is enforced at write time above; these catch a dependency or test
  # file that IS in the allowlist but must still not be edited here.
  TOUCHED=$( { git diff "$BASE" --name-only; git ls-files --others --exclude-standard; } | sort -u )
  DEPS=$(git diff "$BASE" -- package.json requirements.txt pyproject.toml Cargo.toml \
         2>/dev/null | grep '^+[^+]' || true)
  TESTS=$(printf '%s\n' $TOUCHED | grep -E '(test_|_test\.|\.test\.|/tests?/)' || true)

  if [[ -n "$DEPS$TESTS" ]]; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      [[ -n "$DEPS"  ]] && echo "Dependencies added: $DEPS"
      [[ -n "$TESTS" ]] && echo "Test files modified: $TESTS"
      echo "Allowed only: ${ALLOWED[*]}"
    } > /tmp/feedback.md
    continue
  fi

  if run_tests > /tmp/test.out 2>&1; then
    echo "PASS $STEP (iteration $i)"
    exit 0
  fi
  { echo "TESTS FAILED — your changes were reverted."
    echo "The files you will see next are the ORIGINAL ones, not your attempt."
    echo "Re-output complete file blocks from scratch. Do not assume prior edits exist."
    tail -40 /tmp/test.out
  } > /tmp/feedback.md
done

git checkout "$BASE" -- .
git clean -fdq 2>/dev/null || true
{ echo "step: $STEP"
  echo "exhausted 3 iterations"
  echo "--- last feedback ---"
  cat /tmp/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
echo "ESCALATE: $STEP exhausted 3 iterations" >&2
exit 1
