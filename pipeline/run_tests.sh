#!/usr/bin/env bash
set -euo pipefail

CONFIG=.pipeline/toolchain.json
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG; run pipeline/detect.sh" >&2; exit 1; }
jq -e '.supported == true' "$CONFIG" >/dev/null || { jq -r '.reason' "$CONFIG" >&2; exit 1; }

# A coder can introduce an infinite loop, and an unbounded test run hangs the
# whole pipeline — in a parallel wave, silently and with no output. Exit 124 is
# timeout's, kept distinct from an ordinary test failure.
TIMEOUT=$(jq -r '.test_timeout_seconds // 600' "$CONFIG" | tr -d '\r')
TIMEOUT="${PIPELINE_TEST_TIMEOUT:-$TIMEOUT}"

run_cmd() {
  local rc=0
  timeout --kill-after=30 "$TIMEOUT" "$@" || rc=$?
  if ((rc == 124 || rc == 137)); then
    echo "TIMEOUT: '$*' exceeded ${TIMEOUT}s and was killed" >&2
    return 124
  fi
  return $rc
}

run_json_command() {
  local json="$1"
  mapfile -t command < <(jq -r '.[]' <<< "$json" | tr -d '\r')
  ((${#command[@]})) || return 0
  run_cmd "${command[@]}"
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

# RUN_TESTS_COLLECT=1 resolves the selector without executing anything, so a
# caller can tell "these tests fail" apart from "these names match no test".
# Adapters with no collect_command skip the check rather than fake an answer.
if [[ -n "${RUN_TESTS_LOAD:-}" ]]; then
  test_json=$(jq -c '.load_command // []' "$CONFIG")
  (( $(jq -r 'length' <<< "$test_json") )) || exit 0
  run_json_command "$test_json"
  exit
elif [[ -n "${RUN_TESTS_COLLECT:-}" ]]; then
  test_json=$(jq -c '.collect_command // []' "$CONFIG")
  (( $(jq -r 'length' <<< "$test_json") )) || exit 0
else
  test_json=$(jq -c '.test_command' "$CONFIG")
fi
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
    run_cmd "${command[@]}" -k "$expression"
    ;;
  regex)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    language=$(jq -r '.language' "$CONFIG")
    if [[ "$language" == go ]]; then
      run_cmd "${command[@]}" -run "$regex"
    else
      run_cmd "${command[@]}" -t "$regex"
    fi
    ;;
  node)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    run_cmd "${command[@]}" --test-name-pattern "$regex"
    ;;
  repeat)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do run_cmd "${command[@]}" "$test_name"; done
    ;;
  maven)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do run_cmd "${command[@]}" "-Dtest=*#$test_name"; done
    ;;
  gradle)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    for test_name in "${tests[@]}"; do run_cmd "${command[@]}" --tests "*.$test_name"; done
    ;;
  dotnet)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    # `Name=` compares against the display name, which xunit and NUnit report
    # fully qualified, so an exact match on a bare method name selects nothing —
    # and `dotnet test` exits 0 when nothing matches. `FullyQualifiedName~` is a
    # substring match and resolves the method name as written in plan_final.json.
    filters=()
    for test_name in "${tests[@]}"; do filters+=("FullyQualifiedName~$test_name"); done
    filter=$(join_by '|' "${filters[@]}")
    run_cmd "${command[@]}" --filter "$filter"
    ;;
  ctest)
    mapfile -t command < <(jq -r '.[]' <<< "$test_json" | tr -d '\r')
    run_cmd "${command[@]}" -R "$regex"
    ;;
  *)
    echo "unknown selector mode: $mode" >&2
    exit 1
    ;;
esac
