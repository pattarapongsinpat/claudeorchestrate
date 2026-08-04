#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

V="$WORK/backlog_verdict.md"
VAL="$PIPELINE_HOME/pipeline/validate_backlog_verdict.sh"

printf 'SOUND\n' > "$V"
[[ "$(bash "$VAL" "$V")" == SOUND ]]
[[ ! -e "$WORK/backlog-1.md" ]]

# First rejection is archived and buys one revision.
printf 'UNSOUND: no unit deletes failed uploads\n' > "$V"
rc=0; bash "$VAL" "$V" >/dev/null || rc=$?
[[ "$rc" == 2 ]]
[[ -f "$WORK/backlog-1.md" && ! -e "$V" ]]
[[ ! -e "$WORK/HALT" ]]

# Second rejection spends the budget and HALTs.
printf 'UNSOUND: still no delete\n' > "$V"
rc=0; bash "$VAL" "$V" >/dev/null || rc=$?
[[ "$rc" == 3 ]]
[[ -f "$WORK/backlog-2.md" ]]
grep -Fq 'rejected 2 times' "$WORK/HALT"

# A raised budget spends later.
rm -f "$WORK/HALT" "$WORK"/backlog-*.md
for _ in 1 2; do
  printf 'UNSOUND: no delete\n' > "$V"
  rc=0
  PIPELINE_MAX_BACKLOG_REVISIONS=2 bash "$VAL" "$V" >/dev/null || rc=$?
  [[ "$rc" == 2 ]]
done
[[ ! -e "$WORK/HALT" ]]

# Malformed verdicts stop the run and are never archived as a rejection.
rm -f "$WORK"/backlog-*.md
for invalid in '' 'sound' 'UNSOUND' 'UNSOUND:' 'SOUND extra' 'PASS'; do
  printf '%s\n' "$invalid" > "$V"
  rc=0; bash "$VAL" "$V" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || { echo "accepted malformed verdict: '$invalid'" >&2; exit 1; }
done
printf 'SOUND\nextra\n' > "$V"
rc=0; bash "$VAL" "$V" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
[[ ! -e "$WORK/backlog-1.md" ]]
rm -f "$V"
rc=0; bash "$VAL" "$V" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# check_backlog sends the brief and the units, and nothing else: the state file
# and the intent are the same reading restated.
REPO="$WORK/repo"
mkdir -p "$REPO/.campaign"
cd "$REPO"
cat > .campaign/brief.txt <<'EOF'
## Request
admin page for uploads

## Clarifications (verbatim)
Q: What should the admin page do?
A: List uploads and delete the failed ones
EOF
cat > .campaign/backlog.json <<'EOF'
{"units": [
  {"id": "u1", "title": "uploads list endpoint", "request": "expose GET /uploads"},
  {"id": "u2", "title": "delete failed uploads", "request": "expose DELETE /uploads/:id"}
]}
EOF
printf '{"base":"abc","status":"running","units":[]}\n' > .campaign/state.json
out=$(PIPELINE_BACKLOG_DRY=1 bash "$PIPELINE_HOME/pipeline/check_backlog.sh")
grep -Fq 'List uploads and delete the failed ones' <<<"$out"
grep -Fq 'expose GET /uploads' <<<"$out"
grep -Fq 'delete failed uploads' <<<"$out"
! grep -Fq '"base"' <<<"$out"
! grep -Fq 'u1' <<<"$out"

# Broken inputs are a configuration error, not a pass.
rc=0; PIPELINE_BACKLOG_MODEL=gpt bash "$PIPELINE_HOME/pipeline/check_backlog.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
printf '{"units": []}\n' > .campaign/backlog.json
rc=0; PIPELINE_BACKLOG_DRY=1 bash "$PIPELINE_HOME/pipeline/check_backlog.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
printf '{"units":[{"id":"u1","title":"t","request":"r"}]}\n' > .campaign/backlog.json
: > .campaign/brief.txt
rc=0; PIPELINE_BACKLOG_DRY=1 bash "$PIPELINE_HOME/pipeline/check_backlog.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A spent budget stops the stage before it spends another call.
printf 'brief\n' > .campaign/brief.txt
touch .campaign/HALT
rc=0; PIPELINE_BACKLOG_DRY=1 bash "$PIPELINE_HOME/pipeline/check_backlog.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

cd /
echo "backlog gate tests passed"
