#!/usr/bin/env bash
# Repository-wide index of declared symbols, one `path:line: declaration` per line.
#
# A step sees only its own allowlisted files plus the context files the gate named,
# so anything it needs that lives elsewhere is invisible to it. The observed failure
# mode is not a wrong answer but a redundant one: a coder writes a helper that already
# exists two files away, and the duplication survives review because no single diff
# shows both copies. This index is the cheapest fix — names and signatures only, no
# bodies, so it stays small enough to prepend to every coder call.
set -euo pipefail
CONFIG=.pipeline/toolchain.json
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG; run pipeline/detect.sh" >&2; exit 1; }

MAX_FILES="${PIPELINE_SYMBOL_INDEX_FILES:-150}"
MAX_LINES="${PIPELINE_SYMBOL_INDEX_LINES:-400}"

language=$(jq -r '.language' "$CONFIG" | tr -d '\r')
source_regex=$(jq -r '.source_regex' "$CONFIG" | tr -d '\r')

# One declaration pattern per language, shared with tests.sh so the tester and the
# coder are shown the same view of the codebase.
case "$language" in
  python) declaration='^(async[[:space:]]+def|def|class)[[:space:]]' ;;
  javascript|typescript) declaration='(^|[[:space:]])(export[[:space:]]+)?(async[[:space:]]+)?(function|class|interface|type|const)[[:space:]]' ;;
  go) declaration='^(func|type|const|var)[[:space:]]' ;;
  rust) declaration='^(pub([[:space:]]*\([^)]*\))?[[:space:]]+)?(fn|struct|enum|trait|type|const)[[:space:]]' ;;
  java|csharp) declaration='^[[:space:]]*(public|protected)[[:space:]].*(class|interface|enum|record|\()' ;;
  *) declaration='^[[:space:]]*([A-Za-z_][A-Za-z0-9_:<>*&[:space:]]+)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' ;;
esac

# --declaration prints the pattern so callers can reuse it without duplicating the case.
if [[ "${1:-}" == --declaration ]]; then
  printf '%s\n' "$declaration"
  exit 0
fi

# Test files are excluded deliberately. A coder may not edit them, and their fixture
# helpers are the single largest source of noise in this index.
while IFS= read -r file; do
  rg --with-filename --no-heading -n "$declaration" "$file" 2>/dev/null || true
done < <(
  rg --files 2>/dev/null \
    | grep -E "$source_regex" \
    | grep -Ev '(^|/)(test|tests)/|(^|/)test_[^/]+|_test\.|\.test\.|\.spec\.' \
    | head -"$MAX_FILES"
) | head -"$MAX_LINES"
