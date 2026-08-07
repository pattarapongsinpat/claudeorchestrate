#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

P() { bash "$PIPELINE_HOME/pipeline/$1.sh" "${@:2}"; }

new_repo() {
  rm -rf "$WORK/repo"
  mkdir -p "$WORK/repo"
  cd "$WORK/repo"
  git init -q
  git config user.email t@t; git config user.name t
  echo base > file.txt
  printf '{"name":"t","version":"1.0.0","scripts":{"test":"node --test"}}\n' > package.json
  git add -A; git commit -qm base
}

backlog() {
  cat > .campaign/backlog.json <<'EOF'
{"units": [
  {"id": "u1", "title": "first", "request": "add the first thing"},
  {"id": "u2", "title": "second", "request": "add the second thing"}
]}
EOF
}

open_campaign() {
  new_repo
  P campaign_init >/dev/null
  printf '## Request\nbuild the thing\n' > .campaign/brief.txt
  backlog
  P validate_backlog >/dev/null
}

# .campaign survives run.sh, which deletes .pipeline at the start of every unit.
open_campaign
mkdir -p .pipeline && echo x > .pipeline/marker
P run >/dev/null
[[ ! -e .pipeline/marker ]]
[[ -f .campaign/state.json && -f .campaign/brief.txt ]]
git status --porcelain | grep -q . && { echo "campaign state dirtied the tree" >&2; exit 1; }

# Backlog validation.
open_campaign
for bad in '{}' '{"units": []}' \
           '{"units": [{"id": "u 1", "title": "t", "request": "r"}]}' \
           '{"units": [{"id": "u1", "title": "t"}]}' \
           '{"units": [{"id": "u1", "title": "", "request": "r"}]}' \
           '{"units": [{"id":"u1","title":"t","request":"r"},{"id":"u1","title":"t2","request":"r2"}]}'; do
  printf '%s' "$bad" > .campaign/backlog.json
  rc=0; P validate_backlog >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "backlog accepted: $bad" >&2; exit 1; }
done
printf 'not json' > .campaign/backlog.json
rc=0; P validate_backlog >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A campaign nobody narrowed is refused rather than run.
backlog
rc=0
PIPELINE_MAX_CAMPAIGN_UNITS=1 P validate_backlog >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A dirty tree blocks the campaign, not just the unit.
open_campaign
echo dirty >> file.txt
rc=0; P campaign_next >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
git checkout -q -- file.txt

# The unit request carries the brief verbatim and marks the decomposition as ours.
P campaign_next >/dev/null
grep -Fq 'build the thing' .campaign/unit_request.txt
grep -Fq 'add the first thing' .campaign/unit_request.txt
grep -Fq 'not the user' .campaign/unit_request.txt
[[ "$(jq -r .current .campaign/state.json)" == u1 ]]
[[ "$(jq -r '.units[0].attempts' .campaign/state.json)" == 1 ]]

# Marking a unit done requires a commit and a clean tree.
rc=0; P campaign_done u2 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
rc=0; P campaign_done u1 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
echo one >> file.txt; git commit -qam u1
echo stray >> file.txt
rc=0; P campaign_done u1 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
git checkout -q -- file.txt
P campaign_done u1 >/dev/null
[[ "$(jq -r '.units[0].status' .campaign/state.json)" == done ]]
[[ "$(jq -r '.units[0].commit' .campaign/state.json)" == "$(git rev-parse HEAD)" ]]
[[ ! -e .campaign/unit_request.txt ]]

# The next unit starts from the previous unit's commit, not the campaign base.
P campaign_next >/dev/null
[[ "$(cat .campaign/unit_base)" == "$(git rev-parse HEAD)" ]]
[[ "$(cat .campaign/unit_base)" != "$(cat .campaign/base)" ]]
echo two >> file.txt; git commit -qam u2
P campaign_done u2 >/dev/null
rc=0; P campaign_next >/dev/null || rc=$?
[[ "$rc" == 3 ]]
[[ "$(jq -r .status .campaign/state.json)" == complete ]]
rc=0; P campaign_next >/dev/null || rc=$?
[[ "$rc" == 3 ]]

# A retry resets to the unit base, tags what it abandons, and keeps earlier units.
open_campaign
P campaign_next >/dev/null
echo one >> file.txt; git commit -qam u1
P campaign_done u1 >/dev/null
KEPT=$(git rev-parse HEAD)
P campaign_next >/dev/null
echo half >> file.txt; git commit -qam "u2 partial"
# The evidence the next unit's run.sh would delete.
mkdir -p .pipeline/logs .pipeline/wt/u2
echo "step s1 failed the assertion" > .pipeline/ESCALATE
echo "DRIFT: built the wrong endpoint" > .pipeline/verify.md
echo "coder output" > .pipeline/logs/s1.log
echo live > .pipeline/wt/u2/scratch
rc=0; P campaign_fail u2 regression "suite red" >/dev/null || rc=$?
[[ "$rc" == 2 ]]
ARCH=.campaign/failed/u2-1
[[ -f "$ARCH/ESCALATE" && -f "$ARCH/verify.md" && -f "$ARCH/logs/s1.log" ]]
grep -Fq 'regression: suite red' "$ARCH/reason.txt"
[[ ! -e "$ARCH/wt" ]]
[[ "$(git rev-parse HEAD)" == "$KEPT" ]]
[[ -n "$(git tag -l 'campaign-abandoned-u2-*')" ]]
[[ "$(jq -r '.units[1].status' .campaign/state.json)" == pending ]]
[[ "$(jq -r .status .campaign/state.json)" == running ]]
[[ ! -e .campaign/unit_request.txt ]]

# The retry sees why the last attempt failed, not just that it did. The subagent
# reported one line; the diagnosis was in .pipeline and is now in the archive.
rm -rf .pipeline
P campaign_next >/dev/null
grep -Fq 'regression: suite red' .campaign/unit_request.txt
grep -Fq 'step s1 failed the assertion' .campaign/unit_request.txt
grep -Fq 'DRIFT: built the wrong endpoint' .campaign/unit_request.txt
grep -Fq "$ARCH" .campaign/unit_request.txt
[[ "$(jq -r '.units[1].attempts' .campaign/state.json)" == 2 ]]

# Failing the same way twice stops instead of spending the last attempt.
rc=0; P campaign_fail u2 regression "suite red" >/dev/null || rc=$?
[[ "$rc" == 3 ]]
[[ "$(jq -r .status .campaign/state.json)" == stopped ]]
[[ "$(jq -r '.units[1].status' .campaign/state.json)" == failed ]]
[[ "$(git rev-parse HEAD)" == "$KEPT" ]]
# A stopped campaign is the case where the evidence matters most, and the first
# attempt's archive is not overwritten by the last one's.
[[ -f .campaign/failed/u2-2/reason.txt ]]
[[ -f .campaign/failed/u2-1/ESCALATE ]]
rc=0; P campaign_next >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A HALT is impossible on the first attempt: the campaign is the stage that
# cannot ask, so a second run asks the same unanswerable question.
open_campaign
P campaign_next >/dev/null
rc=0; P campaign_fail u1 halt "needs a decision" >/dev/null || rc=$?
[[ "$rc" == 3 ]]
[[ "$(jq -r .stopped_because .campaign/state.json)" == *decision* ]]
[[ "$(jq -r '.units[0].attempts' .campaign/state.json)" == 1 ]]

# Attempts are a budget, and a raised one spends later.
open_campaign
P campaign_next >/dev/null
rc=0; PIPELINE_MAX_UNIT_ATTEMPTS=1 P campaign_fail u1 error "boom" >/dev/null || rc=$?
[[ "$rc" == 3 ]]
open_campaign
for n in 1 2; do
  P campaign_next >/dev/null
  rc=0
  PIPELINE_MAX_UNIT_ATTEMPTS=3 P campaign_fail u1 error "boom $n" >/dev/null || rc=$?
  [[ "$rc" == 2 ]]
done
[[ "$(jq -r .status .campaign/state.json)" == running ]]

# Bad arguments are refused before any state changes.
open_campaign
P campaign_next >/dev/null
for args in "u1 mystery reason" "u1" ""; do
  rc=0; P campaign_fail $args >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
done
rc=0; P campaign_fail u2 error "wrong unit" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
[[ "$(jq -r '.units[0].failures | length' .campaign/state.json)" == 0 ]]

# A second campaign archives the first rather than overwriting it.
open_campaign
P campaign_next >/dev/null
echo one >> file.txt; git commit -qam u1
P campaign_done u1 >/dev/null
rc=0; P campaign_init >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
tmp=$(mktemp); jq '.status="complete"' .campaign/state.json > "$tmp"; mv "$tmp" .campaign/state.json
P campaign_init >/dev/null
[[ ! -e .campaign/state.json ]]
[[ -n "$(ls -d .campaign/finished-* 2>/dev/null)" ]]

# The campaign's own budget, counted by validate_backlog against the brief. Same
# repository, same brief text: the second open is the second attempt, and the
# third is refused before check_backlog spends a call on it.
new_repo
for _ in 1 2; do
  P campaign_init >/dev/null
  printf '## Request\nrepeat the same campaign\n' > .campaign/brief.txt
  backlog
  P validate_backlog >/dev/null
  tmp=$(mktemp); jq '.status="stopped"' .campaign/state.json > "$tmp"; mv "$tmp" .campaign/state.json
done
P campaign_init >/dev/null
printf '## Request\nrepeat the same campaign\n' > .campaign/brief.txt
backlog
rc=0; P validate_backlog >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]
[[ -f .campaign/HALT ]]
[[ ! -e .campaign/state.json ]]

cd /
echo "campaign tests passed"
