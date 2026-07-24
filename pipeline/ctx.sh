#!/usr/bin/env bash
# usage: ctx.sh <file>... > context.md
set -euo pipefail
for f in "$@"; do
  [[ -z "$f" ]] && continue
  echo "### $f"
  case "$(basename "$f")" in
    .env|.env.*|*.pem|*.key|id_rsa|id_ed25519|*.p12|*.pfx|credentials|credentials.*|secrets|secrets.*)
      echo "(redacted — secret-bearing path, excluded from model context and raw logs)"
      echo
      continue ;;
  esac
  if [[ -f "$f" ]]; then
    echo '```'
    cat -n "$f"
    echo '```'
  else
    echo "(does not exist — create it)"
  fi
  echo
done
