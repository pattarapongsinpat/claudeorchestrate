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
    jq -e '.supported == true and (.test_command | type == "array") and (.load_command | type == "array")' .pipeline/toolchain.json >/dev/null
  )
}

mkdir -p "$WORK/python"
printf '[project]\nname="demo"\n' > "$WORK/python/pyproject.toml"
check_case python python pytest

mkdir -p "$WORK/javascript"
printf '{"devDependencies":{"vitest":"latest"}}\n' > "$WORK/javascript/package.json"
check_case javascript javascript vitest

mkdir -p "$WORK/typescript"
printf '{"devDependencies":{"vitest":"latest"}}\n' > "$WORK/typescript/package.json"
printf '{"compilerOptions":{"strict":true}}\n' > "$WORK/typescript/tsconfig.json"
check_case typescript typescript vitest

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

mkdir -p "$WORK/csharp-build/src"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' > "$WORK/csharp-build/src/Demo.csproj"
check_case csharp-build csharp dotnet-build
(
  cd "$WORK/csharp-build"
  jq -e '.generated_tests == false and .selector_mode == "none" and .generated_test_file == "" and .test_command == ["dotnet","build","src/Demo.csproj"]' .pipeline/toolchain.json >/dev/null
  jq -e '.verification_mode == "judgment" and .judgment_command == .test_command' .pipeline/toolchain.json >/dev/null
)

mkdir -p "$WORK/csharp-metadata/specs"
cat > "$WORK/csharp-metadata/specs/Verification.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
  <ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.9.0" /></ItemGroup>
</Project>
EOF
check_case csharp-metadata csharp dotnet-test

mkdir -p "$WORK/csharp-linked/src" "$WORK/csharp-linked/tests"
printf 'internal class Reachable {}\n' > "$WORK/csharp-linked/src/Reachable.cs"
printf 'internal class Missing {}\n' > "$WORK/csharp-linked/src/Missing.cs"
cat > "$WORK/csharp-linked/tests/Linked.Tests.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup>
  <ItemGroup>
    <Compile Include="..\src\Reachable.cs" Link="Reachable.cs" />
  </ItemGroup>
</Project>
EOF
(
  cd "$WORK/csharp-linked"
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  jq -e '.test_project_coverage == "explicit-links" and (.linked_source_files | index("src/Reachable.cs") != null)' .pipeline/toolchain.json >/dev/null
  printf '%s\n' '{"allowed_files":["src/Reachable.cs","src/Missing.cs"]}' > .pipeline/intent.json
  rc=0
  "$PIPELINE_HOME/pipeline/validate_test_reachability.sh" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'src/Missing.cs' .pipeline/HALT
)

mkdir -p "$WORK/override"
printf '[project]\nname="override"\n' > "$WORK/override/pyproject.toml"
cat > "$WORK/override/.pipeline-toolchain.json" <<'EOF'
{"test_command":["custom-suite"],"load_command":["custom-load"],"generated_tests":false,"generated_test_file":"","selector_mode":"none","framework":"custom"}
EOF
(
  cd "$WORK/override"
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  jq -e '.framework == "custom" and .test_command == ["custom-suite"] and .load_command == ["custom-load"] and (.dependency_files | index(".pipeline-toolchain.json") != null)' .pipeline/toolchain.json >/dev/null
)

mkdir -p "$WORK/bad-override-path"
printf '[project]\nname="bad-path"\n' > "$WORK/bad-override-path/pyproject.toml"
printf '%s\n' '{"generated_test_file":"..\\outside.py"}' > "$WORK/bad-override-path/.pipeline-toolchain.json"
(
  cd "$WORK/bad-override-path"
  ! "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null 2>&1
  grep -Fq 'unsafe generated_test_file' .pipeline/HALT
)

mkdir -p "$WORK/bad-override-command"
printf '[project]\nname="bad-command"\n' > "$WORK/bad-override-command/pyproject.toml"
printf '%s\n' '{"setup_commands":["not-a-command-array"]}' > "$WORK/bad-override-command/.pipeline-toolchain.json"
(
  cd "$WORK/bad-override-command"
  ! "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null 2>&1
  grep -Fq 'invalid .pipeline-toolchain.json' .pipeline/HALT
)

mkdir -p "$WORK/judgment"
printf '[project]\nname="judgment"\n' > "$WORK/judgment/pyproject.toml"
(
  cd "$WORK/judgment"
  "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
  printf '%s\n' '{"allowed_files":["plugin.py"],"verification":{"mode":"judgment","reason":"behavior requires a running game host"}}' > .pipeline/intent.json
  "$PIPELINE_HOME/pipeline/tests.sh" >/dev/null
  jq -e '.verification_mode == "judgment" and .generated_tests == false and .generated_test_file == "" and .test_command == []' .pipeline/toolchain.json >/dev/null
  "$PIPELINE_HOME/pipeline/check_baseline.sh" | grep -Fq 'Opus will judge behavior directly'
  "$PIPELINE_HOME/pipeline/final_check.sh" | grep -Fq 'Opus judgment is still required'
  "$PIPELINE_HOME/pipeline/review_trigger.sh" | grep -Fq 'Opus judgment is mandatory'
)

mkdir -p "$WORK/c"
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WORK/c/CMakeLists.txt"
printf 'int demo(void);\n' > "$WORK/c/demo.c"
check_case c c cmake

mkdir -p "$WORK/cpp"
printf 'cmake_minimum_required(VERSION 3.20)\n' > "$WORK/cpp/CMakeLists.txt"
printf 'int demo();\n' > "$WORK/cpp/demo.cpp"
check_case cpp cpp cmake

for fallback_case in python javascript typescript go rust java csharp csharp-build c cpp; do
  (
    cd "$WORK/$fallback_case"
    printf '%s\n' '{"allowed_files":["src/change.txt"],"verification":{"mode":"judgment","reason":"behavior requires an unavailable host runtime"}}' > .pipeline/intent.json
    "$PIPELINE_HOME/pipeline/tests.sh" >/dev/null
    jq -e '.verification_mode == "judgment" and .generated_tests == false and .generated_test_file == "" and .selector_mode == "none"' .pipeline/toolchain.json >/dev/null
    "$PIPELINE_HOME/pipeline/review_trigger.sh" | grep -Fq 'Opus judgment is mandatory'
  )
done

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
  jq -n '{supported:true,setup_commands:[],test_command:["fake-test","run"],load_command:["fake-test","load"],selector_mode:"none",language:"test"}' > .pipeline/toolchain.json
  PATH="$PWD/bin:$PATH" RUN_TESTS_LOAD=1 "$PIPELINE_HOME/pipeline/run_tests.sh"
  grep -Fxq -- 'load' "$TEST_LOG"

  : > "$TEST_LOG"
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

# The baseline loader must inspect the pre-existing suite without the generated
# test file, then restore that file before running the expected-red baseline.
mkdir -p "$WORK/baseline/.pipeline" "$WORK/baseline/bin" "$WORK/baseline/tests"
cat > "$WORK/baseline/bin/fake-load" <<'EOF'
#!/usr/bin/env bash
[[ ! -e tests/pipeline_generated.test.js ]]
EOF
cat > "$WORK/baseline/bin/fake-red" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/baseline/bin/fake-load" "$WORK/baseline/bin/fake-red"
printf 'generated\n' > "$WORK/baseline/tests/pipeline_generated.test.js"
jq -n '{supported:true,generated_tests:true,generated_test_file:"tests/pipeline_generated.test.js",setup_commands:[],load_command:["fake-load"],collect_command:[],test_command:["fake-red"],selector_mode:"none",language:"javascript"}' > "$WORK/baseline/.pipeline/toolchain.json"
(
  cd "$WORK/baseline"
  PATH="$PWD/bin:$PATH" "$PIPELINE_HOME/pipeline/check_baseline.sh" >/dev/null
  [[ "$(cat tests/pipeline_generated.test.js)" == generated ]]
  [[ ! -e .pipeline/HALT ]]
)

echo "baseline isolation tests passed"
