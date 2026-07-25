#!/usr/bin/env bash
set -euo pipefail

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
  write_config python pytest tests/test_pipeline_generated.py pytest true '[]' \
    '["python","-m","pytest","-q"]' '\.py$' pyproject.toml setup.py setup.cfg requirements.txt requirements-dev.txt poetry.lock uv.lock
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
elif compgen -G '*.sln' >/dev/null || compgen -G '*.csproj' >/dev/null || rg --files -g '*.csproj' | grep -q .; then
  test_project=$(rg --files -g '*[Tt]est*.csproj' | head -1 || true)
  [[ -n "$test_project" ]] || unsupported 'C# projects require an existing test .csproj for generated tests'
  test_dir=$(dirname "$test_project")
  write_config csharp dotnet-test "$test_dir/PipelineGeneratedTests.cs" dotnet true '[]' \
    "$(printf '%s\n' dotnet test "$test_project" | jq -R . | jq -s .)" '\.cs$' '*.sln' '*.csproj' Directory.Build.props Directory.Build.targets packages.lock.json
elif [[ -f CMakeLists.txt ]]; then
  language=c
  source_regex='\.(c|h)$'
  if rg --files -g '*.cc' -g '*.cpp' -g '*.cxx' -g '*.hpp' -g '*.hh' | grep -q .; then
    language=cpp
    source_regex='\.(c|cc|cpp|cxx|h|hh|hpp)$'
  fi
  write_config "$language" cmake '' ctest false \
    '[["cmake","-S",".","-B",".pipeline/build"],["cmake","--build",".pipeline/build"]]' \
    '["ctest","--test-dir",".pipeline/build","--output-on-failure"]' "$source_regex" CMakeLists.txt '*.cmake' conanfile.txt conanfile.py vcpkg.json
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
case "$(jq -r '.framework' "$OUT")" in
  pytest) collect='["python","-m","pytest","--collect-only","-q"]' ;;
  *)      collect='[]' ;;
esac
tmp=$(mktemp)
jq --argjson c "$collect" '.collect_command = $c' "$OUT" > "$tmp" && mv "$tmp" "$OUT"

echo "detected: $(jq -r '.language + " / " + .framework' "$OUT")"
