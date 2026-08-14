#!/usr/bin/env bash
#
# Removes agent worktrees that have nothing left in them.
#
# Every implementer builds its bead in `.claude/worktrees/<bead>` and is told to remove it on the way
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
#   1. It is under `.claude/worktrees/`. The main checkout is never touched.
#   2. The working tree is clean — no modified files, no untracked ones.
#   3. Its branch holds no commit that `origin/main` does not already have.
#   4. Nothing has changed in it for a while (see STALE_MINUTES), so a tree that was created moments
#      ago and has not been written to yet is left alone.
#
# Fail any one and it stays, with the reason printed. Together they mean the directory can go without
# destroying a line of anybody's work: the commits are on main and there is nothing uncommitted.
#
# Deliberately NOT part of the test: whether the bead is `in_progress`. That sounds like the obvious
# guard and it is the wrong one — an agent that crashed leaves its bead claimed for ever, so keying
# on it would protect exactly the trees most in need of removing. ah-6xq.8 was one: merged, closed by
# nobody, claim still standing, worktree still on disk.
#
# `git worktree prune` runs first regardless. That only clears registrations whose directory is
# already gone, which can never lose anything.

set -uo pipefail

STALE_MINUTES="${STALE_MINUTES:-30}"
WATCH_SECONDS="${WATCH_SECONDS:-600}"

dry_run=false
watch=false
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=true ;;
    --watch) watch=true ;;
    *) echo "usage: .claude/cerebro/scripts/prune-worktrees.sh [--dry-run] [--watch]" >&2; exit 2 ;;
  esac
done

# The main checkout, asked of git rather than derived from this file's own path. Run from a worktree
# — which is where an agent usually is — `dirname $0/..` is that worktree, not the repository, so
# every path comparison below would miss and the sweep would silently find nothing. This is the same
# mistake ah-vek fixed in `scripts/cargoTargetDir.test.ts`, which is how it was recognised here.
#
# Two questions, because this script now lives in a submodule. Asking `--git-common-dir` from here
# answers the *submodule's* git directory, so the repository would come out as
# `<consumer>/.git/modules/.claude` and the sweep would again find nothing — measured, not feared.
# `--show-superproject-working-tree` answers the consumer's working tree from inside a submodule and
# nothing at all outside one, which is exactly the distinction needed.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

superproject="$(git -C "$script_dir" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [[ -n "$superproject" ]]; then
  repo_root="$superproject"
else
  # Not a submodule: cerebro checked out on its own, or vendored as a plain directory. Then the
  # enclosing repository is the one to sweep, and `--git-common-dir` answers the main `.git` from
  # anywhere, worktrees included, with the repository one level above it.
  git_common_dir="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "prune-worktrees: not in a git repository" >&2
    exit 1
  }
  repo_root="$(dirname "$git_common_dir")"
fi

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
      "$repo_root"/.claude/worktrees/*) ;;
      *) continue ;;
    esac

    local name reason=""
    name="$(basename "$tree")"

    if [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
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
