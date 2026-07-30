#!/usr/bin/env bash
# Runs the WHOLE suite after implementation.
#
# code.sh only runs each step's mapped tests, so a step can satisfy its own tests
# while breaking tests it was never pointed at. Nothing else in the chain would
# notice: review reads code, verify reads the diff, and neither runs anything.
# Adapters with selector_mode "none" already run everything per step; for every
# other adapter this is the only full-suite execution in the run.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verification_mode=$(jq -r '.verification_mode // "tests"' .pipeline/toolchain.json | tr -d '\r')

if "$PIPELINE_HOME/pipeline/run_tests.sh" > .pipeline/final.out 2>&1; then
  if [[ "$verification_mode" == judgment ]]; then
    echo "mechanical verification green; Opus judgment is still required"
  else
    echo "full suite green"
  fi
  exit 0
fi

if [[ "$verification_mode" == judgment ]]; then
  { echo "mechanical verification failed after implementation."
    echo "Opus judgment cannot replace a configured compile or validation command."
    echo
    tail -40 .pipeline/final.out
  } > .pipeline/REGRESSION
  echo "REGRESSION: mechanical verification failed — see .pipeline/REGRESSION" >&2
else
  { echo "the full suite is red after implementation."
    echo "Steps passed their own mapped tests, so this is a regression in tests no step"
    echo "was pointed at, or a generated test no step covered."
    echo
    tail -40 .pipeline/final.out
  } > .pipeline/REGRESSION
  echo "REGRESSION: full suite red after implementation — see .pipeline/REGRESSION" >&2
fi
tail -15 .pipeline/final.out >&2
exit 1
