#!/usr/bin/env bash
# Holds the backlog verdict, so the session that wrote the split cannot decide how
# much the rejection counts for. One line is the whole contract: a chatty answer is
# malformed, not a rejection, and only UNSOUND spends the budget.
set -euo pipefail
VERDICT_FILE="${1:-.campaign/backlog_verdict.md}"
[[ -f "$VERDICT_FILE" ]] || { echo "missing backlog verdict: $VERDICT_FILE" >&2; exit 1; }
DIR=$(dirname "$VERDICT_FILE")
MAX_REVISIONS="${PIPELINE_MAX_BACKLOG_REVISIONS:-1}"

mapfile -t lines < <(tr -d '\r' < "$VERDICT_FILE")
((${#lines[@]} == 1)) || { echo "invalid backlog verdict: expected exactly one line" >&2; exit 1; }

case "${lines[0]}" in
  SOUND)
    echo SOUND
    exit 0
    ;;
  "UNSOUND: "?*)
    # The rejection count is the file count. Nothing has to remember the budget.
    n=1; while [[ -e "$DIR/backlog-$n.md" ]]; do ((n++)); done
    mv "$VERDICT_FILE" "$DIR/backlog-$n.md"
    printf '%s\n' "${lines[0]}"
    if ((n > MAX_REVISIONS)); then
      printf 'backlog rejected %d times; the brief is underspecified\n%s\n' "$n" "${lines[0]}" > "$DIR/HALT"
      exit 3
    fi
    exit 2
    ;;
  *)
    echo "invalid backlog verdict: ${lines[0]}" >&2
    exit 1
    ;;
esac
