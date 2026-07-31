#!/usr/bin/env bash
# Validates the pre-implementation baseline and HALTs when it is not usable.
#
# "The suite must be red" is not enough on its own. A suite that fails to load —
# a collection error in Python, a compile error elsewhere — also exits non-zero,
# and it means every step is unwinnable rather than merely unimplemented. This
# separates the two before any coder runs.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=.pipeline/toolchain.json
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG; run pipeline/detect.sh" >&2; exit 1; }

halt() { echo "$1" > .pipeline/HALT; echo "$1" >&2; exit 1; }

generated=$(jq -r '.generated_tests' "$CONFIG" | tr -d '\r')
test_file=$(jq -r '.generated_test_file // ""' "$CONFIG" | tr -d '\r')
verification_mode=$(jq -r '.verification_mode // "tests"' "$CONFIG" | tr -d '\r')

# Validate the repository's existing suite independently. Generated tests often
# reference APIs that do not exist yet and therefore cannot compile in Java, Go,
# Rust, or C# until implementation is complete.
held_test=""
restore_test() {
  if [[ -n "$held_test" && -f "$held_test" ]]; then
    mkdir -p "$(dirname "$test_file")"
    mv "$held_test" "$test_file"
  fi
}
trap restore_test EXIT
if [[ "$generated" == true && -n "$test_file" && -f "$test_file" ]]; then
  held_test=$(mktemp)
  mv "$test_file" "$held_test"
fi

if ! RUN_TESTS_LOAD=1 "$PIPELINE_HOME/pipeline/run_tests.sh" > .pipeline/load.out 2>&1; then
  { echo "the existing test suite does not load, so no step can reliably pass:"
    tail -30 .pipeline/load.out
  } > .pipeline/HALT
  echo "HALT: existing test suite fails to load; see .pipeline/HALT" >&2
  exit 1
fi
restore_test
held_test=""

# Pytest supports true collection, so also reject malformed generated tests.
mapfile -t collect < <(jq -r '.collect_command[]?' "$CONFIG" | tr -d '\r')
if ((${#collect[@]})); then
  if ! RUN_TESTS_COLLECT=1 "$PIPELINE_HOME/pipeline/run_tests.sh" > .pipeline/collect.out 2>&1; then
    { echo "the test suite does not load, so no step can ever pass:"
      tail -30 .pipeline/collect.out
    } > .pipeline/HALT
    echo "HALT: test suite fails to collect — see .pipeline/HALT" >&2
    exit 1
  fi
fi

if "$PIPELINE_HOME/pipeline/run_tests.sh" > .pipeline/baseline.out 2>&1; then
  if [[ "$verification_mode" == judgment ]]; then
    echo "mechanical baseline green; Opus will judge behavior directly"
    exit 0
  fi
  [[ "$generated" == true ]] &&
    halt "baseline is green before implementation; the generated tests assert nothing"
  echo "baseline green (existing-suite adapter) — proceeding"
  exit 0
fi

if [[ "$verification_mode" == judgment ]]; then
  echo "mechanical baseline red — proceeding so the requested change may repair it"
  tail -5 .pipeline/baseline.out
  exit 0
fi

# Red is not one state. A mapped assertion that does not hold yet is the whole
# point of the baseline; a generated test file that cannot execute is a defect in
# the test, and no implementation can satisfy it. Both exit non-zero and are
# indistinguishable from the exit code alone, so the run proceeds into three doomed
# coder attempts and reports "the code is wrong" about a broken fixture.
#
# These patterns mean the test file itself is broken:
#   ReferenceError / NameError  a helper or fixture used outside the scope it was declared in
#   SyntaxError / IndentationError / Unexpected token   the file does not parse
# A missing module is deliberately NOT here: the implementation has yet to create it,
# which is the expected shape of a red baseline.
BROKEN_PATTERNS='ReferenceError:|SyntaxError|IndentationError|Unexpected token|NameError: name'
if [[ "$generated" == true && -z "${PIPELINE_ALLOW_BROKEN_TESTS:-}" ]]; then
  if broken=$(grep -nE "$BROKEN_PATTERNS" .pipeline/baseline.out | head -20); then
    { echo "the generated tests do not execute, so no step can ever pass:"
      echo
      echo "$broken"
      echo
      echo "This is a defect in $test_file, not in the implementation. Fix the test file"
      echo "at the gate, then re-run check_baseline. Set PIPELINE_ALLOW_BROKEN_TESTS=1 to"
      echo "override when the pattern is a false positive, such as a test that asserts on"
      echo "an error message containing one of these words."
    } > .pipeline/HALT
    echo "HALT: generated tests fail to execute; see .pipeline/HALT" >&2
    exit 1
  fi
fi

echo "baseline red — proceeding"
tail -5 .pipeline/baseline.out
