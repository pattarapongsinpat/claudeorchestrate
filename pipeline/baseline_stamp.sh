#!/usr/bin/env bash
# The identity of whatever a baseline was measured against, so a later stage can
# tell whether the measurement still describes the tree.
#
# Content, never mtime. The gate commits the generated test file immediately after
# re-running the baseline, a checkout or a worktree copy rewrites mtimes without
# changing a byte, and filesystem timestamp granularity is coarse enough that two
# writes in the same second compare equal.
set -euo pipefail
CONFIG="${1:-.pipeline/toolchain.json}"
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

generated=$(jq -r '.generated_tests' "$CONFIG" | tr -d '\r')
test_file=$(jq -r '.generated_test_file // ""' "$CONFIG" | tr -d '\r')

if [[ "$generated" == true && -n "$test_file" ]]; then
  [[ -f "$test_file" ]] || { echo "missing generated test file: $test_file" >&2; exit 1; }
  # Normalized, not raw bytes. With core.autocrlf on Windows a checkout rewrites
  # every line ending without changing a single assertion, and a stamp that moved
  # on that would abort a legitimate resume.
  tr -d '\r' < "$test_file" | sha256sum | cut -d' ' -f1
else
  # Existing-suite and judgment adapters have no generated file to hash. The stamp
  # still has to exist, because its absence is what proves the stage was skipped.
  echo existing-suite
fi
