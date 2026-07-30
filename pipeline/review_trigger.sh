#!/usr/bin/env bash
# Decides mechanically whether /review is warranted. Exits 0 (review) or 1 (skip)
# and prints the reasons, so the orchestration step is not a judgement call.
set -euo pipefail
reasons=()

# Persistent run history survives escalation recovery and later waves.
if [[ -f .pipeline/done.json ]]; then
  while IFS=$'\t' read -r step attempts escalated; do
    [[ -n "$step" ]] || continue
    [[ "$escalated" == true ]] && reasons+=("$step escalated during this run")
    ((attempts > 1)) && reasons+=("$step needed more than one attempt")
  done < <(jq -r '.steps | to_entries[] | [.key, (.value.attempts // 0), (.value.ever_escalated // false)] | @tsv' .pipeline/done.json | tr -d '\r')
fi

# A step that needed more than one attempt got there by reacting to test output,
# which is how a weak model arrives at code that passes without being right.
for log in .pipeline/logs/*.log; do
  [[ -f "$log" ]] || continue
  step=$(basename "$log" .log)
  if ! jq -e --arg step "$step" '.steps[$step] != null' .pipeline/done.json >/dev/null 2>&1 \
      && grep -qE 'iteration [2-9]' "$log"; then
    reasons+=("$step needed more than one attempt")
  fi
  if grep -q '^NOOP' "$log"; then
    reasons+=("$step claimed the work was already done")
  fi
done

# Tests that were green before the step ran did not gate it.
for warn in .pipeline/WARN_*; do
  [[ -f "$warn" ]] && reasons+=("$(basename "$warn" | sed 's/^WARN_//') was not gated by its tests")
done

# The same file edited by two steps is where conflicting assumptions land.
if [[ -f .pipeline/touched.log ]]; then
  while read -r f; do
    [[ -n "$f" ]] && reasons+=("$f was touched by more than one step")
  done < <(sort .pipeline/touched.log | uniq -d)
fi

if ((${#reasons[@]})); then
  printf 'review triggered:\n'
  printf '  - %s\n' "${reasons[@]}"
  exit 0
fi
echo "no review trigger: every step passed first try, gated by its own tests, on its own files"
exit 1
