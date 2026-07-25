#!/usr/bin/env bash
# Full contents of every touched file, with a size fallback.
set -euo pipefail
MAXLINES=1500
OUT=.pipeline/review_ctx.md
BASE=$(cat .pipeline/step_base 2>/dev/null || cat .pipeline/run_base)
: > "$OUT"

while IFS=$'\t' read -r status f newpath; do
  # A deletion has no file to cat, and skipping it hid removals from review
  # entirely — which is exactly where a bad deletion should surface.
  case "$status" in
    D*) { echo "### $f  (deleted)"
          echo '```'
          git diff "$BASE"..HEAD -- "$f"
          echo '```'
          echo
        } >> "$OUT"
        continue ;;
    R*) [[ -n "$newpath" ]] && f="$newpath" ;;
  esac
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
done < <(git diff --name-status "$BASE"..HEAD)

echo "review context: $(wc -l < "$OUT") lines"
