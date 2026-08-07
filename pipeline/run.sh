#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "run this inside a git repository" >&2; exit 1; }
EXCLUDE=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$EXCLUDE")"
grep -Fxq '/.pipeline/' "$EXCLUDE" 2>/dev/null || printf '\n/.pipeline/\n' >> "$EXCLUDE"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "run requires a clean worktree" >&2
  git status --short >&2
  exit 1
fi
rm -rf .pipeline && mkdir -p .pipeline
git rev-parse HEAD > .pipeline/run_base
"$PIPELINE_HOME/pipeline/detect.sh"

# Scope the generated test path to this run. tests.sh refuses to overwrite an
# existing file — correctly, since the previous run's tests are now part of the
# suite — but with a fixed name that refusal stops the second run of any project
# dead until someone renames the file by hand. A per-run name never collides, and
# the accumulated files are exactly the growing test suite.
#
# The run id may not be pasted in wherever it fits. A file name is an input to
# the toolchain twice over, and both readings constrain it:
#
#   As an identifier. Python derives the module name from the stem, Rust the
#   integration-test crate name, Java the public class name. `.20260101-120000.`
#   is not an identifier in any of them, so pytest reported ModuleNotFoundError
#   and collected nothing, and check_baseline HALTed the run before a coder ever
#   ran. The separator is therefore `_` and the id itself carries no `-`.
#
#   As a suffix the runner matches on. `go test` only compiles `*_test.go`, and
#   Maven's surefire only runs `*Test.java`; appending the id after the stem
#   destroys both, and the generated tests are silently never executed — the
#   worse failure, because the suite passes. Those two get the id inserted
#   *before* the suffix. The `.test.js` family is already safe: the existing
#   extension-chain pattern treats the whole chain as the extension.
if [[ "$(jq -r '.generated_tests' .pipeline/toolchain.json | tr -d '\r')" == true ]]; then
  RUN_ID=$(date +%Y%m%d_%H%M%S)
  case "$(jq -r '.generated_test_file' .pipeline/toolchain.json | tr -d '\r')" in
    *_test.go)   scope='sub("_test(?<ext>\\.go)$";     "_\($run)_test\(.ext)")' ;;
    *Test.java)  scope='sub("Test(?<ext>\\.java)$";    "_\($run)Test\(.ext)")' ;;
    *)           scope='sub("(?<stem>[^/]+?)(?<ext>(\\.[^./]+)+)$"; "\(.stem)_\($run)\(.ext)")' ;;
  esac
  tmp=$(mktemp)
  jq --arg run "$RUN_ID" "
    .generated_test_file |= (
      if . == \"\" or . == null then .
      else $scope
      end)
  " .pipeline/toolchain.json > "$tmp" && mv "$tmp" .pipeline/toolchain.json
  echo "generated tests: $(jq -r '.generated_test_file' .pipeline/toolchain.json)"
fi
echo "run: $(date -Iseconds)"
echo "base: $(cat .pipeline/run_base)"
echo "next: open Claude in this project and run /build <request>"
