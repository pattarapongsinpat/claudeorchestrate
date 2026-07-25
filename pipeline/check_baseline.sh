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

mapfile -t collect < <(jq -r '.collect_command[]?' "$CONFIG" | tr -d '\r')
if ((${#collect[@]})); then
  if ! "${collect[@]}" > .pipeline/collect.out 2>&1; then
    { echo "the test suite does not load, so no step can ever pass:"
      tail -30 .pipeline/collect.out
    } > .pipeline/HALT
    echo "HALT: test suite fails to collect — see .pipeline/HALT" >&2
    exit 1
  fi
fi

if "$PIPELINE_HOME/pipeline/run_tests.sh" > .pipeline/baseline.out 2>&1; then
  [[ "$generated" == true ]] &&
    halt "baseline is green before implementation; the generated tests assert nothing"
  echo "baseline green (existing-suite adapter) — proceeding"
  exit 0
fi

echo "baseline red — proceeding"
tail -5 .pipeline/baseline.out
