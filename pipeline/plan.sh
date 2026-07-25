#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }
mapfile -t INTENT_FILES < <(jq -r '.allowed_files[]' .pipeline/intent.json | tr -d '\r')

# Per-invocation scratch, not a fixed /tmp path: two runs in different repos
# would otherwise share the file.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

{
  cat .pipeline/intent.md
  echo
  echo "## Repository structure"
  rg --files | head -200
  echo
  echo "## Files in scope — current contents"
  "$PIPELINE_HOME/pipeline/ctx.sh" "${INTENT_FILES[@]}"
} > "$WORK/pin.md"

"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/planner.txt" "$WORK/pin.md" deepseek-v4-pro > .pipeline/plan.md
