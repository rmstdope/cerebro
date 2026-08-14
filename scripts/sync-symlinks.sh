#!/usr/bin/env bash
set -euo pipefail

# Sync Claude Code customization symlinks from .github/cerebro into .github.
# Run from anywhere inside the consumer repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GITHUB_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.github"

# Verify consumer repo root by checking .github.
if [[ ! -d "$GITHUB_ROOT" ]]; then
  echo "Required directory not found: $GITHUB_ROOT" >&2
  exit 1
fi

# Ensure target subdirectories exist.
mkdir -p "$GITHUB_ROOT/skills" "$GITHUB_ROOT/agents"

sync_links() {
  local source_dir="$1"
  local dest_dir="$2"
  local label="$3"
  local item_kind="$4"
  local updated=0

  if [[ ! -d "$source_dir" ]]; then
    echo "Source $label directory not found: $source_dir" >&2
    exit 1
  fi

  for item_path in "$source_dir"/*; do
    if [[ "$item_kind" == "dir" ]]; then
      [[ -d "$item_path" ]] || continue
    elif [[ "$item_kind" == "file" ]]; then
      [[ -f "$item_path" ]] || continue
    else
      echo "Invalid sync item kind: $item_kind" >&2
      exit 1
    fi

    item_name="$(basename "$item_path")"
    target="$dest_dir/$item_name"

    ln -sfn "$item_path" "$target"
    updated=$((updated + 1))
  done

  echo "Synced $updated $label link(s) from $source_dir to $dest_dir"
}

sync_links "$SOURCE_ROOT/skills" "$GITHUB_ROOT/skills" "skill" "dir"
sync_links "$SOURCE_ROOT/agents" "$GITHUB_ROOT/agents" "agent" "file"

