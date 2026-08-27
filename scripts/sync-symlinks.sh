#!/usr/bin/env bash
set -euo pipefail
# An empty skills/ or agents/ would otherwise leave the loops below iterating
# once over the literal "*". The -f guards already skip it, so this is about
# saying so rather than relying on them.
shopt -s nullglob

# Sync the mount's skills and agents into every agent CLI's discovery paths, and mirror the
# project's own definitions between them. Run from anywhere inside the consumer repo.
#
# `scripts/agent-cli --layouts' is the one place a provider's discovery paths are written down;
# this script spells none of them and knows no provider's name. EVERY layout is written in EVERY
# consumer, whatever `agent_cli' declares (cb-d59.4), so that switching a fleet between agent CLIs
# is one line in .cerebro/project.conf and nothing else - the navigator's choice, taken over
# writing only the declared CLI's layout.
#
# So this script now writes OUTSIDE .claude/, which cb-pq4 had reduced it to. That rule was about
# the consumer ROOT - the `.dir-locals.el' it could not merge - and that part of it stands: the
# root is still the project's alone. What is deliberately superseded is only the "nothing outside
# .claude/" summary of it. The second layout lands in `.github/', which is tracked, so the sync
# says so once whenever it writes there.

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

# Every layout's link directory is exactly two components deep (.claude/agents, .github/skills,
# ...), so a link there reaches the consumer root through `../../'. When the mount lives under the
# same first component, one `../' plus the rest of the mount is shorter and is what every consumer
# already has committed - `../cerebro/skills/plan-bead', not `../../.claude/cerebro/skills/...'.
rel_source_for() {                 # $1: the destination directory, relative to the consumer root
  local top="${1%%/*}"
  case "$REL_FROM_ROOT" in
    "$top"/*) printf '%s' "../${REL_FROM_ROOT#"$top"/}" ;;
    *)        printf '%s' "../../$REL_FROM_ROOT" ;;
  esac
}

# Said once per run, and only when a link outside .claude/ was created or repointed: launch-preflight
# syncs before every single session, so an unconditional line would sit above the first prompt of
# every agent for ever.
tracked_note=""
note_tracked_write() {             # $1: the destination directory, relative to the consumer root
  local top="${1%%/*}"
  [[ "$top" == ".claude" ]] && return 0
  tracked_note="$top/ is tracked - commit these links so every clone has them without running this script."
}

# True when writing $2 at $1 would create a link or change where one points. `ln -sfn' cannot tell
# us afterwards, so it is asked before.
link_would_change() {              # $1: the link path, $2: the target about to be written
  [[ -L "$1" ]] || return 0
  [[ "$(readlink "$1")" == "$2" ]] && return 1
  return 0
}

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
  local link_suffix="${5:-}"
  local updated=0
  local rel_dest="${dest_dir#"$consumer_root/"}"
  local rel_source
  rel_source="$(rel_source_for "$rel_dest")"

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
    # A provider may spell an agent file differently (`<role>.agent.md'); a skill keeps its own
    # directory name everywhere, so the suffix is a file-only affair.
    if [[ "$item_kind" == "file" ]]; then
      target="$dest_dir/${item_name%.md}${link_suffix:-.md}"
    else
      target="$dest_dir/$item_name"
    fi

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

    link_to="$rel_source/$(basename "$source_dir")/$item_name"
    link_would_change "$target" "$link_to" && note_tracked_write "$rel_dest"
    ln -sfn "$link_to" "$target"
    updated=$((updated + 1))
  done

  # A link this script wrote for a skill or agent the mount no longer ships dangles after a
  # submodule bump. Remove it, and say so - but ONLY a link that points into the mount: a
  # consumer's own link to somewhere else is not this script's, dangling or not.
  local prefix="$rel_source/$(basename "$source_dir")/"
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

# A consumer may declare a role cerebro does not ship and write .claude/agents/<role>.md itself
# (root CLAUDE.md, *Where the project declares its facts*; scripts/launch reads it). Another CLI
# needs the same content under its own name, so the canonical layout's REAL entries are mirrored
# into every other layout - one way only, because .claude/ is where a project writes its own
# definitions and two sources of truth for one definition is the ambiguity this avoids.
#
# NEVER a symlink: the mount pass has just written .claude/agents/planner.md -> ../cerebro/..., and
# mirroring that would put a link through a link over the mount link written moments earlier.
mirror_links() {
  local source_dir="$1"            # the canonical layout's directory, absolute
  local dest_dir="$2"
  local label="$3"
  local item_kind="$4"
  local link_suffix="${5:-}"
  local updated=0
  local rel_source_dir="${source_dir#"$consumer_root/"}"
  local rel_dest="${dest_dir#"$consumer_root/"}"
  local prefix="../../$rel_source_dir/"

  [[ "$source_dir" == "$dest_dir" ]] && return 0
  [[ -d "$source_dir" ]] || return 0

  local item_path item_name target link_to
  for item_path in "$source_dir"/*; do
    [[ -L "$item_path" ]] && continue          # this script's own mount link, or the project's
    if [[ "$item_kind" == "dir" ]]; then
      [[ -f "$item_path/SKILL.md" ]] || continue
    else
      [[ -f "$item_path" ]] || continue
      [[ "$item_path" == *.md ]] || continue
    fi

    item_name="$(basename "$item_path")"
    if [[ "$item_kind" == "file" ]]; then
      target="$dest_dir/${item_name%.md}${link_suffix:-.md}"
    else
      target="$dest_dir/$item_name"
    fi

    if [[ -d "$target" && ! -L "$target" ]]; then
      echo "Refusing to link over the directory $target" >&2
      echo "  It is a real directory, not a symlink, so linking would nest inside it." >&2
      echo "  Remove it (git rm -r '$target') and run this again." >&2
      exit 1
    fi

    link_to="$prefix$item_name"
    link_would_change "$target" "$link_to" && note_tracked_write "$rel_dest"
    ln -sfn "$link_to" "$target"
    updated=$((updated + 1))
  done

  # Same rule as the mount sweep: remove a link this pass wrote whose source the project has
  # deleted, and nothing else - a link pointing anywhere else is not this script's, dangling or not.
  local link link_target
  for link in "$dest_dir"/*; do
    [[ -L "$link" ]] || continue
    link_target="$(readlink "$link")"
    [[ "$link_target" == "$prefix"* ]] || continue
    [[ -e "$link" ]] && continue
    rm "$link"
    echo "Removed stale $label link: $link (its source is gone)"
  done

  [[ $updated -gt 0 ]] && echo "Mirrored $updated project $label link(s) from $source_dir to $dest_dir"
  return 0
}

# The layouts, read into arrays first: a pipe would build them in a subshell and lose them.
providers=() agents_dirs=() skills_dirs=() suffixes=()
while IFS=$'\t' read -r p ad sd sx; do
  [[ -n "$p" ]] || continue
  providers+=("$p"); agents_dirs+=("$ad"); skills_dirs+=("$sd"); suffixes+=("$sx")
done < <("$SCRIPT_DIR/agent-cli" --layouts)

for i in "${!providers[@]}"; do
  mkdir -p "$consumer_root/${skills_dirs[$i]}" "$consumer_root/${agents_dirs[$i]}"
  sync_links "$SOURCE_ROOT/skills" "$consumer_root/${skills_dirs[$i]}" "skill" "dir"  ""
  sync_links "$SOURCE_ROOT/agents" "$consumer_root/${agents_dirs[$i]}" "agent" "file" "${suffixes[$i]}"
done

# The mirror reads what the mount pass has just written, so it runs after all of it. Row 0 is the
# canonical layout by agent-cli's own rule.
for i in "${!providers[@]}"; do
  [[ $i -eq 0 ]] && continue
  mirror_links "$consumer_root/${skills_dirs[0]}" "$consumer_root/${skills_dirs[$i]}" "skill" "dir"  ""
  mirror_links "$consumer_root/${agents_dirs[0]}" "$consumer_root/${agents_dirs[$i]}" "agent" "file" "${suffixes[$i]}"
done

remove_retired_dir_locals
[[ -n "$tracked_note" ]] && echo "$tracked_note"
exit 0
