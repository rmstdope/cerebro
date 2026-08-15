#!/usr/bin/env bash
# Re-run the symlink sync when the .claude/cerebro gitlink moved between two commits.
#
# Usage: sync-if-changed.sh <old-ref> <new-ref>
#
# Shared by the post-merge and post-checkout hooks. Silent when nothing changed,
# so it can run on every checkout without adding noise.
set -euo pipefail

OLD_REF="${1:-}"
NEW_REF="${2:-}"
SUBMODULE_PATH=".claude/cerebro"

# --show-toplevel here, not scripts/consumer-root: a git hook runs with cwd already inside the
# tree it fires in, so the enclosing tree IS --show-toplevel by definition (ah-e0w).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || exit 0
cd "$REPO_ROOT"

SYNC_SCRIPT="$SUBMODULE_PATH/scripts/sync-symlinks.sh"
[[ -x "$SYNC_SCRIPT" ]] || exit 0

# Missing or unresolvable refs (a first clone, a shallow checkout) mean there is
# no "before" to compare against; sync rather than guess.
if [[ -n "$OLD_REF" && -n "$NEW_REF" ]] \
  && git rev-parse --verify --quiet "$OLD_REF^{commit}" >/dev/null \
  && git rev-parse --verify --quiet "$NEW_REF^{commit}" >/dev/null; then
  if git diff --quiet "$OLD_REF" "$NEW_REF" -- "$SUBMODULE_PATH"; then
    exit 0
  fi
fi

echo "cerebro: $SUBMODULE_PATH changed - syncing customization symlinks"
"$SYNC_SCRIPT"
