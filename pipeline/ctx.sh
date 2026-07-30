#!/usr/bin/env bash
# usage: ctx.sh [--writable] <file>... > context.md
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"

WRITABLE=0
[[ "${1:-}" == "--writable" ]] && { WRITABLE=1; shift; }

# Exact repository-relative paths in this file are never sent to a model.
# A writable excluded file is fatal because the coder cannot safely reproduce it.
MODEL_EXCLUDE=.pipeline-model-exclude
MODEL_ALLOW=.pipeline-model-allow
SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|github_pat_[A-Za-z0-9_]{40,}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|(sk|pk)_(live|test)_[A-Za-z0-9_-]{16,}|(sk|pk)-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|(api[_-]?key|secret|passwd|password|token|credential|accountkey|aws_secret_access_key)[[:space:]]*[:=][[:space:]]*["'"'"']?[^"'"'"'[:space:]#;]{16,}'
REDACTION='(line redacted: possible credential)'
blocked=0

line_hash() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

is_reviewed_match() {
  local file="$1" hash="$2"
  [[ -f "$MODEL_ALLOW" ]] || return 1
  tr -d '\r' < "$MODEL_ALLOW" | grep -Fxq -- "$hash  $file"
}

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

  if ! safe_repo_path "$f"; then
    if ((WRITABLE)); then block_writable "$f" "unsafe repository path"; else echo "(withheld: unsafe repository path)"; fi
    echo
    continue
  fi

  if has_symlink_component "$f"; then
    if ((WRITABLE)); then block_writable "$f" "symlinked path"; else echo "(withheld: symlinked path)"; fi
    echo
    continue
  fi

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

  unreviewed=0
  sanitized=$(mktemp)
  cp "$f" "$sanitized"
  while IFS=: read -r number content; do
    [[ -n "$number" ]] || continue
    line=$(sed -n "${number}p" "$f")
    hash=$(line_hash "$line")
    if ! is_reviewed_match "$f" "$hash"; then
      unreviewed=1
      sed -i "${number}s/.*/$REDACTION/" "$sanitized"
      if ((WRITABLE)); then
        echo "  matching line $number; approve reviewed line with:" >&2
        echo "  $hash  $f" >&2
      fi
    fi
  done < <(grep -nEi -e "$SECRET_RE" "$f" 2>/dev/null || true)

  if ((unreviewed && WRITABLE)); then
    block_writable "$f" "credential pattern detected"
    rm -f "$sanitized"
    echo
    continue
  fi

  echo '```'
  if ((unreviewed)); then
    cat -n "$sanitized"
  else
    cat -n "$f"
  fi
  rm -f "$sanitized"
  echo '```'
  echo
done

((blocked)) && {
  echo "Remove the file from files_allowed or list it in $MODEL_EXCLUDE as read-only context." >&2
  exit 3
}
exit 0
