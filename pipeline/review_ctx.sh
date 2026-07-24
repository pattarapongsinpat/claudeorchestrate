#!/usr/bin/env bash
# Full contents of every touched file, with a size fallback.
set -euo pipefail
MAXLINES=1500
OUT=.pipeline/review_ctx.md
BASE=$(cat .pipeline/step_base 2>/dev/null || cat .pipeline/run_base)
: > "$OUT"

for f in $(git diff --name-only "$BASE"..HEAD); do
  [[ -f "$f" ]] || continue
  LINES=$(wc -l < "$f")
  {
    echo "### $f  (${LINES} lines)"
    echo '```'
    if (( LINES <= MAXLINES )); then
      cat "$f"
    else
      echo "[file exceeds ${MAXLINES} lines — diff plus 60 lines of context]"
      git diff -U60 "$BASE"..HEAD -- "$f"
    fi
    echo '```'
    echo
  } >> "$OUT"
done

echo "review context: $(wc -l < "$OUT") lines"
