#!/usr/bin/env bash
# Record a unit that failed, then decide between a retry and stopping.
#
# usage: campaign_fail.sh <unit-id> <halt|drift|regression|budget|error> <reason>
#
# Exit codes: 2 the unit is armed for another attempt, 3 the campaign stopped.
set -euo pipefail
ID="${1:-}"; CLASS="${2:-}"; shift 2 || true
REASON="$*"
[[ -n "$ID" && -n "$CLASS" && -n "$REASON" ]] || {
  echo "usage: campaign_fail.sh <unit-id> <halt|drift|regression|budget|error> <reason>" >&2; exit 1; }
case "$CLASS" in halt|drift|regression|budget|error) ;;
  *) echo "unknown failure class: $CLASS" >&2; exit 1 ;; esac
[[ -f .campaign/state.json ]] || { echo "no campaign" >&2; exit 1; }

CURRENT=$(jq -r '.current // ""' .campaign/state.json | tr -d '\r')
[[ "$CURRENT" == "$ID" ]] || { echo "REFUSED: current unit is '$CURRENT', not '$ID'" >&2; exit 1; }

ENTRY="$CLASS: $REASON"
PREV=$(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .failures[-1] // ""' .campaign/state.json)
ATTEMPTS=$(jq -r --arg id "$ID" '.units[] | select(.id == $id) | .attempts' .campaign/state.json)
MAX_ATTEMPTS="${PIPELINE_MAX_UNIT_ATTEMPTS:-2}"

# Impossible, in the three forms the campaign can actually recognise. A HALT is a
# decision nobody is there to supply, and the campaign is the stage that cannot
# ask. The same failure twice is a second run of the same inputs. Out of attempts
# is out of attempts.
STOP=""
[[ "$CLASS" == halt ]] && STOP="the unit needs a decision no answer in the brief supplies"
[[ -z "$STOP" && "$ENTRY" == "$PREV" ]] && STOP="the retry failed the same way; another attempt repeats it"
[[ -z "$STOP" ]] && ((ATTEMPTS >= MAX_ATTEMPTS)) && STOP="attempts spent ($ATTEMPTS of $MAX_ATTEMPTS)"

tmp=$(mktemp)
jq --arg id "$ID" --arg e "$ENTRY" --arg st "$([[ -n "$STOP" ]] && echo failed || echo pending)" '
  .units |= map(if .id == $id then .failures += [$e] | .status = $st else . end)
' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json

if [[ -n "$STOP" ]]; then
  tmp=$(mktemp)
  jq --arg r "$STOP" '.status = "stopped" | .stopped_because = $r' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json
  rm -f .campaign/unit_request.txt
  echo "STOPPED at $ID: $STOP"
  echo "  $ENTRY"
  echo "commits are left in place; nothing was reset"
  exit 3
fi

# Retry from where this unit began. The units before it committed and are kept.
BASE=$(tr -d '\r' < .campaign/unit_base)
if [[ "$(git rev-parse HEAD)" != "$BASE" ]]; then
  TAG="campaign-abandoned-$ID-$(date +%Y%m%d-%H%M%S)"
  git tag -f "$TAG" HEAD >/dev/null
  echo "abandoned attempt tagged $TAG ($(git rev-list --count "$BASE"..HEAD) commit(s))"
fi
git reset -q --hard "$BASE"
git clean -fdq -e .pipeline -e .campaign 2>/dev/null || true

tmp=$(mktemp)
jq '.current = null' .campaign/state.json > "$tmp" && mv "$tmp" .campaign/state.json
rm -f .campaign/unit_request.txt .campaign/unit_base

echo "RETRY $ID: worktree back at $BASE"
echo "  $ENTRY"
echo "next: run campaign_next again"
exit 2
