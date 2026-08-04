#!/usr/bin/env bash
# Check the backlog, then build the campaign state from it.
#
# The backlog is decomposed once, before any unit runs. A unit that discovers new
# work fails the campaign rather than growing it: the alternative is a scope that
# changes with nothing checking it against the brief.
set -euo pipefail
BACKLOG="${1:-.campaign/backlog.json}"

[[ -f .campaign/base ]] || { echo "no .campaign/base — run campaign_init first" >&2; exit 1; }
[[ -s .campaign/brief.txt ]] || { echo "missing or empty .campaign/brief.txt" >&2; exit 1; }
[[ -f "$BACKLOG" ]] || { echo "missing $BACKLOG" >&2; exit 1; }
jq -e . "$BACKLOG" >/dev/null 2>&1 || { echo "$BACKLOG is not valid JSON" >&2; exit 1; }

COUNT=$(jq '.units | length' "$BACKLOG")
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "backlog has no .units array" >&2; exit 1; }
((COUNT > 0)) || { echo "backlog has no units" >&2; exit 1; }

MAX_UNITS="${PIPELINE_MAX_CAMPAIGN_UNITS:-12}"
((COUNT <= MAX_UNITS)) || {
  echo "backlog has $COUNT units (limit $MAX_UNITS)." >&2
  echo "A campaign this long is a request that was never narrowed. Split it." >&2
  exit 1
}

# Every field a later stage reads must be present now. A unit missing its request
# text is discovered when its turn comes, after the units before it committed.
jq -e '
  .units | all(
    (.id? | type == "string" and test("^[A-Za-z0-9_-]+$")) and
    (.title? | type == "string" and length > 0) and
    (.request? | type == "string" and length > 0)
  )
' "$BACKLOG" >/dev/null || {
  echo "each unit needs id (word characters), title, and request" >&2
  exit 1
}

DUPES=$(jq -r '[.units[].id] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$BACKLOG")
[[ -z "$DUPES" ]] || { echo "duplicate unit ids: $DUPES" >&2; exit 1; }

jq -n --arg base "$(tr -d '\r' < .campaign/base)" \
      --arg started "$(date -Iseconds)" \
      --slurpfile b "$BACKLOG" '
  {base: $base, started: $started, status: "running", current: null,
   units: [$b[0].units[] | {id, title, status: "pending", attempts: 0,
                            commit: null, failures: []}]}
' > .campaign/state.json

echo "campaign: $COUNT unit(s)"
jq -r '.units[] | "  \(.id)  \(.title)"' .campaign/state.json
