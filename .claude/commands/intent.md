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
