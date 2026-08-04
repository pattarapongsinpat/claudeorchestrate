#!/usr/bin/env bash
# Hand the next pending unit to /build.
#
# Exit codes are authoritative: 0 a unit is ready, 3 the campaign is complete,
# 1 stopped or broken.
set -euo pipefail
[[ -f .campaign/state.json ]] || { echo "no campaign — run campaign_init first" >&2; exit 1; }
[[ -f .campaign/backlog.json ]] || { echo "missing .campaign/backlog.json" >&2; exit 1; }

STATUS=$(jq -r '.status' .campaign/state.json | tr -d '\r')
case "$STATUS" in
  running) ;;
  complete) echo "campaign already complete"; exit 3 ;;
  *) echo "campaign is $STATUS; not resuming" >&2; exit 1 ;;
esac

if [[ -n "$(git status --porcelain)" ]]; then
  echo "a unit cannot start on a dirty worktree" >&2
  git status --short >&2
  exit 1
fi

ID=$(jq -r 'first(.units[] | select(.status == "pending") | .id) // ""' .campaign/state.json | tr -d '\r')
if [[ -z "$ID" ]]; then
  tmp=$(mktemp)
  jq '.status = "complete" | .current = null' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json
  rm -f .campaign/unit_request.txt
  echo "all units done"
  exit 3
fi

MAX_ATTEMPTS="${PIPELINE_MAX_UNIT_ATTEMPTS:-2}"
ATTEMPTS=$(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .attempts' .campaign/state.json)
((ATTEMPTS < MAX_ATTEMPTS)) || {
  echo "REFUSED: $ID already used $ATTEMPTS attempt(s) (limit $MAX_ATTEMPTS)" >&2
  exit 1
}

# The unit's own base, so a retry resets to where this unit started rather than
# to the campaign base, which would discard the units that already succeeded.
git rev-parse HEAD > .campaign/unit_base

{
  echo "## Campaign brief (verbatim)"
  echo
  cat .campaign/brief.txt
  echo
  echo "## This unit (pipeline decomposition, not the user's words)"
  echo
  # Marked, because it is not the user's text. The assumption check and the final
  # verifier both read this file and nothing else; unmarked, they would grade the
  # decomposition against itself and the brief would never be read.
  jq -r --arg id "$ID" '.units[] | select(.id == $id) | "\(.id): \(.title)\n\n\(.request)"' .campaign/backlog.json
  PREV=$(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .failures[-1] // ""' .campaign/state.json)
  if [[ -n "$PREV" ]]; then
    echo
    echo "## Previous attempt failed (verbatim)"
    echo
    printf '%s\n' "$PREV"
  fi
} > .campaign/unit_request.txt

tmp=$(mktemp)
jq --arg id "$ID" '
  .current = $id
  | .units |= map(if .id == $id then .attempts += 1 else . end)
' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json

echo "unit: $ID ($(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .title' .campaign/state.json))"
echo "attempt: $(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .attempts' .campaign/state.json) of $MAX_ATTEMPTS"
echo "base: $(cat .campaign/unit_base)"
echo "next: run the full /build workflow; intent reads .campaign/unit_request.txt and asks nothing"
