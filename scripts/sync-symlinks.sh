#!/usr/bin/env bash
set -euo pipefail

# Sync Claude Code customization symlinks from .claude/cerebro into .claude.
# Run from anywhere inside the consumer repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.claude"

# Verify consumer repo root by checking .claude.
if [[ ! -d "$CLAUDE_ROOT" ]]; then
  echo "Required directory not found: $CLAUDE_ROOT" >&2
  exit 1
fi

# Ensure target subdirectories exist.
mkdir -p "$CLAUDE_ROOT/skills" "$CLAUDE_ROOT/agents"

# Remove the old aggregate symlink, from before skills were linked one by one.
if [[ -L "$CLAUDE_ROOT/skills/cerebro" ]]; then
  rm "$CLAUDE_ROOT/skills/cerebro"
  echo "Removed stale aggregate symlink: $CLAUDE_ROOT/skills/cerebro"
fi

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
      # A skill is a directory holding a SKILL.md; anything else is not one.
      [[ -f "$item_path/SKILL.md" ]] || continue
    elif [[ "$item_kind" == "file" ]]; then
      [[ -f "$item_path" ]] || continue
      [[ "$item_path" == *.md ]] || continue
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

sync_links "$SOURCE_ROOT/skills" "$CLAUDE_ROOT/skills" "skill" "dir"
sync_links "$SOURCE_ROOT/agents" "$CLAUDE_ROOT/agents" "agent" "file"
