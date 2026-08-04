#!/usr/bin/env bash
set -euo pipefail
[[ -f .campaign/state.json ]] || { echo "no campaign"; exit 1; }
jq -r '
  "campaign: \(.status)\(if .stopped_because then " (\(.stopped_because))" else "" end)",
  "base: \(.base)",
  (.units[] | "  \(.status | .[0:1] | ascii_upcase)  \(.id)  \(.title)\(if .attempts > 1 then "  [\(.attempts) attempts]" else "" end)")
' .campaign/state.json
