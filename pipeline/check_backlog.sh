#!/usr/bin/env bash
# Grades the backlog against the brief alone, before any unit runs.
#
# The split is the highest-leverage reading in a campaign — get it wrong and every
# unit is misdirected — and it was the one reading nothing checked until the final
# verifier, after all of it had been built. Same shape as check_assumptions.sh, and
# for the same reason: a different model family reading the same English, given the
# brief and the units and nothing else.
#
# Exit codes: 0 SOUND, 2 revise the backlog and run again, 3 budget spent and HALT
# written, 1 malformed or broken.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .campaign/HALT ]] && { echo "campaign halted" >&2; exit 1; }
[[ -s .campaign/brief.txt ]] || { echo "missing or empty .campaign/brief.txt" >&2; exit 1; }
[[ -f .campaign/backlog.json ]] || { echo "missing .campaign/backlog.json" >&2; exit 1; }
jq -e '.units | length > 0' .campaign/backlog.json >/dev/null 2>&1 || {
  echo "backlog has no units; run validate_backlog first" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The brief whole, and the units as written. Not intent.md, not a plan, not the
# state file: everything else in a campaign is this same reading restated.
{
  echo "## Brief"
  echo
  cat .campaign/brief.txt
  echo
  echo "## Units, in order"
  echo
  jq -r '.units[] | "- \(.title)\n  \(.request)"' .campaign/backlog.json
} > "$WORK/input.md"

if [[ -n "${PIPELINE_BACKLOG_DRY:-}" ]]; then
  cat "$WORK/input.md"
  exit 0
fi

MODEL="${PIPELINE_BACKLOG_MODEL:-deepseek-v4-flash}"
case "$MODEL" in
  flash) MODEL=deepseek-v4-flash ;;
  pro)   MODEL=deepseek-v4-pro ;;
  deepseek-v4-flash|deepseek-v4-pro) ;;
  *) echo "PIPELINE_BACKLOG_MODEL must be flash or pro (got: $MODEL)" >&2; exit 1 ;;
esac

VERDICT=.campaign/backlog_verdict.md
"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/backlog.txt" \
  "$WORK/input.md" "$MODEL" | sed -e '/^[[:space:]]*$/d' > "$VERDICT"

exec "$PIPELINE_HOME/pipeline/validate_backlog_verdict.sh" "$VERDICT"
