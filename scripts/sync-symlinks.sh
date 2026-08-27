#!/usr/bin/env bash
set -euo pipefail
# An empty skills/ or agents/ would otherwise leave the loops below iterating
# once over the literal "*". The -f guards already skip it, so this is about
# saying so rather than relying on them.
shopt -s nullglob

# Sync Claude Code customization symlinks from .claude/cerebro into .claude.
# Run from anywhere inside the consumer repo.

# -P (physical) throughout: consumer-root resolves symlinks the same way (macOS mktemp lives
# under /var -> /private/var), and SOURCE_ROOT is compared against paths it hands back.
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
# every worktree and on every machine - an absolute link would point at one worktree's path and be
# wrong (or dirty the tree) everywhere else (ah-cuc). Where this checkout sits under the consumer
# is consumer-root's to say (cb-akc): `.claude/cerebro' for the standard mount and for cerebro
# serving itself through the symlink `.claude/cerebro -> ..' (cb-i3l.1), the physical relative
# path for a submodule vendored elsewhere.
REL_FROM_ROOT="$("$SCRIPT_DIR/consumer-root" --mount)"

# The skill and agent links live one level below $CLAUDE_ROOT ($CLAUDE_ROOT/skills/<name>,
# $CLAUDE_ROOT/agents/<name>), so from there the mount is `../cerebro' - one `../' to reach
# .claude/, then the rest of the mount path. A mount outside .claude/ is two levels up.
case "$REL_FROM_ROOT" in
  .claude/*) REL_SOURCE="../${REL_FROM_ROOT#.claude/}" ;;
  *)         REL_SOURCE="../../$REL_FROM_ROOT" ;;
esac

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

  # A link this script wrote for a skill or agent the mount no longer ships dangles after a
  # submodule bump. Remove it, and say so - but ONLY a link that points into the mount: a
  # consumer's own link to somewhere else is not this script's, dangling or not.
  local prefix="$REL_SOURCE/$(basename "$source_dir")/"
  local link link_target
  for link in "$dest_dir"/*; do
    [[ -L "$link" ]] || continue
    link_target="$(readlink "$link")"
    [[ "$link_target" == "$prefix"* ]] || continue
    [[ -e "$link" ]] && continue          # -e follows the link: the source is still there
    rm "$link"
    echo "Removed stale $label link: $link (its source is gone from the mount)"
  done

  echo "Synced $updated $label link(s) from $source_dir to $dest_dir"
}

# Until cb-pq4 this script linked the consumer's root `.dir-locals.el' to
# templates/consumer-dir-locals.el, so that `M-x cerebro' existed for every contributor. That
# template is gone - the fleet view has its own command, `scripts/cerebro' - and every consumer
# that ever synced still carries the link, which now dangles and which Emacs complains about on
# every file opened. So the link that names the retired template is removed here, and ONLY that
# one: a `.dir-locals.el' the project wrote itself, or linked somewhere of its own, is the
# project's and is not touched. Same shape as the retired-path refusals in roster and
# launch-preflight, and the same class of defect if skipped: found weeks later, in somebody
# else's checkout.
#
# With this, the script writes nothing outside .claude/ at all.
remove_retired_dir_locals() {
  local target="$consumer_root/.dir-locals.el"

  # -L, and no -e: the link is expected to dangle by the time this runs.
  [[ -L "$target" ]] || return 0
  [[ "$(readlink "$target")" == */templates/consumer-dir-locals.el ]] || return 0

  rm "$target"
  echo "Removed stale .dir-locals.el link (templates/consumer-dir-locals.el is gone)"
}

sync_links "$SOURCE_ROOT/skills" "$CLAUDE_ROOT/skills" "skill" "dir"
sync_links "$SOURCE_ROOT/agents" "$CLAUDE_ROOT/agents" "agent" "file"
remove_retired_dir_locals
