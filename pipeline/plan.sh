#!/usr/bin/env bash
set -euo pipefail
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }

{
  cat .pipeline/intent.md
  echo
  echo "## Repository structure"
  rg --files | head -200
  echo
  echo "## Files in scope — current contents"
  ./pipeline/ctx.sh $(jq -r '.allowed_files[]' .pipeline/intent.json)
} > /tmp/pin.md

./pipeline/ds.sh prompts/planner.txt /tmp/pin.md deepseek-v4-pro > .pipeline/plan.md
