#!/usr/bin/env bash
set -euo pipefail
# An empty skills/ or agents/ would otherwise leave the loops below iterating
# once over the literal "*". The -f guards already skip it, so this is about
# saying so rather than relying on them.
shopt -s nullglob

# Sync Claude Code customization symlinks from .claude/cerebro into .claude.
# Run from anywhere inside the consumer repo.

# -P (physical) throughout: consumer-root resolves symlinks the same way (macOS mktemp lives
# under /var -> /private/var), and REL_SOURCE below strips CLAUDE_ROOT as a literal prefix of
# SOURCE_ROOT, so the two must agree on which form of the path they use.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# The enclosing tree — the consumer this copy is running as (main checkout, or a bead worktree
# when this copy is the worktree's own submodule). A worktree syncs its own links, which is what
# lets a submodule-bump PR commit them (ah-cuc). See scripts/consumer-root's header for why this
# is not --shared.
consumer_root="$("$SCRIPT_DIR/consumer-root" 2>/dev/null)" || {
  echo "sync-symlinks.sh: must run from a consumer repo's .claude/cerebro (found $SOURCE_ROOT)" >&2
  exit 1
}
CLAUDE_ROOT="$consumer_root/.claude"

# Every link this script writes is RELATIVE, so the same link is correct in the main checkout, in
# every worktree and on every machine — an absolute link would point at one worktree's path and be
# wrong (or dirty the tree) everywhere else (ah-cuc). REL_SOURCE is not relative to $CLAUDE_ROOT
# itself: it is relative to where a link actually lives, one level below $CLAUDE_ROOT
# ($CLAUDE_ROOT/skills/<name>, $CLAUDE_ROOT/agents/<name>) — hence the leading "../" and no more.
REL_SOURCE="../${SOURCE_ROOT#"$CLAUDE_ROOT/"}"

# Unless the source root is not below $CLAUDE_ROOT at all, in which case the strip stripped nothing
# and the line above just glued "../" to the front of an absolute path. That is cerebro serving
# itself (cb-i3l.1): the mount is a symlink `.claude/cerebro -> ..`, so the source root IS the
# consumer root. Link through the mount, which resolves there and reads exactly like every other
# consumer's link - the whole point of mounting by symlink rather than teaching every path here
# about a second layout.
if [[ "$REL_SOURCE" == "../$SOURCE_ROOT" \
      && "$(cd "$CLAUDE_ROOT/cerebro" 2>/dev/null && pwd -P)" == "$SOURCE_ROOT" ]]; then
  REL_SOURCE="../cerebro"
fi

# `.dir-locals.el' lives at the consumer ROOT, one level above where the skill and agent links
# sit, so it needs the source path relative to the root rather than to $CLAUDE_ROOT/<sub>/. Same
# two cases as REL_SOURCE above, for the same reasons: the ordinary submodule (any mount, not just
# .claude/cerebro), and cerebro serving itself, where the strip strips nothing and the mount is
# the answer.
REL_FROM_ROOT="${SOURCE_ROOT#"$consumer_root/"}"
if [[ "$REL_FROM_ROOT" == "$SOURCE_ROOT" ]]; then
  REL_FROM_ROOT=".claude/cerebro"
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

# The one file this script writes outside .claude/, and the one it may not merge: Emacs reads
# exactly one `.dir-locals.el' per directory, so a consumer that has its own already has spent
# the slot. It gets a line on stderr and keeps its file - guessing which of the two sets of
# settings matters is not this script's call, and silently replacing them is the failure that
# would be found weeks later.
#
# Why a link rather than a copy: a change to the form is then carried by a submodule bump, like
# every skill and agent here. Why at all: `M-x cerebro' otherwise costs each contributor an edit
# to their own init, and the fleet view is how this harness is driven.
sync_dir_locals() {
  local template="$SOURCE_ROOT/templates/consumer-dir-locals.el"
  local target="$consumer_root/.dir-locals.el"
  local link="$REL_FROM_ROOT/templates/consumer-dir-locals.el"

  # A submodule from before this template existed. Nothing to link, and nothing wrong.
  [[ -f "$template" ]] || return 0

  if [[ -L "$target" ]]; then
    # Ours, or the consumer's own link to somewhere else? `-L' alone would repoint the latter.
    # Only a link that already names this template is refreshed - which is what moves it when
    # the mount moves.
    if [[ "$(readlink "$target")" == */templates/consumer-dir-locals.el ]]; then
      ln -sfn "$link" "$target"
      echo "Synced .dir-locals.el -> $link"
    else
      echo "Left $target alone: it is a symlink of this project's own." >&2
    fi
    return 0
  fi

  if [[ -e "$target" ]]; then
    echo "Left $target alone: this project has its own." >&2
    echo "  Emacs reads one per directory, so M-x cerebro is not installed by it." >&2
    echo "  To enable it, copy the eval form from $template into that file." >&2
    return 0
  fi

  ln -s "$link" "$target"
  echo "Synced .dir-locals.el -> $link"
}

sync_links "$SOURCE_ROOT/skills" "$CLAUDE_ROOT/skills" "skill" "dir"
sync_links "$SOURCE_ROOT/agents" "$CLAUDE_ROOT/agents" "agent" "file"
sync_dir_locals
