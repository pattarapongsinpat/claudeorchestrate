#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"

PLAN="${1:-.pipeline/plan_final.json}"
[[ -f "$PLAN" ]] || { echo "missing plan: $PLAN" >&2; exit 1; }

jq -e '
  (.steps | type == "array" and length > 0) and
  all(.steps[];
    (.id | type == "string") and
    (.description | type == "string" and length > 0) and
    (.done_when | type == "string" and length > 0) and
    (.files_allowed | type == "array" and length > 0) and
    (.context_files | type == "array") and
    ((.deps // []) | type == "array") and
    ((.tests // []) | type == "array") and
    all(.files_allowed[]; type == "string") and
    all(.context_files[]; type == "string") and
    all((.deps // [])[]; type == "string") and
    all((.tests // [])[]; type == "string"))
' "$PLAN" >/dev/null || { echo "invalid plan schema" >&2; exit 1; }

jq -e '
  all(.steps[];
    . as $step |
    (($step.files_allowed | length) == ($step.files_allowed | unique | length)) and
    (($step.context_files | length) == ($step.context_files | unique | length)) and
    ((($step.deps // []) | length) == (($step.deps // []) | unique | length)) and
    ((($step.tests // []) | length) == (($step.tests // []) | unique | length)) and
    (([$step.files_allowed[]] - [$step.context_files[]] | length) == ($step.files_allowed | length)))
' "$PLAN" >/dev/null || { echo "duplicate or overlapping plan entries" >&2; exit 1; }

# An empty tests array does not mean "unverified", it means "run the entire suite", so
# the step is graded against tests for code it is forbidden to write and can never pass.
# This is only legal in existing-suite and judgment modes, where running everything is
# the intended behavior. In generated-tests mode it is always an authoring mistake.
CONFIG="$(dirname "$PLAN")/toolchain.json"
if [[ -f "$CONFIG" ]] \
  && [[ "$(jq -r '.generated_tests // false' "$CONFIG" | tr -d '\r')" == true ]] \
  && [[ "$(jq -r '.verification_mode // "tests"' "$CONFIG" | tr -d '\r')" == tests ]]; then
  mapfile -t UNMAPPED < <(jq -r '.steps[] | select(((.tests // []) | length) == 0) | .id' "$PLAN" | tr -d '\r')
  if ((${#UNMAPPED[@]})); then
    {
      echo "steps with no mapped tests in generated-tests mode: ${UNMAPPED[*]}"
      echo "An empty tests array runs the WHOLE suite for that step, so it is graded on"
      echo "tests for files it may not write and will always escalate. Map each step to the"
      echo "exact test names that verify its done_when. A step with genuinely nothing to"
      echo "assert should be merged into the step that consumes it."
    } >&2
    exit 1
  fi
fi

mapfile -t IDS < <(jq -r '.steps[].id' "$PLAN" | tr -d '\r')
declare -A SEEN=()
for id in "${IDS[@]}"; do
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || {
    echo "unsafe step id: $id" >&2; exit 1;
  }
  [[ -z "${SEEN[$id]:-}" ]] || { echo "duplicate step id: $id" >&2; exit 1; }
  SEEN["$id"]=1
done

while IFS= read -r path; do
  safe_repo_path "$path" || { echo "unsafe plan path: $path" >&2; exit 1; }
done < <(jq -r '.steps[] | (.files_allowed[]), (.context_files[])' "$PLAN" | tr -d '\r')

INTENT="$(dirname "$PLAN")/intent.json"
if [[ -f "$INTENT" ]]; then
  jq -e '.allowed_files as $allowed | ($allowed | type == "array") and all($allowed[]; type == "string") and (($allowed | length) == ($allowed | unique | length))' "$INTENT" >/dev/null || {
    echo "invalid intent allowlist" >&2; exit 1;
  }
  while IFS= read -r path; do
    safe_repo_path "$path" || { echo "unsafe intent path: $path" >&2; exit 1; }
  done < <(jq -r '.allowed_files[]' "$INTENT" | tr -d '\r')
  while IFS= read -r path; do
    jq -e --arg path "$path" '.allowed_files | index($path) != null' "$INTENT" >/dev/null || {
      echo "plan path outside intent allowlist: $path" >&2; exit 1;
    }
  done < <(jq -r '.steps[].files_allowed[]' "$PLAN" | tr -d '\r')
fi

for id in "${IDS[@]}"; do
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" != "$id" ]] || { echo "step depends on itself: $id" >&2; exit 1; }
    [[ -n "${SEEN[$dep]:-}" ]] || { echo "unknown dependency for $id: $dep" >&2; exit 1; }
  done < <(jq -r --arg id "$id" '.steps[] | select(.id == $id) | (.deps // [])[]' "$PLAN" | tr -d '\r')
done

declare -A RESOLVED=()
resolved_count=0
while ((resolved_count < ${#IDS[@]})); do
  progress=0
  for id in "${IDS[@]}"; do
    [[ -n "${RESOLVED[$id]:-}" ]] && continue
    ready=1
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      [[ -n "${RESOLVED[$dep]:-}" ]] || ready=0
    done < <(jq -r --arg id "$id" '.steps[] | select(.id == $id) | (.deps // [])[]' "$PLAN" | tr -d '\r')
    if ((ready)); then
      RESOLVED["$id"]=1
      resolved_count=$((resolved_count + 1))
      progress=1
    fi
  done
  ((progress)) || { echo "dependency cycle in plan" >&2; exit 1; }
done

echo "plan valid"
