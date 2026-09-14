# shellcheck shell=bash
#
# scripts/worktree-safety.sh - the one place bash answers "can this worktree go without losing
# anything" (cb-10d.3). Sourced, never executed; it sets no shell options of its own and relies on
# neither `set -e' nor its absence, because its two callers differ: `prune-worktrees.sh' runs
# `set -uo pipefail', `release-bead --worktree' runs `set -euo pipefail'.
#
#   cerebro_worktree_landed <tree> <default branch> <merged_check> <cold minutes>
#       exit 0 when the tree's work is on origin/<default branch>, or `merged_check' says it landed
#   cerebro_worktree_keep_reason <tree> <default branch> <merged_check> <cold minutes>
#       prints why the tree must be kept, or nothing when it may go; always exit 0
#   cerebro_worktree_remove <owning repository> <tree>
#       removes the tree (never --force) and its branch; exit 1 when git would not remove it
#
# The pruner's other rules - only trees under `.cerebro/worktrees/', the verifier's exception, the
# stale-minutes rule - stay in `prune-worktrees.sh': they are about trees nobody vouches for, and
# `release-bead --worktree' only ever judges a tree recorded for the agent that has left it.
#
# merged_check, the answer to "did this branch's work land?" when the commits are not on origin
# by ancestry (a squash merge rewrites them):
#
#   gh         ask GitHub for a merged PR from this branch. If `gh' cannot answer - no network, not
#              authenticated - the answer is no and the worktree stays. A janitor that guesses
#              permissively is worse than one that leaves a directory behind.
#   none       NOT "skip the check". Pairs the ancestry test with a staleness bound instead: a tree
#              nobody has written to in <cold minutes> is finished with, whoever merged it and how.
#   <command>  run it, with `{branch}' substituted if it appears and the branch appended if it does
#              not; exit 0 means the work landed.

cerebro_worktree_landed() {
  local tree="$1" base="$2" check="$3" cold="$4" branch command_line

  if [ "$(git -C "$tree" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 1)" = "0" ]; then
    return 0
  fi

  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  if [ -z "$branch" ]; then
    return 1
  fi

  case "$check" in
    gh)
      # From the tree, in a subshell. `gh' infers its repository from the process's working
      # directory, so asking from the caller's cwd asks the wrong repository about a branch it has
      # never heard of, reads "not merged", and keeps a delivered tree for ever (ah-apw4).
      if [ "$( (cd "$tree" && gh pr list --head "$branch" --state merged --json number --jq 'length') 2>/dev/null || echo 0)" != "0" ]; then
        return 0
      fi
      return 1
      ;;
    none)
      # Deep, not `-maxdepth 0': a tree's own mtime stops moving while every write lands in a
      # subdirectory that already exists, which would call an actively-used tree cold.
      if [ -z "$(find "$tree" -mmin "-$cold" -print -quit 2>/dev/null)" ]; then
        return 0
      fi
      return 1
      ;;
    *)
      case "$check" in
        *"{branch}"*) command_line="${check//\{branch\}/$branch}" ;;
        *)            command_line="$check $branch" ;;
      esac
      # shellcheck disable=SC2086
      if eval $command_line >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
  esac
}

cerebro_worktree_keep_reason() {
  if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
    echo "it has uncommitted or untracked changes"
  elif ! cerebro_worktree_landed "$1" "$2" "$3" "$4"; then
    echo "it holds work that is not on main yet"
  fi
  return 0
}

cerebro_worktree_remove() {
  local owner="$1" tree="$2" branch
  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  # No `--force'. The caller has already established the tree is clean and landed; forcing would
  # override the very guard that makes this safe, and a removal git refuses is worth reporting.
  if ! git -C "$owner" worktree remove "$tree" 2>/dev/null; then
    return 1
  fi
  # `-d' first, then `-D'. The fallback looks reckless and is not: the work has landed, so either
  # the commits are on main - `-d' succeeds and `-D' never runs - or GitHub says the PR merged and
  # git only calls the branch unmerged because a squash merge rewrote it. Without the fallback every
  # squash-merged branch stays for ever.
  if [ -n "$branch" ]; then
    git -C "$owner" branch -d "$branch" >/dev/null 2>&1 ||
      git -C "$owner" branch -D "$branch" >/dev/null 2>&1 || true
  fi
  return 0
}
