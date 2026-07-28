#!/usr/bin/env bash
set -euo pipefail

VERDICT_FILE="${1:-.pipeline/verify.md}"
[[ -f "$VERDICT_FILE" ]] || { echo "missing verifier verdict: $VERDICT_FILE" >&2; exit 1; }

mapfile -t lines < <(tr -d '\r' < "$VERDICT_FILE")
((${#lines[@]} == 1)) || { echo "invalid verifier verdict: expected exactly one line" >&2; exit 1; }

case "${lines[0]}" in
  ACCEPT)
    echo ACCEPT
    exit 0
    ;;
  "DRIFT: "?*)
    echo "${lines[0]}"
    exit 2
    ;;
  *)
    echo "invalid verifier verdict: ${lines[0]}" >&2
    exit 1
    ;;
esac
