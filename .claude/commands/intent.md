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
Paths that may be written. Narrowest set that could satisfy the goal.
Include files that do not exist yet and must be created, at their exact
intended path — a path absent from this list can never be written, and a coder
that needs an undeclared file has no way to ask for it. Directories are created
as needed.
The identical list MUST appear as `allowed_files` in intent.json, which is
authoritative — plan and gate read the JSON, not this prose. Keep them equal.

# Ambiguities
Each: description, the interpretations available, which was chosen, why.

# Verification
`mode: tests` by default. Use `mode: judgment` only when observable behavior
requires a host, hardware, or proprietary runtime that is unavailable to the
pipeline, such as a BepInEx game process. Record a concrete `reason`. Missing
dependencies, a broken suite, or tests that are merely difficult are not valid
reasons. The structured form is
`"verification":{"mode":"tests|judgment","reason":"..."}`. Omit `reason`
for test mode.

# Confidence
high | medium | low

Judgment mode keeps available compilation checks but requires Opus review and
isolated final verification.

Rules:
- `low` → STOP. Write `.pipeline/HALT` with the questions. Do not continue.
- `medium` or `high` → proceed, but every ambiguity must be resolved
  explicitly in Assumptions.
- Underclaiming costs one halt. Overclaiming costs a wrong implementation
  discovered at review. Bias toward `low`.
