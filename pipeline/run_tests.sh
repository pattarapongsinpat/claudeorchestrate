#!/usr/bin/env bash
set -euo pipefail

CONFIG=.pipeline/toolchain.json
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG; run pipeline/detect.sh" >&2; exit 1; }
jq -e '.supported == true' "$CONFIG" >/dev/null || { jq -r '.reason' "$CONFIG" >&2; exit 1; }

run_json_command() {
  local json="$1"
  mapfile -t command < <(jq -r '.[]' <<< "$json" | tr -d '\r')
  ((${#command[@]})) || return 0
  "${command[@]}"
}

join_by() {
  local separator="$1" result="" item
  shift
  for item in "$@"; do
    [[ -n "$result" ]] && result+="$separator"
    result+="$item"
  done
  printf '%s' "$result"
}

while IFS= read -r setup; do
  [[ -n "$setup" ]] && run_json_command "$setup"
done < <(jq -c '.setup_commands[]?' "$CONFIG")

test_json=$(jq -c '.test_command' "$CONFIG")
mode=$(jq -r '.selector_mode' "$CONFIG" | tr -d '\r')
tests=("$@")

if ((${#tests[@]} == 0)) || [[ "$mode" == none ]]; then
  run_json_command "$test_json"
  exit
fi

regex=$(join_by '|' "${tests[@]}")
case "$mode" in
  pytest)
    expression=$(join_by ' or ' "${tests[@]}")
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    "${command[@]}" -k "$expression"
    ;;
  regex)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    language=$(jq -r '.language' "$CONFIG")
    if [[ "$language" == go ]]; then
      "${command[@]}" -run "$regex"
    else
      "${command[@]}" -t "$regex"
    fi
    ;;
  node)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    "${command[@]}" --test-name-pattern "$regex"
    ;;
  repeat)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do "${command[@]}" "$test_name"; done
    ;;
  maven)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do "${command[@]}" "-Dtest=*#$test_name"; done
    ;;
  gradle)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do "${command[@]}" --tests "*.$test_name"; done
    ;;
  dotnet)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    filters=()
    for test_name in "${tests[@]}"; do filters+=("Name=$test_name"); done
    filter=$(join_by '|' "${filters[@]}")
    "${command[@]}" --filter "$filter"
    ;;
  ctest)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    "${command[@]}" -R "$regex"
    ;;
  *)
    echo "unknown selector mode: $mode" >&2
    exit 1
    ;;
esac
