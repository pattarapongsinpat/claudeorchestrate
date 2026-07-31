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
if [[ "$(jq -r '.generated_tests' .pipeline/toolchain.json | tr -d '\r')" == true ]]; then
  RUN_ID=$(date +%Y%m%d-%H%M%S)
  tmp=$(mktemp)
  jq --arg run "$RUN_ID" '
    .generated_test_file |= (
      if . == "" or . == null then .
      else sub("(?<stem>[^/]+?)(?<ext>(\\.[^./]+)+)$"; "\(.stem).\($run)\(.ext)")
      end)
  ' .pipeline/toolchain.json > "$tmp" && mv "$tmp" .pipeline/toolchain.json
  echo "generated tests: $(jq -r '.generated_test_file' .pipeline/toolchain.json)"
fi
echo "run: $(date -Iseconds)"
echo "base: $(cat .pipeline/run_base)"
echo "next: open Claude in this project and run /build <request>"
