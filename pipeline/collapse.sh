#!/usr/bin/env bash
# Collapse the run's per-step commits into one, but only when the isolated
# verifier accepted it.
#
# This was the one step in the workflow no script performed: the session typed
# `git reset --soft` itself, so "never collapse unless validate_verify exits 0"
# was a rule the collapsing party administered. Doing the reset from here makes
# that exit code the thing that actually holds.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MSG="${1:-}"
[[ -n "$MSG" ]] || { echo "usage: collapse.sh <commit message>" >&2; exit 1; }
[[ -f .pipeline/run_base ]] || { echo "no .pipeline/run_base — nothing to collapse" >&2; exit 1; }
BASE=$(tr -d '\r' < .pipeline/run_base)

# A marker means the run stopped for a reason, and collapsing would bury the
# per-step commits that were deliberately left in place for inspection.
for marker in HALT ESCALATE REGRESSION; do
  [[ -f ".pipeline/$marker" ]] && {
    echo "REFUSED: .pipeline/$marker is present; the run did not finish clean" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo "REFUSED: uncommitted changes; the diff the verifier read is not what is on disk" >&2
  git status --short >&2
  exit 1
fi

if [[ "$(git rev-parse HEAD)" == "$BASE" ]]; then
  echo "REFUSED: HEAD is still the run base; there is nothing to collapse" >&2
  exit 1
fi

rc=0
VERDICT=$("$PIPELINE_HOME/pipeline/validate_verify.sh") || rc=$?
case "$rc" in
  0) ;;
  2) echo "REFUSED: $VERDICT" >&2
     echo "DRIFT reports an upstream misreading. Leave the step commits in place." >&2
     exit 2 ;;
  *) echo "REFUSED: the verifier verdict is missing or malformed" >&2
     exit 1 ;;
esac

COUNT=$(git rev-list --count "$BASE"..HEAD)
git reset -q --soft "$BASE"
git commit -qm "$MSG"
echo "collapsed $COUNT commit(s) into $(git rev-parse --short HEAD)"

# The cap counts failed runs, so a run that reached an accepted collapse returns
# the budget. Without this, asking for the same change twice a month apart would
# spend the second ask's attempts on the first ask's successes.
[[ -f .pipeline/request.txt ]] &&
  "$PIPELINE_HOME/pipeline/attempt_guard.sh" --clear build .pipeline/request.txt >/dev/null || true
