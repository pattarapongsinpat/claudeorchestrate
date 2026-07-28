#!/usr/bin/env bash
set -euo pipefail

PLAN="${1:-.pipeline/plan_final.json}"
STEP="${2:-}"
CONFIG=.pipeline/toolchain.json
[[ -f "$PLAN" ]] || { echo "missing plan: $PLAN" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

if [[ -n "$STEP" ]]; then
  jq -e --arg id "$STEP" '.steps[] | select(.id == $id)' "$PLAN" >/dev/null || {
    echo "unknown step: $STEP" >&2; exit 1;
  }
  mapfile -t TESTS < <(jq -r --arg id "$STEP" '.steps[] | select(.id == $id) | (.tests // [])[]' "$PLAN" | tr -d '\r')
else
  mapfile -t TESTS < <(jq -r '[.steps[] | (.tests // [])[]] | unique[]' "$PLAN" | tr -d '\r')
fi

((${#TESTS[@]})) || exit 0

generated=$(jq -r '.generated_tests // false' "$CONFIG" | tr -d '\r')
test_file=$(jq -r '.generated_test_file // ""' "$CONFIG" | tr -d '\r')
language=$(jq -r '.language // ""' "$CONFIG" | tr -d '\r')

if [[ "$generated" != true ]]; then
  echo "named tests are not mechanically resolvable for an existing suite; map this step to []" >&2
  exit 1
fi
[[ -n "$test_file" && -f "$test_file" ]] || {
  echo "generated test file is missing: $test_file" >&2; exit 1;
}

for name in "${TESTS[@]}"; do
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "unsafe mapped test name: $name" >&2; exit 1;
  }
  case "$language" in
    python)
      pattern="^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+$name[[:space:]]*\\("
      ;;
    javascript|typescript)
      pattern="\\b(test|it)[[:space:]]*\\([[:space:]]*['\"]$name['\"]"
      ;;
    go)
      pattern="^[[:space:]]*func[[:space:]]+$name[[:space:]]*\\("
      ;;
    rust)
      pattern="^[[:space:]]*(pub([[:space:]]*\\([^)]*\\))?[[:space:]]+)?fn[[:space:]]+$name[[:space:]]*\\("
      ;;
    java)
      pattern="^[[:space:]]*(@[A-Za-z0-9_$.]+(\\([^)]*\\))?[[:space:]]+)*((public|protected|private)[[:space:]]+)?(static[[:space:]]+)?void[[:space:]]+$name[[:space:]]*\\("
      ;;
    csharp)
      pattern="^[[:space:]]*(\\[[^]]+\\][[:space:]]*)*((public|protected|private|internal)[[:space:]]+)?(static[[:space:]]+)?(async[[:space:]]+)?(void|Task|ValueTask)[[:space:]]+$name[[:space:]]*\\("
      ;;
    *)
      echo "cannot validate mapped tests for language: $language" >&2
      exit 1
      ;;
  esac
  rg --pcre2 -q "$pattern" "$test_file" || {
    echo "mapped test does not exist in $test_file: $name" >&2; exit 1;
  }
done

echo "mapped tests valid"
