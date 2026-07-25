#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_case() {
  local name="$1" expected_language="$2" expected_framework="$3"
  (
    cd "$WORK/$name"
    "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
    [[ "$(jq -r '.language' .pipeline/toolchain.json)" == "$expected_language" ]]
    [[ "$(jq -r '.framework' .pipeline/toolchain.json)" == "$expected_framework" ]]
    jq -e '.supported == true and (.test_command | type == "array")' .pipeline/toolchain.json >/dev/null
  )
}

mkdir -p "$WORK/python"
printf '[project]\nname="demo"\n' > "$WORK/python/pyproject.toml"
check_case python python pytest

mkdir -p "$WORK/javascript"
printf '{"devDependencies":{"vitest":"latest"}}\n' > "$WORK/javascript/package.json"
check_case javascript javascript vitest

mkdir -p "$WORK/go/pkg"
printf 'module example.test/demo\n\ngo 1.22\n' > "$WORK/go/go.mod"
printf 'package pkg\n' > "$WORK/go/pkg/demo.go"
check_case go go go-test

mkdir -p "$WORK/rust/src"
printf '[package]\nname="demo"\nversion="0.1.0"\n' > "$WORK/rust/Cargo.toml"
check_case rust rust cargo-test

mkdir -p "$WORK/java"
printf '<project></project>\n' > "$WORK/java/pom.xml"
check_case java java maven

mkdir -p "$WORK/csharp/Demo.Tests"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' > "$WORK/csharp/Demo.Tests/Demo.Tests.csproj"
check_case csharp csharp dotnet-test

mkdir -p "$WORK/c"
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WORK/c/CMakeLists.txt"
printf 'int demo(void);\n' > "$WORK/c/demo.c"
check_case c c cmake

mkdir -p "$WORK/cpp"
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WORK/cpp/CMakeLists.txt"
printf 'int demo();\n' > "$WORK/cpp/demo.cpp"
check_case cpp cpp cmake

mkdir -p "$WORK/runrepo"
(
  cd "$WORK/runrepo"
  git init -q
  git config user.name 'Adapter Test'
  git config user.email 'adapter@example.invalid'
  printf '[project]\nname="demo"\n' > pyproject.toml
  git add pyproject.toml
  git commit -qm base
  "$PIPELINE_HOME/pipeline/run.sh" >/dev/null
  [[ "$(jq -r '.language' .pipeline/toolchain.json)" == python ]]
  [[ -z "$(git status --porcelain)" ]]
)

mkdir -p "$WORK/runner/.pipeline" "$WORK/runner/bin"
cat > "$WORK/runner/bin/fake-test" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
EOF
chmod +x "$WORK/runner/bin/fake-test"
export TEST_LOG="$WORK/runner/calls.log"

(
  cd "$WORK/runner"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"pytest",language:"python"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '-k alpha or beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"dotnet",language:"csharp"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '--filter FullyQualifiedName~alpha|FullyQualifiedName~beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"repeat",language:"rust"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  [[ "$(wc -l < "$TEST_LOG")" -eq 2 ]]
  grep -Fxq alpha "$TEST_LOG"
  grep -Fxq beta "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"regex",language:"go"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '-run alpha|beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"regex",language:"javascript"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '-t alpha|beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"node",language:"javascript"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '--test-name-pattern alpha|beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test","test"],selector_mode:"maven",language:"java"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- 'test -Dtest=*#alpha' "$TEST_LOG"
  grep -Fxq -- 'test -Dtest=*#beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test","test"],selector_mode:"gradle",language:"java"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- 'test --tests *.alpha' "$TEST_LOG"
  grep -Fxq -- 'test --tests *.beta' "$TEST_LOG"

  : > "$TEST_LOG"
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test"],selector_mode:"ctest",language:"cpp"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/run_tests.sh" alpha beta
  grep -Fxq -- '-R alpha|beta' "$TEST_LOG"
)

echo "adapter detection tests passed"
