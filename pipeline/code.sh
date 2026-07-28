#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="$1"
PLAN=.pipeline/plan_final.json
bash "$PIPELINE_HOME/pipeline/validate_plan.sh" "$PLAN" >/dev/null
jq -e --arg id "$STEP" '[.steps[].id] | index($id) != null' "$PLAN" >/dev/null || {
  echo "unknown step: $STEP" >&2; exit 1;
}

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
mapfile -t ALLOWED < <(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.files_allowed[]' "$PLAN" | tr -d '\r')
mapfile -t CONTEXT_FILES < <(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.context_files[]?' "$PLAN" | tr -d '\r')
mapfile -t TEST_NAMES < <(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.tests // [] | if type == "array" then .[] else . end' "$PLAN" | tr -d '\r')
rm -f $WORK/feedback.md

run_tests() { "$PIPELINE_HOME/pipeline/run_tests.sh" "${TEST_NAMES[@]}"; }

# A selector matching no test exits 0 on most runners — verified against the real
# toolchains for node --test, Vitest, Jest, Go, Cargo, Maven and dotnet. Resolve
# every generated test name from source before any coder call. Existing-suite
# adapters map [] and run the complete suite.
if ! bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" "$PLAN" "$STEP" > $WORK/test_names.out 2>&1; then
  { echo "step: $STEP"
    cat $WORK/test_names.out
  } > .pipeline/ESCALATE
  cat $WORK/test_names.out >&2
  echo "ESCALATE: $STEP has invalid mapped tests" >&2
  exit 1
fi

# Red-before: a step whose tests already pass at BASE asserts nothing about it,
# so the loop's exit condition is satisfiable without real work. Non-fatal —
# a refactor step may legitimately keep tests green — but surfaced for review.
if ((${#TEST_NAMES[@]})) && run_tests > $WORK/redcheck.out 2>&1; then
  { echo "step: $STEP"
    echo "tests '${TEST_NAMES[*]}' already pass at BASE — step is not gated by its tests"
  } > ".pipeline/WARN_${STEP}"
  echo "WARN: $STEP tests green before implementation; loop exit is trivially satisfiable" >&2
fi

# Built once: every iteration reverts to BASE first, so the allowlisted files the
# coder sees are identical each time. ctx.sh --writable exits 3 when one of them
# matches a credential pattern, which must stop the step rather than leak it.
if ! "$PIPELINE_HOME/pipeline/ctx.sh" --writable "${ALLOWED[@]}" > $WORK/allowed_ctx.md 2> $WORK/ctx.err; then
  { echo "step: $STEP"
    echo "refusing to run: an allowlisted file matches a credential pattern"
    cat $WORK/ctx.err
  } > .pipeline/ESCALATE
  cat $WORK/ctx.err >&2
  echo "ESCALATE: $STEP — credential in a file this step may rewrite" >&2
  exit 1
fi

MODEL=deepseek-v4-flash
TRUNCATED=0
for i in 1 2 3; do
  git checkout "$BASE" -- .
  git clean -fdq 2>/dev/null || true   # entry guard guarantees a clean tree, so every untracked file here is this run's

  [[ $i -ge 2 ]] && MODEL=deepseek-v4-pro

  {
    echo "## Step"
    jq -r --arg id "$STEP" '.steps[]|select(.id==$id)' "$PLAN"
    echo
    echo "## Files you may modify — current contents"
    cat $WORK/allowed_ctx.md
    echo
    echo "## Read-only context — do NOT modify these"
    "$PIPELINE_HOME/pipeline/ctx.sh" "${CONTEXT_FILES[@]}"
  } > $WORK/step.md
  [[ -f $WORK/feedback.md ]] && cat $WORK/feedback.md >> $WORK/step.md

  ds_rc=0
  "$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/coder.txt" $WORK/step.md "$MODEL" > $WORK/coder.out || ds_rc=$?
  if ((ds_rc == 4)); then
    # Truncation is a budget problem, not a comprehension problem. Retrying the
    # same whole-file request usually truncates again, so name the real cause.
    TRUNCATED=1
    { echo "RESPONSE TRUNCATED — it hit the output limit, so nothing was applied."
      echo "Emit only the files this step must change. If a single file is too large to"
      echo "reproduce in full, output NOOP so the step can be escalated for splitting."
    } > $WORK/feedback.md
    continue
  elif ((ds_rc)); then
    echo "ds.sh failed for $STEP (exit $ds_rc)" >&2
    exit 1
  fi

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
  # out-of-scope file never reaches disk. 1 => scope violation, 3 => malformed.
  rc=0
  "$PIPELINE_HOME/pipeline/apply_files.sh" $WORK/coder.out "${ALLOWED[@]}" > $WORK/viol.out 2>&1 || rc=$?
  case $rc in
    0) ;;
    1) { echo "SCOPE VIOLATION — reverted. Redo within bounds."
         echo "Files outside allowlist (not written): $(tr '\n' ' ' < $WORK/viol.out)"
         echo "Allowed only: ${ALLOWED[*]}"
       } > $WORK/feedback.md
       continue ;;
    3) { echo "MALFORMED OUTPUT — nothing was applied."
         echo "$(tr '\n' ' ' < $WORK/viol.out)"
         echo "Every block must close with a line that is exactly: >>>>>>> ENDFILE"
         echo "Re-emit the complete file blocks."
       } > $WORK/feedback.md
       continue ;;
    *) echo "apply_files.sh failed for $STEP (exit $rc)" >&2
       cat $WORK/viol.out >&2
       exit 1 ;;
  esac

  # Allowlist is enforced at write time above; these catch a dependency or test
  # file that IS in the allowlist but must still not be edited here.
  TOUCHED=$( { git diff "$BASE" --name-only; git ls-files --others --exclude-standard; } | sort -u )
  mapfile -t DEPENDENCY_FILES < <(jq -r '.dependency_files[]?' .pipeline/toolchain.json | tr -d '\r')
  # Guard the empty case: `git diff BASE --` with no pathspec diffs the whole
  # tree, so every added line would read as a dependency violation.
  DEPS=""
  if ((${#DEPENDENCY_FILES[@]})); then
    DEPS=$(git diff "$BASE" -- "${DEPENDENCY_FILES[@]}" 2>/dev/null | grep '^+[^+]' || true)
  fi
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
  # Blaming the tests when nothing was written sends the model chasing a
  # failure it did not cause, so the two cases get different feedback.
  if [[ -z "$TOUCHED" ]]; then
    { echo "NO FILE CHANGED — your output parsed but wrote nothing, and the tests still fail."
      echo "Emit a block per file you must change, with its complete contents."
      echo "Allowed only: ${ALLOWED[*]}"
      tail -40 $WORK/test.out
    } > $WORK/feedback.md
  else
    { echo "TESTS FAILED — your changes were reverted."
      echo "The files you will see next are the ORIGINAL ones, not your attempt."
      echo "Re-output complete file blocks from scratch. Do not assume prior edits exist."
      tail -40 $WORK/test.out
    } > $WORK/feedback.md
  fi
done

git checkout "$BASE" -- .
git clean -fdq 2>/dev/null || true
{ echo "step: $STEP"
  echo "exhausted 3 iterations"
  ((TRUNCATED)) && echo "cause: at least one response was truncated — the step's files are probably too large for the whole-file contract. Split the step or narrow files_allowed."
  echo "--- last feedback ---"
  cat $WORK/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
echo "ESCALATE: $STEP exhausted 3 iterations" >&2
exit 1
