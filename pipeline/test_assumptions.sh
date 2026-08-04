#!/usr/bin/env bash
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

V="$WORK/assumptions.md"

printf 'SOUND\n' > "$V"
[[ "$(bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V")" == SOUND ]]
[[ ! -e "$WORK/assumptions-1.md" ]]

# First rejection is archived and buys one revision.
printf 'UNSOUND: assumes a cache the request never mentions\n' > "$V"
rc=0
bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null || rc=$?
[[ "$rc" == 2 ]]
[[ -f "$WORK/assumptions-1.md" && ! -e "$V" ]]
[[ ! -e "$WORK/HALT" ]]

# Second rejection spends the budget and HALTs.
printf 'UNSOUND: still assumes a cache\n' > "$V"
rc=0
bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null || rc=$?
[[ "$rc" == 3 ]]
[[ -f "$WORK/assumptions-2.md" ]]
grep -Fq 'rejected 2 times' "$WORK/HALT"

# A raised budget spends later.
rm -f "$WORK/HALT" "$WORK"/assumptions-*.md
printf 'UNSOUND: assumes a cache\n' > "$V"
rc=0
PIPELINE_MAX_ASSUMPTION_REVISIONS=2 bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null || rc=$?
[[ "$rc" == 2 ]]
printf 'UNSOUND: assumes a cache\n' > "$V"
rc=0
PIPELINE_MAX_ASSUMPTION_REVISIONS=2 bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null || rc=$?
[[ "$rc" == 2 ]]
[[ ! -e "$WORK/HALT" ]]

# Malformed verdicts stop the run and are never archived as a rejection.
rm -f "$WORK"/assumptions-*.md
for invalid in '' 'sound' 'UNSOUND' 'UNSOUND:' 'SOUND extra' 'PASS'; do
  printf '%s\n' "$invalid" > "$V"
  rc=0
  bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
done
printf 'SOUND\nextra\n' > "$V"
rc=0
bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
[[ ! -e "$WORK/assumptions-1.md" ]]

rm -f "$V"
rc=0
bash "$PIPELINE_HOME/pipeline/validate_assumptions.sh" "$V" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# check_assumptions.sh sends the whole request and the Assumptions section, and
# nothing else: the goal and the allowlist are the same reading restated.
REPO="$WORK/repo"
mkdir -p "$REPO/.pipeline"
cd "$REPO"
cat > .pipeline/request.txt <<'EOF'
## Request
do it

## Clarifications (verbatim)
Q: What should "do it" implement?
A: The uploader retry discussed above
EOF
cat > .pipeline/intent.md <<'EOF'
# Goal
Uploads survive a transient network failure.

# Assumptions
- Three attempts is enough.
- Backoff is exponential.

# Non-goals
Do not add a queue.

# Allowed files
src/upload.py
EOF
out=$(PIPELINE_ASSUMPTIONS_DRY=1 bash "$PIPELINE_HOME/pipeline/check_assumptions.sh")
grep -Fq 'The uploader retry discussed above' <<<"$out"
grep -Fq 'Three attempts is enough.' <<<"$out"
grep -Fq 'Backoff is exponential.' <<<"$out"
! grep -Fq 'Uploads survive' <<<"$out"
! grep -Fq 'Do not add a queue' <<<"$out"
! grep -Fq 'src/upload.py' <<<"$out"

# An intent with no assumptions to grade is a broken intent, not a pass.
cat > .pipeline/intent.md <<'EOF'
# Goal
Uploads survive a transient network failure.

# Assumptions

# Non-goals
Do not add a queue.
EOF
rc=0
PIPELINE_ASSUMPTIONS_DRY=1 bash "$PIPELINE_HOME/pipeline/check_assumptions.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# An unknown model is a configuration error, not a silent default.
printf '# Assumptions\n- Three attempts is enough.\n' > .pipeline/intent.md
rc=0
PIPELINE_ASSUMPTIONS_MODEL=gpt bash "$PIPELINE_HOME/pipeline/check_assumptions.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

# A HALT from intent stops the stage before it spends a call.
touch .pipeline/HALT
rc=0
PIPELINE_ASSUMPTIONS_DRY=1 bash "$PIPELINE_HOME/pipeline/check_assumptions.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]

echo "assumption gate tests passed"
