#!/usr/bin/env bash
# Parallel step runner. Schedules plan_final.json steps into dependency waves;
# within a wave, steps with disjoint files_allowed run concurrently, each in its
# own git worktree branched from the wave base. Each runs code.sh unchanged; a
# successful step is committed in its worktree and cherry-picked back (disjoint
# files => conflict-free). Steps that depend on each other, or that share a file,
# are serialized. With no deps and disjoint files it is fully parallel; with a
# linear dep chain it degrades to the sequential loop.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN=.pipeline/plan_final.json
[[ -f "$PLAN" ]] || { echo "no $PLAN" >&2; exit 1; }
bash "$PIPELINE_HOME/pipeline/validate_plan.sh" "$PLAN" >/dev/null

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ABORT: tree dirty at entry to waves." >&2
  git status --short >&2; exit 1
fi

deps_of(){  jq -r --arg id "$1" '.steps[]|select(.id==$id)|.deps[]?'        "$PLAN" | tr -d '\r'; }
files_of(){ jq -r --arg id "$1" '.steps[]|select(.id==$id)|.files_allowed[]' "$PLAN" | tr -d '\r'; }

mapfile -t REMAINING < <(jq -r '.steps[].id' "$PLAN" | tr -d '\r')
declare -A DONE=()
WORKROOT="$(pwd)/.pipeline/wt"

cleanup_wt(){
  if [[ -d "$WORKROOT" ]]; then
    for d in "$WORKROOT"/*/; do [[ -d "$d" ]] && git worktree remove --force "$d" 2>/dev/null || true; done
  fi
  git worktree prune 2>/dev/null || true
  git for-each-ref --format='%(refname:short)' refs/heads/wt/ 2>/dev/null \
    | while read -r b; do git branch -D "$b" 2>/dev/null || true; done
  rm -rf "$WORKROOT" 2>/dev/null || true
}
trap cleanup_wt EXIT
cleanup_wt
mkdir -p "$WORKROOT"

escalated=""
while ((${#REMAINING[@]})); do
  # ready = remaining steps whose deps are all DONE
  ready=()
  for s in "${REMAINING[@]}"; do
    ok=1
    while read -r d; do [[ -z "$d" ]] && continue; [[ -n "${DONE[$d]:-}" ]] || ok=0; done < <(deps_of "$s")
    ((ok)) && ready+=("$s")
  done
  ((${#ready[@]})) || { echo "ERROR: dependency cycle among: ${REMAINING[*]}" >&2; exit 1; }

  # batch = maximal file-disjoint subset of ready (order preserved)
  batch=(); declare -A used=()
  for s in "${ready[@]}"; do
    conflict=0
    while read -r f; do [[ -n "${used[$f]:-}" ]] && conflict=1; done < <(files_of "$s")
    if ((!conflict)); then
      batch+=("$s")
      while read -r f; do used["$f"]=1; done < <(files_of "$s")
    fi
  done
  unset used

  BASE=$(git rev-parse HEAD)
  echo "WAVE base=$(git rev-parse --short HEAD) parallel=[${batch[*]}]"

  # launch the batch, each in its own worktree
  declare -A PIDS=()
  for s in "${batch[@]}"; do
    wt="$WORKROOT/$s"
    git worktree add -q -b "wt/$s" "$wt" "$BASE"
    mkdir -p "$wt/.pipeline"
    cp "$PLAN" "$wt/.pipeline/plan_final.json"
    cp .pipeline/toolchain.json "$wt/.pipeline/toolchain.json"
    ( cd "$wt" && "$PIPELINE_HOME/pipeline/code.sh" "$s" > .pipeline/code.log 2>&1 ) &
    PIDS["$s"]=$!
  done

  # collect results; commit successes inside their worktrees
  batch_ok=1
  declare -A FAILED=()
  for s in "${batch[@]}"; do
    wt="$WORKROOT/$s"
    step_ok=0
    if wait "${PIDS[$s]}"; then step_ok=1; fi

    # Copy per-step artifacts out before cleanup_wt deletes the worktree —
    # a WARN raised inside a worktree is otherwise lost, unlike sequential runs.
    cp "$wt"/.pipeline/WARN_* .pipeline/ 2>/dev/null || true
    mkdir -p .pipeline/logs .pipeline/raw
    cp "$wt/.pipeline/code.log" ".pipeline/logs/$s.log" 2>/dev/null || true
    cp "$wt"/.pipeline/raw/* .pipeline/raw/ 2>/dev/null || true

    if ((step_ok)); then
      if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        git -C "$wt" add -A
        git -C "$wt" commit -qm "step $s"
      fi                                   # else NOOP: HEAD stays at BASE
    else
      echo "ESCALATE: step $s" >&2
      sed 's/^/    /' "$wt/.pipeline/code.log" >&2 || true
      # Append, never overwrite: a second failure in the same wave used to
      # erase the first one's marker.
      { echo "=== $s ==="
        cat "$wt/.pipeline/ESCALATE" 2>/dev/null ||
          echo "step: $s (no ESCALATE marker; see .pipeline/logs/$s.log)"
      } >> .pipeline/ESCALATE
      FAILED["$s"]=1; escalated="$s"; batch_ok=0
    fi
  done

  # merge successful steps back (disjoint files => clean cherry-pick)
  for s in "${batch[@]}"; do
    [[ -n "${FAILED[$s]:-}" ]] && continue
    wt="$WORKROOT/$s"; tip=$(git -C "$wt" rev-parse HEAD)
    if [[ "$tip" != "$BASE" ]]; then
      git cherry-pick "$tip" >/dev/null 2>&1 || { git cherry-pick --abort 2>/dev/null || true; echo "MERGE CONFLICT on $s — steps not disjoint" >&2; exit 1; }
      files_of "$s" >> .pipeline/touched.log
    fi
    DONE["$s"]=1
  done

  # shrink REMAINING
  newrem=()
  for s in "${REMAINING[@]}"; do
    [[ -n "${DONE[$s]:-}" || -n "${FAILED[$s]:-}" ]] && continue
    newrem+=("$s")
  done
  REMAINING=("${newrem[@]}")

  ((batch_ok)) || { echo "stopping: $escalated escalated; partial commits left in place" >&2; exit 1; }
done
echo "waves complete: $(git rev-parse --short HEAD)"
