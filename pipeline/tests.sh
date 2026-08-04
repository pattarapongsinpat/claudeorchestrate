#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"
[[ -f .pipeline/HALT ]] && { echo "halted before tests"; exit 1; }

# Same gate as plan.sh. The tests are written from the intent's reading of the
# request, so an ungraded reading produces tests that assert the wrong thing and
# then everything downstream passes them.
if [[ ! -f .pipeline/assumptions.md ]] ||
   [[ "$(head -1 .pipeline/assumptions.md | tr -d '\r')" != SOUND ]]; then
  echo "no SOUND assumption verdict; run check_assumptions before tests" >&2
  exit 1
fi

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

# Specification context. The tester is given the contents of allowed_files, but those
# are the paths the implementation will CREATE, so they are usually absent. Without the
# behavioral spec the tester guesses the domain and produces tests that assert invented
# field names and unsatisfiable values. Declare spec_files in intent.json; failing that,
# fall back to markdown paths referenced from intent.md that actually exist and are tracked.
spec_file_list() {
  local -a declared=()
  mapfile -t declared < <(
    jq -r '(.spec_files // [])[]' .pipeline/intent.json 2>/dev/null | tr -d '\r'
  )
  if ((${#declared[@]})); then
    printf '%s\n' "${declared[@]}"
    return
  fi
  { grep -oE '[A-Za-z0-9_./-]+\.md' .pipeline/intent.md 2>/dev/null || true; } \
    | sed 's#^\./##' | sort -u | while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      [[ "$candidate" == .pipeline/* ]] && continue
      safe_repo_path "$candidate" 2>/dev/null || continue
      has_symlink_component "$candidate" && continue
      git ls-files --error-unmatch -- "$candidate" >/dev/null 2>&1 || continue
      printf '%s\n' "$candidate"
    done
}

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


{
  cat .pipeline/intent.md
  echo
  echo "## Native toolchain"
  jq . "$CONFIG"
  echo
  echo "## Repository files"
  rg --files | head -200
  echo
  echo "## Specification documents"
  echo
  echo "These define the required behavior. Where they conflict with your own assumptions"
  echo "they win. Do not invent field names, call signatures, or rules that contradict them."
  echo "If this section is empty, say so in a comment rather than guessing at the domain."
  echo
  mapfile -t spec_files < <(spec_file_list)
  if ((${#spec_files[@]})); then
    "$PIPELINE_HOME/pipeline/ctx.sh" "${spec_files[@]}"
  else
    echo "(none found; declare \"spec_files\" in .pipeline/intent.json)"
  fi
  echo
  echo "## Intent-scoped source contents"
  echo
  echo "NOTE: these are the paths the implementation will WRITE. Most are absent or empty"
  echo "right now, which is expected and is not a reason to infer behavior from them."
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
  "$PIPELINE_HOME/pipeline/symbol_index.sh"
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
"$PIPELINE_HOME/pipeline/normalize_test_names.sh" "$test_file" "$language"
echo "generated native tests: $test_file"
