#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$HOME/.claudeochestrate"
CLAUDE_HOME="$HOME/.claude"

link_dir() {
  local source="$1" destination="$2"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ "$(cd "$destination" 2>/dev/null && pwd -P)" == "$(cd "$source" && pwd -P)" ]] || {
      echo "path already exists and points elsewhere: $destination" >&2
      exit 1
    }
    return
  fi
  ln -s "$source" "$destination"
}

if [[ "$(cd "$ROOT" && pwd -P)" != "$(cd "$HOME" && pwd -P)/.claudeochestrate" ]]; then
  link_dir "$ROOT" "$RUNTIME"
fi

mkdir -p "$CLAUDE_HOME/skills"
link_dir "$RUNTIME/.claude/skills/build" "$CLAUDE_HOME/skills/build"

if [[ ! -e "$CLAUDE_HOME/commands" ]]; then
  ln -s "$RUNTIME/.claude/commands" "$CLAUDE_HOME/commands"
else
  mkdir -p "$CLAUDE_HOME/commands"
  for source in "$RUNTIME"/.claude/commands/*.md; do
    destination="$CLAUDE_HOME/commands/$(basename "$source")"
    if [[ -e "$destination" ]]; then
      cmp -s "$source" "$destination" || {
        echo "global command conflicts with this project: $destination" >&2
        exit 1
      }
    else
      cp "$source" "$destination"
    fi
  done
fi

MEMORY="$CLAUDE_HOME/CLAUDE.md"
MARKER='<!-- claudeochestrate:global -->'
touch "$MEMORY"
if ! grep -Fq "$MARKER" "$MEMORY"; then
  cat >> "$MEMORY" <<EOF

$MARKER
## Autonomous development workflow

Use the globally installed build skill for software changes in Git projects.

@$RUNTIME/PIPELINE.md
EOF
fi

[[ -f "$RUNTIME/.env" ]] || cp "$RUNTIME/.env.example" "$RUNTIME/.env"

missing=()
for command in git jq curl rg pytest; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if ((${#missing[@]})); then
  echo "install missing prerequisites: ${missing[*]}" >&2
fi

echo "installed Claude orchestration from $ROOT"
echo "set DEEPSEEK_API_KEY in $RUNTIME/.env, then restart Claude Code"
