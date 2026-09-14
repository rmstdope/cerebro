#!/usr/bin/env bash
#
# Proves `scripts/worktree-safety.sh`: the one place bash answers "can this worktree go without
# losing anything" (cb-10d.3), shared by `prune-worktrees.sh` and `release-bead --worktree`.
#
#     bash tests/worktree-safety.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"
source "$repo_root/scripts/worktree-safety.sh"

consumer="$(consumer_new safety --origin)"
stub="$work_dir/stub"
mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "${GH_MERGED:-0}"
STUB
chmod +x "$stub/gh"
export PATH="$stub:$PATH"

make_tree() {
  git_q -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/$1" -b "$1-branch" origin/main
  echo "$consumer/.cerebro/worktrees/$1"
}

commit_in() {
  echo change >> "$1/file.txt"
  git_q -C "$1" commit -q -am change
}

# --- a clean tree whose work is on origin has no reason to be kept -------------------------------

tree="$(make_tree clean)"
out="$(cerebro_worktree_keep_reason "$tree" main gh 1440)" || fail "keep_reason is exit 0"
[[ -z "$out" ]] || fail "a clean landed tree has no reason, got: $out"
pass "a clean tree whose work is on origin has no reason to be kept"

# --- an untracked file keeps a tree --------------------------------------------------------------

tree="$(make_tree dirty)"
touch "$tree/scratch.txt"
out="$(cerebro_worktree_keep_reason "$tree" main gh 1440)"
[[ "$out" == "it has uncommitted or untracked changes" ]] || fail "untracked keeps, got: $out"
pass "an untracked file keeps a tree"

# --- a local commit keeps a tree -----------------------------------------------------------------

tree="$(make_tree ahead)"
commit_in "$tree"
out="$(cerebro_worktree_keep_reason "$tree" main gh 1440)"
[[ "$out" == "it holds work that is not on main yet" ]] || fail "a local commit keeps, got: $out"
pass "a local commit keeps a tree"

# --- a commit whose PR merged is landed ----------------------------------------------------------

out="$(GH_MERGED=1 cerebro_worktree_keep_reason "$tree" main gh 1440)"
[[ -z "$out" ]] || fail "a merged PR is landed, got: $out"
GH_MERGED=1 cerebro_worktree_landed "$tree" main gh 1440 || fail "landed is exit 0 for a merged PR"
pass "a commit whose PR merged is landed"

# --- merged_check none keeps a recently written tree with a commit -------------------------------

out="$(cerebro_worktree_keep_reason "$tree" main none 1440)"
[[ "$out" == "it holds work that is not on main yet" ]] || fail "none keeps a warm tree, got: $out"
pass "merged_check none keeps a recently written tree with a commit"

# --- removal deletes the tree and its branch -----------------------------------------------------

tree="$(make_tree gone)"
cerebro_worktree_remove "$consumer" "$tree" || fail "removal is exit 0"
[[ ! -e "$tree" ]] || fail "the tree is removed"
! git -C "$consumer" show-ref --verify --quiet refs/heads/gone-branch || fail "the branch is deleted"
pass "removal deletes the tree and its branch"

# --- git's refusal is a status of 1 --------------------------------------------------------------

tree="$(make_tree locked)"
git_q -C "$consumer" worktree lock "$tree"
status=0; cerebro_worktree_remove "$consumer" "$tree" || status=$?
[[ $status -eq 1 ]] || fail "a refused removal is exit 1, got $status"
[[ -e "$tree" ]] || fail "a refused removal leaves the tree"
pass "git's refusal is a status of 1"

# --- the functions behave the same under set -e and without it -----------------------------------

for opts in "-euo pipefail" "-uo pipefail"; do
  # shellcheck disable=SC2086
  out="$(bash $opts -c 'source "$1"; cerebro_worktree_keep_reason "$2" main gh 1440; echo "exit=$?"' \
           _ "$repo_root/scripts/worktree-safety.sh" "$consumer/.cerebro/worktrees/dirty")"
  [[ "$out" == $'it has uncommitted or untracked changes\nexit=0' ]] \
    || fail "keep_reason under set $opts, got: $out"
done
pass "the functions behave the same under set -e and without it"

suite_passed
