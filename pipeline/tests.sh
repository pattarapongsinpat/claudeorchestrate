#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }

# intent + signatures ONLY. Never the plan.
cat .pipeline/intent.md > /tmp/tin.md
{
  echo
  echo "## Existing interfaces"
  rg --no-heading -n '^(def |class |func |export function |type |interface )' src/ || true
} >> /tmp/tin.md

# Materialize the tests to a file pytest actually discovers. A spec that only
# lives in .pipeline/ gates nothing — the loop would run the repo's old tests
# and "pass" a step that changed the target behavior not at all.
mkdir -p tests
"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/tester.txt" /tmp/tin.md deepseek-v4-pro \
  | tee .pipeline/tests_spec.md > tests/test_generated.py
