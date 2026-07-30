Read `.pipeline/plan_final.json`, `.pipeline/toolchain.json`,
`.pipeline/tests_spec.md`, `.pipeline/review_ctx.md` (full contents of
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

When `verification_mode` is `judgment`, tests do not establish behavioral
correctness. Judge each `done_when` directly from the complete implementation
and the stated host constraint. Report PASS only when the code provides enough
evidence that the requested behavior is correct.

Skip style. Skip anything already enforced mechanically in code.sh —
allowlist, dependencies, test-file edits are handled there and re-flagging
them wastes the call.

Verdict to `.pipeline/review.md`: PASS, or specific defects as file:line.
For duplication, cite BOTH locations.
