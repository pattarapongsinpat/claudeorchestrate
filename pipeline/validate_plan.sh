#!/usr/bin/env bash
set -euo pipefail

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

mapfile -t IDS < <(jq -r '.steps[].id' "$PLAN" | tr -d '\r')
declare -A SEEN=()
for id in "${IDS[@]}"; do
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] || {
    echo "unsafe step id: $id" >&2; exit 1;
  }
  [[ -z "${SEEN[$id]:-}" ]] || { echo "duplicate step id: $id" >&2; exit 1; }
  SEEN["$id"]=1
done

safe_path() {
  local path="$1"
  [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  case "$path" in
    /*|?:[/\\]*|.|..|../*|*/../*|*/..) return 1 ;;
  esac
  return 0
}

while IFS= read -r path; do
  safe_path "$path" || { echo "unsafe plan path: $path" >&2; exit 1; }
done < <(jq -r '.steps[] | (.files_allowed[]), (.context_files[])' "$PLAN" | tr -d '\r')

INTENT="$(dirname "$PLAN")/intent.json"
if [[ -f "$INTENT" ]]; then
  jq -e '.allowed_files as $allowed | ($allowed | type == "array") and all($allowed[]; type == "string") and (($allowed | length) == ($allowed | unique | length))' "$INTENT" >/dev/null || {
    echo "invalid intent allowlist" >&2; exit 1;
  }
  while IFS= read -r path; do
    safe_path "$path" || { echo "unsafe intent path: $path" >&2; exit 1; }
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

echo "plan valid"
