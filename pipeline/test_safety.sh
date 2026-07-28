#!/usr/bin/env bash
set -euo pipefail
PIPELINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/repo/.pipeline"
cd "$WORK/repo"

cat > good.json <<'EOF'
{"steps":[
  {"id":"s1","files_allowed":["src/a.txt"],"context_files":[],"deps":[]},
  {"id":"build_2","files_allowed":["src/b.txt"],"context_files":["src/a.txt"],"deps":["s1"]}
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

echo "pipeline safety tests passed"
