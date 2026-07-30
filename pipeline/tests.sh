#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"
[[ -f .pipeline/HALT ]] && { echo "halted before tests"; exit 1; }
CONFIG=.pipeline/toolchain.json
[[ -f "$CONFIG" ]] || "$PIPELINE_HOME/pipeline/detect.sh"

jq -e '
  ((.verification // {mode:"tests"}) | type == "object") and
  ((.verification.mode // "tests") | IN("tests", "judgment")) and
  (if (.verification.mode // "tests") == "judgment"
   then (.verification.reason | type == "string" and length > 0)
   else true end)
' .pipeline/intent.json >/dev/null || {
  echo "invalid intent verification mode or missing judgment reason" >&2
  exit 1
}

requested_mode=$(jq -r '.verification.mode // "tests"' .pipeline/intent.json | tr -d '\r')
detected_mode=$(jq -r '.verification_mode // "tests"' "$CONFIG" | tr -d '\r')
if [[ "$requested_mode" == judgment || "$detected_mode" == judgment ]]; then
  reason=$(jq -r '.verification.reason // "the detected adapter has no executable behavioral test suite"' .pipeline/intent.json | tr -d '\r')
  tmp=$(mktemp)
  jq '.verification_mode = "judgment"
      | .generated_tests = false
      | .generated_test_file = ""
      | .selector_mode = "none"
      | .test_command = (.judgment_command // [])
      | .load_command = (.judgment_command // [])
      | .collect_command = []' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  {
    echo "# Opus judgment fallback"
    echo
    echo "Behavioral tests are unavailable: $reason"
    echo
    echo "The pipeline will run the configured mechanical command when available."
    echo "Opus review and isolated final verification are mandatory."
    echo
    echo "## Toolchain"
    jq . "$CONFIG"
  } > .pipeline/tests_spec.md
  echo "judgment fallback: $reason"
  exit 0
fi

bash "$PIPELINE_HOME/pipeline/validate_test_reachability.sh"

if [[ "$(jq -r '.generated_tests' "$CONFIG")" != true ]]; then
  {
    echo "# Existing-suite mode"
    echo
    echo "This adapter uses the project's existing native tests."
    echo
    echo "## Toolchain"
    jq . "$CONFIG"
    echo
    echo "## Existing test files"
    rg --files | grep -Ei '(^|/)(test|tests)/|(_test\.|\.test\.|\.spec\.|Tests?\.)' | head -200 || true
  } > .pipeline/tests_spec.md
  echo "existing-suite mode: $(jq -r '.language + " / " + .framework' "$CONFIG")"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
language=$(jq -r '.language' "$CONFIG" | tr -d '\r')
test_file=$(jq -r '.generated_test_file' "$CONFIG" | tr -d '\r')

case "$language" in
  python) declaration='^(async[[:space:]]+def|def|class)[[:space:]]' ;;
  javascript|typescript) declaration='(^|[[:space:]])(export[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type|const)[[:space:]]' ;;
  go) declaration='^(func|type|const|var)[[:space:]]' ;;
  rust) declaration='^(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(fn|struct|enum|trait|type|const)[[:space:]]' ;;
  java|csharp) declaration='^[[:space:]]*(public|protected)[[:space:]].*(class|interface|enum|record|\()' ;;
  *) declaration='^[[:space:]]*([A-Za-z_][A-Za-z0-9_:<>*&[:space:]]+)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' ;;
esac

{
  cat .pipeline/intent.md
  echo
  echo "## Native toolchain"
  jq . "$CONFIG"
  echo
  echo "## Repository files"
  rg --files | head -200
  echo
  echo "## Intent-scoped source contents"
  mapfile -t intent_files < <(jq -r '.allowed_files[]' .pipeline/intent.json | tr -d '\r')
  "$PIPELINE_HOME/pipeline/ctx.sh" "${intent_files[@]}"
  echo
  echo "## Build and dependency configuration"
  mapfile -t dependency_patterns < <(jq -r '.dependency_files[]?' "$CONFIG" | tr -d '\r')
  if ((${#dependency_patterns[@]})); then
    mapfile -t dependency_files < <(git ls-files -- "${dependency_patterns[@]}")
    "$PIPELINE_HOME/pipeline/ctx.sh" "${dependency_files[@]}"
  fi
  echo
  echo "## Existing public interfaces"
  while IFS= read -r file; do
    rg --with-filename --no-heading -n "$declaration" "$file" || true
  done < <(rg --files | grep -E "$(jq -r '.source_regex' "$CONFIG")" | head -150)
} > "$WORK/test-input.md"

safe_repo_path "$test_file" || { echo "unsafe generated-test path: $test_file" >&2; exit 1; }
has_symlink_component "$test_file" && { echo "refusing symlinked generated-test path: $test_file" >&2; exit 1; }
mkdir -p "$(dirname "$test_file")"
[[ ! -e "$test_file" && ! -L "$test_file" ]] || {
  echo "refusing to overwrite existing generated-test path: $test_file" >&2
  exit 1
}
"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/tester.txt" "$WORK/test-input.md" deepseek-v4-pro \
  | tee .pipeline/tests_spec.md > "$test_file"

[[ -s "$test_file" ]] || { echo "generated test file is empty: $test_file" >&2; exit 1; }
echo "generated native tests: $test_file"
