#!/usr/bin/env bash
# Runs each adapter's REAL toolchain against a hand-written test file. No DeepSeek
# calls, no plan, no coder — this covers the gap test_adapters.sh leaves.
#
# test_adapters.sh proves detection and which command gets built, against a fake
# binary. It cannot tell you whether the real runner accepts that selector syntax
# or discovers a file at generated_test_file. That is what breaks per language.
#
# Per adapter, with one passing and one failing test in place:
#   A  unselected run fails            -> the runner sees the generated file at all
#   B  selecting the passing test  -> 0 -> the selector resolves a real name
#   C  selecting the failing test  -> !0 -> the selector is not silently matching all
#   D  selecting a name that matches nothing
#      A runner that exits 0 here is dangerous: a wrong test name in plan_final.json
#      would make code.sh report PASS over unimplemented code. Reported, not failed,
#      because it is the runner's behavior and the fix belongs in the gate.
#
# Adapters whose toolchain is absent are SKIPped, never silently passed.
set -uo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0; skip=0; warn=()

have() { command -v "$1" >/dev/null 2>&1; }
selected() { [[ -z "${SMOKE_ONLY:-}" || "$SMOKE_ONLY" == "$1" ]]; }

# Run the adapter's test command; echo the exit code.
rt() { ( cd "$1" && shift && "$PIPELINE_HOME/pipeline/run_tests.sh" "$@" >/dev/null 2>&1; echo $? ); }
rtl() { ( cd "$1" && RUN_TESTS_LOAD=1 "$PIPELINE_HOME/pipeline/run_tests.sh" >/dev/null 2>&1; echo $? ); }

check() {
  local name="$1" got="$2" want="$3"
  if [[ "$want" == nonzero ]]; then
    [[ "$got" != 0 ]] && { echo "    ok   $name"; pass=$((pass+1)); return; }
  elif [[ "$got" == "$want" ]]; then
    echo "    ok   $name"; pass=$((pass+1)); return
  fi
  echo "    FAIL $name (exit $got, wanted $want)"; fail=$((fail+1))
}

# dir, passing test name, failing test name
verify_adapter() {
  local d="$1" good="$2" bad="$3"
  local framework selector
  framework=$(jq -r '.framework' "$d/.pipeline/toolchain.json")
  selector=$(jq -r '.selector_mode' "$d/.pipeline/toolchain.json")
  echo "  framework=$framework selector_mode=$selector"

  if (( $(jq -r '.load_command | length' "$d/.pipeline/toolchain.json") )); then
    check "E suite loads without running tests" "$(rtl "$d")" 0
  else
    echo "    --   E load-only check unavailable"
  fi

  check "A unselected run fails"        "$(rt "$d")"        nonzero
  if [[ "$selector" == none ]]; then
    echo "    --   B/C/D skipped (selector_mode none runs the whole suite by design)"
    return
  fi
  check "B passing test selected"      "$(rt "$d" "$good")" 0
  check "C failing test selected"      "$(rt "$d" "$bad")"  nonzero

  local d_rc; d_rc=$(rt "$d" "pipeline_no_such_test_name_xyz")
  if [[ "$d_rc" == 0 ]]; then
    echo "    WARN D unmatched selector exits 0 — a wrong test name would read as PASS"
    warn+=("$framework: a selector matching no test exits 0")
  else
    echo "    ok   D unmatched selector fails"; pass=$((pass+1))
  fi
}

skip_adapter() { echo "  SKIP ($1 not installed)"; skip=$((skip+1)); }

# ---------------------------------------------------------------- python
echo "== python / pytest"
if selected python && have python && python -m pytest --version >/dev/null 2>&1; then
  d="$ROOT/py"; mkdir -p "$d/tests"
  printf '[project]\nname="demo"\nversion="0.1"\n' > "$d/pyproject.toml"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/tests/test_pipeline_generated.py" <<'EOF'
def test_smoke_good():
    assert 1 == 1


def test_smoke_bad():
    assert 1 == 2
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter pytest; fi

# ---------------------------------------------------------------- node --test
echo "== javascript / node-test"
if selected node && have node; then
  d="$ROOT/nodetest"; mkdir -p "$d/test"
  printf '{"name":"demo","version":"1.0.0"}\n' > "$d/package.json"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/test/pipeline_generated.test.js" <<'EOF'
const test = require('node:test');
const assert = require('node:assert');

test('test_smoke_good', () => { assert.strictEqual(1, 1); });
test('test_smoke_bad', () => { assert.strictEqual(1, 2); });
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter node; fi

# ---------------------------------------------------------------- npm test
echo "== javascript / npm-test (existing suite)"
if selected npm && have npm; then
  d="$ROOT/npmtest"; mkdir -p "$d/test"
  printf '{"name":"demo","version":"1.0.0","scripts":{"test":"node --test"}}\n' > "$d/package.json"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/test/existing.test.js" <<'EOF'
const test = require('node:test');
const assert = require('node:assert');

test('test_smoke_bad', () => { assert.strictEqual(1, 2); });
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter npm; fi

# ---------------------------------------------------------------- vitest
echo "== javascript / vitest"
if selected vitest && have npm; then
  d="$ROOT/vitest"; mkdir -p "$d/tests"
  printf '{"name":"demo","version":"1.0.0","devDependencies":{"vitest":"^2"}}\n' > "$d/package.json"
  if ( cd "$d" && npm install --silent --no-audit --no-fund >/dev/null 2>&1 ); then
    ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
    cat > "$d/tests/pipeline_generated.test.js" <<'EOF'
import { test, expect } from 'vitest';

test('test_smoke_good', () => { expect(1).toBe(1); });
test('test_smoke_bad', () => { expect(1).toBe(2); });
EOF
    verify_adapter "$d" test_smoke_good test_smoke_bad
  else skip_adapter "vitest (npm install failed)"; fi
else skip_adapter npm; fi

# ---------------------------------------------------------------- jest
echo "== javascript / jest"
if selected jest && have npm; then
  d="$ROOT/jest"; mkdir -p "$d/tests"
  printf '{"name":"demo","version":"1.0.0","devDependencies":{"jest":"^29"}}\n' > "$d/package.json"
  if ( cd "$d" && npm install --silent --no-audit --no-fund >/dev/null 2>&1 ); then
    ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
    cat > "$d/tests/pipeline_generated.test.js" <<'EOF'
test('test_smoke_good', () => { expect(1).toBe(1); });
test('test_smoke_bad', () => { expect(1).toBe(2); });
EOF
    verify_adapter "$d" test_smoke_good test_smoke_bad
  else skip_adapter "jest (npm install failed)"; fi
else skip_adapter npm; fi

# ---------------------------------------------------------------- go
echo "== go / go test"
if selected go && have go; then
  d="$ROOT/go"; mkdir -p "$d"
  printf 'module example.test/demo\n\ngo 1.22\n' > "$d/go.mod"
  printf 'package demo\n\nfunc Demo() int { return 1 }\n' > "$d/demo.go"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/pipeline_generated_test.go" <<'EOF'
package demo

import "testing"

func Test_smoke_good(t *testing.T) { if Demo() != 1 { t.Fatal("bad") } }
func Test_smoke_bad(t *testing.T)  { if Demo() != 2 { t.Fatal("bad") } }
EOF
  verify_adapter "$d" Test_smoke_good Test_smoke_bad
else skip_adapter go; fi

# ---------------------------------------------------------------- rust
echo "== rust / cargo test"
if selected rust && have cargo; then
  d="$ROOT/rust"; mkdir -p "$d/src" "$d/tests"
  printf '[package]\nname="demo"\nversion="0.1.0"\nedition="2021"\n' > "$d/Cargo.toml"
  printf 'pub fn demo() -> i32 { 1 }\n' > "$d/src/lib.rs"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/tests/pipeline_generated.rs" <<'EOF'
#[test]
fn test_smoke_good() { assert_eq!(demo::demo(), 1); }

#[test]
fn test_smoke_bad() { assert_eq!(demo::demo(), 2); }
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter cargo; fi

# ---------------------------------------------------------------- maven
echo "== java / maven"
if selected maven && have mvn; then
  d="$ROOT/maven"; mkdir -p "$d/src/test/java"
  cat > "$d/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>demo</groupId><artifactId>demo</artifactId><version>1.0</version>
  <properties><maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target></properties>
  <dependencies><dependency>
    <groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId>
    <version>5.10.2</version><scope>test</scope>
  </dependency></dependencies>
</project>
EOF
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/src/test/java/PipelineGeneratedTest.java" <<'EOF'
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class PipelineGeneratedTest {
    @Test void test_smoke_good() { assertEquals(1, 1); }
    @Test void test_smoke_bad()  { assertEquals(1, 2); }
}
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter maven; fi

# ---------------------------------------------------------------- gradle
echo "== java / gradle"
if selected gradle && have gradle; then
  d="$ROOT/gradle"; mkdir -p "$d/src/test/java"
  cat > "$d/build.gradle" <<'EOF'
plugins { id 'java' }
repositories { mavenCentral() }
dependencies { testImplementation 'org.junit.jupiter:junit-jupiter:5.10.2' }
dependencies { testRuntimeOnly 'org.junit.platform:junit-platform-launcher' }
test { useJUnitPlatform() }
EOF
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  cat > "$d/src/test/java/PipelineGeneratedTest.java" <<'EOF'
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class PipelineGeneratedTest {
    @Test void test_smoke_good() { assertEquals(1, 1); }
    @Test void test_smoke_bad()  { assertEquals(1, 2); }
}
EOF
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter gradle; fi

# ---------------------------------------------------------------- dotnet
echo "== csharp / dotnet test"
if selected csharp && have dotnet; then
  d="$ROOT/csharp/Demo.Tests"; mkdir -p "$d"
  cat > "$d/Demo.Tests.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.9.0" />
    <PackageReference Include="xunit" Version="2.7.0" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.7" />
  </ItemGroup>
</Project>
EOF
  cat > "$d/PipelineGeneratedTests.cs" <<'EOF'
using Xunit;

public class PipelineGeneratedTests
{
    [Fact] public void test_smoke_good() { Assert.Equal(1, 1); }
    [Fact] public void test_smoke_bad()  { Assert.Equal(1, 2); }
}
EOF
  ( cd "$ROOT/csharp" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  verify_adapter "$ROOT/csharp" test_smoke_good test_smoke_bad
else skip_adapter dotnet; fi

# ---------------------------------------------------------------- cmake
echo "== c / cmake + ctest"
if selected cmake && have cmake && have ctest; then
  d="$ROOT/cmake"; mkdir -p "$d"
  cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(demo C)
enable_testing()
add_executable(demo_good demo_good.c)
add_executable(demo_bad demo_bad.c)
add_test(NAME test_smoke_good COMMAND demo_good)
add_test(NAME test_smoke_bad COMMAND demo_bad)
EOF
  printf 'int main(void){return 0;}\n' > "$d/demo_good.c"
  printf 'int main(void){return 1;}\n' > "$d/demo_bad.c"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter cmake; fi

# ---------------------------------------------------------------- meson
echo "== c / meson"
if selected meson && have meson; then
  d="$ROOT/meson"; mkdir -p "$d"
  cat > "$d/meson.build" <<'EOF'
project('demo', 'c')
good = executable('demo_good', 'demo_good.c')
bad = executable('demo_bad', 'demo_bad.c')
test('test_smoke_good', good)
test('test_smoke_bad', bad)
EOF
  printf 'int main(void){return 0;}\n' > "$d/demo_good.c"
  printf 'int main(void){return 1;}\n' > "$d/demo_bad.c"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter meson; fi

# ---------------------------------------------------------------- make
echo "== c / make"
if selected make && have make; then
  d="$ROOT/make"; mkdir -p "$d"
  printf 'test:\n\t@exit 1\n' > "$d/Makefile"
  ( cd "$d" && "$PIPELINE_HOME/pipeline/detect.sh" >/dev/null )
  verify_adapter "$d" test_smoke_good test_smoke_bad
else skip_adapter make; fi

echo
if ((${#warn[@]})); then
  echo "WARNINGS (runner behavior compensated by validate_test_names.sh before waves):"
  printf '  - %s\n' "${warn[@]}"
  echo
fi
echo "RESULT pass=$pass fail=$fail skip=$skip"
((fail == 0))
