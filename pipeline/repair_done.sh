#!/usr/bin/env bash
# Accept a main-session Opus repair of an escalated step.
#
# The repair is written by a session that has the whole run in context, which is
# why it is worth doing at all — but that session is also the one that chose to
# repair, so it does not get to grade itself. Every bound the coder had is
# re-checked here against the working tree: allowlist, dependency manifests, test
# files, and the step's own mapped tests. Only then does the step count as done,
# and only then will waves.sh skip it on resume.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="${1:?usage: repair_done.sh <step-id>}"
PLAN=.pipeline/plan_final.json
STATE=.pipeline/done.json

bash "$PIPELINE_HOME/pipeline/validate_plan.sh" "$PLAN" >/dev/null
jq -e --arg id "$STEP" '[.steps[].id] | index($id) != null' "$PLAN" >/dev/null || {
  echo "unknown step: $STEP" >&2; exit 1;
}
jq -e --arg id "$STEP" '.steps[$id].status == "escalated"' "$STATE" >/dev/null 2>&1 || {
  echo "REFUSED: $STEP is not an escalated step in $STATE" >&2; exit 1;
}

# The repair budget, enforced here rather than left to the session that is
# spending it. Without this the stage quietly becomes "Opus writes everything":
# the verify subagent sees only the request and the final diff, so a run repaired
# end to end looks exactly like one DeepSeek produced, and the cost this stage was
# meant to bound goes unmeasured. Two failures are a bad step; three are a bad
# plan or a bad generated test, and repairing them one at a time hides that.
MAX_REPAIRS="${PIPELINE_MAX_REPAIRS:-2}"
[[ "$MAX_REPAIRS" =~ ^[0-9]+$ ]] || {
  echo "PIPELINE_MAX_REPAIRS must be a non-negative integer (got: $MAX_REPAIRS)" >&2; exit 1;
}
REPAIRED=$(jq '[.steps[] | select(.repaired_by_opus == true)] | length' "$STATE" 2>/dev/null || echo 0)
((REPAIRED < MAX_REPAIRS)) || {
  echo "REFUSED: $REPAIRED steps already repaired this run (limit $MAX_REPAIRS)." >&2
  echo "Stop and report. That many coder failures points at the plan or the" >&2
  echo "generated tests, not at the steps — repairing them one by one hides it." >&2
  exit 1
}

BASE=$(git rev-parse HEAD)
mapfile -t ALLOWED < <(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.files_allowed[]' "$PLAN" | tr -d '\r')
mapfile -t TEST_NAMES < <(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.tests[]?' "$PLAN" | tr -d '\r')

# .claude/routing-ack is harness state the routing gate requires before Opus may
# write anything, so it exists by the time any repair does. It is excluded by
# exact path, never by prefix: the rest of .claude/ is project configuration and a
# repair has no business there.
TOUCHED=$( { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } \
  | { grep -Fxv '.claude/routing-ack' || true; } | sort -u )
[[ -n "$TOUCHED" ]] || { echo "REFUSED: nothing changed for $STEP" >&2; exit 1; }

# The same bounds code.sh enforces, but manifests and tests are checked before the
# allowlist. Those files are almost never in an allowlist, so the generic "outside
# the allowlist" message would be the one reported every time, and it does not say
# the part that matters: the repair edited its own grader.
mapfile -t DEPENDENCY_FILES < <(jq -r '.dependency_files[]?' .pipeline/toolchain.json | tr -d '\r')
if ((${#DEPENDENCY_FILES[@]})); then
  DEPS=$(printf '%s\n' "$TOUCHED" | grep -Fx -f <(printf '%s\n' "${DEPENDENCY_FILES[@]}") || true)
  [[ -z "$DEPS" ]] || { echo "REFUSED: dependency manifest modified: $DEPS" >&2; exit 1; }
fi

GENERATED_TEST_FILE=$(jq -r '.generated_test_file // ""' .pipeline/toolchain.json | tr -d '\r')
TESTS=$( {
  printf '%s\n' "$TOUCHED" | grep -Ei '(^|/)(test|tests)/|(^|/)test_[^/]+|_test\.|\.test\.|\.spec\.' || true
  printf '%s\n' "$TOUCHED" | grep -E '(^|/)[^/]*(Test|Tests)\.cs$' || true
  [[ -z "$GENERATED_TEST_FILE" ]] || printf '%s\n' "$TOUCHED" | grep -Fx -- "$GENERATED_TEST_FILE" || true
} | sort -u )
[[ -z "$TESTS" ]] || {
  echo "REFUSED: test files modified: $TESTS" >&2
  echo "A repair that edits its own grader is the failure mode this stage exists to avoid." >&2
  exit 1
}

OUTSIDE=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  ok=0
  for a in "${ALLOWED[@]}"; do [[ "$f" == "$a" ]] && ok=1 && break; done
  ((ok)) || OUTSIDE+="$f "
done <<< "$TOUCHED"
[[ -z "$OUTSIDE" ]] || {
  echo "REFUSED: files outside the step allowlist: $OUTSIDE" >&2
  echo "Allowed only: ${ALLOWED[*]}" >&2
  exit 1
}

"$PIPELINE_HOME/pipeline/run_tests.sh" "${TEST_NAMES[@]}" || {
  echo "REFUSED: mapped tests still fail for $STEP — the step stays escalated" >&2
  exit 1
}

git add -A -- "${ALLOWED[@]}"
git commit -qm "repair($STEP): $(jq -r --arg id "$STEP" '.steps[]|select(.id==$id)|.description' "$PLAN")"
COMMIT=$(git rev-parse HEAD)

# ever_escalated stays true, so review_trigger.sh still demands an Opus review of
# the run — a repaired step is exactly the kind that needs one.
FINGERPRINT=$(jq -cS --arg id "$STEP" '.steps[] | select(.id == $id)' "$PLAN" | sha256sum | cut -d' ' -f1)
TMP=$(mktemp)
jq --arg id "$STEP" --arg commit "$COMMIT" --arg fingerprint "$FINGERPRINT" '
  (.steps[$id] // {}) as $old |
  .steps[$id] = {
    status: "done",
    attempts: (($old.attempts // 0) + 1),
    ever_escalated: true,
    repaired_by_opus: true,
    commit: $commit,
    fingerprint: $fingerprint
  }
' "$STATE" > "$TMP" && mv "$TMP" "$STATE"

# The marker is per-run and append-only, so it is only cleared once no escalated
# step is left. Otherwise a second failing step in the same wave loses its record.
if ! jq -e '[.steps[] | select(.status == "escalated")] | length > 0' "$STATE" >/dev/null; then
  rm -f .pipeline/ESCALATE
fi

echo "REPAIRED $STEP at $COMMIT"
