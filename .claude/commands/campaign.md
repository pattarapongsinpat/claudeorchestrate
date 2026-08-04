Run a campaign: one request too large for a single `/build`, split once into
build-sized units, each unit a full pipeline run of its own.

On Windows, record the project root once and invoke every pipeline script through
`powershell -ExecutionPolicy Bypass -File "$HOME\.claudeorchestrate\pipeline\invoke.ps1" <script-name> -Repo "<project-root>"`.
Never use bare `bash` on Windows because it may resolve to WSL. On macOS and
Linux, use `bash "$HOME/.claudeorchestrate/pipeline/<script-name>.sh"`.

## 1. Open the campaign

Run pipeline script `campaign_init`. It requires a clean worktree, excludes
`.campaign/`, and records the campaign base.

## 2. Ask, once

Perform the question round from
`$HOME/.claudeorchestrate/.claude/commands/intent.md`: one to three multiple
choice questions in a single `AskUserQuestion` call, the first mandatory and
always what to build. This is the only round the whole campaign gets. No unit
may ask, so a question worth asking is worth asking here — including the scope
question a single build would not need, because the answer decides how many
units there are.

Write `.campaign/brief.txt` in the `request.txt` format: the request verbatim,
then `## Clarifications (verbatim)` with the answers as the user gave them. It
is subject to every rule `intent.md` puts on `request.txt`, for the same reason:
each unit's assumption check and final verifier read it and nothing else.

## 3. Decompose, once

Write `.campaign/backlog.json`:

```json
{"units": [
  {"id": "u1", "title": "short imperative", "request": "self-contained request text"}
]}
```

Ordered. Each unit is one `/build`: a change a single plan can carry, with its
own observable outcome and its own tests. A unit that only makes sense once a
later unit lands is not a unit; merge them. The order is the dependency order,
since units run one at a time on the previous unit's commit.

Each `request` must stand on its own the way `request.txt` must. It is read
beside the brief, not instead of it, but a unit whose text is "the rest of it"
gives the tester nothing to write tests from.

Then run pipeline script `validate_backlog`. It checks the shape and builds
`.campaign/state.json`. Fix what it rejects; do not hand-write the state file.

Then run pipeline script `check_backlog`. It sends DeepSeek the brief and the
units, nothing else, and its exit code is authoritative: 0 continues, 2 means
revise the named unit in `backlog.json` and re-run `validate_backlog` and
`check_backlog`, 3 means the budget is spent and `.campaign/HALT` is written,
1 means the verdict was malformed.

Revising means adding the missing unit or dropping the invented one. It does not
mean arguing with the verdict, and it does not mean editing the brief to fit the
split. This is the only check on the split before it is built: the per-unit
verifier judges each unit against its own text, which is the split restated, and
the campaign verifier runs after every unit has already been committed.

## 4. Run the units

Loop until the campaign ends:

a. Run pipeline script `campaign_next`. Exit 3 means every unit is done, so go
   to step 5. Exit 1 means stopped or broken, so report and stop. Exit 0 prints
   the unit id and writes `.campaign/unit_request.txt`.

b. Run the full `/build` workflow for that unit, in a fresh general-purpose
   subagent, using `$HOME/.claudeorchestrate/.claude/skills/build/SKILL.md` from
   step 1 of its Workflow. The subagent's context is the point: the unit does not
   need this conversation, and the campaign should not carry N build transcripts.
   Tell it the project root, that this is campaign unit `<id>`, that intent will
   find `.campaign/unit_request.txt` and must not ask, and that it must return
   one line: `DONE`, or `FAILED <halt|drift|regression|budget|error>: <reason>`.

c. On `DONE`, run pipeline script `campaign_done` with the unit id. It refuses
   when the unit produced no commit or left the tree dirty; a refusal means the
   subagent reported a success it did not achieve, so treat it as a failure of
   class `error` and record it in step d.

d. On failure, run pipeline script `campaign_fail` with the unit id, the class,
   and the reason. Exit 2 means it reset the worktree to the unit's base and the
   unit gets another attempt, so go back to a. Exit 3 means the campaign stopped:
   report the unit, the reason, and the commits already in place.

   `campaign_fail` archives that attempt's whole `.pipeline/` to
   `.campaign/failed/<unit>-<attempt>/` before it resets, because the next unit's
   `run.sh` deletes it. The retry's `unit_request.txt` carries an excerpt, and the
   full evidence stays on disk. Read it when a campaign stops.

   Do not repair a failed unit yourself and do not edit its backlog entry to make
   it easier. The retry is the whole remedy the campaign has. Escalation inside a
   unit is the build pipeline's job and already happened before the subagent
   reported.

## 5. Verify the campaign

Each unit's own verifier judged that unit against its own text. Nothing has yet
read the whole result against what the user asked for.

Launch a fresh general-purpose subagent with no inherited context. Give it only
the verbatim contents of `.campaign/brief.txt`, the full campaign diff from
`git diff $(cat .campaign/base)..HEAD`, and the question "Would the person who
wrote this brief accept this diff?". Not the backlog, not the unit texts, not
your own assessment: the decomposition is the reading under test.

It returns exactly `ACCEPT` or `DRIFT: <specific divergence>`. Write the response
verbatim to `.campaign/verify.md` and run pipeline script `validate_verify` with
that path. Never revise the verdict. `DRIFT` reports that the split or the brief
was wrong, and must not be patched with another unit.

## 6. Report

Run pipeline script `campaign_status`. Report the verdict, the units and their
commits, and any unit that took more than one attempt. Leave every unit commit
in place; a campaign is not collapsed into one commit.
