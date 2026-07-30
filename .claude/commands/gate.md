Read `.pipeline/intent.md`, `.pipeline/intent.json`, `.pipeline/plan.md`,
`.pipeline/tests_spec.md`, and `.pipeline/toolchain.json`.

Rewrite the plan directly. Write `.pipeline/plan_final.json` using the planner
schema plus `tests` and corrected `deps` fields.

Checks:

1. Delete steps that do not trace to the intent goal.
2. Ensure the plan can satisfy the native tests. Record plan or test divergence in `.pipeline/gate_notes.md`.
3. Narrow every `files_allowed` list to the minimum required paths. Keep paths the step must create; never drop one because the file does not exist yet. Add a missing path for a file the step must create, provided it is inside `allowed_files`.
4. Remove anything that violates a Non-goal.
5. Split steps that perform more than one observable change.
6. Add every file defining a consumed type, signature, constant, package, or namespace to `context_files`.
7. Remove paths from `context_files` when they already appear in `files_allowed`.
8. Assign each step a `tests` array containing exact native test case names that verify its `done_when`. Use `.pipeline/toolchain.json` for the language and selector mode. Every generated test must map to at least one step. In existing-suite mode (`generated_tests: false`), always use an empty array so the step runs the full suite, and record the coverage limitation.
   In judgment mode (`verification_mode: "judgment"`), always use an empty
   `tests` array and record why Opus must assess the behavior directly.
9. Set `deps` to exactly the earlier steps whose output each step consumes. Add an edge when a context file is created by another step or when shared files require ordering.
10. Enforce signature fidelity. When `generated_test_file` is present, compare every public call in that file against the intent's exact names, parameter names, order, types, packages, and namespaces. Edit only the configured generated test file to correct drift while preserving behavior. When `generated_tests` is false, do not edit existing tests.

Every `files_allowed` entry must be a subset of `.pipeline/intent.json`
`allowed_files`. The JSON allowlist is authoritative.

Write `.pipeline/gate_notes.md` with every material correction or coverage
limitation. If nothing changed, state that explicitly.
