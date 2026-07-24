# Autonomous Opus + DeepSeek Pipeline

Claude Code runs on **Opus as orchestrator**. DeepSeek is called as a **subprocess**, never
as the session model.

## Model roles

| Stage | Model | Why |
|---|---|---|
| Intent | Opus (session) | Judgment under ambiguity; output poisons everything downstream |
| Plan | `deepseek-v4-pro` | Mechanical given clear intent |
| Tests | `deepseek-v4-pro` | Mechanical given clear intent |
| Plan gate | Opus (session) | Architectural judgment; errors compound |
| Code | `deepseek-v4-flash` | Pure mechanical, tight spec |
| Diff review | Opus (session), conditional | Only when mechanical checks can't decide |

Cost shape: ~1.5 Opus calls per task.

## Autonomy note

Removing human confirmation removes the only ground-truth check. Opus validating its own
intent rewrite is self-consistency, not correctness. Two compensations, both specified below:

1. **Confidence gate** (§3) — halt only on high ambiguity, not every run.
2. **Post-hoc intent check** (§8) — Opus re-reads the *original* request against the final
   diff. Genuinely independent, because it compares against the raw request rather than its
   own rewrite.

Without at least one of these, drift is silent.

---

## 1. Layout

```
project/
├─ .claude/
│  ├─ settings.json
│  └─ commands/
│     ├─ build.md
│     ├─ intent.md
│     ├─ gate.md
│     └─ review.md
├─ pipeline/
│  ├─ ds.sh
│  ├─ ctx.sh
│  ├─ plan.sh
│  ├─ tests.sh
│  ├─ code.sh
│  ├─ apply_files.sh
│  ├─ waves.sh
│  └─ run.sh
├─ prompts/
│  ├─ planner.txt
│  ├─ tester.txt
│  └─ coder.txt
└─ .pipeline/          # gitignored run artifacts
```

```bash
export DEEPSEEK_API_KEY=sk-...
chmod +x pipeline/*.sh
echo ".pipeline/" >> .gitignore
```

Requires `jq`, `curl`, `git`, `rg`.

---

## 2. DeepSeek caller

`pipeline/ds.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
MODEL="${3:-deepseek-v4-pro}"
mkdir -p .pipeline/raw
RAW=".pipeline/raw/${MODEL}_$(date +%s%N).json"

jq -n --arg m "$MODEL" --arg s "$(cat "$1")" --arg u "$(cat "$2")" \
  '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],
    stream:false,max_tokens:8000,temperature:0}' \
| curl -sS --fail-with-body --max-time 300 \
    https://api.deepseek.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -d @- > "$RAW"

FIN=$(jq -r '.choices[0].finish_reason // "?"' "$RAW")
[[ "$FIN" == "length" ]] && echo "WARN truncated: $RAW" >&2

jq -r '.choices[0].message.content // "" | select(length>0)
       // (.choices[0].message.reasoning_content // "")' "$RAW" \
| sed -e 's/^```[a-z]*$//' -e 's/^```$//' \
| sed -e '/./,$!d'
```

Plain chat completions. Keeps the Opus session clean. `temperature:0` and an explicit `max_tokens` keep diffs appliable; a `reasoning_content` fallback covers reasoner variants that leave `content` empty, and raw responses are logged to `.pipeline/raw/`.

---

## 3. Intent (Opus, autonomous with confidence gate)

`.claude/commands/intent.md`

```markdown
Convert the request into an intent artifact. Write `.pipeline/intent.md`,
then `.pipeline/intent.json` with the same content as structured data.

Verbatim copy of the original request goes in `.pipeline/request.txt` first —
unmodified, no interpretation. Later stages compare against it.

# Goal
One sentence. Observable outcome, not implementation.

# Assumptions
Everything inferred but not stated. Be exhaustive; this list is the
main failure surface now that no human confirms it.

# Non-goals
Explicit prohibitions. Be aggressive. Name modules not to touch, patterns
not to introduce, dependencies not to add. Vague non-goals do nothing —
"don't over-engineer" is useless, "do not add a caching layer" works.

# Allowed files
Paths that may be modified. Narrowest set that could satisfy the goal.
The identical list MUST appear as `allowed_files` in intent.json, which is
authoritative — plan and gate read the JSON, not this prose. Keep them equal.

# Ambiguities
Each: description, the interpretations available, which was chosen, why.

# Confidence
high | medium | low

Rules:
- `low` → STOP. Write `.pipeline/HALT` with the questions. Do not continue.
- `medium` or `high` → proceed, but every ambiguity must be resolved
  explicitly in Assumptions.
- Underclaiming costs one halt. Overclaiming costs a wrong implementation
  discovered at review. Bias toward `low`.
```

Ambiguity forces enumeration of alternatives, which is what makes autonomous intent
survivable — a wrong choice is at least recorded and checkable at §8.

---

## 4. Plan and tests — parallel, isolated

`pipeline/plan.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }

{
  cat .pipeline/intent.md
  echo
  echo "## Repository structure"
  rg --files | head -200
  echo
  echo "## Files in scope — current contents"
  ./pipeline/ctx.sh $(jq -r '.allowed_files[]' .pipeline/intent.json)
} > $WORK/pin.md

./pipeline/ds.sh prompts/planner.txt $WORK/pin.md deepseek-v4-pro > .pipeline/plan.md
```

`pipeline/tests.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ -f .pipeline/HALT ]] && { echo "halted at intent"; exit 1; }

# intent + signatures ONLY. Never the plan.
cat .pipeline/intent.md > $WORK/tin.md
{
  echo
  echo "## Existing interfaces"
  rg --no-heading -n '^(def |class |func |export function |type |interface )' src/ || true
} >> $WORK/tin.md

# Materialize the tests to a file pytest actually discovers. A spec that only
# lives in .pipeline/ gates nothing — the loop would run the repo's old tests
# and "pass" a step that changed the target behavior not at all.
mkdir -p tests
./pipeline/ds.sh prompts/tester.txt $WORK/tin.md deepseek-v4-pro \
  | tee .pipeline/tests_spec.md > tests/test_generated.py
```

The test writer must not see the plan. A plan-derived test asserts on the plan's internal
shape, so it passes when the implementation matches the plan rather than when behavior is
correct — a wrong plan then gets confirmed by its own tests. Tests derived from intent fail
loudly instead.

Divergence between plan and tests is signal, not noise. The gate consumes it.

`pipeline/ctx.sh` — dumps numbered file contents so the coder and planner see real source, not just paths. `cat -n` is deliberate: the coder needs line numbers to build hunk headers.

```bash
#!/usr/bin/env bash
# usage: ctx.sh <file>... > context.md
set -euo pipefail
for f in "$@"; do
  [[ -z "$f" ]] && continue
  echo "### $f"
  case "$(basename "$f")" in
    .env|.env.*|*.pem|*.key|id_rsa|id_ed25519|*.p12|*.pfx|credentials|credentials.*|secrets|secrets.*)
      echo "(redacted — secret-bearing path, excluded from model context and raw logs)"
      echo
      continue ;;
  esac
  if [[ -f "$f" ]]; then
    echo '```'
    cat -n "$f"
    echo '```'
  else
    echo "(does not exist — create it)"
  fi
  echo
done
```

Secret-bearing paths are redacted before they reach the model or the
`.pipeline/raw/` logs — an in-scope `.env` or key file would otherwise sit in
plaintext in a directory that is gitignored but not otherwise protected.

`prompts/planner.txt`

```
Produce an implementation plan as JSON. Output JSON only, no prose, no fences.

{"steps":[{
  "id":"s1",
  "description":"single observable change",
  "files_allowed":["exact/path.py"],
  "context_files":["src/models.py"],
  "deps":[],
  "done_when":"externally checkable condition"
}]}

files_allowed  — the step MAY modify these. Minimum set.
context_files  — the step must READ these to be implemented correctly, and
                 must NOT modify them. Include anything defining a type,
                 signature, or constant the step depends on.
deps           — ids of steps that must finish first because this step reads
                 or builds on their output. Keep it truthful and minimal:
                 steps with no dep edge and disjoint files_allowed run in
                 PARALLEL, so a false dep serializes needlessly and a missing
                 dep lets a step run before the code it needs exists.

Never list the same path in both. Anything in files_allowed is already
readable.

Rules:
- Each step independently implementable by an agent that sees ONLY that step.
- files_allowed is the minimum. A path listed here that the step doesn't
  strictly need will be rejected at the gate.
- No step may modify test files.
- Order by dependency.
- Respect Non-goals absolutely. They override anything that seems helpful.
```

`prompts/tester.txt`

```
Write tests from the intent. You will NOT see the implementation plan;
this is deliberate. Test the goal, not a presumed structure.

Rules:
- Import the MODULE under test and reference symbols as attributes
  (e.g. `import pkg.mod as m` then `m.func(...)`), not
  `from pkg.mod import func`. Steps are implemented incrementally, so a
  symbol may not exist yet; attribute access makes only that symbol's tests
  fail, whereas a top-level `from ... import` breaks collection for the whole
  file and blocks every earlier step from going green.
- Assert on observable behavior and public interfaces only.
- No assertions about internal helpers, private functions, or call order.
- Cover each Assumption in the intent with at least one test — assumptions
  are unverified inferences and are the likeliest failure point.
- Include tests that would FAIL if a Non-goal were violated where detectable.
- Output runnable test code only.
```

The module-attribute import rule matters because the whole suite lives in one generated file.
A step that implements only its own symbol must still leave the file collectable, or its tests
error at import time and it can never go green — the single most likely multi-step failure, and
the trigger for splitting tests per step (see §10) if it recurs.

---

## 5. Plan gate (Opus — revises, does not approve)

`.claude/commands/gate.md`

```markdown
Read `.pipeline/intent.md`, `.pipeline/plan.md`, `.pipeline/tests_spec.md`.

Rewrite the plan. Do not approve or reject — a rejection round-trip costs an
Opus call plus a DeepSeek regeneration plus a second Opus review. Patching
directly costs one call.

Checks:
1. Does each step trace to the goal? Delete steps that don't.
2. Could the plan satisfy the tests? Divergence means plan or tests misread
   the intent — say which, in `.pipeline/gate_notes.md`.
3. Is any `files_allowed` broader than the step's description requires?
   Narrow it. This is where scope drift originates.
4. Does anything violate a Non-goal? Remove it.
5. Any step doing two things? Split it.
6. Is `context_files` sufficient? A step referencing a type, signature, or
   constant defined elsewhere needs that file listed, or the coder will
   invent a signature that does not exist. Add what is missing.
7. Is anything in `context_files` also in `files_allowed`? Remove it from
   context_files — allowed files are already readable, and the overlap
   makes the allowlist ambiguous.
8. Assign each step a `"tests"` field: a pytest `-k` expression selecting the
   test functions (by name substring, joined with `or`) that verify this
   step's `done_when`. You can see the test code in `tests_spec.md`; the
   planner could not, so this mapping is yours. Every generated test must be
   selected by at least one step. A step with no matching test is a step
   nothing verifies — flag it in `gate_notes.md` rather than inventing a
   selector.
9. Fix `deps`. Each step lists exactly the earlier steps whose output it
   consumes — a step whose `context_files` names another step's not-yet-written
   file needs that step in `deps`. This drives parallelism: `waves.sh` runs
   dep-free, file-disjoint steps concurrently. Two steps sharing a
   `files_allowed` path are serialized by the runner regardless, so do not
   rely on parallelism there; add a dep edge if their order matters. A false
   dep only costs speed; a missing one costs correctness.

Write `.pipeline/plan_final.json` — same schema plus the `tests` field,
tightened. Every `files_allowed` entry must be a subset of
`.pipeline/intent.json` `.allowed_files` (the authoritative allowlist —
the plan and this gate read the JSON, not the intent prose).

Note in `gate_notes.md` whether you changed anything material. If this is
consistently empty across runs, the gate is dead weight and should be cut.
```

---

## 6. Coding loop

`pipeline/code.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
STEP="$1"
PLAN=.pipeline/plan_final.json

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ABORT: tree dirty at entry to $STEP." >&2
  git status --short >&2
  exit 1
fi
BASE=$(git rev-parse HEAD)

# Per-invocation scratch dir so parallel code.sh runs (waves.sh) never clobber
# each other's temp files.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# tr -d '\r': jq on Windows (and CRLF-checked-out plan files) emits trailing CR,
# which would make every allowlist and selector comparison silently miss.
mapfile -t ALLOWED < <(jq -r ".steps[]|select(.id==\"$STEP\")|.files_allowed[]" "$PLAN" | tr -d '\r')
TESTSEL=$(jq -r ".steps[]|select(.id==\"$STEP\")|.tests // empty" "$PLAN" | tr -d '\r')
rm -f $WORK/feedback.md

# A selector that matches no test would make every iteration exit 5 and escalate.
# Fall back to the full suite in that case.
if [[ -n "$TESTSEL" ]] && ! pytest -k "$TESTSEL" --collect-only -q >/dev/null 2>&1; then
  echo "WARN: test selector '$TESTSEL' for $STEP matched nothing; using full suite" >&2
  TESTSEL=""
fi

run_tests() {                       # scoped to the step when the gate assigned a selector
  if [[ -n "$TESTSEL" ]]; then
    pytest -q -k "$TESTSEL" "$@"
  else
    pytest -q "$@"
  fi
}

# Red-before: a step whose tests already pass at BASE asserts nothing about it,
# so the loop's exit condition is satisfiable without real work. Non-fatal —
# a refactor step may legitimately keep tests green — but surfaced for review.
if [[ -n "$TESTSEL" ]] && run_tests > $WORK/redcheck.out 2>&1; then
  { echo "step: $STEP"
    echo "tests '$TESTSEL' already pass at BASE — step is not gated by its tests"
  } > ".pipeline/WARN_${STEP}"
  echo "WARN: $STEP tests green before implementation; loop exit is trivially satisfiable" >&2
fi

MODEL=deepseek-v4-flash
for i in 1 2 3; do
  git checkout "$BASE" -- .
  git clean -fdq 2>/dev/null || true   # entry guard guarantees a clean tree, so every untracked file here is this run's

  [[ $i -ge 2 ]] && MODEL=deepseek-v4-pro

  {
    echo "## Step"
    jq -r ".steps[]|select(.id==\"$STEP\")" "$PLAN"
    echo
    echo "## Files you may modify — current contents"
    ./pipeline/ctx.sh "${ALLOWED[@]}"
    echo
    echo "## Read-only context — do NOT modify these"
    ./pipeline/ctx.sh $(jq -r ".steps[]|select(.id==\"$STEP\")|.context_files[]?" "$PLAN" | tr -d '\r')
  } > $WORK/step.md
  [[ -f $WORK/feedback.md ]] && cat $WORK/feedback.md >> $WORK/step.md

  ./pipeline/ds.sh prompts/coder.txt $WORK/step.md "$MODEL" > $WORK/coder.out

  grep -qx 'NOOP' $WORK/coder.out && { echo "NOOP $STEP"; exit 0; }
  if [[ ! -s $WORK/coder.out ]] || ! grep -q '^<<<<<<< FILE ' $WORK/coder.out; then
    { echo "NO FILE BLOCKS FOUND."
      echo "For each changed file emit its COMPLETE contents between"
      echo "  <<<<<<< FILE <path>"
      echo "  >>>>>>> ENDFILE"
      echo "Nothing outside the blocks. If already satisfied, output: NOOP"
    } > $WORK/feedback.md
    continue
  fi

  # apply_files.sh writes only allowlisted blocks and refuses the rest, so an
  # out-of-scope file never reaches disk. Non-zero => at least one violation.
  if ! ./pipeline/apply_files.sh $WORK/coder.out "${ALLOWED[@]}" > $WORK/viol.out 2>&1; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      echo "Files outside allowlist (not written): $(tr '\n' ' ' < $WORK/viol.out)"
      echo "Allowed only: ${ALLOWED[*]}"
    } > $WORK/feedback.md
    continue
  fi

  # Allowlist is enforced at write time above; these catch a dependency or test
  # file that IS in the allowlist but must still not be edited here.
  TOUCHED=$( { git diff "$BASE" --name-only; git ls-files --others --exclude-standard; } | sort -u )
  DEPS=$(git diff "$BASE" -- package.json requirements.txt pyproject.toml Cargo.toml \
         2>/dev/null | grep '^+[^+]' || true)
  TESTS=$(printf '%s\n' $TOUCHED | grep -E '(test_|_test\.|\.test\.|/tests?/)' || true)

  if [[ -n "$DEPS$TESTS" ]]; then
    { echo "SCOPE VIOLATION — reverted. Redo within bounds."
      [[ -n "$DEPS"  ]] && echo "Dependencies added: $DEPS"
      [[ -n "$TESTS" ]] && echo "Test files modified: $TESTS"
      echo "Allowed only: ${ALLOWED[*]}"
    } > $WORK/feedback.md
    continue
  fi

  if run_tests > $WORK/test.out 2>&1; then
    echo "PASS $STEP (iteration $i)"
    exit 0
  fi
  { echo "TESTS FAILED — your changes were reverted."
    echo "The files you will see next are the ORIGINAL ones, not your attempt."
    echo "Re-output complete file blocks from scratch. Do not assume prior edits exist."
    tail -40 $WORK/test.out
  } > $WORK/feedback.md
done

git checkout "$BASE" -- .
git clean -fdq 2>/dev/null || true
{ echo "step: $STEP"
  echo "exhausted 3 iterations"
  echo "--- last feedback ---"
  cat $WORK/feedback.md 2>/dev/null || true
} > .pipeline/ESCALATE
echo "ESCALATE: $STEP exhausted 3 iterations" >&2
exit 1
```

Loop exit is `tests pass AND files ⊆ allowlist AND no new deps AND no test edits`. The last
three are mechanical — zero model cost, and they catch most scope drift on their own. Try the
allowlist check alone before touching prompts, or you won't know which fix worked.

Cap at 3. A loop that only terminates on green tests rewards passing, not minimality, and a
weak model will grind indefinitely producing increasingly baroque workarounds.

Tests are scoped per step via the gate's `tests` selector, not the whole suite. Two reasons:
a step should not be reverted for a *later* step's still-failing tests, and running one step's
tests is cheaper as the suite grows. The `--collect-only` guard falls back to the full suite
if a selector matches nothing, so a bad selector degrades rather than deadlocks. The red-before
check catches the inverse failure — a step whose tests already pass asserts nothing, making the
loop's exit trivially satisfiable; it warns rather than halts, since a refactor step may keep
tests green legitimately, and leaves the judgment to `/verify`.

`prompts/coder.txt`

```
Implement ONLY the step given.

For every file you change, output its COMPLETE new contents inside a block:

<<<<<<< FILE <path>
<the entire file, exactly as it should exist afterward>
>>>>>>> ENDFILE

Rules for the blocks:
- Output the whole file, not a diff and not a fragment. The file shown to you
  with "cat -n" is the current content; the leading line numbers are NOT part
  of the file — do not reproduce them.
- One block per changed file. Emit blocks only for files in files_allowed.
- Output nothing outside the blocks: no prose, no explanation, no markdown
  fences.
- If the step is already satisfied, output exactly: NOOP

Modify ONLY files in files_allowed.

Do NOT add: error handling, logging, helper functions, abstractions,
comments, configuration, or dependencies not named in the step.
Do NOT modify test files.
Do NOT implement future steps or scaffold for them.
Do NOT refactor adjacent code.

When uncertain, make the smaller change.
```

Whole-file output, not a diff. Live testing showed `deepseek-v4-flash` and `-pro` both emit
`/dev/null` full-file-creation diffs for files that already exist, which never apply — a
guaranteed escalation every run. Asking a weak model to compute exact hunk headers, context
lines, and `@@` line math is the wrong contract; asking it for the finished file is what it is
good at. `apply_files.sh` then writes the file and enforces the allowlist mechanically, so the
diff is never on the model's critical path.

Negative instructions land harder than "be minimal" on weaker models. Drift is pattern
completion — the model fills silence with plausible additions — so silence has to be removed.

`pipeline/apply_files.sh` — parses the whole-file blocks and writes each allowlisted one.
A block whose path is outside the allowlist is refused (never written) and its path reported,
so a scope violation costs nothing on disk.

```bash
#!/usr/bin/env bash
# usage: apply_files.sh <coder_output> <allowed_file>...
set -euo pipefail
OUT="$1"; shift
# Strip CR so a CRLF allowlist or CRLF coder output still matches path keys.
declare -A OK=(); for f in "$@"; do OK["${f%$'\r'}"]=1; done

viol=0; path=""; tmp=""
# Use `if`, not `&&`: a trailing `&& rm` that short-circuits returns 1, and an
# EXIT trap's non-zero status leaks out as the script's exit code.
cleanup(){ if [[ -n "$tmp" && -f "$tmp" ]]; then rm -f "$tmp"; fi; }
trap cleanup EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "<<<<<<< FILE "*)
      path="${line#<<<<<<< FILE }"
      path="${path%$'\r'}"
      path="$(printf '%s' "$path" | sed 's/[[:space:]]*$//')"
      tmp="$(mktemp)"; : > "$tmp"
      ;;
    ">>>>>>> ENDFILE")
      if [[ -z "$path" ]]; then continue; fi
      if [[ -n "${OK[$path]:-}" ]]; then
        mkdir -p "$(dirname "$path")"; cp "$tmp" "$path"
      else
        echo "$path"; viol=1
      fi
      rm -f "$tmp"; tmp=""; path=""
      ;;
    *)
      [[ -n "$path" ]] && printf '%s\n' "$line" >> "$tmp"
      ;;
  esac
done < "$OUT"

exit $viol
```

---

## 6b. Parallel execution across steps

`pipeline/waves.sh` runs the coding phase. It schedules steps into dependency **waves** and, within
a wave, runs steps with **disjoint `files_allowed`** concurrently — each in its own `git worktree`
branched from the wave base, each running `code.sh` unchanged. A successful step is committed in its
worktree and cherry-picked back; disjoint files make the merge conflict-free. Steps that depend on
each other, or that share a file, are serialized (the next wave branches from the merged result, so a
later step sees the earlier one's code). With no deps and disjoint files it is fully parallel; with a
linear dep chain it degrades to the sequential loop.

Two properties make this safe rather than clever:

- **The worktree is the isolation boundary.** Each parallel `code.sh` has its own working tree and
  index, so its revert invariant (`git checkout BASE -- .` + `git clean -fdq`) touches only its own
  checkout. The shared object store is the only contention, and git locks it. `code.sh` also uses a
  per-invocation `mktemp -d` for scratch, so two coders never share `$WORK/coder.out`.
- **The allowlist is the merge guarantee.** Steps batched together are file-disjoint by construction,
  so cherry-picking their commits in sequence never conflicts. A conflict means the plan lied about
  disjointness; `waves.sh` aborts the cherry-pick and stops rather than guessing.

On any step's ESCALATE the run stops with the already-merged commits in place (matching the sequential
design), and the failed step's `.pipeline/ESCALATE` is surfaced. Worktrees and `wt/*` branches are torn
down on exit.

```bash
#!/usr/bin/env bash
set -euo pipefail
PLAN=.pipeline/plan_final.json

deps_of(){  jq -r --arg id "$1" '.steps[]|select(.id==$id)|.deps[]?'        "$PLAN" | tr -d '\r'; }
files_of(){ jq -r --arg id "$1" '.steps[]|select(.id==$id)|.files_allowed[]' "$PLAN" | tr -d '\r'; }
mapfile -t REMAINING < <(jq -r '.steps[].id' "$PLAN" | tr -d '\r')
declare -A DONE=()

while ((${#REMAINING[@]})); do
  # ready = deps satisfied; batch = maximal file-disjoint subset of ready
  ready=(); for s in "${REMAINING[@]}"; do
    ok=1; while read -r d; do [[ -z "$d" ]] && continue; [[ -n "${DONE[$d]:-}" ]] || ok=0; done < <(deps_of "$s")
    ((ok)) && ready+=("$s"); done
  batch=(); declare -A used=(); for s in "${ready[@]}"; do
    conflict=0; while read -r f; do [[ -n "${used[$f]:-}" ]] && conflict=1; done < <(files_of "$s")
    if ((!conflict)); then batch+=("$s"); while read -r f; do used["$f"]=1; done < <(files_of "$s"); fi
  done; unset used

  BASE=$(git rev-parse HEAD)
  declare -A PIDS=()
  for s in "${batch[@]}"; do
    wt=".pipeline/wt/$s"; git worktree add -q -b "wt/$s" "$wt" "$BASE"
    mkdir -p "$wt/.pipeline"; cp "$PLAN" "$wt/.pipeline/plan_final.json"
    ( cd "$wt" && ./pipeline/code.sh "$s" > .pipeline/code.log 2>&1 ) &
    PIDS["$s"]=$!
  done
  for s in "${batch[@]}"; do
    if wait "${PIDS[$s]}"; then
      wt=".pipeline/wt/$s"
      [[ -n "$(git -C "$wt" status --porcelain)" ]] && { git -C "$wt" add -A; git -C "$wt" commit -qm "step $s"; }
      tip=$(git -C "$wt" rev-parse HEAD)
      [[ "$tip" != "$BASE" ]] && { git cherry-pick "$tip" >/dev/null; files_of "$s" >> .pipeline/touched.log; }
      DONE["$s"]=1
    else
      cp ".pipeline/wt/$s/.pipeline/ESCALATE" .pipeline/ESCALATE 2>/dev/null || echo "step: $s" > .pipeline/ESCALATE
      echo "ESCALATE: $s" >&2; exit 1
    fi
  done
  newrem=(); for s in "${REMAINING[@]}"; do [[ -n "${DONE[$s]:-}" ]] || newrem+=("$s"); done
  REMAINING=("${newrem[@]}")
done
```

The listing above is condensed; the shipped script adds worktree cleanup, cycle detection, and
cherry-pick conflict handling. Review now scopes to `run_base..HEAD` (the whole run) rather than a
single `step_base`, which is what you want once steps no longer run in a fixed order.

---

## 7. Conditional full-file review

Opus reads each touched file **in full**, not the diff. A diff shows changed lines without
the surrounding code, which structurally hides the failure modes a weak coder actually
produces: a function added that duplicates one forty lines above, a second implementation of
something already present under a different name, code the step orphaned, an import left
behind. None of these appear as a defect *in* the diff — they appear as a defect in the
relationship between the diff and the rest of the file.

This changes what the stage is for. It stops being a change check and becomes a **coherence
check**: the diff was already validated mechanically and by tests, so the open question is
whether the file makes sense as a whole afterward.

`pipeline/review_ctx.sh` — assemble the review payload

```bash
#!/usr/bin/env bash
# Full contents of every touched file, with a size fallback.
set -euo pipefail
MAXLINES=1500
OUT=.pipeline/review_ctx.md
BASE=$(cat .pipeline/step_base 2>/dev/null || cat .pipeline/run_base)
: > "$OUT"

for f in $(git diff --name-only "$BASE"..HEAD); do
  [[ -f "$f" ]] || continue
  LINES=$(wc -l < "$f")
  {
    echo "### $f  (${LINES} lines)"
    echo '```'
    if (( LINES <= MAXLINES )); then
      cat "$f"
    else
      echo "[file exceeds ${MAXLINES} lines — diff plus 60 lines of context]"
      git diff -U60 "$BASE"..HEAD -- "$f"
    fi
    echo '```'
    echo
  } >> "$OUT"
done

echo "review context: $(wc -l < "$OUT") lines"
```

The ceiling isn't about cost. Review quality degrades when a single file fills most of the
window — attention spreads thin and Opus starts skimming, which is worse than a focused diff
review because it reads as thorough. Above the threshold, fall back to `-U60` for that file
only; other files in the same run still get read in full.

`.claude/commands/review.md`

```markdown
Read `.pipeline/plan_final.json`, `.pipeline/review_ctx.md` (full contents of
every touched file), and `git diff $(cat .pipeline/step_base 2>/dev/null || cat .pipeline/run_base)..HEAD`
to see what this step changed.

You have the whole file deliberately. Review the file as it now stands, not
just the changed lines.

Check:
1. Correctness against the step's `done_when`.
2. Duplication — does the new code reimplement something already in this
   file or an adjacent one? This is the most common weak-model failure and
   it is invisible in a diff.
3. Orphans — code, imports, or branches the change left unreachable.
4. Coherence — does the addition match the file's existing conventions, or
   is it a foreign body that happens to work?
5. Behavior the tests don't cover.

Skip style. Skip anything already enforced mechanically in code.sh —
allowlist, dependencies, test-file edits are handled there and re-flagging
them wastes the call.

Verdict to `.pipeline/review.md`: PASS, or specific defects as file:line.
For duplication, cite BOTH locations.
```

Triggers stay conditional — full-file reading makes each review more valuable, not free.
Fire on: escalation, diff > 150 lines, allowlist violation surviving the loop, test files
touched, or a risky path (`auth`, `payment`, `migration`, `crypto`, `.github/`).

Add one trigger that full-file review makes worth having: **more than one step touched the
same file**. That's where duplication concentrates, because each coding agent saw only its
own step and neither could see what the other had already added.

```bash
# in build orchestration — track repeat touches across steps
git diff --name-only "$(cat .pipeline/step_base)" >> .pipeline/touched.log
REPEAT=$(sort .pipeline/touched.log | uniq -d)
[[ -n "$REPEAT" ]] && touch .pipeline/REVIEW_TRIGGER
```

---

## 8. Post-hoc intent check (Opus)

The compensation for dropping human confirmation.

`.claude/commands/verify.md`

```markdown
Read `.pipeline/request.txt` — the ORIGINAL request, not the intent artifact.
Then read the full run diff: `git diff $(cat .pipeline/run_base)..HEAD`.

Question: would the person who wrote that request accept this diff?

Do not consult intent.md while judging. Its interpretation is the thing
under test — checking the diff against it would confirm any misreading
rather than catch it.

Then read `.pipeline/intent.md` Ambiguities. For each: given the finished
implementation, does the chosen interpretation still look right?

Write `.pipeline/verify.md`: ACCEPT, or DRIFT with the specific divergence.
DRIFT means the intent artifact misread the request — report it rather than
patching the code, because the bug is upstream.
```

This is the only stage comparing against raw user words. Cheap, and it catches the failure
mode that autonomy introduces.

---

## 9. Orchestration

`.claude/commands/build.md`

```markdown
Run the pipeline. Halt immediately if `.pipeline/HALT` appears.

1. /intent — write request.txt, intent.md, intent.json.
   Confidence low → stop, surface questions, do not continue.
2. Run in ONE turn so outputs can't contaminate each other:
   `./pipeline/plan.sh` and `./pipeline/tests.sh`
   Then baseline the suite: `pytest -q`. It MUST be red. A suite that is all
   green before any code means the generated tests assert nothing about the
   change. If green, write `.pipeline/HALT` (test spec is wrong) and stop.
   Commit the generated tests so the tree is clean for the step loop and the
   run diff includes them: `git add -A && git commit -qm "generated tests"`.
   Without this the untracked test file leaves the tree dirty and the step
   loop's entry guard aborts before step 1.
3. /gate — rewrite to plan_final.json (adds per-step `tests` selector and `deps`).
4. Run the steps: `./pipeline/waves.sh`. It schedules the plan into dependency
   waves, runs dep-free file-disjoint steps in parallel git worktrees, commits
   and cherry-picks each success back, and appends to `.pipeline/touched.log`.
   On any step's ESCALATE it stops with the partial commits in place and writes
   `.pipeline/ESCALATE`; do not continue.
5. If a trigger fired (including a repeat-touched file):
   run `./pipeline/review_ctx.sh`, then /review.
   review_ctx.sh must run first — /review reads its output.
6. /verify — always. It reads `git diff $(cat .pipeline/run_base)..HEAD`,
   so run it BEFORE any history collapse.
7. On ACCEPT: collapse the per-step commits into one —
   `git reset --soft "$(cat .pipeline/run_base)" && git commit -qm "<intent goal>"`.
   On DRIFT or ESCALATE: leave the per-step commits in place for inspection.
8. Append one row to `.pipeline/log.csv`.
```

`pipeline/run.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
rm -rf .pipeline && mkdir -p .pipeline
git rev-parse HEAD > .pipeline/run_base
echo "run: $(date -Iseconds)"
echo "base: $(cat .pipeline/run_base)"
echo "next: open claude and run /build"
```

---

## 10. Instrumentation

Twenty tasks, one row each in `.pipeline/log.csv`:

```csv
task,intent_confidence,gate_changed_plan,scope_violations,loop_iters,review_fired,review_ctx_lines,review_found,review_found_needed_full_file,selector_widened,verify_verdict
```

`selector_widened` is true for a step whenever `code.sh` fell back to the full suite because
the gate's `-k` selector matched no test. It is the trigger for the test-file layout decision
below, so it must be recorded, not left to memory.

`review_found_needed_full_file` is the column that justifies this design choice. Mark it true
only when the defect was invisible in the diff alone — duplication, an orphan, a convention
clash. That distinguishes "full-file review found something" from "full-file review found
something a diff review would also have caught."

Decision rules:

- `gate_changed_plan` rarely true → cut the gate, let DeepSeek self-critique.
- `review_fired` often but `review_found` rarely → raise the thresholds.
- `review_found` true but `review_found_needed_full_file` almost never → the extra context
  isn't earning its tokens; revert §7 to reading `git diff -U40`.
- `review_ctx_lines` routinely near the ceiling → your files are too large for this stage to
  work well. Lower `MAXLINES` rather than raising it; a skimmed full file is worse than a
  focused diff.
- `scope_violations` high but resolving inside 3 iterations → mechanical checks are working,
  leave the prompts alone.
- `verify_verdict = DRIFT` more than ~1 in 10 → autonomous intent isn't holding. Restore
  confirmation, or halt on `medium` confidence instead of only `low`.
- `selector_widened` often → the `-k` mapping is fragile (rename drift, substring collisions
  like `test_foo` matching `test_foobar`). Move the split into the gate: have it partition the
  generated tests into `tests/test_<id>.py`, one file per step, and set each step's selector to
  that path. Selection becomes exact instead of inferred at run time, and the `--collect-only`
  fallback stops being load-bearing. The tester stays plan-blind — it still writes one blob
  from intent; the gate, which sees both, does the partitioning. If `selector_widened` is
  rarely true, the flat `tests/test_generated.py` is fine indefinitely: file size alone does
  not force the split, pytest handles large files without complaint.

That last number is the one to watch. It's the direct measure of what dropping the human cost
you, and it's the only stage that can tell you.
