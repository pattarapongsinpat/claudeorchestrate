#!/usr/bin/env bash
# Brief for the main-session Opus repair of an escalated step.
#
# The repair runs in the session that already holds the request, the intent, and
# the plan, so this prints only what that session does not have: which step gave
# up, the exact bounds it must stay inside, and what the coder's last attempt hit.
# Writes .pipeline/repair_ctx.md and prints the step id.
set -euo pipefail
PLAN=.pipeline/plan_final.json
STATE=.pipeline/done.json
OUT=.pipeline/repair_ctx.md

[[ -f "$PLAN" ]] || { echo "no $PLAN" >&2; exit 1; }
[[ -f .pipeline/ESCALATE ]] || { echo "no .pipeline/ESCALATE — nothing to repair" >&2; exit 1; }

# done.json is the authority on which step failed. The ESCALATE marker is appended
# to by every failing step in a wave, so parsing it for the id would pick one of
# several arbitrarily.
mapfile -t STEPS < <(jq -r '.steps | to_entries[] | select(.value.status == "escalated") | .key' "$STATE" 2>/dev/null | tr -d '\r')
((${#STEPS[@]})) || { echo "no escalated step in $STATE" >&2; exit 1; }

MAXTESTLINES=800
TEST_FILE=$(jq -r '.generated_test_file // ""' .pipeline/toolchain.json 2>/dev/null | tr -d '\r')
mapfile -t ALL_TESTS < <(
  for s in "${STEPS[@]}"; do
    jq -r --arg id "$s" '.steps[] | select(.id == $id) | .tests[]?' "$PLAN" | tr -d '\r'
  done
)
((${#ALL_TESTS[@]})) || ALL_TESTS=(".")

# The routing gate resolves `.claude/routing-ack` against the working directory,
# which during a run is the project, not the runtime. Writing it here keeps the
# repair to one step and keeps the ack inside its freshness window, and the
# info/exclude line keeps it from dirtying a tree that waves.sh refuses to start on.
mkdir -p .claude
printf 'Routing: inline - escalation repair\n' > .claude/routing-ack
EXCLUDE="$(git rev-parse --git-path info/exclude)"
grep -Fqx '/.claude/routing-ack' "$EXCLUDE" 2>/dev/null || printf '/.claude/routing-ack\n' >> "$EXCLUDE"

{
  echo "# Escalated step repair"
  echo
  echo "Write ONLY the files listed under files_allowed. Do not touch tests or"
  echo "dependency manifests — the same bounds the coder had. Then run the mapped"
  echo "tests, commit, and mark the step repaired."
  echo
  for s in "${STEPS[@]}"; do
    echo "## Step $s"
    echo '```json'
    jq -r --arg id "$s" '.steps[] | select(.id == $id)' "$PLAN"
    echo '```'
    echo
    echo "### Current contents of files_allowed"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      echo "#### $f"
      echo '```'
      cat "$f" 2>/dev/null || echo "[does not exist yet]"
      echo '```'
    done < <(jq -r --arg id "$s" '.steps[] | select(.id == $id) | .files_allowed[]' "$PLAN" | tr -d '\r')
    echo
  done
  echo "## Why the coder gave up"
  echo '```'
  cat .pipeline/ESCALATE
  echo '```'
  echo

  # The coder never sees this file, which is why it can fail a step for reasons no
  # amount of rewriting fixes — an exact error string it had to guess, a field name
  # stated nowhere else. Opus can read it, so the brief hands it over rather than
  # making the repair go looking. It stays read-only: a repair that edits its
  # grader is refused by repair_done.sh.
  echo "## Mapped tests — READ ONLY, editing these is refused"
  if [[ -n "$TEST_FILE" && -f "$TEST_FILE" ]]; then
    echo "### $TEST_FILE"
    echo '```'
    if (( $(wc -l < "$TEST_FILE") <= MAXTESTLINES )); then
      cat "$TEST_FILE"
    else
      # The declaration line alone is worthless here — the assertion is the whole
      # reason to read the file — so the match carries its body with it.
      echo "[file exceeds $MAXTESTLINES lines — showing the mapped tests with context]"
      grep -nE -A 25 "$(IFS='|'; echo "${ALL_TESTS[*]}")" "$TEST_FILE" || true
    fi
    echo '```'
    echo
    echo "If the assertion here cannot be satisfied by any implementation within"
    echo "files_allowed, stop and say so. Do not bend the implementation to a test"
    echo "that is wrong, and do not edit the test."
  else
    echo "No generated test file for this toolchain — the step ran against the"
    echo "existing suite. Read the tests named in the step's \`tests\` array."
  fi
} > "$OUT"

printf '%s\n' "${STEPS[@]}"
