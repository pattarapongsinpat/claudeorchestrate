#!/usr/bin/env bash

# Repository paths are portable, relative Git paths. Reject Windows separators
# as well as dot segments so the same allowlist cannot escape on another host.
safe_repo_path() {
  local path="$1" part
  local -a parts
  [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  [[ "$path" != /* && "$path" != *\\* && "$path" != ?":"* ]] || return 1
  [[ "$path" != */ && "$path" != *//* ]] || return 1
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
  done
}

has_symlink_component() {
  local candidate="$1" part current=""
  local -a parts
  IFS='/' read -r -a parts <<< "$candidate"
  for part in "${parts[@]}"; do
    current="${current:+$current/}$part"
    [[ -L "$current" ]] && return 0
  done
  return 1
}
