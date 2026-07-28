#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANGUAGE="${1:-}"
case "$LANGUAGE" in java|csharp|c|cpp) ;; *) echo "usage: test_e2e_compiled.sh <java|csharp|c|cpp>" >&2; exit 2 ;; esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO"

git init -q
git config user.name 'Pipeline Compiled E2E'
git config user.email 'pipeline@example.invalid'
printf '/.pipeline/\n' >> "$(git rev-parse --git-path info/exclude)"

case "$LANGUAGE" in
  java)
    command -v mvn >/dev/null || { echo "mvn is required" >&2; exit 1; }
    mkdir -p src/main/java src/test/java
    printf '/target/\n' > .gitignore
    cat > pom.xml <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>pipeline</groupId><artifactId>compiled-e2e</artifactId><version>1.0</version>
  <properties><maven.compiler.source>17</maven.compiler.source><maven.compiler.target>17</maven.compiler.target></properties>
  <dependencies><dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.10.2</version><scope>test</scope></dependency></dependencies>
</project>
EOF
    cat > src/main/java/Calculator.java <<'EOF'
public final class Calculator {
    public static int add(int left, int right) { return 0; }
}
EOF
    cat > src/test/java/PipelineGeneratedTest.java <<'EOF'
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;
class PipelineGeneratedTest {
    @Test void adds_numbers() { assertEquals(5, Calculator.add(2, 3)); }
}
EOF
    source_file=src/main/java/Calculator.java
    tests_json='["adds_numbers"]'
    description='Make Calculator.add return the sum of its two integer arguments.'
    done_when='Calculator.add(2, 3) returns 5'
    ;;
  csharp)
    command -v dotnet >/dev/null || { echo "dotnet is required" >&2; exit 1; }
    mkdir -p Demo Demo.Tests
    printf 'bin/\nobj/\n' > .gitignore
    cat > Demo/Demo.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>
EOF
    cat > Demo/Calculator.cs <<'EOF'
public static class Calculator
{
    public static int Add(int left, int right) => 0;
}
EOF
    cat > Demo.Tests/Demo.Tests.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net8.0</TargetFramework><IsPackable>false</IsPackable></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.9.0" />
    <PackageReference Include="xunit" Version="2.7.0" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.7" />
    <ProjectReference Include="../Demo/Demo.csproj" />
  </ItemGroup>
</Project>
EOF
    cat > Demo.Tests/PipelineGeneratedTests.cs <<'EOF'
using Xunit;
public class PipelineGeneratedTests
{
    [Fact] public void adds_numbers() => Assert.Equal(5, Calculator.Add(2, 3));
}
EOF
    source_file=Demo/Calculator.cs
    tests_json='["adds_numbers"]'
    description='Make Calculator.Add return the sum of its two integer arguments.'
    done_when='Calculator.Add(2, 3) returns 5'
    ;;
  c)
    command -v cmake >/dev/null || { echo "cmake is required" >&2; exit 1; }
    cat > CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(compiled_e2e C)
enable_testing()
add_library(calculator calculator.c)
add_executable(calculator_test calculator_test.c)
target_link_libraries(calculator_test PRIVATE calculator)
add_test(NAME adds_numbers COMMAND calculator_test)
EOF
    cat > calculator.h <<'EOF'
int add(int left, int right);
EOF
    cat > calculator.c <<'EOF'
#include "calculator.h"
int add(int left, int right) { return 0; }
EOF
    cat > calculator_test.c <<'EOF'
#include "calculator.h"
int main(void) { return add(2, 3) == 5 ? 0 : 1; }
EOF
    source_file=calculator.c
    tests_json='[]'
    description='Make add return the sum of its two integer arguments.'
    done_when='add(2, 3) returns 5'
    ;;
  cpp)
    command -v cmake >/dev/null || { echo "cmake is required" >&2; exit 1; }
    cat > CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(compiled_e2e CXX)
enable_testing()
add_library(calculator calculator.cpp)
add_executable(calculator_test calculator_test.cpp)
target_link_libraries(calculator_test PRIVATE calculator)
add_test(NAME adds_numbers COMMAND calculator_test)
EOF
    cat > calculator.hpp <<'EOF'
int add(int left, int right);
EOF
    cat > calculator.cpp <<'EOF'
#include "calculator.hpp"
int add(int left, int right) { return 0; }
EOF
    cat > calculator_test.cpp <<'EOF'
#include "calculator.hpp"
int main() { return add(2, 3) == 5 ? 0 : 1; }
EOF
    source_file=calculator.cpp
    tests_json='[]'
    description='Make add return the sum of its two integer arguments.'
    done_when='add(2, 3) returns 5'
    ;;
esac

git add .
git commit -qm 'fixture baseline'
"$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
jq -n --arg file "$source_file" --arg description "$description" --arg done "$done_when" --argjson tests "$tests_json" \
  '{steps:[{id:"s1",description:$description,files_allowed:[$file],context_files:[],tests:$tests,deps:[],done_when:$done}]}' \
  > .pipeline/plan_final.json

if "$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null 2>&1; then
  echo "$LANGUAGE fixture unexpectedly passed before implementation" >&2
  exit 1
fi

"$PIPELINE_HOME/pipeline/code.sh" s1
"$PIPELINE_HOME/pipeline/final_check.sh" >/dev/null
git diff --quiet -- "$source_file" && { echo "DeepSeek made no $LANGUAGE implementation change" >&2; exit 1; }

echo "DeepSeek $LANGUAGE implementation loop passed"
