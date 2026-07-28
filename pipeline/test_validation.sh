#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_case() {
  local language="$1" source="$2"
  local repo="$WORK/$language"
  mkdir -p "$repo/.pipeline" "$repo/tests"
  printf '%s\n' "$source" > "$repo/tests/generated.txt"
  jq -n --arg language "$language" \
    '{supported:true,generated_tests:true,generated_test_file:"tests/generated.txt",language:$language}' \
    > "$repo/.pipeline/toolchain.json"
  cat > "$repo/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"change","files_allowed":["src/code.txt"],"context_files":[],"deps":[],"tests":["alpha"],"done_when":"works"}]}
EOF
  (
    cd "$repo"
    bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" >/dev/null
    jq '.steps[0].tests = ["missing"]' .pipeline/plan_final.json > bad.json
    ! bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" bad.json >/dev/null 2>&1
    jq '.steps[0].tests = ["alpha|beta"]' .pipeline/plan_final.json > bad.json
    ! bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" bad.json >/dev/null 2>&1
  )
}

run_case python 'def alpha():'
run_case javascript "test('alpha', () => {});"
run_case typescript 'it("alpha", () => {});'
run_case go 'func alpha(t *testing.T) {'
run_case rust 'fn alpha() {'
run_case java '@Test void alpha() {'
run_case csharp '[Fact] public void alpha() {'

(
  cd "$WORK/javascript"
  jq '.steps[0].tests = ["missing"]' .pipeline/plan_final.json > bad.json
  mv bad.json .pipeline/plan_final.json
  ! bash "$PIPELINE_HOME/pipeline/waves.sh" >/dev/null 2>&1
  grep -Fq 'mapped test does not exist' .pipeline/ESCALATE
)

mkdir -p "$WORK/existing/.pipeline"
jq -n '{supported:true,generated_tests:false,generated_test_file:"",language:"c"}' > "$WORK/existing/.pipeline/toolchain.json"
cat > "$WORK/existing/.pipeline/plan_final.json" <<'EOF'
{"steps":[{"id":"s1","description":"change","files_allowed":["src/code.c"],"context_files":[],"deps":[],"tests":["alpha"],"done_when":"works"}]}
EOF
(
  cd "$WORK/existing"
  ! bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" >/dev/null 2>&1
  jq '.steps[0].tests = []' .pipeline/plan_final.json > empty.json
  bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" empty.json >/dev/null
)

echo "plan and mapped-test validation tests passed"
