#!/usr/bin/env bash
# Rewrites generated test titles into bare identifiers, in place.
#
# The tester emits human prose titles: `it('reuses the seed: retry case', ...)`.
# Two things downstream cannot cope with that. validate_test_names.sh requires
# `^[A-Za-z_][A-Za-z0-9_]*$` and rejects the plan, and the runner selectors
# (`vitest -t`, `node --test-name-pattern`, `go -run`) build one regex from the
# mapped names, where a space or a colon either fails to match or matches too much.
# Correcting this by hand at the gate is pure toil, so it happens here, once,
# immediately after generation.
#
# Only javascript and typescript need it. Every other supported language names a
# test with a function declaration, which is already an identifier.
set -euo pipefail
FILE="${1:?usage: normalize_test_names.sh <test-file> <language>}"
LANGUAGE="${2:?usage: normalize_test_names.sh <test-file> <language>}"

case "$LANGUAGE" in
  javascript|typescript) ;;
  *) exit 0 ;;
esac
[[ -f "$FILE" ]] || { echo "normalize: no such file: $FILE" >&2; exit 1; }

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "normalize: no python available; leaving test titles as written" >&2
  exit 0
fi

"$PY" - "$FILE" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    source = handle.read()

seen = {}


def identifier(title):
    ident = re.sub(r"[^A-Za-z0-9]+", "_", title).strip("_")
    if not ident:
        ident = "unnamed_test"
    if not re.match(r"^[A-Za-z_]", ident):
        ident = "t_" + ident
    # Two prose titles can collapse onto one identifier; a duplicate name would
    # make the selector run both and the mapping ambiguous.
    count = seen.get(ident, 0) + 1
    seen[ident] = count
    return ident if count == 1 else f"{ident}_{count}"


# DOTALL with a non-greedy body also catches the generator's habit of putting the
# title on the line after `it(`, which the validator's single-line pattern misses.
pattern = re.compile(r"\b(it|test)\(\s*(['\"])(.+?)\2", re.DOTALL)


def replace(match):
    keyword, quote, title = match.group(1), match.group(2), match.group(3)
    return f"{keyword}({quote}{identifier(title)}{quote}"


rewritten = pattern.sub(replace, source)
if rewritten != source:
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(rewritten)
print(f"normalized {len(seen)} test titles to identifiers", file=sys.stderr)
PY
