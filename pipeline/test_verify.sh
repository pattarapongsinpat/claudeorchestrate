#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

printf 'ACCEPT\n' > "$WORK/verdict"
[[ "$(bash "$PIPELINE_HOME/pipeline/validate_verify.sh" "$WORK/verdict")" == ACCEPT ]]

printf 'DRIFT: changed an API outside the request\n' > "$WORK/verdict"
rc=0
bash "$PIPELINE_HOME/pipeline/validate_verify.sh" "$WORK/verdict" >/dev/null || rc=$?
[[ "$rc" == 2 ]]

for invalid in '' 'accept' 'DRIFT:' 'ACCEPT extra'; do
  printf '%s\n' "$invalid" > "$WORK/verdict"
  ! bash "$PIPELINE_HOME/pipeline/validate_verify.sh" "$WORK/verdict" >/dev/null 2>&1
done
printf 'ACCEPT\nextra\n' > "$WORK/verdict"
! bash "$PIPELINE_HOME/pipeline/validate_verify.sh" "$WORK/verdict" >/dev/null 2>&1

echo "verifier gate tests passed"
