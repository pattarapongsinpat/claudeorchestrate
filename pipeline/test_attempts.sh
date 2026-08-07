#!/usr/bin/env bash
# Covers attempt_guard.sh without the API: the per-request budget for builds and
# campaigns, what makes an attempt the same attempt, and the three ways the count
# is returned or bypassed.
set -euo pipefail

PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$PIPELINE_HOME/pipeline/attempt_guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/attempts"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q
  git config user.name 'Pipeline Attempts Test'
  git config user.email 'pipeline@example.invalid'
  printf 'x\n' > file.txt
  git add -A
  git commit -qm baseline
)
LEDGER="$REPO/.git/pipeline-attempts.json"

# Stand in for a run: run.sh creates .pipeline, intent writes request.txt.
new_run() { rm -rf "$REPO/.pipeline"; mkdir -p "$REPO/.pipeline"; printf '%s\n' "$1" > "$REPO/.pipeline/request.txt"; }

# --- build: three attempts, then a hard stop -------------------------------

(
  cd "$REPO"
  for n in 1 2 3; do
    new_run 'add a retry cap'
    "$GUARD" build .pipeline/request.txt > "$WORK/b$n.out"
    grep -Fq "build attempt $n of 3" "$WORK/b$n.out"
    [[ "$(cat .pipeline/attempt)" == "$n" ]]
    [[ ! -f .pipeline/HALT ]]
  done

  new_run 'add a retry cap'
  rc=0
  "$GUARD" build .pipeline/request.txt > "$WORK/b4.out" 2>&1 || rc=$?
  [[ "$rc" == 3 ]]
  grep -Fq 'already used 3 build attempt(s)' "$WORK/b4.out"
  # The refusal is a HALT, so the skill's own stop-on-HALT rule catches it too.
  [[ -f .pipeline/HALT ]]
  grep -Fq 'limit 3' .pipeline/HALT
  # A refused attempt is not counted; the ledger still reads 3.
  [[ "$(jq -r '[.entries[].attempts] | max' "$LEDGER")" == 3 ]]
  [[ ! -f .pipeline/attempt ]]
)

# --- the key is the request, not the run -----------------------------------

(
  cd "$REPO"
  # A different request gets its own budget.
  new_run 'something else entirely'
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 1 of 3'

  # Line endings and edge whitespace are not a different request: a checkout
  # under core.autocrlf rewrites every line without changing what was typed.
  rm -rf .pipeline && mkdir -p .pipeline
  printf '\r\n\r\nsomething else entirely   \r\n\r\n' > .pipeline/request.txt
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 2 of 3'
)

# --- idempotent inside one run ---------------------------------------------

(
  cd "$REPO"
  new_run 'idempotence'
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 1 of 3'
  # check_assumptions.sh re-runs on a revision verdict. Revisions are not attempts.
  "$GUARD" build .pipeline/request.txt > "$WORK/again.out"
  grep -Fq 'already recorded for this run' "$WORK/again.out"
  "$GUARD" build .pipeline/request.txt >/dev/null
  [[ "$(jq -r --arg k "$(printf 'build\nidempotence\n' | sha256sum | cut -d' ' -f1)" \
        '.entries[$k].attempts' "$LEDGER")" == 1 ]]
)

# --- a success returns the budget ------------------------------------------

(
  cd "$REPO"
  new_run 'succeeds eventually'
  "$GUARD" build .pipeline/request.txt >/dev/null
  new_run 'succeeds eventually'
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 2 of 3'
  "$GUARD" --clear build .pipeline/request.txt >/dev/null
  [[ ! -f .pipeline/attempt ]]
  new_run 'succeeds eventually'
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 1 of 3'
)

# --- campaign: two attempts ------------------------------------------------

(
  cd "$REPO"
  mkdir -p .campaign
  printf '%s\n' 'rewrite the world' > .campaign/brief.txt

  rm -f .campaign/attempt
  "$GUARD" campaign .campaign/brief.txt | grep -Fq 'campaign attempt 1 of 2'
  rm -f .campaign/attempt
  "$GUARD" campaign .campaign/brief.txt | grep -Fq 'campaign attempt 2 of 2'
  rm -f .campaign/attempt

  rc=0
  "$GUARD" campaign .campaign/brief.txt > "$WORK/c3.out" 2>&1 || rc=$?
  [[ "$rc" == 3 ]]
  grep -Fq 'already used 2 campaign attempt(s)' "$WORK/c3.out"
  [[ -f .campaign/HALT ]]

  # Scope is part of the key: the same text as a build has its own budget.
  rm -rf .pipeline && mkdir -p .pipeline
  printf '%s\n' 'rewrite the world' > .pipeline/request.txt
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 1 of 3'
  rm -f .campaign/HALT
)

# --- a campaign unit is not charged to the build budget --------------------

(
  cd "$REPO"
  printf '%s\n' '{"status":"running"}' > .campaign/state.json
  new_run 'a unit request'
  "$GUARD" build .pipeline/request.txt > "$WORK/unit.out"
  grep -Fq 'bounded by the campaign' "$WORK/unit.out"
  [[ ! -f .pipeline/attempt ]]

  # Only while it is running. A stopped campaign leaves the file behind.
  printf '%s\n' '{"status":"stopped"}' > .campaign/state.json
  "$GUARD" build .pipeline/request.txt | grep -Fq 'build attempt 1 of 3'
  rm -rf .campaign
)

# --- configuration ----------------------------------------------------------

(
  cd "$REPO"
  new_run 'configurable'
  PIPELINE_MAX_BUILD_ATTEMPTS=1 "$GUARD" build .pipeline/request.txt | grep -Fq 'attempt 1 of 1'
  new_run 'configurable'
  rc=0
  PIPELINE_MAX_BUILD_ATTEMPTS=1 "$GUARD" build .pipeline/request.txt >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 3 ]]

  new_run 'configurable'
  rc=0
  PIPELINE_MAX_BUILD_ATTEMPTS=nope "$GUARD" build .pipeline/request.txt > "$WORK/bad.out" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'must be a positive integer' "$WORK/bad.out"

  rc=0
  "$GUARD" sideways .pipeline/request.txt > "$WORK/scope.out" 2>&1 || rc=$?
  [[ "$rc" == 1 ]]
  grep -Fq 'scope must be build or campaign' "$WORK/scope.out"
)

# --- the ledger is bounded and outside the worktree -------------------------

(
  cd "$REPO"
  for n in $(seq 1 60); do
    new_run "request number $n"
    "$GUARD" build .pipeline/request.txt >/dev/null
  done
  [[ "$(jq '.entries | length' "$LEDGER")" == 50 ]]
  # Newest kept, oldest dropped.
  jq -e --arg ex 'request number 60' 'any(.entries[]; .request == $ex)' "$LEDGER" >/dev/null
  jq -e --arg ex 'request number 1' 'all(.entries[]; .request != $ex)' "$LEDGER" >/dev/null

  # Nothing the guard writes can dirty the tree the next run requires to be clean.
  rm -rf .pipeline
  [[ -z "$(git status --porcelain)" ]]
)

echo "attempt tests passed"
