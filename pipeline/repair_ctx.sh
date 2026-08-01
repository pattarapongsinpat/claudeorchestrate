#!/usr/bin/env bash
# Brief for the main-session Opus repair of an escalated step.
#
# The repair runs in the session that already holds the request, the intent, and
# the plan, so this prints only what that session does not have: which step gave
# up, the exact bounds it must stay inside, and what the coder's last attempt hit.
# Writes .pipeline/repair_ctx.md and prints the step id.
set -euo pipefail
PLAN=.pipeline/plan_final.json
STATE=.pipeline/done.json
OUT=.pipeline/repair_ctx.md

[[ -f "$PLAN" ]] || { echo "no $PLAN" >&2; exit 1; }
[[ -f .pipeline/ESCALATE ]] || { echo "no .pipeline/ESCALATE — nothing to repair" >&2; exit 1; }

# done.json is the authority on which step failed. The ESCALATE marker is appended
# to by every failing step in a wave, so parsing it for the id would pick one of
# several arbitrarily.
mapfile -t STEPS < <(jq -r '.steps | to_entries[] | select(.value.status == "escalated") | .key' "$STATE" 2>/dev/null | tr -d '\r')
((${#STEPS[@]})) || { echo "no escalated step in $STATE" >&2; exit 1; }

# The routing gate resolves `.claude/routing-ack` against the working directory,
# which during a run is the project, not the runtime. Writing it here keeps the
# repair to one step and keeps the ack inside its freshness window, and the
# info/exclude line keeps it from dirtying a tree that waves.sh refuses to start on.
mkdir -p .claude
printf 'Routing: inline - escalation repair\n' > .claude/routing-ack
EXCLUDE="$(git rev-parse --git-path info/exclude)"
grep -Fqx '/.claude/routing-ack' "$EXCLUDE" 2>/dev/null || printf '/.claude/routing-ack\n' >> "$EXCLUDE"

{
  echo "# Escalated step repair"
  echo
  echo "Write ONLY the files listed under files_allowed. Do not touch tests or"
  echo "dependency manifests — the same bounds the coder had. Then run the mapped"
  echo "tests, commit, and mark the step repaired."
  echo
  for s in "${STEPS[@]}"; do
    echo "## Step $s"
    echo '```json'
    jq -r --arg id "$s" '.steps[] | select(.id == $id)' "$PLAN"
    echo '```'
    echo
    echo "### Current contents of files_allowed"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      echo "#### $f"
      echo '```'
      cat "$f" 2>/dev/null || echo "[does not exist yet]"
      echo '```'
    done < <(jq -r --arg id "$s" '.steps[] | select(.id == $id) | .files_allowed[]' "$PLAN" | tr -d '\r')
    echo
  done
  echo "## Why the coder gave up"
  echo '```'
  cat .pipeline/ESCALATE
  echo '```'
} > "$OUT"

printf '%s\n' "${STEPS[@]}"
