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

mapfile -t ALLOWED < <(jq -r ".steps[]|select(.id==\"$STEP\")|.files_allowed[]" "$PLAN")
TESTSEL=$(jq -r ".steps[]|select(.id==\"$STEP\")|.tests // empty" "$PLAN")
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
  git clean -fdq -- "${ALLOWED[@]}" 2>/dev/null || true

  [[ $i -ge 2 ]] && MODEL=deepseek-v4-pro

  {
    echo "## Step"
    jq -r ".steps[]|select(.id==\"$STEP\")" "$PLAN"
    echo
    echo "## Files you may modify — current contents"
    ./pipeline/ctx.sh "${ALLOWED[@]}"
    echo
    echo "## Read-only context — do NOT modify these"
    ./pipeline/ctx.sh $(jq -r ".steps[]|select(.id==\"$STEP\")|.context_files[]?" "$PLAN")
  } > /tmp/step.md
  [[ -f /tmp/feedback.md ]] && cat /tmp/feedback.md >> /tmp/step.md

  ./pipeline/ds.sh prompts/coder.txt /tmp/step.md "$MODEL" > /tmp/patch.diff

  if [[ ! -s /tmp/patch.diff ]] || ! grep -q '^\(---\|+++\|@@\)' /tmp/patch.diff; then
    { echo "EMPTY OR MALFORMED OUTPUT."
      echo "Output a unified diff only, starting with '--- a/<path>'."
      echo "No prose, no markdown fences, no explanation."
      echo "If the step is already satisfied, output exactly: NOOP"
    } > /tmp/feedback.md
    continue
  fi
  grep -qx 'NOOP' /tmp/patch.diff && { echo "NOOP $STEP"; exit 0; }

  if ! git apply --check /tmp/patch.diff 2>/tmp/apply.err; then
    { echo "PATCH DID NOT APPLY:"; cat /tmp/apply.err; } > /tmp/feedback.md
    continue
  fi
  git apply /tmp/patch.diff

  TOUCHED=$(git diff "$BASE" --name-only)
  VIOL=""
  for f in $TOUCHED; do
    printf '%s\n' "${ALLOWED[@]}" | grep -qxF "$f" || VIOL+="$f "
  done
  DEPS=$(git diff "$BASE" -- package.json requirements.txt pyproject.toml Cargo.toml \
         2>/dev/null | grep '^+[^+]' || true)
  TESTS=$(printf '%s\n' $TOUCHED | grep -E '(test_|_test\.|\.test\.|/tests?/)' || true)

  if [[ -n "$VIOL$DEPS$TESTS" ]]; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      [[ -n "$VIOL"  ]] && echo "Files outside allowlist: $VIOL"
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
  { echo "TESTS FAILED — your patch was reverted."
    echo "The files you will see next are the ORIGINAL ones, not your attempt."
    echo "Produce a complete patch from scratch. Do not assume prior edits exist."
    tail -40 /tmp/test.out
  } > /tmp/feedback.md
done

git checkout "$BASE" -- .
git clean -fdq -- "${ALLOWED[@]}" 2>/dev/null || true
{ echo "step: $STEP"
  echo "exhausted 3 iterations"
  echo "--- last feedback ---"
  cat /tmp/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
echo "ESCALATE: $STEP exhausted 3 iterations" >&2
exit 1
