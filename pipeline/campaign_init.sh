#!/usr/bin/env bash
# Start a campaign: a fixed backlog of build-sized units, run one /build each.
#
# Campaign state lives in .campaign/, not .pipeline/. run.sh deletes .pipeline at
# the start of every unit, which is exactly what makes units stack cleanly, and
# is also why nothing that must survive a unit can live there.
set -euo pipefail
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "run this inside a git repository" >&2; exit 1; }

EXCLUDE=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$EXCLUDE")"
grep -Fxq '/.campaign/' "$EXCLUDE" 2>/dev/null || printf '\n/.campaign/\n' >> "$EXCLUDE"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "campaign requires a clean worktree" >&2
  git status --short >&2
  exit 1
fi

if [[ -f .campaign/state.json ]]; then
  STATUS=$(jq -r '.status' .campaign/state.json | tr -d '\r')
  if [[ "$STATUS" == running ]]; then
    echo "REFUSED: a campaign is already running (base $(jq -r .base .campaign/state.json))." >&2
    echo "Resume it with campaign_next, or archive .campaign/ to start over." >&2
    exit 1
  fi
  ARCHIVE=".campaign/finished-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARCHIVE"
  for f in brief.txt backlog.json state.json unit_request.txt; do
    [[ -f ".campaign/$f" ]] && mv ".campaign/$f" "$ARCHIVE/" || true
  done
  echo "previous campaign archived to $ARCHIVE"
fi

mkdir -p .campaign
# The per-campaign marker attempt_guard.sh writes. Left behind it would make the
# new campaign look like one whose attempt was already counted, so the guard
# would wave through every campaign after the first.
rm -f .campaign/attempt
git rev-parse HEAD > .campaign/base

echo "campaign base: $(cat .campaign/base)"
echo "next: write .campaign/brief.txt and .campaign/backlog.json, then run validate_backlog"
