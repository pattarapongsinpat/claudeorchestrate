#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }

# The assumption check is the only stage that reads the request against the
# intent, and nothing consumed its verdict, so going straight from intent to plan
# was silent. Every stage after this one inherits the intent's reading and agrees
# with it.
if [[ ! -f .pipeline/assumptions.md ]] ||
   [[ "$(head -1 .pipeline/assumptions.md | tr -d '\r')" != SOUND ]]; then
  echo "no SOUND assumption verdict; run check_assumptions before plan" >&2
  exit 1
fi

mapfile -t INTENT_FILES < <(jq -r '.allowed_files[]' .pipeline/intent.json | tr -d '\r')

# Per-invocation scratch, not a fixed /tmp path: two runs in different repos
# would otherwise share the file.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Intent already defines every file a coder may rewrite. Reject an unsafe target
# before paying for planning or creating worktrees.
if ! "$PIPELINE_HOME/pipeline/ctx.sh" --writable "${INTENT_FILES[@]}" \
    > "$WORK/intent_ctx.md" 2> "$WORK/intent_ctx.err"; then
  {
    echo "an intent-scoped writable file failed the model safety check:"
    cat "$WORK/intent_ctx.err"
  } > .pipeline/HALT
  cat "$WORK/intent_ctx.err" >&2
  echo "HALT: unsafe writable intent; see .pipeline/HALT" >&2
  exit 1
fi

{
  cat .pipeline/intent.md
  echo
  echo "## Repository structure"
  rg --files | head -200
  echo
  echo "## Files in scope — current contents"
  cat "$WORK/intent_ctx.md"
} > "$WORK/pin.md"

"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/planner.txt" "$WORK/pin.md" deepseek-v4-pro > .pipeline/plan.md
