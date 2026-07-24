#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }
mapfile -t INTENT_FILES < <(jq -r '.allowed_files[]' .pipeline/intent.json | tr -d '\r')

{
  cat .pipeline/intent.md
  echo
  echo "## Repository structure"
  rg --files | head -200
  echo
  echo "## Files in scope — current contents"
  "$PIPELINE_HOME/pipeline/ctx.sh" "${INTENT_FILES[@]}"
} > /tmp/pin.md

"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/planner.txt" /tmp/pin.md deepseek-v4-pro > .pipeline/plan.md
