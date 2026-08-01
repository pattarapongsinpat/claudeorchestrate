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

write_status() {
  local attempts="$1" escalated="$2"
  jq -n --arg step "$STEP" --argjson attempts "$attempts" --argjson escalated "$escalated" \
    '{step:$step,attempts:$attempts,escalated:$escalated}' > .pipeline/step_status.json
}

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
  write_status 0 true
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
  write_status 0 true
  exit 1
fi

# Built once, outside the retry loop: the index describes the repository, which no
# attempt changes. A failure here is not worth stopping the step over — the coder
# simply loses the duplication hint.
"$PIPELINE_HOME/pipeline/symbol_index.sh" > $WORK/symbols.md 2>/dev/null || : > $WORK/symbols.md

# Which model writes the step. There is no flash-then-pro ladder: a step that
# fails its tests escalates to the Opus repair, which can read the mapped test the
# coder never sees and so solves failures no further DeepSeek sample would. The
# ladder's retries were reverted wholesale on escalation, so they bought a
# diagnosis the first failure already carried.
case "${PIPELINE_CODER_MODEL:-flash}" in
  flash|deepseek-v4-flash) MODEL=deepseek-v4-flash ;;
  pro|deepseek-v4-pro)     MODEL=deepseek-v4-pro ;;
  *) echo "PIPELINE_CODER_MODEL must be flash or pro (got: $PIPELINE_CODER_MODEL)" >&2; exit 1 ;;
esac

# One graded attempt, plus bounded re-asks for output that never reached a test.
# Truncated, malformed, empty, and out-of-scope responses are formatting failures,
# not coding failures: no assertion has run, so there is nothing for a repair to
# read and re-asking the same model is the cheap fix.
MAX_FORMAT_RETRIES="${PIPELINE_MAX_FORMAT_RETRIES:-2}"
[[ "$MAX_FORMAT_RETRIES" =~ ^[0-9]$ ]] || {
  echo "PIPELINE_MAX_FORMAT_RETRIES must be 0-9 (got: $MAX_FORMAT_RETRIES)" >&2; exit 1;
}

TRUNCATED=0
for ((i = 1; i <= MAX_FORMAT_RETRIES + 1; i++)); do
  git checkout "$BASE" -- .
  git clean -fdq 2>/dev/null || true   # entry guard guarantees a clean tree, so every untracked file here is this run's

  echo "=== attempt $i model=$MODEL ==="

  {
    echo "## Step"
    jq -r --arg id "$STEP" '.steps[]|select(.id==$id)' "$PLAN"
    echo
    echo "## Files you may modify — current contents"
    cat $WORK/allowed_ctx.md
    echo
    echo "## Read-only context — do NOT modify these"
    "$PIPELINE_HOME/pipeline/ctx.sh" "${CONTEXT_FILES[@]}"
    echo
    echo "## Repository symbol index — names and signatures only"
    echo
    echo "These already exist elsewhere in the repository. Call them rather than"
    echo "writing a second implementation. You may not edit these files in this step;"
    echo "if the helper you need lives in one of them, use it via its module."
    cat $WORK/symbols.md
  } > $WORK/step.md
  [[ -f $WORK/feedback.md ]] && cat $WORK/feedback.md >> $WORK/step.md

  ds_rc=0
  DS_RUNNER="${PIPELINE_DS_COMMAND:-$PIPELINE_HOME/pipeline/ds.sh}"
  "$DS_RUNNER" "$PIPELINE_HOME/prompts/coder.txt" $WORK/step.md "$MODEL" > $WORK/coder.out || ds_rc=$?
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
    write_status "$i" true
    exit 1
  fi

  grep -qx 'NOOP' $WORK/coder.out && { write_status "$i" false; echo "NOOP $STEP"; exit 0; }
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
       write_status "$i" true
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
    DEPS=$( {
      git diff "$BASE" --name-only -- "${DEPENDENCY_FILES[@]}"
      git ls-files --others --exclude-standard -- "${DEPENDENCY_FILES[@]}"
    } 2>/dev/null | sort -u )
  fi
  GENERATED_TEST_FILE=$(jq -r '.generated_test_file // ""' .pipeline/toolchain.json | tr -d '\r')
  TESTS=$( {
    printf '%s\n' "$TOUCHED" | grep -Ei '(^|/)(test|tests)/|(^|/)test_[^/]+|_test\.|\.test\.|\.spec\.' || true
    printf '%s\n' "$TOUCHED" | grep -E '(^|/)[^/]*(Test|Tests)\.cs$' || true
    [[ -z "$GENERATED_TEST_FILE" ]] || printf '%s\n' "$TOUCHED" | grep -Fx -- "$GENERATED_TEST_FILE" || true
  } | sort -u )

  if [[ -n "$DEPS$TESTS" ]]; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      [[ -n "$DEPS"  ]] && echo "Dependency files modified: $DEPS"
      [[ -n "$TESTS" ]] && echo "Test files modified: $TESTS"
      echo "Allowed only: ${ALLOWED[*]}"
    } > $WORK/feedback.md
    continue
  fi

  if run_tests > $WORK/test.out 2>&1; then
    write_status "$i" false
    echo "PASS $STEP (iteration $i)"
    exit 0
  fi
  echo "--- test output ---"
  cat $WORK/test.out
  echo "--- end test output ---"

  # The graded attempt ran and failed. Re-asking the same model with the same
  # information is what the ladder used to do, and its output was reverted anyway.
  # The repair reads the mapped test the coder cannot see, so it goes there now.
  # Nothing unverified is left behind: the tree returns to BASE either way.
  # -N so a file the step created shows as a diff rather than as nothing: a step
  # that adds a module is exactly the case where the attempt is worth keeping.
  git add -N -- "${ALLOWED[@]}" 2>/dev/null || true
  ATTEMPT_DIFF=$(git diff "$BASE" -- "${ALLOWED[@]}" 2>/dev/null)
  git checkout "$BASE" -- .
  git clean -fdq 2>/dev/null || true
  { echo "step: $STEP"
    if [[ -z "$TOUCHED" ]]; then
      echo "the coder's output parsed but wrote nothing, and the tests fail"
    else
      echo "the coder's attempt on $MODEL failed its mapped tests"
    fi
    echo "mapped tests: ${TEST_NAMES[*]}"
    echo "Read the mapped test before rewriting: it may assert something no"
    echo "implementation within this step's files can satisfy."
    echo "--- test output ---"
    tail -40 $WORK/test.out
    if [[ -n "$ATTEMPT_DIFF" ]]; then
      # Reverted from the tree but kept here: the attempt is usually close, and a
      # repair that starts from it is cheaper and less likely to drop a detail the
      # coder got right. It is the only artifact the failed call produced.
      echo "--- the coder's reverted attempt ---"
      printf '%s\n' "$ATTEMPT_DIFF"
    fi
  } > .pipeline/ESCALATE
  write_status "$i" true
  echo "ESCALATE: $STEP failed its mapped tests on $MODEL" >&2
  exit 1
done

git checkout "$BASE" -- .
git clean -fdq 2>/dev/null || true
{ echo "step: $STEP"
  echo "the coder never produced usable output in $((MAX_FORMAT_RETRIES + 1)) attempts"
  ((TRUNCATED)) && echo "cause: at least one response was truncated — the step's files are probably too large for the whole-file contract. Split the step or narrow files_allowed."
  echo "--- last feedback ---"
  cat $WORK/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
write_status "$((MAX_FORMAT_RETRIES + 1))" true
echo "ESCALATE: $STEP produced no usable output" >&2
exit 1
