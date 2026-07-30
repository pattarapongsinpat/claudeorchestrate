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
#
# Exit codes: 0 applied, 1 scope violation, 2 unsafe allowlist, 3 malformed output.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_HOME/pipeline/path_safety.sh"
OUT="$1"; shift

# Markers are matched after stripping CR and trailing blanks: a CRLF response
# whose ENDFILE line failed an exact match used to parse as zero blocks, write
# nothing, and exit 0. Leading "./" is normalized so ./x and x are one path.
norm() {
  local p="${1%$'\r'}"
  p="${p%"${p##*[![:space:]]}"}"
  printf '%s' "${p#./}"
}

declare -A OK=()

for f in "$@"; do
  p="$(norm "$f")"
  [[ -z "$p" ]] && continue
  # The allowlist comes from the gate, but a traversal or absolute path must
  # never reach the write below.
  safe_repo_path "$p" || { echo "refusing unsafe allowlist path: $p" >&2; exit 2; }
  has_symlink_component "$p" && { echo "refusing symlinked allowlist path: $p" >&2; exit 2; }
  OK["$p"]=1
done

viol=0; malformed=0; path=""; tmp=""; write_tmp=""
# Use `if`, not `&&`: a trailing `&& rm` that short-circuits returns 1, and an
# EXIT trap's non-zero status leaks out as the script's exit code.
cleanup(){
  if [[ -n "$tmp" && -f "$tmp" ]]; then rm -f "$tmp"; fi
  if [[ -n "$write_tmp" && -f "$write_tmp" ]]; then rm -f "$write_tmp"; fi
}
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  marker="$(norm "$line")"
  case "$marker" in
    "<<<<<<< FILE "*)
      if [[ -n "$path" ]]; then
        echo "unterminated block: $path (missing >>>>>>> ENDFILE)" >&2
        malformed=1; rm -f "$tmp"; tmp=""
      fi
      path="$(norm "${marker#<<<<<<< FILE }")"
      tmp="$(mktemp)"; : > "$tmp"
      ;;
    ">>>>>>> ENDFILE")
      if [[ -z "$path" ]]; then continue; fi
      if [[ -n "${OK[$path]:-}" ]]; then
        has_symlink_component "$path" && { echo "refusing symlinked output path: $path" >&2; exit 2; }
        parent=$(dirname "$path")
        mkdir -p "$parent"
        write_tmp=$(mktemp "$parent/.pipeline-write.XXXXXX")
        cp "$tmp" "$write_tmp"
        [[ ! -e "$path" ]] || chmod --reference="$path" "$write_tmp"
        mv -f "$write_tmp" "$path"
        write_tmp=""
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

# A block left open at EOF means a truncated response, not an applied file.
if [[ -n "$path" ]]; then
  echo "unterminated block: $path (missing >>>>>>> ENDFILE)" >&2
  malformed=1
fi

((viol)) && exit 1
((malformed)) && exit 3
exit 0
