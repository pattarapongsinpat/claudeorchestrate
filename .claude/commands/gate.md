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
