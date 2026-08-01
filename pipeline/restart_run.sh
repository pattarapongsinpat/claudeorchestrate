#!/usr/bin/env bash
# Start the run over when the generated tests, not the code, are what failed.
# Regenerate rather than edit: the cheap way to make a test pass is to change what
# it asserts, so the tester runs again from the request and the spec.
# Resets to the run base and clears plan, tests, and wave state. Keeps the request
# and the intent, neither of which changed.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REASON="${1:-}"
[[ -n "$REASON" ]] || { echo "usage: restart_run.sh <reason>" >&2; exit 1; }
[[ -f .pipeline/run_base ]] || { echo "no .pipeline/run_base — nothing to restart" >&2; exit 1; }
BASE=$(tr -d '\r' < .pipeline/run_base)

# One restart. A second bad test set points at the spec or the intent, not the
# tester, and regenerating again will not find that.
MAX_RESTARTS="${PIPELINE_MAX_RESTARTS:-1}"
COUNT=0
[[ -f .pipeline/restarts ]] && COUNT=$(tr -d '\r' < .pipeline/restarts)
[[ "$COUNT" =~ ^[0-9]+$ ]] || COUNT=0
((COUNT < MAX_RESTARTS)) || {
  echo "REFUSED: already restarted $COUNT time(s) this request (limit $MAX_RESTARTS)." >&2
  echo "Stop and report. A second bad test set points at the spec or the intent," >&2
  echo "not at the tester, and regenerating again will not find that." >&2
  exit 1
}

# Nothing is discarded silently: the abandoned attempt keeps a tag.
ATTEMPT=$((COUNT + 1))
TAG="pipeline-abandoned-$(date +%Y%m%d-%H%M%S)"
if [[ "$(git rev-parse HEAD)" != "$BASE" ]]; then
  git tag -f "$TAG" HEAD >/dev/null
  echo "abandoned attempt tagged $TAG ($(git rev-list --count "$BASE"..HEAD) commit(s))"
else
  echo "no commits to abandon"
fi

ARCHIVE=".pipeline/attempt-$ATTEMPT"
mkdir -p "$ARCHIVE"
for f in plan.md plan_final.json tests_spec.md ESCALATE HALT REGRESSION repair_ctx.md; do
  [[ -f ".pipeline/$f" ]] && cp ".pipeline/$f" "$ARCHIVE/" || true
done
printf '%s\n' "$REASON" > "$ARCHIVE/reason.txt"

# Before the reset, not after: the reset is what removes it.
OLD_TEST=$(jq -r '.generated_test_file // ""' .pipeline/toolchain.json | tr -d '\r')
[[ -n "$OLD_TEST" && -f "$OLD_TEST" ]] && cp "$OLD_TEST" "$ARCHIVE/$(basename "$OLD_TEST")"

git reset -q --hard "$BASE"
git clean -fdq -e .pipeline 2>/dev/null || true

rm -f .pipeline/plan.md .pipeline/plan_final.json .pipeline/tests_spec.md \
      .pipeline/done.json .pipeline/ESCALATE .pipeline/HALT .pipeline/REGRESSION \
      .pipeline/repair_ctx.md .pipeline/step_status.json .pipeline/baseline.out \
      .pipeline/touched.log
rm -rf .pipeline/status .pipeline/wt .pipeline/waves.lock

# New test path: tests.sh refuses to overwrite and the old file is still on disk.
# Stamped from a fresh detect, because restamping an already-stamped path appends
# to the old stamp and every restart lengthens the name.
"$PIPELINE_HOME/pipeline/detect.sh" >/dev/null
if [[ "$(jq -r '.generated_tests' .pipeline/toolchain.json | tr -d '\r')" == true ]]; then
  tmp=$(mktemp)
  jq --arg run "r$ATTEMPT-$(date +%Y%m%d-%H%M%S)" '
    .generated_test_file |= (
      if . == "" or . == null then .
      else sub("(?<stem>[^/]+?)(?<ext>(\\.[^./]+)+)$"; "\(.stem).\($run)\(.ext)")
      end)
  ' .pipeline/toolchain.json > "$tmp" && mv "$tmp" .pipeline/toolchain.json
  echo "generated tests: $(jq -r '.generated_test_file' .pipeline/toolchain.json)"
fi

printf '%s\n' "$ATTEMPT" > .pipeline/restarts
{ echo "attempt $ATTEMPT abandoned at $(date -Iseconds)"
  echo "tag: ${TAG}"
  echo "reason: $REASON"
} >> .pipeline/restart_log.txt

echo "RESTART $ATTEMPT: worktree back at $BASE, plan and tests cleared"
echo "next: re-run plan and tests, then check_baseline, gate, waves"
