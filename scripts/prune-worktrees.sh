#!/usr/bin/env bash
#
# Removes agent worktrees that have nothing left in them.
#
# Every implementer builds its bead in `.cerebro/worktrees/<bead>` and is told to remove it on the way
# out — on every exit, including the ones that go wrong. It does not always get there: a session that
# crashes, is killed, or has its bead merged by somebody else leaves the tree, its branch and its
# build artifacts on disk. They accumulate, and a stray one costs more than space: `git worktree
# list` gets long enough that nobody reads it, and a `main` checked out in an abandoned tree makes
# the next agent's `git checkout main` fail for no visible reason.
#
#     .claude/cerebro/scripts/prune-worktrees.sh              # one sweep, then exit
#     .claude/cerebro/scripts/prune-worktrees.sh --dry-run    # say what would go, remove nothing
#     .claude/cerebro/scripts/prune-worktrees.sh --watch      # sweep every ten minutes until killed
#
# ## What counts as safe
#
# Safe means **nothing can be lost**, which is a stronger and simpler test than "nobody is using it":
#
#   1. It is under `.cerebro/worktrees/` or `.claude/worktrees/`. The main checkout is never
#      touched. The second path is the pre-`.cerebro/`-move location — nothing else sweeps it, and a
#      2.1 GB tree sat there, registered and invisible, until ah-gdp added it here.
#   2. The working tree is clean — no modified files, no untracked ones.
#   3. Its branch holds no commit that `origin/main` does not already have.
#   4. Nothing has changed in it for a while (see STALE_MINUTES), so a tree that was created moments
#      ago and has not been written to yet is left alone.
#
# Fail any one and it stays, with the reason printed. Together they mean the directory can go without
# destroying a line of anybody's work: the commits are on main and there is nothing uncommitted.
#
# One named exception, at **either** path: `psylocke` is kept by name, unconditionally, ahead of all
# four checks. It is Psylocke's own verification tree (ah-p31) — reset hard to `origin/main` before
# every use rather than merged, so it never satisfies "holds no commit main lacks" the way a normal
# agent worktree does, and there is nothing in it to lose by keeping it either way.
#
# Deliberately NOT part of the test: whether the bead is `in_progress`. That sounds like the obvious
# guard and it is the wrong one — an agent that crashed leaves its bead claimed for ever, so keying
# on it would protect exactly the trees most in need of removing. ah-6xq.8 was one: merged, closed by
# nobody, claim still standing, worktree still on disk.
#
# `git worktree prune` runs first regardless. That only clears registrations whose directory is
# already gone, which can never lose anything.
#
# ## Reclaiming a kept tree's build directory
#
# `psylocke` is kept for ever, and every worktree now builds into its own `target/` (ah-gdp:
# `.cargo/config.toml` is tracked, so each worktree's search for it stops at its own root rather
# than reaching a shared one) — so its build tree only ever grows. This sweep reclaims just that
# directory, never the worktree itself, once it has sat unwritten for far longer than
# STALE_MINUTES would ever tolerate for a whole tree (see COLD_TARGET_MINUTES; a day by default —
# Psylocke runs several times a day, so this fires on a quiet weekend rather than between two
# verifications). The rebuild that follows is a cold one; Psylocke's own text already warms it
# again after her reset, so that cost is accepted on purpose.

set -uo pipefail

STALE_MINUTES="${STALE_MINUTES:-30}"
COLD_TARGET_MINUTES="${COLD_TARGET_MINUTES:-1440}"
WATCH_SECONDS="${WATCH_SECONDS:-600}"

case "$COLD_TARGET_MINUTES" in
  ''|*[!0-9]*)
    echo "prune-worktrees: COLD_TARGET_MINUTES must be a positive integer of minutes, got '$COLD_TARGET_MINUTES'" >&2
    exit 2
    ;;
esac

dry_run=false
watch=false
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=true ;;
    --watch) watch=true ;;
    *) echo "usage: .claude/cerebro/scripts/prune-worktrees.sh [--dry-run] [--watch]" >&2; exit 2 ;;
  esac
done

# The shared checkout every worktree of the repository has in common — asked of
# scripts/consumer-root rather than derived from this file's own path, which run from a bead
# worktree would otherwise answer the worktree, not the repository the sweep needs to walk. See
# consumer-root's header for the two roots and why a sweep needs the shared one.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo_root="$("$script_dir/consumer-root" --shared)" || exit 1

# Whether everything in this worktree is already on main.
#
# Two tests, because one is not enough. `origin/main..HEAD` empty catches a branch that was never
# committed to or was merged by fast-forward — but **this repository merges with `--squash`**, which
# writes a brand new commit, so a squash-merged branch's own commits are never reachable from main
# and that test alone would keep every worktree for ever. ah-6xq.8 was the case that found this: PR
# #156 merged, branch fully delivered, and `rev-list` still counting two commits ahead.
#
# So the second test asks GitHub whether a PR from this branch merged. If `gh` cannot answer — no
# network, not authenticated — the answer is no, and the worktree stays. A janitor that guesses in
# the permissive direction is worse than one that leaves a directory behind.
landed_on_main() {
  local tree="$1" branch

  [ "$(git -C "$tree" rev-list --count origin/main..HEAD 2>/dev/null || echo 1)" = "0" ] && return 0

  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  [ -n "$branch" ] || return 1

  [ "$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null || echo 0)" != "0" ]
}

# Removes a kept tree's `target/` when it has sat unwritten for far longer than a whole tree would
# ever be left alone for (COLD_TARGET_MINUTES). This never touches the worktree itself — only a
# directory inside one that is staying. Called only for the tree kept by the `psylocke` name
# exception, before any of the elif safety checks below ever run for it — those checks judge
# whether a *worktree* can be removed, which is a different question from this one; what makes
# removing just its target/ safe is this function's own existence check and the mtime check next.
reclaim_cold_target() {
  local tree="$1" name="$2" target size_gb

  target="$tree/target"
  [ -d "$target" ] || return 0
  # Any file or directory touched within the window, not just target/'s own mtime: a build in
  # progress only bumps that the moment a new top-level entry lands, and stays unchanged while
  # every later write lands in a subdirectory that already exists — `-maxdepth 0` alone
  # misclassified an actively-building tree as cold. `-print -quit` stops at the first match.
  [ -z "$(find "$target" -mmin "-$COLD_TARGET_MINUTES" -print -quit 2>/dev/null)" ] || return 0

  size_gb="$(du -sk "$target" 2>/dev/null | awk '{printf "%.1f", $1 / 1024 / 1024}')"

  if $dry_run; then
    echo "prune-worktrees: would reclaim $name/target ($size_gb GB, cold for over $COLD_TARGET_MINUTES minutes)"
  else
    rm -rf "$target"
    echo "prune-worktrees: reclaimed $name/target ($size_gb GB, cold for over $COLD_TARGET_MINUTES minutes)"
  fi
}

sweep() {
  git -C "$repo_root" worktree prune

  # One fetch per sweep: rule 3 compares against origin/main, and a stale ref would call an already
  # merged branch unmerged and keep every worktree for ever.
  git -C "$repo_root" fetch --quiet origin main 2>/dev/null || {
    echo "prune-worktrees: could not reach origin; skipping this sweep rather than guessing"
    return 0
  }

  local removed=0 kept=0

  while IFS= read -r tree; do
    case "$tree" in
      "$repo_root"/.cerebro/worktrees/*) ;;
      "$repo_root"/.claude/worktrees/*) ;;
      *) continue ;;
    esac

    local name reason=""
    name="$(basename "$tree")"

    if [ "$name" = "psylocke" ]; then
      reason="it is Psylocke's verification tree, reset to origin/main before every use (ah-p31)"
      reclaim_cold_target "$tree" "$name"
    elif [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
      reason="it has uncommitted or untracked changes"
    elif ! landed_on_main "$tree"; then
      reason="it holds work that is not on main yet"
    elif [ -n "$(find "$tree" -maxdepth 0 -mmin "-$STALE_MINUTES" 2>/dev/null)" ]; then
      reason="it was touched in the last $STALE_MINUTES minutes"
    fi

    if [ -n "$reason" ]; then
      echo "prune-worktrees: keeping $name — $reason"
      kept=$((kept + 1))
      continue
    fi

    if $dry_run; then
      echo "prune-worktrees: would remove $name"
      removed=$((removed + 1))
      continue
    fi

    # No `--force`. The checks above already established the tree is clean and merged; forcing would
    # override the very guard that makes this safe, and a removal that git refuses is a surprise
    # worth reporting rather than steamrolling.
    local branch
    branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if git -C "$repo_root" worktree remove "$tree" 2>/dev/null; then
      echo "prune-worktrees: removed $name"
      removed=$((removed + 1))
      # `-d` first, then `-D`. The fallback looks reckless and is not: `landed_on_main` has already
      # passed, so either the commits are on main — in which case `-d` succeeds and `-D` never runs —
      # or GitHub says the PR merged, and git only calls the branch unmerged because a squash merge
      # rewrote it. Without the fallback every squash-merged branch stays for ever.
      if [ -n "$branch" ]; then
        git -C "$repo_root" branch -d "$branch" >/dev/null 2>&1 ||
          git -C "$repo_root" branch -D "$branch" >/dev/null 2>&1
      fi
    else
      echo "prune-worktrees: keeping $name — git would not remove it"
      kept=$((kept + 1))
    fi
  done < <(git -C "$repo_root" worktree list --porcelain | sed -n 's/^worktree //p')

  if [ "$removed" -eq 0 ] && [ "$kept" -eq 0 ]; then
    echo "prune-worktrees: no agent worktrees"
  fi
}

if $watch; then
  while :; do
    sweep
    sleep "$WATCH_SECONDS"
  done
else
  sweep
fi
