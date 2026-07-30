#!/usr/bin/env bash
set -euo pipefail

CONFIG=.pipeline/toolchain.json
INTENT=.pipeline/intent.json
[[ -f "$CONFIG" && -f "$INTENT" ]] || exit 0
[[ "$(jq -r '.generated_tests // false' "$CONFIG")" == true ]] || exit 0
[[ "$(jq -r '.test_project_coverage // "unknown"' "$CONFIG")" == explicit-links ]] || exit 0

missing=()
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  jq -e --arg file "$file" '.linked_source_files | index($file) != null' "$CONFIG" >/dev/null \
    || missing+=("$file")
done < <(jq -r '.allowed_files[] | select(test("\\.cs$"; "i"))' "$INTENT" | tr -d '\r')

if ((${#missing[@]})); then
  {
    echo "the detected source-linked C# test project cannot compile intent-scoped files:"
    printf '  %s\n' "${missing[@]}"
    echo "test project: $(jq -r '.test_project' "$CONFIG")"
    echo "add links, add a ProjectReference, or commit .pipeline-toolchain.json with the repository's real test and load commands"
  } > .pipeline/HALT
  cat .pipeline/HALT >&2
  exit 1
fi
