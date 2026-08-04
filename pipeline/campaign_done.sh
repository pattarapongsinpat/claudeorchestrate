#!/usr/bin/env bash
# Record a unit that finished and verified. Called after /build collapsed its
# commits, so HEAD is that unit's single commit.
set -euo pipefail
ID="${1:-}"
[[ -n "$ID" ]] || { echo "usage: campaign_done.sh <unit-id>" >&2; exit 1; }
[[ -f .campaign/state.json ]] || { echo "no campaign" >&2; exit 1; }

CURRENT=$(jq -r '.current // ""' .campaign/state.json | tr -d '\r')
[[ "$CURRENT" == "$ID" ]] || { echo "REFUSED: current unit is '$CURRENT', not '$ID'" >&2; exit 1; }

# A unit that changed nothing did not do its work. Marking it done would let the
# campaign walk to the end having built none of it.
BASE=$(tr -d '\r' < .campaign/unit_base)
if [[ "$(git rev-parse HEAD)" == "$BASE" ]]; then
  echo "REFUSED: $ID produced no commit (HEAD is still the unit base)" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "REFUSED: uncommitted changes after $ID" >&2
  git status --short >&2
  exit 1
fi

tmp=$(mktemp)
jq --arg id "$ID" --arg c "$(git rev-parse HEAD)" '
  .current = null
  | .units |= map(if .id == $id then .status = "done" | .commit = $c else . end)
' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json
rm -f .campaign/unit_request.txt .campaign/unit_base

REMAINING=$(jq '[.units[] | select(.status == "pending")] | length' .campaign/state.json)
echo "done: $ID"
echo "remaining: $REMAINING"
