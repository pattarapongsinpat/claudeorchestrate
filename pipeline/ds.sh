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

# Body goes to a file, not a pipe: curl must be able to replay it on retry.
REQ=$(mktemp)
trap 'rm -f "$REQ"' EXIT
# The coder contract is whole-file output, so the budget bounds the largest file the
# pipeline can rewrite. 8000 truncated mid-file on ordinary sources; 32000 is accepted.
MAX_TOKENS="${DS_MAX_TOKENS:-32000}"
# --rawfile, not --arg "$(cat ...)": command substitution puts the whole prompt on
# jq's command line, and a context of a few hundred KB exceeds the platform argv
# limit (32 KB on Windows) with "Argument list too long".
jq -n --arg m "$MODEL" --rawfile s "$1" --rawfile u "$2" \
  --argjson mt "$MAX_TOKENS" \
  '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],
    stream:false,max_tokens:$mt,temperature:0}' > "$REQ"

# Retry 429 and 5xx with backoff. Without this a single transient error kills
# the whole step (and, in waves, the run) with curl's raw exit code.
rc=0
curl -sS --fail-with-body --max-time 300 \
    --retry 4 --retry-delay 2 --retry-max-time 240 --retry-connrefused \
    https://api.deepseek.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -d @"$REQ" > "$RAW" || rc=$?
if ((rc)); then
  echo "deepseek request failed after retries (curl exit $rc, model $MODEL)" >&2
  head -c 500 "$RAW" >&2; echo >&2
  exit 1
fi

jq -r '.choices[0].message.content // "" | select(length>0)
       // (.choices[0].message.reasoning_content // "")' "$RAW" \
| sed -e 's/^```[a-z]*$//' -e 's/^```$//' \
| sed -e '/./,$!d'

# Exit 4, not 0, on a truncated response. A cut-off whole-file block is not a
# smaller edit — it is a file with its tail deleted, and callers must be able to
# tell that apart from a model that simply answered badly.
FIN=$(jq -r '.choices[0].finish_reason // "?"' "$RAW")
if [[ "$FIN" == "length" ]]; then
  echo "truncated at max_tokens=$MAX_TOKENS (model $MODEL): $RAW" >&2
  exit 4
fi
