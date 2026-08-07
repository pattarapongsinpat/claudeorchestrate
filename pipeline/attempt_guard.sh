#!/usr/bin/env bash
# A hard cap on re-running a request that already failed.
#
# Every other budget here bounds something *inside* one run: repairs, restarts,
# format re-asks, a unit's attempts. Nothing bounded the run itself. A run that
# HALTs, DRIFTs, or regresses resets the worktree to its base, so the obvious
# next move is to type the same command again — free to the session, not free to
# the account, and the third identical failure carries the same diagnosis as the
# second. Three builds and two campaigns per request, then stop and read the
# evidence.
#
# usage: attempt_guard.sh <build|campaign> <request-file>
#        attempt_guard.sh --clear <build|campaign> <request-file>
#
# Exit codes: 0 the attempt is recorded and the stage may proceed, 3 the cap is
# spent and a HALT was written, 1 the invocation or the configuration is wrong.
set -euo pipefail

MODE=record
if [[ "${1:-}" == --clear ]]; then MODE=clear; shift; fi
SCOPE="${1:-}"; REQUEST="${2:-}"
[[ -n "$SCOPE" && -n "$REQUEST" ]] || {
  echo "usage: attempt_guard.sh [--clear] <build|campaign> <request-file>" >&2; exit 1; }
case "$SCOPE" in build|campaign) ;;
  *) echo "scope must be build or campaign (got: $SCOPE)" >&2; exit 1 ;; esac
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "run this inside a git repository" >&2; exit 1; }
[[ -s "$REQUEST" ]] || { echo "missing or empty $REQUEST" >&2; exit 1; }

case "$SCOPE" in
  build)
    MAX="${PIPELINE_MAX_BUILD_ATTEMPTS:-3}"; VAR=PIPELINE_MAX_BUILD_ATTEMPTS
    MARKER=.pipeline/attempt; HALT=.pipeline/HALT ;;
  campaign)
    MAX="${PIPELINE_MAX_CAMPAIGN_ATTEMPTS:-2}"; VAR=PIPELINE_MAX_CAMPAIGN_ATTEMPTS
    MARKER=.campaign/attempt; HALT=.campaign/HALT ;;
esac
{ [[ "$MAX" =~ ^[0-9]+$ ]] && ((MAX > 0)); } || {
  echo "$VAR must be a positive integer (got: $MAX)" >&2; exit 1; }

# A campaign unit is a build run, but its budget is the campaign's: the unit text
# carries the previous failure's excerpt, so every retry hashes differently and
# would be granted a fresh three. PIPELINE_MAX_UNIT_ATTEMPTS already bounds it.
if [[ "$SCOPE" == build && -f .campaign/state.json ]]; then
  if [[ "$(jq -r '.status // ""' .campaign/state.json | tr -d '\r')" == running ]]; then
    echo "campaign unit: attempts are bounded by the campaign, not per unit"
    exit 0
  fi
fi

# The key is the request itself, so a changed request is a new budget and an
# identical one is a repeat. Normalized the way baseline_stamp.sh normalizes:
# `\r` stripped, because a checkout under core.autocrlf rewrites every line
# ending without changing a byte the user typed.
NORM=$(tr -d '\r' < "$REQUEST" | sed -e 's/[[:space:]]*$//' -e '/./,$!d')
KEY=$(printf '%s\n%s\n' "$SCOPE" "$NORM" | sha256sum | cut -d' ' -f1)

# Outside the worktree, because both stages that consume this require a clean
# tree, and inside .git because the two directories that would otherwise hold it
# are the two that get deleted: run.sh removes .pipeline at the start of every
# run, and campaign_init.sh archives .campaign.
LEDGER=$(git rev-parse --git-path pipeline-attempts.json)
mkdir -p "$(dirname "$LEDGER")"
{ [[ -s "$LEDGER" ]] && jq -e . "$LEDGER" >/dev/null 2>&1; } || printf '{"entries":{}}\n' > "$LEDGER"

if [[ "$MODE" == clear ]]; then
  tmp=$(mktemp)
  jq --arg k "$KEY" 'del(.entries[$k])' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
  rm -f "$MARKER"
  echo "$SCOPE attempts cleared for this request"
  exit 0
fi

# Idempotent within a run. The consuming stages are re-run on a revision verdict,
# and a budget that counted revisions would be a different budget than the one
# documented. The marker lives in the directory the run owns, so the next run
# starts without it.
if [[ -f "$MARKER" ]]; then
  echo "$SCOPE attempt $(tr -d '\r' < "$MARKER") of $MAX (already recorded for this run)"
  exit 0
fi

COUNT=$(jq -r --arg k "$KEY" '.entries[$k].attempts // 0' "$LEDGER" | tr -d '\r')
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
N=$((COUNT + 1))

if ((N > MAX)); then
  FIRST=$(jq -r --arg k "$KEY" '.entries[$k].first // "?"' "$LEDGER")
  REASON="REFUSED: this request already used $COUNT $SCOPE attempt(s) (limit $MAX, first $FIRST)."
  [[ -d "$(dirname "$HALT")" ]] && {
    printf '%s\n' "$REASON" \
      "$MAX runs failed on the same text. Read the evidence rather than paying for a fourth." > "$HALT"
  }
  echo "$REASON" >&2
  echo "Three identical failures share one diagnosis. Read the archived attempts," >&2
  echo "then change the request, or set $VAR if the repeats are deliberate." >&2
  exit 3
fi

EXCERPT=$(printf '%s' "$NORM" | head -n 1 | cut -c1-120)
tmp=$(mktemp)
jq --arg k "$KEY" --arg now "$(date -Iseconds)" --arg ex "$EXCERPT" \
   --argjson n "$N" --argjson keep 50 '
  .entries[$k] = {
    attempts: $n,
    first: (.entries[$k].first // $now),
    last: $now,
    request: $ex
  }
  # Bounded, because nothing else prunes it and a repository accumulates requests
  # forever. Newest by last use; a request 50 requests old is not being retried.
  | .entries |= (to_entries | sort_by(.value.last) | reverse | .[0:$keep] | from_entries)
' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"

printf '%s\n' "$N" > "$MARKER"
echo "$SCOPE attempt $N of $MAX"
