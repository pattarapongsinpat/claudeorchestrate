#!/usr/bin/env bash
# usage: ctx.sh [--writable] <file>... > context.md
set -euo pipefail

WRITABLE=0
[[ "${1:-}" == "--writable" ]] && { WRITABLE=1; shift; }

# Exact repository-relative paths in this file are never sent to a model.
# A writable excluded file is fatal because the coder cannot safely reproduce it.
MODEL_EXCLUDE=.pipeline-model-exclude
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|(sk|pk)_(live|test)_[A-Za-z0-9_-]{16,}|(sk|pk)-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|(api[_-]?key|secret|passwd|password|token|credential|accountkey|aws_secret_access_key)[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:]#;]{16,}'
REDACTION='(line redacted: possible credential)'
blocked=0

is_explicitly_excluded() {
  local candidate="$1"
  [[ -f "$MODEL_EXCLUDE" ]] || return 1
  tr -d '\r' < "$MODEL_EXCLUDE" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | grep -Fxq -- "$candidate"
}

block_writable() {
  local file="$1" reason="$2"
  echo "(withheld: $reason)"
  echo "REFUSING to send writable file $file: $reason" >&2
  blocked=1
}

for original in "$@"; do
  [[ -z "$original" ]] && continue
  f="${original#./}"
  echo "### $f"

  if is_explicitly_excluded "$f"; then
    if ((WRITABLE)); then block_writable "$f" "listed in $MODEL_EXCLUDE"; else echo "(excluded by $MODEL_EXCLUDE)"; fi
    echo
    continue
  fi

  case "$(basename "$f")" in
    .env|.env.*|*.pem|*.key|id_rsa|id_ed25519|*.p12|*.pfx|credentials|credentials.*|secrets|secrets.*)
      if ((WRITABLE)); then block_writable "$f" "secret-bearing path"; else echo "(redacted: secret-bearing path)"; fi
      echo
      continue
      ;;
  esac

  if [[ ! -f "$f" ]]; then
    echo "(does not exist: create it)"
    echo
    continue
  fi

  if [[ -s "$f" ]] && ! grep -Iq '' "$f" 2>/dev/null; then
    if ((WRITABLE)); then block_writable "$f" "binary content"; else echo "(withheld: binary content)"; fi
    echo
    continue
  fi

  hit=0
  grep -qEi -e "$SECRET_RE" "$f" 2>/dev/null && hit=1
  if ((hit && WRITABLE)); then
    block_writable "$f" "credential pattern detected"
    grep -nEi -e "$SECRET_RE" "$f" | cut -d: -f1 | sed 's/^/  matching line /' >&2
    echo
    continue
  fi

  echo '```'
  if ((hit)); then
    sed -E "/$SECRET_RE/I s/.*/$REDACTION/" "$f" | cat -n
  else
    cat -n "$f"
  fi
  echo '```'
  echo
done

((blocked)) && {
  echo "Remove the file from files_allowed or list it in $MODEL_EXCLUDE as read-only context." >&2
  exit 3
}
exit 0
