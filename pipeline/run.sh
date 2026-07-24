#!/usr/bin/env bash
set -euo pipefail
rm -rf .pipeline && mkdir -p .pipeline
git rev-parse HEAD > .pipeline/run_base
echo "run: $(date -Iseconds)"
echo "base: $(cat .pipeline/run_base)"
echo "next: open claude and run /build"
