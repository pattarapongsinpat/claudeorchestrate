#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"

mkdir -p .pipeline
OUT=.pipeline/toolchain.json

write_config() {
  local language="$1" framework="$2" test_file="$3" selector_mode="$4"
  local generated="$5" setup_json="$6" test_json="$7" source_regex="$8"
  shift 8
  jq -n \
    --arg language "$language" \
    --arg framework "$framework" \
    --arg test_file "$test_file" \
    --arg selector_mode "$selector_mode" \
    --arg source_regex "$source_regex" \
    --argjson generated "$generated" \
    --argjson setup_commands "$setup_json" \
    --argjson test_command "$test_json" \
    --args '{supported:true, language:$language, framework:$framework,
            generated_tests:$generated, generated_test_file:$test_file,
            verification_mode:"tests",
            selector_mode:$selector_mode, setup_commands:$setup_commands,
            test_command:$test_command, source_regex:$source_regex,
            dependency_files:$ARGS.positional}' "$@" > "$OUT"
}

unsupported() {
  jq -n --arg reason "$1" '{supported:false,reason:$reason}' > "$OUT"
  echo "$1" > .pipeline/HALT
  echo "$1" >&2
  exit 1
}

first_source_dir() {
  local pattern="$1" file
  file=$(rg --files -g "$pattern" -g '!vendor/**' -g '!node_modules/**' -g '!target/**' -g '!build/**' | head -1 || true)
  [[ -n "$file" ]] && dirname "$file" || printf '.'
}

if [[ -f package.json ]]; then
  language=javascript
  extension=js
  if [[ -f tsconfig.json ]]; then language=typescript; extension=ts; fi
  if jq -e '((.devDependencies // {}) + (.dependencies // {})) | has("vitest")' package.json >/dev/null; then
    write_config "$language" vitest "tests/pipeline_generated.test.$extension" regex true '[]' \
      '["npm","exec","--","vitest","run"]' '\.(js|jsx|mjs|cjs|ts|tsx)$' package.json package-lock.json pnpm-lock.yaml yarn.lock tsconfig.json
  elif jq -e '((.devDependencies // {}) + (.dependencies // {})) | has("jest")' package.json >/dev/null; then
    write_config "$language" jest "tests/pipeline_generated.test.$extension" regex true '[]' \
      '["npm","exec","--","jest"]' '\.(js|jsx|mjs|cjs|ts|tsx)$' package.json package-lock.json pnpm-lock.yaml yarn.lock tsconfig.json
  elif jq -e '.scripts.test? != null' package.json >/dev/null; then
    write_config "$language" npm-test '' none false '[]' \
      '["npm","test","--"]' '\.(js|jsx|mjs|cjs|ts|tsx)$' package.json package-lock.json pnpm-lock.yaml yarn.lock tsconfig.json
  else
    [[ "$language" == javascript ]] || unsupported 'TypeScript projects require an existing Vitest, Jest, or npm test setup'
    write_config javascript node-test "test/pipeline_generated.test.js" node true '[]' \
      '["node","--test"]' '\.(js|jsx|mjs|cjs|ts|tsx)$' package.json package-lock.json pnpm-lock.yaml yarn.lock tsconfig.json
  fi
elif [[ -f pyproject.toml || -f setup.py || -f requirements.txt ]]; then
  # `python -m pytest`, not `pytest`: only the module form puts the repository
  # root on sys.path, and the generated tests live in tests/ and import from it.
  py_test='["python","-m","pytest","-q"]'
  # src layout puts packages one level down, where neither form finds them.
  # pytest's pythonpath option adds it without requiring an editable install,
  # which would otherwise re-run on every one of the four test invocations
  # a single step can make.
  if [[ -d src ]] && rg --files -g 'src/**/*.py' | grep -q .; then
    py_test='["python","-m","pytest","-q","-o","pythonpath=src"]'
  fi
  write_config python pytest tests/test_pipeline_generated.py pytest true '[]' \
    "$py_test" '\.py$' pyproject.toml setup.py setup.cfg requirements.txt requirements-dev.txt poetry.lock uv.lock
elif [[ -f go.mod ]]; then
  go_dir=$(first_source_dir '*.go')
  [[ "$go_dir" == '.' ]] && go_file=pipeline_generated_test.go || go_file="$go_dir/pipeline_generated_test.go"
  write_config go go-test "$go_file" regex true '[]' \
    '["go","test","./..."]' '\.go$' go.mod go.sum
elif [[ -f Cargo.toml ]]; then
  write_config rust cargo-test tests/pipeline_generated.rs repeat true '[]' \
    '["cargo","test"]' '\.rs$' Cargo.toml Cargo.lock
elif [[ -f pom.xml ]]; then
  mvn=(mvn)
  [[ -f mvnw ]] && mvn=(./mvnw)
  write_config java maven src/test/java/PipelineGeneratedTest.java maven true '[]' \
    "$(printf '%s\n' "${mvn[@]}" test | jq -R . | jq -s .)" '\.java$' pom.xml
elif [[ -f build.gradle || -f build.gradle.kts || -f settings.gradle || -f settings.gradle.kts ]]; then
  gradle=(gradle)
  [[ -f gradlew ]] && gradle=(./gradlew)
  write_config java gradle src/test/java/PipelineGeneratedTest.java gradle true '[]' \
    "$(printf '%s\n' "${gradle[@]}" test | jq -R . | jq -s .)" '\.java$' build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradle.properties
elif compgen -G '*.sln' >/dev/null || compgen -G '*.slnx' >/dev/null || compgen -G '*.csproj' >/dev/null || rg --files -g '*.csproj' | grep -q .; then
  # Prefer project metadata because a valid test project need not contain "Test"
  # in its filename. Keep the filename fallback for conventional projects whose
  # minimal project file relies on SDK defaults.
  test_project=""
  while IFS= read -r project; do
    project="${project//\\//}"
    if rg -qi '<IsTestProject>[[:space:]]*true|Microsoft\.NET\.Test\.Sdk' "$project"; then
      test_project="$project"
      break
    fi
  done < <(rg --files -g '*.csproj')
  [[ -n "$test_project" ]] || test_project=$(rg --files -g '*Test.csproj' -g '*Tests.csproj' | head -1 || true)
  test_project="${test_project//\\//}"

  if [[ -n "$test_project" ]]; then
    test_dir=$(dirname "$test_project")
    write_config csharp dotnet-test "$test_dir/PipelineGeneratedTests.cs" dotnet true '[]' \
      "$(printf '%s\n' dotnet test "$test_project" | jq -R . | jq -s .)" '\.cs$' '*.sln' '*.slnx' '*.csproj' Directory.Build.props Directory.Build.targets packages.lock.json

    coverage=unknown
    linked_json='[]'
    if rg -qi '<ProjectReference[[:space:]]+Include=' "$test_project"; then
      coverage=project-reference
    elif rg -qi '<Compile[[:space:]]+Include="[^"]+"[^>]*Link=' "$test_project"; then
      coverage=explicit-links
      linked_json=$(
        rg -o '<Compile[[:space:]]+Include="[^"]+"' "$test_project" \
          | sed -E 's/.*Include="([^"]+)"/\1/' | tr '\\' '/' \
          | while IFS= read -r include; do
              [[ "$include" != *'*'* && "$include" != *'?'* ]] || continue
              realpath -m --relative-to="$PWD" "$test_dir/$include" | tr '\\' '/'
            done | jq -R . | jq -s .
      )
    fi
    tmp=$(mktemp)
    jq --arg project "$test_project" --arg coverage "$coverage" --argjson linked "$linked_json" \
      '.test_project = $project | .test_project_coverage = $coverage | .linked_source_files = $linked' \
      "$OUT" > "$tmp" && mv "$tmp" "$OUT"
  else
    # A small C# change can still be verified safely by compilation. Prefer a
    # solution, then require one unambiguous non-test project outside test dirs.
    build_target=$(compgen -G '*.sln' | head -1 || true)
    [[ -n "$build_target" ]] || build_target=$(compgen -G '*.slnx' | head -1 || true)
    if [[ -z "$build_target" ]]; then
      mapfile -t build_projects < <(rg --files -g '*.csproj' | tr '\\' '/' | grep -Eiv '(^|/)(test|tests|spec|specs)/' || true)
      ((${#build_projects[@]} == 1)) || unsupported 'C# project has no test project and no unambiguous build target'
      build_target="${build_projects[0]}"
    fi
    write_config csharp dotnet-build '' none false '[]' \
      "$(printf '%s\n' dotnet build "$build_target" | jq -R . | jq -s .)" '\.cs$' '*.sln' '*.slnx' '*.csproj' Directory.Build.props Directory.Build.targets packages.lock.json
    tmp=$(mktemp)
    jq '.verification_mode = "judgment"' "$OUT" > "$tmp" && mv "$tmp" "$OUT"
  fi
elif [[ -f CMakeLists.txt ]]; then
  language=c
  source_regex='\.(c|h)$'
  if rg --files -g '*.cc' -g '*.cpp' -g '*.cxx' -g '*.hpp' -g '*.hh' | grep -q .; then
    language=cpp
    source_regex='\.(c|cc|cpp|cxx|h|hh|hpp)$'
  fi
  # -C/--config Debug is required by multi-config generators (Visual Studio,
  # Xcode, Ninja Multi-Config): without it ctest cannot resolve the executable
  # and every test reports "Not Run". Single-config generators ignore it.
  write_config "$language" cmake '' ctest false \
    '[["cmake","-S",".","-B",".pipeline/build"],["cmake","--build",".pipeline/build","--config","Debug"]]' \
    '["ctest","--test-dir",".pipeline/build","--output-on-failure","-C","Debug","--no-tests=error"]' "$source_regex" CMakeLists.txt '*.cmake' conanfile.txt conanfile.py vcpkg.json
elif [[ -f meson.build ]]; then
  language=c
  source_regex='\.(c|h)$'
  if rg --files -g '*.cc' -g '*.cpp' -g '*.cxx' -g '*.hpp' -g '*.hh' | grep -q .; then
    language=cpp
    source_regex='\.(c|cc|cpp|cxx|h|hh|hpp)$'
  fi
  write_config "$language" meson '' none false \
    '[["meson","setup",".pipeline/build"]]' \
    '["meson","test","-C",".pipeline/build"]' "$source_regex" meson.build meson_options.txt
elif [[ -f Makefile || -f makefile ]]; then
  language=c
  source_regex='\.(c|h)$'
  if rg --files -g '*.cc' -g '*.cpp' -g '*.cxx' -g '*.hpp' -g '*.hh' | grep -q .; then
    language=cpp
    source_regex='\.(c|cc|cpp|cxx|h|hh|hpp)$'
  fi
  make -n test >/dev/null 2>&1 || unsupported 'C and C++ Make projects require a test target'
  write_config "$language" make '' none false '[]' '["make","test"]' "$source_regex" Makefile makefile
else
  unsupported 'Unsupported project. Add a recognized package or build manifest.'
fi

# Optional command that loads the suite without running it. It is what separates a
# genuine red baseline from a suite that fails to collect — both are "non-zero exit",
# and only the first one means the tests are actually gating anything.
framework=$(jq -r '.framework' "$OUT")
case "$framework" in
  # Derive from test_command so adapter-specific flags (src layout's pythonpath)
  # are inherited rather than duplicated and left to drift.
  pytest) collect=$(jq -c '.test_command + ["--collect-only"]' "$OUT") ;;
  *)      collect='[]' ;;
esac

# Loads and builds the existing suite without executing its tests. The baseline
# check temporarily removes the generated test file before invoking this command,
# so expected references to not-yet-created APIs do not look like repository
# compilation failures.
case "$framework" in
  pytest)      load="$collect" ;;
  node-test)   load=$(jq -c '.test_command + ["--test-name-pattern", "a^"]' "$OUT") ;;
  vitest|jest) load=$(jq -c '.test_command + ["-t", "a^", "--passWithNoTests"]' "$OUT") ;;
  go-test)     load='["go","test","-run","a^","./..."]' ;;
  cargo-test)  load=$(jq -c '.test_command + ["--no-run"]' "$OUT") ;;
  maven)       load=$(jq -c '.test_command + ["-DskipTests"]' "$OUT") ;;
  gradle)      load=$(jq -c '.test_command[0:-1] + ["testClasses"]' "$OUT") ;;
  dotnet-test) load=$(jq -c '.test_command + ["--list-tests"]' "$OUT") ;;
  dotnet-build) load=$(jq -c '.test_command' "$OUT") ;;
  cmake)       load=$(jq -c '.test_command + ["-N"]' "$OUT") ;;
  meson)       load=$(jq -c '.test_command + ["--list"]' "$OUT") ;;
  *)           load='[]' ;;
esac

# Mechanical checks retained when Opus must judge behavior directly. Some host
# environments cannot execute meaningful unit tests, but compilation is still
# valuable when the detected toolchain provides it.
case "$framework" in
  go-test)      judgment="$load" ;;
  cargo-test)   judgment="$load" ;;
  maven)        judgment="$load" ;;
  gradle)       judgment="$load" ;;
  dotnet-test)  judgment=$(jq -c '.test_command | .[1] = "build"' "$OUT") ;;
  dotnet-build) judgment=$(jq -c '.test_command' "$OUT") ;;
  cmake)        judgment='[]' ;;
  meson)        judgment='["meson","compile","-C",".pipeline/build"]' ;;
  make)         judgment='["make"]' ;;
  *)            judgment='[]' ;;
esac

# Ceiling on a single test invocation. Compiled toolchains build first, so they
# get a larger budget. PIPELINE_TEST_TIMEOUT overrides at run time.
case "$framework" in
  cargo-test|maven|gradle|dotnet-test|dotnet-build|cmake|meson|make) timeout_s=1800 ;;
  go-test)                                              timeout_s=900 ;;
  *)                                                    timeout_s=600 ;;
esac

tmp=$(mktemp)
jq --argjson c "$collect" --argjson l "$load" --argjson j "$judgment" --argjson t "$timeout_s" \
   '.collect_command = $c | .load_command = $l | .judgment_command = $j | .test_timeout_seconds = $t' "$OUT" > "$tmp" && mv "$tmp" "$OUT"

# Repositories with non-standard suites can commit an exact adapter override.
# This avoids rediscovering custom harness commands on every run and lets the
# baseline load command omit expectation-bearing compiled projects.
OVERRIDE=.pipeline-toolchain.json
if [[ -f "$OVERRIDE" ]]; then
  jq -e '
    type == "object" and
    all(keys[]; IN("test_command", "load_command", "collect_command", "setup_commands",
                   "selector_mode", "generated_tests", "generated_test_file",
                   "framework", "test_timeout_seconds", "test_project_coverage",
                   "linked_source_files", "verification_mode", "judgment_command")) and
    ((.test_command // []) | type == "array" and all(.[]; type == "string")) and
    ((.load_command // []) | type == "array" and all(.[]; type == "string")) and
    ((.collect_command // []) | type == "array" and all(.[]; type == "string")) and
    ((.judgment_command // []) | type == "array" and all(.[]; type == "string")) and
    ((.setup_commands // []) | type == "array" and all(.[]; type == "array" and all(.[]; type == "string"))) and
    ((.generated_tests // false) | type == "boolean") and
    ((.generated_test_file // "") | type == "string") and
    ((.verification_mode // "tests") | IN("tests", "judgment")) and
    ((.selector_mode // "none") | IN("none", "pytest", "regex", "node", "repeat", "maven", "gradle", "dotnet", "ctest")) and
    ((.test_timeout_seconds // 600) | type == "number" and . > 0)
  ' "$OVERRIDE" >/dev/null || unsupported 'invalid .pipeline-toolchain.json override'
  override_test_file=$(jq -r '.generated_test_file // ""' "$OVERRIDE" | tr -d '\r')
  [[ -z "$override_test_file" ]] || safe_repo_path "$override_test_file" \
    || unsupported 'unsafe generated_test_file in .pipeline-toolchain.json override'
  tmp=$(mktemp)
  jq -s '.[0] * .[1] | .dependency_files += [".pipeline-toolchain.json"] | .dependency_files |= unique' \
    "$OUT" "$OVERRIDE" > "$tmp" && mv "$tmp" "$OUT"
fi

echo "detected: $(jq -r '.language + " / " + .framework' "$OUT")"
