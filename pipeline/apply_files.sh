#!/usr/bin/env bash
# usage: apply_files.sh <coder_output> <allowed_file>...
# Parses whole-file blocks from the coder output and writes each one whose path
# is in the allowlist. A block outside the allowlist is NOT written; its path is
# printed and the script exits non-zero, so the caller reports a scope violation
# without any out-of-scope file ever touching disk.
#
# Block format (exact):
#   <<<<<<< FILE <path>
#   <full file contents>
#   >>>>>>> ENDFILE
set -euo pipefail
OUT="$1"; shift
# Strip CR so a CRLF allowlist or CRLF coder output still matches path keys.
declare -A OK=(); for f in "$@"; do OK["${f%$'\r'}"]=1; done

viol=0; path=""; tmp=""
# Use `if`, not `&&`: a trailing `&& rm` that short-circuits returns 1, and an
# EXIT trap's non-zero status leaks out as the script's exit code.
cleanup(){ if [[ -n "$tmp" && -f "$tmp" ]]; then rm -f "$tmp"; fi; }
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "<<<<<<< FILE "*)
      path="${line#<<<<<<< FILE }"
      path="${path%$'\r'}"
      path="$(printf '%s' "$path" | sed 's/[[:space:]]*$//')"
      tmp="$(mktemp)"; : > "$tmp"
      ;;
    ">>>>>>> ENDFILE")
      if [[ -z "$path" ]]; then continue; fi
      if [[ -n "${OK[$path]:-}" ]]; then
        mkdir -p "$(dirname "$path")"
        cp "$tmp" "$path"
      else
        echo "$path"; viol=1
      fi
      rm -f "$tmp"; tmp=""; path=""
      ;;
    *)
      [[ -n "$path" ]] && printf '%s\n' "$line" >> "$tmp"
      ;;
  esac
done < "$OUT"

exit $viol
