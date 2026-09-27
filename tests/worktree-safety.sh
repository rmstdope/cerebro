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

# --- a squash-merged bead is landed by its delivery commit, with no network -----------------------
#
# cb-7suc: a squash merge rewrites the branch's commits, so ancestry says "not on main", and when
# `gh` cannot answer (no network, not authenticated, another repository) the tree was kept for
# ever. The tree is named for its bead, and a commit on origin/main naming that bead
# (`scripts/bead-delivery.sh`, the fleet's own delivery test) is what "landed" means here.

tree="$(make_tree sq-1)"
commit_in "$tree"
git_q -C "$consumer" checkout -q main
echo squashed >> "$consumer/squash.txt"
git_q -C "$consumer" add squash.txt
git_q -C "$consumer" commit -q -m "feat(sq-1): the squash of that branch"
git_q -C "$consumer" push -q origin main
git_q -C "$consumer" fetch -q origin
out="$(GH_MERGED=0 cerebro_worktree_keep_reason "$tree" main gh 1440)"
[[ -z "$out" ]] || fail "a squash-merged bead's tree is landed by its delivery commit, got: $out"
GH_MERGED=0 cerebro_worktree_landed "$tree" main gh 1440 || fail "landed is exit 0 for a delivered bead without gh"
pass "a squash-merged bead's tree is landed by the commit that names it, with no network"

# A stage suffix on the tree's name (a drawing, a retrospective) still names the bead; a bead id
# that ends in a digit is not stripped into a bead that does not exist.
tree2="$(make_tree sq-1-mockup)"
commit_in "$tree2"
GH_MERGED=0 cerebro_worktree_landed "$tree2" main gh 1440 || fail "a -mockup tree of a delivered bead is landed"
tree3="$(make_tree sq-1-retro)"
commit_in "$tree3"
GH_MERGED=0 cerebro_worktree_landed "$tree3" main gh 1440 || fail "a -retro tree of a delivered bead is landed"
[[ "$(cerebro_worktree_bead "$tree")" == "sq-1" ]] || fail "sq-1 is one candidate, itself: got $(cerebro_worktree_bead "$tree" | tr '\n' ' ')"
pass "a tree named <bead>-mockup or <bead>-retro is judged by its bead, and an id ending in a digit is not stripped"

# A bead nothing on main names is still not landed.
tree4="$(make_tree sq-9)"
commit_in "$tree4"
out="$(GH_MERGED=0 cerebro_worktree_keep_reason "$tree4" main gh 1440)"
[[ "$out" == "it holds work that is not on main yet" ]] || fail "an undelivered bead is kept, got: $out"
pass "a bead no commit on main names is still kept"

# --- removal deletes the tree and its branch -----------------------------------------------------

tree="$(make_tree gone)"
cerebro_worktree_remove "$consumer" "$tree" || fail "removal is exit 0"
[[ ! -e "$tree" ]] || fail "the tree is removed"
! git -C "$consumer" show-ref --verify --quiet refs/heads/gone-branch || fail "the branch is deleted"
pass "removal deletes the tree and its branch"

# --- a tree containing a submodule is removed all the same ------------------------------------------
#
# cb-7suc: `git worktree remove` refuses any tree that contains a submodule, whatever its state
# ("working trees containing submodules cannot be moved or removed"), so every tree of a consumer
# with a submodule was kept as "git would not remove it": 74 of 80 on one machine. The caller has
# already established the tree is clean and landed, so the directory goes and the registration is
# pruned; a locked tree is still refused (below).

sub_origin="$work_dir/sub.git"
git init -q --bare -b main "$sub_origin"
sub_src="$work_dir/sub-src"
git init -q -b main "$sub_src"
git -C "$sub_src" config user.name "cerebro tests"
git -C "$sub_src" config user.email "tests@cerebro.invalid"
git_q -C "$sub_src" commit -q --allow-empty -m init
git_q -C "$sub_src" push -q "$sub_origin" HEAD:main
git_q -C "$consumer" checkout -q main
git_q -C "$consumer" -c protocol.file.allow=always submodule add -q "$sub_origin" vendor/sub
git_q -C "$consumer" commit -q -m "add a submodule"
git_q -C "$consumer" push -q origin main
git_q -C "$consumer" fetch -q origin
tree="$(make_tree withsub)"
# Initialised, as `prepare-worktree` initialises `.cerebro/cerebro` in every builder's tree: git
# refuses on a populated submodule directory, not on the `.gitmodules` entry alone.
git_q -C "$tree" -c protocol.file.allow=always submodule update -q --init
[[ -f "$tree/.gitmodules" && -d "$tree/vendor/sub" ]] || fail "the fixture tree carries an initialised submodule"
git -C "$consumer" worktree remove "$tree" 2>/dev/null && fail "the fixture does not reproduce git's refusal; the case proves nothing"
cerebro_worktree_remove "$consumer" "$tree" || fail "a clean, landed tree with a submodule is removed"
[[ ! -e "$tree" ]] || fail "the tree with a submodule is gone"
git -C "$consumer" worktree list --porcelain | grep -q "worktree $tree$" && fail "the registration is pruned"
! git -C "$consumer" show-ref --verify --quiet refs/heads/withsub-branch || fail "its branch is deleted"
pass "a clean, landed tree containing a submodule is removed, and its registration pruned"

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
