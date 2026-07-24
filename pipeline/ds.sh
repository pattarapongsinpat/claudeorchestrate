#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DEEPSEEK_API_KEY:-}" && -f "$PIPELINE_HOME/.env" ]]; then
  set -a
  source "$PIPELINE_HOME/.env"
  set +a
fi
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY%$'\r'}"
[[ -n "${DEEPSEEK_API_KEY:-}" ]] || { echo "DEEPSEEK_API_KEY is not configured" >&2; exit 1; }
MODEL="${3:-deepseek-v4-pro}"
mkdir -p .pipeline/raw
RAW=".pipeline/raw/${MODEL}_$(date +%s%N).json"

jq -n --arg m "$MODEL" --arg s "$(cat "$1")" --arg u "$(cat "$2")" \
  '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],
    stream:false,max_tokens:8000,temperature:0}' \
| curl -sS --fail-with-body --max-time 300 \
    https://api.deepseek.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -d @- > "$RAW"

FIN=$(jq -r '.choices[0].finish_reason // "?"' "$RAW")
[[ "$FIN" == "length" ]] && echo "WARN truncated: $RAW" >&2

jq -r '.choices[0].message.content // "" | select(length>0)
       // (.choices[0].message.reasoning_content // "")' "$RAW" \
| sed -e 's/^```[a-z]*$//' -e 's/^```$//' \
| sed -e '/./,$!d'
