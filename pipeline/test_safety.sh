#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo/.pipeline"
cd "$WORK/repo"

cat > good.json <<'EOF'
{"steps":[
  {"id":"s1","description":"change a","files_allowed":["src/a.txt"],"context_files":[],"deps":[],"tests":["test_a"],"done_when":"a works"},
  {"id":"build_2","description":"change b","files_allowed":["src/b.txt"],"context_files":["src/a.txt"],"deps":["s1"],"tests":[],"done_when":"b works"}
]}
EOF
"$PIPELINE_HOME/pipeline/validate_plan.sh" good.json >/dev/null

for bad in '../escape' 'bad id' 'x/branch'; do
  jq --arg id "$bad" '.steps[0].id = $id' good.json > bad.json
  if "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1; then
    echo "unsafe plan id accepted: $bad" >&2; exit 1
  fi
done

jq '.steps[1].id = "s1"' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[1].deps = ["missing"]' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[0].context_files = ["../../outside"]' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[0].files_allowed = ["C:\\\\outside.txt"]' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[0].files_allowed = ["src/a.txt", "src/a.txt"]' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[0].context_files = ["src/a.txt"]' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq '.steps[0].tests = "test_a"' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1
jq 'del(.steps[0].done_when)' good.json > bad.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" bad.json >/dev/null 2>&1

cp good.json .pipeline/plan_final.json
printf '%s\n' '{"allowed_files":["src/a.txt"]}' > .pipeline/intent.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" .pipeline/plan_final.json >/dev/null 2>&1
printf '%s\n' '{"allowed_files":["src/a.txt","src/b.txt"]}' > .pipeline/intent.json
"$PIPELINE_HOME/pipeline/validate_plan.sh" .pipeline/plan_final.json >/dev/null
printf '%s\n' '{"allowed_files":["src/a.txt","src/a.txt","src/b.txt"]}' > .pipeline/intent.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" .pipeline/plan_final.json >/dev/null 2>&1
printf '%s\n' '{"allowed_files":["src/a.txt","src/b.txt","../escape"]}' > .pipeline/intent.json
! "$PIPELINE_HOME/pipeline/validate_plan.sh" .pipeline/plan_final.json >/dev/null 2>&1

cat > output.txt <<'EOF'
<<<<<<< FILE src/a.txt
safe
>>>>>>> ENDFILE
EOF
"$PIPELINE_HOME/pipeline/apply_files.sh" output.txt src/a.txt
[[ "$(cat src/a.txt)" == safe ]]
! "$PIPELINE_HOME/pipeline/apply_files.sh" output.txt ../src/a.txt >/dev/null 2>&1

mkdir outside linked-parent
if ln -s "$WORK/repo/outside" linked-parent/link 2>/dev/null && [[ -L linked-parent/link ]]; then
  cat > symlink-output.txt <<'EOF'
<<<<<<< FILE linked-parent/link/escaped.txt
escaped
>>>>>>> ENDFILE
EOF
  rc=0
  "$PIPELINE_HOME/pipeline/apply_files.sh" symlink-output.txt linked-parent/link/escaped.txt >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]]
  [[ ! -e outside/escaped.txt ]]
fi

printf '%s\n' 'api_key="sk-test_123456789012345678901234567890"' > sensitive.txt
readonly_ctx=$("$PIPELINE_HOME/pipeline/ctx.sh" sensitive.txt)
[[ "$readonly_ctx" == *'line redacted'* ]]
[[ "$readonly_ctx" != *'123456789012345678901234567890'* ]]
rc=0
"$PIPELINE_HOME/pipeline/ctx.sh" --writable sensitive.txt >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]

# A reviewed false positive is allowed only while its exact path and line stay
# unchanged. The approval never contains the source text.
false_positive='token = File.ReadAllText(_wakeListeningPath).Trim();'
printf '%s\n' "$false_positive" > reviewed.cs
reviewed_hash=$(printf '%s' "$false_positive" | sha256sum | cut -d' ' -f1)
printf '%s  %s\n' "$reviewed_hash" reviewed.cs > .pipeline-model-allow
reviewed_ctx=$("$PIPELINE_HOME/pipeline/ctx.sh" --writable reviewed.cs)
[[ "$reviewed_ctx" == *'File.ReadAllText'* ]]
printf '%s\n' 'token = File.ReadAllText(otherPath).Trim();' > reviewed.cs
rc=0
"$PIPELINE_HOME/pipeline/ctx.sh" --writable reviewed.cs >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]

printf '%s\n' 'not actually inspected' > .env
rc=0
"$PIPELINE_HOME/pipeline/ctx.sh" --writable .env >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]

# Unsafe intent files halt before plan.sh can invoke a model.
printf '%s\n' 'api_key="sk-test_123456789012345678901234567890"' > unsafe-plan.txt
printf '%s\n' '{"allowed_files":["unsafe-plan.txt"]}' > .pipeline/intent.json
printf '%s\n' '# intent' > .pipeline/intent.md
rm -f .pipeline-model-allow .pipeline/HALT
rc=0
"$PIPELINE_HOME/pipeline/plan.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
grep -Fq 'intent-scoped writable file failed' .pipeline/HALT

printf '%s\n' 'excluded.txt' > .pipeline-model-exclude
printf '%s\n' 'ordinary source' > excluded.txt
excluded_ctx=$("$PIPELINE_HOME/pipeline/ctx.sh" excluded.txt)
[[ "$excluded_ctx" == *'excluded by .pipeline-model-exclude'* ]]
[[ "$excluded_ctx" != *'ordinary source'* ]]
rc=0
"$PIPELINE_HOME/pipeline/ctx.sh" --writable excluded.txt >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]

: > empty.txt
"$PIPELINE_HOME/pipeline/ctx.sh" --writable empty.txt >/dev/null
printf 'text\0binary\n' > binary.dat
rc=0
"$PIPELINE_HOME/pipeline/ctx.sh" --writable binary.dat >/dev/null 2>&1 || rc=$?
[[ "$rc" == 3 ]]

echo "pipeline safety tests passed"
