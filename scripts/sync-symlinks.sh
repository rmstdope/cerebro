#!/usr/bin/env bash
set -euo pipefail
# An empty skills/ or agents/ would otherwise leave the loops below iterating
# once over the literal "*". The -f guards already skip it, so this is about
# saying so rather than relying on them.
shopt -s nullglob

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

# A standalone clone of this repository (e.g. ~/repos/cerebro) climbs the same three levels and
# can land on the user's own ~/.claude, which exists — so the check above is not enough on its
# own. Require that SOURCE_ROOT (.claude/cerebro) actually sits inside the CLAUDE_ROOT it found,
# which is only true when this script is running as a consumer's submodule.
if [[ "$SOURCE_ROOT" != "$CLAUDE_ROOT"/* ]]; then
  echo "sync-symlinks.sh: must run from a consumer repo's .claude/cerebro (found $SOURCE_ROOT)" >&2
  exit 1
fi

# Every link this script writes is RELATIVE, so the same link is correct in the main checkout, in
# every worktree and on every machine — an absolute link would point at one worktree's path and be
# wrong (or dirty the tree) everywhere else (ah-cuc). REL_SOURCE is not relative to $CLAUDE_ROOT
# itself: it is relative to where a link actually lives, one level below $CLAUDE_ROOT
# ($CLAUDE_ROOT/skills/<name>, $CLAUDE_ROOT/agents/<name>) — hence the leading "../" and no more.
REL_SOURCE="../${SOURCE_ROOT#"$CLAUDE_ROOT/"}"

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

    # `ln -sfn` into an existing *directory* does not replace it - it creates the link INSIDE it,
    # so `.claude/skills/plan-bead/plan-bead` appears and `.claude/skills/plan-bead/SKILL.md`
    # stays whatever was there before. Claude Code then keeps loading the old skill and the sync
    # looks like it worked. Caught in atlantis-hud, where three skills had silently not migrated.
    #
    # Refusing rather than deleting: that directory is either a pre-migration copy (yours to
    # remove, and `git rm -r` keeps the history) or a skill of the consumer's own that happens to
    # share a name - and this script cannot tell which, so it must not guess with `rm -rf`.
    if [[ -d "$target" && ! -L "$target" ]]; then
      echo "Refusing to link over the directory $target" >&2
      echo "  It is a real directory, not a symlink, so linking would nest inside it." >&2
      echo "  Remove it (git rm -r '$target') and run this again." >&2
      exit 1
    fi

    ln -sfn "$REL_SOURCE/$(basename "$source_dir")/$item_name" "$target"
    updated=$((updated + 1))
  done

  echo "Synced $updated $label link(s) from $source_dir to $dest_dir"
}

sync_links "$SOURCE_ROOT/skills" "$CLAUDE_ROOT/skills" "skill" "dir"
sync_links "$SOURCE_ROOT/agents" "$CLAUDE_ROOT/agents" "agent" "file"
