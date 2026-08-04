#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$HOME/.claudeorchestrate"
LEGACY_RUNTIME="$HOME/.claudeochestrate"
CLAUDE_HOME="$HOME/.claude"

link_dir() {
  local source="$1" destination="$2"

  if [[ -L "$destination" ]]; then
    [[ "$(cd "$destination" 2>/dev/null && pwd -P)" == "$(cd "$source" && pwd -P)" ]] || {
      echo "symlink already exists and points elsewhere: $destination" >&2
      exit 1
    }
    return
  fi

  if [[ -e "$destination" ]]; then
    echo "path already exists and is not a symlink: $destination" >&2
    echo "remove it and run the installer again." >&2
    exit 1
  fi

  ln -s "$source" "$destination"

  # Git Bash without symlink support silently copies the directory instead of
  # linking it, and reports success. The copy goes stale the moment the
  # repository is updated, and the next run finds a real directory where a link
  # belongs — which is how this surfaced: as "path already exists and points
  # elsewhere" on a second install, long after the wrong thing had been done.
  if [[ ! -L "$destination" ]]; then
    rm -rf "$destination"
    echo "cannot create a symlink at $destination" >&2
    echo "ln -s copied the directory instead of linking it." >&2
    echo "On Windows use install.ps1. To use this script anyway, enable Windows" >&2
    echo "Developer Mode and set MSYS=winsymlinks:nativestrict." >&2
    exit 1
  fi
}

remove_legacy_link() {
  local destination="$1" legacy_target="$2"
  if [[ -L "$destination" && "$(readlink "$destination")" == "$legacy_target" ]]; then
    rm "$destination"
  fi
}

if [[ "$(cd "$ROOT" && pwd -P)" != "$(cd "$HOME" && pwd -P)/.claudeorchestrate" ]]; then
  link_dir "$ROOT" "$RUNTIME"
fi

mkdir -p "$CLAUDE_HOME/skills"
remove_legacy_link "$CLAUDE_HOME/skills/build" "$LEGACY_RUNTIME/.claude/skills/build"
link_dir "$RUNTIME/.claude/skills/build" "$CLAUDE_HOME/skills/build"

remove_legacy_link "$CLAUDE_HOME/commands" "$LEGACY_RUNTIME/.claude/commands"
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
MARKER='<!-- claudeorchestrate:global -->'
touch "$MEMORY"
if grep -Fq "$LEGACY_RUNTIME" "$MEMORY" || grep -Fq '<!-- claudeochestrate:global -->' "$MEMORY"; then
  MIGRATED_MEMORY=$(mktemp)
  sed -e "s|$LEGACY_RUNTIME|$RUNTIME|g" \
      -e 's|<!-- claudeochestrate:global -->|<!-- claudeorchestrate:global -->|g' \
      "$MEMORY" > "$MIGRATED_MEMORY"
  mv "$MIGRATED_MEMORY" "$MEMORY"
fi
if ! grep -Fq "$MARKER" "$MEMORY"; then
  cat >> "$MEMORY" <<EOF

$MARKER
## Autonomous development workflow

Use the globally installed build skill for software changes in Git projects.
Write ordinary changes directly; that is the default. Save \`/build <request>\`
for work that is large, risky, or undecided, and \`/campaign <request>\` for work
too large for one plan. The escalation conditions are in the build skill.

@$RUNTIME/PIPELINE.md
EOF
fi

[[ -f "$RUNTIME/.env" ]] || cp "$RUNTIME/.env.example" "$RUNTIME/.env"

missing=()
for command in git jq curl rg; do
  command -v "$command" >/dev/null 2>&1 || missing+=("$command")
done
if ((${#missing[@]})); then
  echo "install missing prerequisites: ${missing[*]}" >&2
fi

echo "installed Claude orchestration from $ROOT"
echo "set DEEPSEEK_API_KEY in $RUNTIME/.env, then restart Claude Code"
