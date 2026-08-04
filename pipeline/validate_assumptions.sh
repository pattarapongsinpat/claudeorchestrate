#!/usr/bin/env bash
# Grades the isolated assumption check and enforces the revision budget. Left as
# prose the stage becomes "revise until the subagent says SOUND", which is the
# self-report this check replaced.
set -euo pipefail

VERDICT_FILE="${1:-.pipeline/assumptions.md}"
MAX_REVISIONS="${PIPELINE_MAX_ASSUMPTION_REVISIONS:-1}"
[[ -f "$VERDICT_FILE" ]] || { echo "missing assumption verdict: $VERDICT_FILE" >&2; exit 1; }

mapfile -t lines < <(tr -d '\r' < "$VERDICT_FILE")
((${#lines[@]} == 1)) || { echo "invalid assumption verdict: expected exactly one line" >&2; exit 1; }

dir=$(dirname "$VERDICT_FILE")

case "${lines[0]}" in
  SOUND)
    echo SOUND
    exit 0
    ;;
  "UNSOUND: "?*)
    # Archiving each rejection makes the count the budget, so no stage has to
    # remember how many times it already tried.
    n=1
    while [[ -e "$dir/assumptions-$n.md" ]]; do ((n++)); done
    mv "$VERDICT_FILE" "$dir/assumptions-$n.md"
    printf '%s\n' "${lines[0]}"
    if ((n > MAX_REVISIONS)); then
      printf 'assumptions rejected %d times; the request is underspecified\n%s\n' \
        "$n" "${lines[0]}" > "$dir/HALT"
      echo "assumption revision budget exhausted after $n rejections" >&2
      exit 3
    fi
    exit 2
    ;;
  *)
    echo "invalid assumption verdict: ${lines[0]}" >&2
    exit 1
    ;;
esac
