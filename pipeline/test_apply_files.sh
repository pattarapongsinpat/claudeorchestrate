#!/usr/bin/env bash
# Parser tolerance for apply_files.sh. A model that gets the block delimiters
# slightly wrong still produced a complete, correct file; the old exact match
# turned that into zero blocks, no write, exit 0, and three wasted coder calls.
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

apply() { "$PIPELINE_HOME/pipeline/apply_files.sh" "$@"; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- the exact documented form still works ---
cat > out.txt <<'EOF'
<<<<<<< FILE a.txt
hello
>>>>>>> ENDFILE
EOF
rm -f a.txt; apply out.txt a.txt
[[ "$(cat a.txt)" == hello ]] || fail "canonical 7-marker block"

# --- short and long marker runs, the real-world slip ---
for n in 4 5 6 8 12; do
  open=$(printf '<%.0s' $(seq 1 $n))
  close=$(printf '>%.0s' $(seq 1 $n))
  printf '%s FILE a.txt\nrun%s\n%s ENDFILE\n' "$open" "$n" "$close" > out.txt
  rm -f a.txt; apply out.txt a.txt
  [[ "$(cat a.txt)" == "run$n" ]] || fail "marker run of $n not parsed"
done

# --- mismatched open/close lengths, which a model mixes freely ---
printf '<<<<<< FILE a.txt\nmixed\n>>>>>>> ENDFILE\n' > out.txt
rm -f a.txt; apply out.txt a.txt
[[ "$(cat a.txt)" == mixed ]] || fail "mismatched marker lengths"

# --- a Markdown-fenced body: the fence is habit, not content ---
cat > out.txt <<'EOF'
<<<<<<< FILE a.txt
```csharp
int x = 1;
```
>>>>>>> ENDFILE
EOF
rm -f a.txt; apply out.txt a.txt
[[ "$(cat a.txt)" == "int x = 1;" ]] || fail "fenced body not unwrapped"

# --- a fence inside the body is content and must survive ---
cat > out.txt <<'EOF'
<<<<<<< FILE a.txt
# Readme

```sh
echo hi
```
>>>>>>> ENDFILE
EOF
rm -f a.txt; apply out.txt a.txt
[[ "$(grep -c '```' a.txt)" == 2 ]] || fail "inner fences must be preserved"

# --- an unterminated block is still malformed, not a silent success ---
printf '<<<<<<< FILE a.txt\nbroken\n' > out.txt
rc=0; apply out.txt a.txt >/dev/null 2>&1 || rc=$?
[[ $rc -eq 3 ]] || fail "unterminated block should exit 3, got $rc"

# --- scope violations still refuse, whatever the marker length ---
printf '<<<<<< FILE secret.txt\nnope\n>>>>>> ENDFILE\n' > out.txt
rc=0; apply out.txt a.txt >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "out-of-scope path should exit 1, got $rc"
[[ ! -e secret.txt ]] || fail "out-of-scope file was written"

# --- content that merely looks like a marker is not one ---
cat > out.txt <<'EOF'
<<<<<<< FILE a.txt
<<<<<<< HEAD
conflict sample
>>>>>>> branch
>>>>>>> ENDFILE
EOF
rm -f a.txt; apply out.txt a.txt
[[ "$(wc -l < a.txt)" -eq 3 ]] || fail "conflict-marker-looking content was eaten"

echo "apply_files parser OK"
