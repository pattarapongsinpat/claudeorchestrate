#!/usr/bin/env bash
# usage: apply_files.sh <coder_output> <allowed_file>...
# Parses whole-file blocks from the coder output and writes each one whose path
# is in the allowlist. A block outside the allowlist is NOT written; its path is
# printed and the script exits non-zero, so the caller reports a scope violation
# without any out-of-scope file ever touching disk.
#
# Block format:
#   <<<<<<< FILE <path>
#   <full file contents>
#   >>>>>>> ENDFILE
#
# The marker runs are matched as 4-12 repeats, not exactly 7. A model that
# emits six "<" produces a response that is complete and correct in every other
# respect, and an exact match turned that into zero parsed blocks, no write, and
# an "exhausted 3 iterations" escalation whose feedback said NO FILE BLOCKS
# FOUND — a formatting slip reported as a coding failure, at three API calls a
# time. The literal FILE and ENDFILE keywords are what make a marker a marker,
# so requiring an exact run length buys no safety.
#
# A single Markdown code fence wrapping the body is also tolerated, for the same
# reason: models fence code by habit, and the fence would otherwise land in the
# written file as line 1.
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

OPEN_RE='^<{4,12}[[:space:]]+FILE[[:space:]]+(.+)$'
CLOSE_RE='^>{4,12}[[:space:]]+ENDFILE[[:space:]]*$'
FENCE_RE='^```[A-Za-z0-9_+#-]*$'

viol=0; malformed=0; path=""; tmp=""; write_tmp=""; fenced=0; body=0
# Use `if`, not `&&`: a trailing `&& rm` that short-circuits returns 1, and an
# EXIT trap's non-zero status leaks out as the script's exit code.
cleanup(){
  if [[ -n "$tmp" && -f "$tmp" ]]; then rm -f "$tmp"; fi
  if [[ -n "$write_tmp" && -f "$write_tmp" ]]; then rm -f "$write_tmp"; fi
}
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  marker="$(norm "$line")"
  if [[ "$marker" =~ $OPEN_RE ]]; then
      if [[ -n "$path" ]]; then
        echo "unterminated block: $path (missing >>>>>>> ENDFILE)" >&2
        malformed=1; rm -f "$tmp"; tmp=""
      fi
      path="$(norm "${BASH_REMATCH[1]}")"
      tmp="$(mktemp)"; : > "$tmp"
      fenced=0; body=0
  elif [[ "$marker" =~ $CLOSE_RE ]]; then
      if [[ -z "$path" ]]; then continue; fi
      # Drop the closing fence of a body the model wrapped in Markdown.
      if ((fenced)) && [[ "$(norm "$(tail -n 1 "$tmp")")" =~ $FENCE_RE ]]; then
        sed -i '$d' "$tmp"
      fi
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
      rm -f "$tmp"; tmp=""; path=""; fenced=0; body=0
  elif [[ -n "$path" ]]; then
      # An opening fence on the first body line is the model's habit, not content.
      if ((body == 0)) && [[ "$marker" =~ $FENCE_RE ]]; then
        fenced=1; body=1; continue
      fi
      body=1
      printf '%s\n' "$line" >> "$tmp"
  fi
done < "$OUT"

# A block left open at EOF means a truncated response, not an applied file.
if [[ -n "$path" ]]; then
  echo "unterminated block: $path (missing >>>>>>> ENDFILE)" >&2
  malformed=1
fi

((viol)) && exit 1
((malformed)) && exit 3
exit 0
