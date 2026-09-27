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
#       removes the tree (never --force; a tree git refuses only for containing a submodule is
#       deleted directly) and its branch; exit 1 when git would not remove it
#   cerebro_worktree_bead <tree>
#       the beads the tree may have been made for, one per line: its name, then less a
#       `-mockup' or `-2' suffix
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

# The beads a worktree may have been made for, one per line, most specific first: its directory
# name as it stands, then less the suffix the UX stage adds for a drawing (`<bead>-mockup'), then
# less the one `assign-bead' adds when a name is taken (`<bead>-2'). Candidates rather than one
# answer, because a bead id ends in `-<word>' itself (`cb-7suc', `sq-1') and stripping blindly
# would name a bead that does not exist.
cerebro_worktree_bead() {
  local name
  name="$(basename "$1")"
  printf '%s\n' "$name"
  case "$name" in
    *-mockup) printf '%s\n' "${name%-mockup}" ;;
    *-[0-9]|*-[0-9][0-9]) printf '%s\n' "${name%-*}" ;;
  esac
}

# Whether a commit on origin/<base> names the tree's bead: the fleet's own delivery test
# (`scripts/bead-delivery.sh`), which needs no network. A squash merge rewrites the branch's
# commits, so ancestry says "not on main" for every delivered tree in a squash-merging consumer,
# and when `gh' cannot answer either the tree was kept for ever (cb-7suc: 80 trees, 442 GB).
cerebro_worktree_delivered() {
  local tree="$1" base="$2" here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # bead-delivery reads `project-conf' beside `$script_dir'; a caller that has not set it gets ours.
  script_dir="${script_dir:-$here}"
  # shellcheck source=scripts/bead-delivery.sh
  . "$here/bead-delivery.sh"
  local bead
  while IFS= read -r bead; do
    [ -n "$bead" ] || continue
    if cerebro_bead_delivered "$tree" "$base" "$bead"; then
      return 0
    fi
  done < <(cerebro_worktree_bead "$tree")
  return 1
}

cerebro_worktree_landed() {
  local tree="$1" base="$2" check="$3" cold="$4" branch command_line

  if [ "$(git -C "$tree" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 1)" = "0" ]; then
    return 0
  fi

  if cerebro_worktree_delivered "$tree" "$base"; then
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

cerebro_worktree_locked() {
  # $1 = owning repository, $2 = tree. `worktree list --porcelain' prints one block per tree; the
  # block of a locked one carries a `locked' line.
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk -v tree="$2" '$1 == "worktree" { current = ($2 == tree) } current && $1 == "locked" { found = 1 } END { exit !found }'
}

cerebro_worktree_remove() {
  local owner="$1" tree="$2" branch
  branch="$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  # No `--force'. The caller has already established the tree is clean and landed; forcing would
  # override the very guard that makes this safe, and a removal git refuses is worth reporting.
  #
  # One refusal is not about safety: git will not remove a working tree that contains a submodule,
  # whatever its state ("working trees containing submodules cannot be moved or removed"), and
  # every tree of a consumer with a submodule was kept as "git would not remove it" (cb-7suc). The
  # caller's tests already hold, so such a tree is deleted directly and its registration pruned. A
  # locked tree is still git's to refuse.
  if ! git -C "$owner" worktree remove "$tree" 2>/dev/null; then
    if [ -f "$tree/.gitmodules" ] && ! cerebro_worktree_locked "$owner" "$tree"; then
      rm -rf "$tree" || return 1
      git -C "$owner" worktree prune >/dev/null 2>&1 || true
    else
      return 1
    fi
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
