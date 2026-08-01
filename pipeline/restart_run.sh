#!/usr/bin/env bash
# Start the run over when the generated tests, not the code, are what failed.
#
# The alternative was letting Opus edit the test it failed against, and that is
# the one edit the whole stage exists to prevent: the cheap way to make a test
# pass is to change what it asserts. Regenerating is different in kind. The tester
# runs again from the request and the spec, independently of the plan and of
# whatever the last attempt wrote, so a bad assertion is redrawn rather than bent
# to fit the code that failed it.
#
# Resets the worktree to the run base and clears the plan, the tests, and the wave
# state. Keeps the request and the intent: the request did not change, and
# re-deriving intent would spend an Opus call to reach the same answer.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REASON="${1:-}"
[[ -n "$REASON" ]] || { echo "usage: restart_run.sh <reason>" >&2; exit 1; }
[[ -f .pipeline/run_base ]] || { echo "no .pipeline/run_base — nothing to restart" >&2; exit 1; }
BASE=$(tr -d '\r' < .pipeline/run_base)

# One restart. A second means the tester is not the variable — the spec, the
# intent, or the request is — and running a third time only spends the tokens to
# find that out again.
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

# Nothing is thrown away silently. The abandoned attempt keeps a tag so its
# commits, its plan, and its tests stay reachable for inspection.
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

# Archive the failing test file before the reset, not after: it was committed at
# the gate, so the reset is exactly what removes it, and it is the artifact most
# worth reading when deciding whether the tester or the spec was at fault.
OLD_TEST=$(jq -r '.generated_test_file // ""' .pipeline/toolchain.json | tr -d '\r')
[[ -n "$OLD_TEST" && -f "$OLD_TEST" ]] && cp "$OLD_TEST" "$ARCHIVE/$(basename "$OLD_TEST")"

git reset -q --hard "$BASE"
git clean -fdq -e .pipeline 2>/dev/null || true

rm -f .pipeline/plan.md .pipeline/plan_final.json .pipeline/tests_spec.md \
      .pipeline/done.json .pipeline/ESCALATE .pipeline/HALT .pipeline/REGRESSION \
      .pipeline/repair_ctx.md .pipeline/step_status.json .pipeline/baseline.out \
      .pipeline/touched.log
rm -rf .pipeline/status .pipeline/wt .pipeline/waves.lock

# A new generated test path, for the same reason run.sh scopes it: tests.sh
# refuses to overwrite, and the previous attempt's file is still on disk. The
# stamp is applied to a freshly detected toolchain rather than to the current one,
# which already carries the last run's stamp — restamping that produced
# `pipeline_generated.r1-<new>.<old>.test.js`, since the greedy extension match
# treats the old stamp as part of the suffix and every restart adds another.
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
