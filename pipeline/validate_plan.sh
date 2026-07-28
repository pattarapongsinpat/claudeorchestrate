#!/usr/bin/env bash
set -euo pipefail

PLAN="${1:-.pipeline/plan_final.json}"
[[ -f "$PLAN" ]] || { echo "missing plan: $PLAN" >&2; exit 1; }

jq -e '
  (.steps | type == "array" and length > 0) and
  all(.steps[];
    (.id | type == "string") and
    (.files_allowed | type == "array") and
    (.context_files | type == "array") and
    ((.deps // []) | type == "array") and
    all(.files_allowed[]; type == "string") and
    all(.context_files[]; type == "string") and
    all((.deps // [])[]; type == "string"))
' "$PLAN" >/dev/null || { echo "invalid plan schema" >&2; exit 1; }

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

for id in "${IDS[@]}"; do
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" != "$id" ]] || { echo "step depends on itself: $id" >&2; exit 1; }
    [[ -n "${SEEN[$dep]:-}" ]] || { echo "unknown dependency for $id: $dep" >&2; exit 1; }
  done < <(jq -r --arg id "$id" '.steps[] | select(.id == $id) | (.deps // [])[]' "$PLAN" | tr -d '\r')
done

echo "plan valid"
