#!/usr/bin/env bash
# Grades the intent's assumptions against the request alone, with a model from a
# different family than the session that wrote them. A Claude subagent would be
# fresh context but the same reader; a disagreement here is information. The call
# is small — a request and a short list — so it runs on flash.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }
[[ -f .pipeline/request.txt ]] || { echo "missing .pipeline/request.txt" >&2; exit 1; }
[[ -f .pipeline/intent.md ]] || { echo "missing .pipeline/intent.md" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Only the Assumptions section. The goal, non-goals, and allowlist are the same
# reading restated, so including them grades the intent against itself.
awk '/^#+[ \t]*Assumptions[ \t]*$/{f=1;next} f&&/^#/{exit} f' .pipeline/intent.md \
  | sed -e '/./,$!d' > "$WORK/assumptions.txt"
if [[ ! -s "$WORK/assumptions.txt" ]]; then
  echo "intent.md has no Assumptions section to check" >&2
  exit 1
fi

# request.txt whole, including the clarifications the intent stage recorded:
# those are the user's answers, not the intent's reading, so the grader gets them.
{
  echo "## Request"
  echo
  cat .pipeline/request.txt
  echo
  echo "## Assumptions"
  echo
  cat "$WORK/assumptions.txt"
} > "$WORK/input.md"

# Lets the offline suite exercise the extraction without an API key.
if [[ -n "${PIPELINE_ASSUMPTIONS_DRY:-}" ]]; then
  cat "$WORK/input.md"
  exit 0
fi

MODEL="${PIPELINE_ASSUMPTIONS_MODEL:-deepseek-v4-flash}"
case "$MODEL" in
  flash) MODEL=deepseek-v4-flash ;;
  pro)   MODEL=deepseek-v4-pro ;;
  deepseek-v4-flash|deepseek-v4-pro) ;;
  *) echo "PIPELINE_ASSUMPTIONS_MODEL must be flash or pro (got: $MODEL)" >&2; exit 1 ;;
esac

# One line is the whole contract, so a chatty answer is a malformed verdict and
# validate_assumptions.sh must see it as one rather than as a rejection.
"$PIPELINE_HOME/pipeline/ds.sh" "$PIPELINE_HOME/prompts/assumptions.txt" \
  "$WORK/input.md" "$MODEL" | sed -e '/^[[:space:]]*$/d' > .pipeline/assumptions.md

exec "$PIPELINE_HOME/pipeline/validate_assumptions.sh" .pipeline/assumptions.md
