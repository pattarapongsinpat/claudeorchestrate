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
if ! test_name_error=$(bash "$PIPELINE_HOME/pipeline/validate_test_names.sh" "$PLAN" 2>&1); then
  printf '%s\n' "$test_name_error" > .pipeline/ESCALATE
  printf '%s\n' "$test_name_error" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ABORT: tree dirty at entry to waves." >&2
  git status --short >&2; exit 1
fi

# Single-runner lock. Two concurrent waves runs share .pipeline/wt/ and done.json:
# they delete each other's worktrees mid-step, which surfaces as a missing code.log
# rather than as a collision, and they mark each other's completed steps as escalated.
# mkdir is atomic, so it is the lock primitive.
LOCK=.pipeline/waves.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  holder=$(cat "$LOCK/pid" 2>/dev/null || echo unknown)
  if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
    echo "ABORT: another waves run is already active (pid $holder)." >&2
    echo "Wait for it to exit rather than starting a second runner." >&2
    exit 1
  fi
  echo "note: clearing stale waves lock left by pid $holder" >&2
  rm -rf "$LOCK"
  mkdir "$LOCK" || { echo "ABORT: cannot acquire waves lock" >&2; exit 1; }
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# .pipeline/ESCALATE is appended to within a run so two failures in one wave both
# survive. Across runs that is wrong: a marker from the previous attempt makes a
# fixed step look like it is still failing, and the report names a step that
# already passed. This run owns the file from here.
rm -f .pipeline/ESCALATE

STATE=.pipeline/done.json
if [[ -f .pipeline/run_base ]]; then
  RUN_BASE=$(tr -d '\r\n' < .pipeline/run_base)
else
  RUN_BASE=$(git rev-parse HEAD)
  printf '%s\n' "$RUN_BASE" > .pipeline/run_base
fi
if [[ -f "$STATE" ]]; then
  jq -e --arg base "$RUN_BASE" '.run_base == $base and (.steps | type == "object")' "$STATE" >/dev/null || {
    echo "ABORT: $STATE belongs to another run" >&2
    exit 1
  }
else
  jq -n --arg base "$RUN_BASE" '{run_base:$base,steps:{}}' > "$STATE"
fi

record_step() {
  local id="$1" status="$2" attempts="$3" commit="$4" fingerprint tmp
  fingerprint=$(jq -cS --arg id "$id" '.steps[] | select(.id == $id)' "$PLAN" | sha256sum | cut -d' ' -f1)
  tmp=$(mktemp)
  jq --arg id "$id" --arg status "$status" --argjson attempts "$attempts" --arg commit "$commit" --arg fingerprint "$fingerprint" '
    (.steps[$id] // {}) as $old |
    .steps[$id] = {
      status: $status,
      attempts: (($old.attempts // 0) + $attempts),
      ever_escalated: (($old.ever_escalated // false) or ($status == "escalated")),
      commit: (if $commit == "" then ($old.commit // null) else $commit end),
      fingerprint: $fingerprint
    }
  ' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

deps_of(){  jq -r --arg id "$1" '.steps[]|select(.id==$id)|.deps[]?'        "$PLAN" | tr -d '\r'; }
files_of(){ jq -r --arg id "$1" '.steps[]|select(.id==$id)|.files_allowed[]' "$PLAN" | tr -d '\r'; }

declare -A DONE=()
while IFS=$'\t' read -r id commit fingerprint; do
  [[ -n "$id" ]] || continue
  current_fingerprint=$(jq -cS --arg id "$id" '.steps[] | select(.id == $id)' "$PLAN" | sha256sum | cut -d' ' -f1)
  [[ -n "$commit" && "$fingerprint" == "$current_fingerprint" ]] \
    && git merge-base --is-ancestor "$commit" HEAD 2>/dev/null || {
      echo "ABORT: persisted result for $id does not match the current plan or history" >&2
      exit 1
    }
  DONE["$id"]=1
done < <(jq -r '.steps | to_entries[] | select(.value.status == "done") | [.key, .value.commit, .value.fingerprint] | @tsv' "$STATE" | tr -d '\r')
REMAINING=()
while IFS= read -r id; do
  [[ -n "${DONE[$id]:-}" ]] || REMAINING+=("$id")
done < <(jq -r '.steps[].id' "$PLAN" | tr -d '\r')
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
# This trap replaces the lock's own EXIT trap, so it must drop the lock too.
# Otherwise every run ends holding its lock, and a reused pid blocks a clean repo.
cleanup_all(){ cleanup_wt; rm -rf "$LOCK"; }
trap cleanup_all EXIT
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
    # Repo-level model safety policy is read relative to the working directory,
    # so it has to follow the step into its worktree. Untracked by design.
    for policy in .pipeline-model-allow .pipeline-model-exclude; do
      if [[ -f "$policy" ]]; then cp "$policy" "$wt/$policy"; fi
    done
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
    mkdir -p .pipeline/logs .pipeline/raw .pipeline/status
    cp "$wt/.pipeline/code.log" ".pipeline/logs/$s.log" 2>/dev/null || true
    cp "$wt/.pipeline/step_status.json" ".pipeline/status/$s.json" 2>/dev/null || true
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
      attempts=$(jq -r '.attempts // 0' ".pipeline/status/$s.json" 2>/dev/null || echo 0)
      record_step "$s" escalated "$attempts" ""
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
    attempts=$(jq -r '.attempts // 0' ".pipeline/status/$s.json" 2>/dev/null || echo 0)
    record_step "$s" done "$attempts" "$(git rev-parse HEAD)"
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
