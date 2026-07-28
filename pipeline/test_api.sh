#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/system.txt" <<'EOF'
Reply with exactly PIPELINE_API_OK and nothing else.
EOF
cat > "$WORK/user.txt" <<'EOF'
Health check.
EOF

response=$(cd "$WORK" && "$PIPELINE_HOME/pipeline/ds.sh" system.txt user.txt deepseek-v4-flash)
[[ "$response" == PIPELINE_API_OK ]] || {
  echo "unexpected DeepSeek response: $response" >&2
  exit 1
}

echo "DeepSeek API test passed"
