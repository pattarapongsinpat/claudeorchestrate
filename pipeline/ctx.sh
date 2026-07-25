#!/usr/bin/env bash
# usage: ctx.sh [--writable] <file>... > context.md
#
# Secret handling differs by whether the model may write the file back:
#
#   read-only context  — matching LINES are redacted; the rest is still useful.
#   --writable         — redaction is unsafe. The coder reproduces the whole file,
#                        so it would write the placeholder back and destroy the
#                        real credential. A hit is fatal instead; the caller stops.
#
# PIPELINE_ALLOW_SECRETS=1 downgrades the fatal case to a warning, for a repo
# where the matches are known false positives.
set -euo pipefail

WRITABLE=0
[[ "${1:-}" == "--writable" ]] && { WRITABLE=1; shift; }

# High-signal patterns only. A bare "password" mention is not enough; the
# assignment has to carry a long literal.
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abprs]-[A-Za-z0-9-]{10,}|(sk|pk)-[A-Za-z0-9_-]{20,}|(api[_-]?key|secret|passwd|password|token|credential)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{16,}'
REDACTION='(line redacted — possible credential)'

blocked=0

for f in "$@"; do
  [[ -z "$f" ]] && continue
  echo "### $f"
  case "$(basename "$f")" in
    .env|.env.*|*.pem|*.key|id_rsa|id_ed25519|*.p12|*.pfx|credentials|credentials.*|secrets|secrets.*)
      echo "(redacted — secret-bearing path, excluded from model context and raw logs)"
      echo
      continue ;;
  esac

  if [[ ! -f "$f" ]]; then
    echo "(does not exist — create it)"
    echo
    continue
  fi

  hit=0
  grep -qEi -e "$SECRET_RE" "$f" 2>/dev/null && hit=1

  if ((hit && WRITABLE)) && [[ -z "${PIPELINE_ALLOW_SECRETS:-}" ]]; then
    echo "(withheld — matches a credential pattern and this step may rewrite it)"
    echo
    { echo "REFUSING to send $f: it matches a secret pattern and the step may rewrite it."
      grep -nEi -e "$SECRET_RE" "$f" | cut -c1-60 | sed 's/^/  /'
    } >&2
    blocked=1
    continue
  fi

  echo '```'
  if ((hit && !WRITABLE)); then
    sed -E "/$SECRET_RE/I s/.*/$REDACTION/" "$f" | cat -n
  else
    ((hit)) && echo "WARN: $f matches a secret pattern; sent because PIPELINE_ALLOW_SECRETS is set" >&2
    cat -n "$f"
  fi
  echo '```'
  echo
done

((blocked)) && {
  echo "Set PIPELINE_ALLOW_SECRETS=1 to send it anyway." >&2
  exit 3
}
exit 0
