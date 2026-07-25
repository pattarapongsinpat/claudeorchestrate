#!/usr/bin/env bash
# Token usage for the run, summed from the raw responses. Answers "what did that
# cost" without a separate ledger to keep in sync — the raw files are already
# copied back out of the parallel worktrees.
set -euo pipefail
shopt -s nullglob
raw=(.pipeline/raw/*.json)
((${#raw[@]})) || { echo "no calls recorded"; exit 0; }

jq -s -r '
  [ .[] | {
      model: (.model // "?"),
      prompt: (.usage.prompt_tokens // 0),
      completion: (.usage.completion_tokens // 0),
      truncated: (if .choices[0].finish_reason == "length" then 1 else 0 end)
    } ]
  | (group_by(.model)[] | "\(.[0].model)  calls=\(length)  in=\(map(.prompt)|add)  out=\(map(.completion)|add)  truncated=\(map(.truncated)|add)"),
    "TOTAL  calls=\(length)  in=\(map(.prompt)|add)  out=\(map(.completion)|add)"
' "${raw[@]}"
