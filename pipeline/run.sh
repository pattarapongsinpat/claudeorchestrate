#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "run this inside a git repository" >&2; exit 1; }
EXCLUDE=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$EXCLUDE")"
grep -Fxq '/.pipeline/' "$EXCLUDE" 2>/dev/null || printf '\n/.pipeline/\n' >> "$EXCLUDE"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "run requires a clean worktree" >&2
  git status --short >&2
  exit 1
fi
rm -rf .pipeline && mkdir -p .pipeline
git rev-parse HEAD > .pipeline/run_base
"$PIPELINE_HOME/pipeline/detect.sh"
echo "run: $(date -Iseconds)"
echo "base: $(cat .pipeline/run_base)"
echo "next: open Claude in this project and run /build <request>"
