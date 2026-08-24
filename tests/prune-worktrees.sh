#!/usr/bin/env bash
#
# Proves scripts/prune-worktrees.sh reclaims a KEPT worktree's `target/` when the disk is near the
# fleet's own build floor, and leaves everything alone when it is not (ah-90gu).
#
# The point of the bead: "live" is not "building". An agent waiting twenty minutes on CI holds a
# stone-cold build tree, and the day-long COLD_TARGET_MINUTES bound cannot see the difference — so
# `prune-worktrees.sh` reclaimed nothing precisely when the floor was tripped and every tree
# belonged to a live agent.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/prune-worktrees.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- stubs -------------------------------------------------------------------------------------
# `df` so the test decides what the disk looks like, and `gh` so `landed_on_main` never asks the
# network. Both ahead of the real ones on PATH, as tests/sweep-stalled.sh does for `bd`.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"
free_kb_file="$work_dir/free_kb"

cat > "$stub_dir/df" <<STUB
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 240000000 100000000 \$(cat "$free_kb_file") 50% /"
STUB
chmod +x "$stub_dir/df"

cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
echo 0
STUB
chmod +x "$stub_dir/gh"

export PATH="$stub_dir:$PATH"

gb_free() { echo $(( $1 * 1024 * 1024 )) > "$free_kb_file"; }

# --- a throwaway consumer with three live agent worktrees --------------------------------------
origin="$work_dir/origin.git"
git init -q --bare "$origin"

consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts" "$consumer/scripts"
git init -q -b main "$consumer"
for s in consumer-root project-conf default-branch roster prune-worktrees.sh; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done

# What this consumer is willing to have reclaimed. Declared rather than assumed since ah-qled.4:
# `reclaim_dirs` defaults to EMPTY, so an unconfigured consumer never has a directory deleted. Every
# assertion below is about what happens once a consumer HAS opted in, which is what this line does;
# tests/project-sweeps.sh owns the opted-out case.
mkdir -p "$consumer/.cerebro"
cat > "$consumer/.cerebro/project.conf" <<'CONF'
reclaim_dirs target
disk_floor_gb 8
CONF

git_q -C "$consumer" add -A
git_q -C "$consumer" commit -q -m "init"
git_q -C "$consumer" remote add origin "$origin"
git_q -C "$consumer" push -q -u origin main

prune="$consumer/.claude/cerebro/scripts/prune-worktrees.sh"

# Each agent tree is live: an untracked file keeps it, exactly as a working implementer's would.
# Its `target/` is aged by hand.
make_tree() {
  local name="$1" minutes="$2"
  local tree="$consumer/.cerebro/worktrees/$name"
  git_q -C "$consumer" worktree add -q "$tree" -b "$name-branch"
  echo scratch > "$tree/untracked.txt"
  mkdir -p "$tree/target/debug/deps"
  head -c 200000 /dev/zero > "$tree/target/debug/deps/blob.o"
  local stamp
  # Local time, not UTC: `touch -t` reads its argument as local time, and stamping it in UTC ages
  # every file by the machine's own offset.
  stamp="$(date -d "@$(( $(date +%s) - minutes * 60 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r $(( $(date +%s) - minutes * 60 )) +%Y%m%d%H%M.%S)"
  find "$tree/target" -exec touch -t "$stamp" {} +
}

make_tree ah-warm 5          # mid-build: must never be touched
make_tree ah-cold 90         # waiting on CI: cold, and the coldest of the two eligible
make_tree ah-cool 45         # also cold, but warmer than ah-cold
make_tree psylocke 5000      # kept by name; never reclaimed under pressure

targets_present() {
  local name
  for name in "$@"; do
    [ -d "$consumer/.cerebro/worktrees/$name/target" ] || return 1
  done
}

# --- 1. ample space reclaims nothing ------------------------------------------------------------
gb_free 40
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999 bash "$prune" 2>&1)"
targets_present ah-warm ah-cold ah-cool psylocke \
  || fail "a target was reclaimed on a roomy disk"
if echo "$out" | grep -qi "reclaim"; then fail "it spoke of reclaiming on a roomy disk: $out"; fi
pass "nothing is reclaimed when free space is comfortable"

# --- 2. under pressure, the coldest goes first --------------------------------------------------
gb_free 5
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999 bash "$prune" 2>&1)"
if [ -d "$consumer/.cerebro/worktrees/ah-cold/target" ]; then
  fail "the coldest tree's target survived under pressure: $out"
fi
targets_present ah-warm ah-cool psylocke \
  || fail "more than the coldest tree went: $out"
pass "under pressure the coldest kept tree's target/ is reclaimed, and only that one"

# --- 3. it says what it did, and why ------------------------------------------------------------
echo "$out" | grep -q "ah-cold/target" || fail "the log did not name the tree: $out"
echo "$out" | grep -qE "\([0-9][0-9.]*[BKMGT]? freed," \
  || fail "the log named no size for what it freed: $out"
echo "$out" | grep -q "5 GB free" || fail "the log did not name the free space that triggered it: $out"
echo "$out" | grep -q "8 GB floor" || fail "the log did not name the floor it was measured against: $out"
echo "$out" | grep -qE "cold for over (30|60) minutes" || fail "the log did not say how cold it was: $out"
pass "the log names the tree, the size, the free space, the floor and the age"

# --- 4. the worktrees themselves are untouched --------------------------------------------------
for name in ah-warm ah-cold ah-cool psylocke; do
  [ -d "$consumer/.cerebro/worktrees/$name" ] \
    || fail "$name's worktree was removed by the pressure path"
done
[ -f "$consumer/.cerebro/worktrees/ah-cold/untracked.txt" ] \
  || fail "ah-cold lost uncommitted work"
pass "the worktree itself is never removed by this path — only its target/"

# --- 5. --dry-run under pressure reclaims nothing -----------------------------------------------
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999 bash "$prune" --dry-run 2>&1)"
echo "$out" | grep -q "would reclaim ah-cool/target" \
  || fail "--dry-run did not name what it would take: $out"
targets_present ah-warm ah-cool psylocke || fail "--dry-run reclaimed something: $out"
pass "--dry-run under pressure names what it would take and takes nothing"

# --- 6. psylocke is never reclaimed by the pressure path ----------------------------------------
# It is the coldest tree on disk by far, and it is 128 MB: reclaiming it costs a verification and
# buys nothing. The day-long outer bound below is the only thing that ever touches it.
gb_free 5
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999 bash "$prune" 2>&1)"
targets_present psylocke || fail "psylocke's target went under pressure: $out"
# And it was exempt by name rather than by there being nothing to take: ah-cool, the only other
# eligible tree left, went on this very sweep.
if [ -d "$consumer/.cerebro/worktrees/ah-cool/target" ]; then
  fail "the sweep reclaimed nothing at all, so psylocke's survival proves nothing: $out"
fi
pass "psylocke is exempt from the pressure path by name, while another tree on the same sweep goes"

# --- 7. the 1440-minute outer bound still applies with no pressure ------------------------------
gb_free 40
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 bash "$prune" 2>&1)"
if [ -d "$consumer/.cerebro/worktrees/psylocke/target" ]; then
  fail "the day-long bound no longer reclaims psylocke's cold target: $out"
fi
targets_present ah-warm || fail "the outer bound took a live agent's warm tree: $out"
pass "the existing COLD_TARGET_MINUTES behaviour is unchanged"

# ================================================================================================
# The janitor and a worktree whose repository is not the consumer (ah-apw4).
#
# A bead whose diff is inside `.claude/cerebro` no longer needs a worktree of the submodule — the
# skill declares the in-place route instead — but the trees older instructions left are real, and
# nothing enumerated them. Two things had to change for them to be seen and taken: `gh` must be
# asked from the tree rather than from the sweep's own working directory, and the sweep must walk
# the submodule's worktree list as well as the consumer's.
#
# Its own fixture, deliberately: the cases above are about the pressure path and must keep passing
# unedited.
# ================================================================================================

sub_stub_dir="$work_dir/bin2"
mkdir -p "$sub_stub_dir"
gh_cwd_log="$work_dir/gh-cwd.log"
gh_merged_branch="$work_dir/gh-merged-branch"
: > "$gh_cwd_log"
: > "$gh_merged_branch"

# Records where it was called from, and calls a branch merged only when the caller asked from the
# right place — which is the whole point of the first assertion below.
cat > "$sub_stub_dir/gh" <<STUB
#!/usr/bin/env bash
pwd >> "$gh_cwd_log"
for arg in "\$@"; do
  if [ "\$arg" = "\$(cat "$gh_merged_branch")" ] && [ -s "$gh_merged_branch" ]; then
    echo 1
    exit 0
  fi
done
echo 0
STUB
chmod +x "$sub_stub_dir/gh"

origin2="$work_dir/origin2.git"
git init -q --bare "$origin2"
consumer2="$work_dir/repo2"
mkdir -p "$consumer2/.claude"
git init -q -b main "$consumer2"
mkdir -p "$consumer2/.cerebro"
cat > "$consumer2/.cerebro/project.conf" <<'CONF'
disk_floor_gb 8
CONF
git_q -C "$consumer2" add -A
git_q -C "$consumer2" commit -q -m "init"
git_q -C "$consumer2" remote add origin "$origin2"
git_q -C "$consumer2" push -q -u origin main

# `.claude/cerebro` is a repository of its own, exactly as the submodule is in a real consumer, and
# the scripts under test are reached through it.
sub_origin="$work_dir/cerebro-origin.git"
git init -q --bare "$sub_origin"
sub="$consumer2/.claude/cerebro"
mkdir -p "$sub/scripts"
git init -q -b main "$sub"
for s in consumer-root project-conf default-branch roster prune-worktrees.sh; do
  ln -s "$repo_root/scripts/$s" "$sub/scripts/$s"
done
git_q -C "$sub" add -A
git_q -C "$sub" commit -q -m "init"
git_q -C "$sub" remote add origin "$sub_origin"
git_q -C "$sub" push -q -u origin main

prune2="$sub/scripts/prune-worktrees.sh"

age() {
  local stamp
  stamp="$(date -d "@$(( $(date +%s) - 600 * 60 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r $(( $(date +%s) - 600 * 60 )) +%Y%m%d%H%M.%S)"
  touch -t "$stamp" "$1"
}

# A consumer tree carrying one commit origin/main lacks: the rev-list test cannot clear it, so
# `landed_on_main` has to ask `gh` — which is what pins where `gh` is asked from.
consumer_tree="$consumer2/.cerebro/worktrees/ah-squashed"
git_q -C "$consumer2" worktree add -q "$consumer_tree" -b ah-squashed-branch
echo delivered > "$consumer_tree/delivered.txt"
git_q -C "$consumer_tree" add -A
git_q -C "$consumer_tree" commit -q -m "delivered by squash"
age "$consumer_tree"

# --- 8. `gh` is asked from the tree, not from the sweep's working directory ---------------------
: > "$gh_cwd_log"
out="$(cd "$consumer2" && PATH="$sub_stub_dir:$PATH" bash "$prune2" --dry-run 2>&1)"
# `pwd` in the stub reports the physical path, so compare against the physical path too — on macOS
# $TMPDIR is a symlink into /private/var and a literal comparison never matches.
consumer_tree_real="$(cd "$consumer_tree" && pwd -P)"
grep -qx "$consumer_tree_real" "$gh_cwd_log" \
  || fail "gh was never asked from the worktree itself (asked from: $(cat "$gh_cwd_log")) — $out"
pass "a_merged_branch_in_another_repository_is_seen: gh is asked from the tree, not the sweep's cwd"

# A worktree of the submodule, under the consumer's own worktree home, clean, old, and carrying a
# commit cerebro's main lacks — i.e. squash-merged, which is how both trees stranded on the machine
# that prompted this bead look.
sub_tree="$consumer2/.cerebro/worktrees/ah-stranded-cerebro"
git_q -C "$sub" worktree add -q "$sub_tree" -b ah-stranded-branch
echo shipped > "$sub_tree/shipped.txt"
git_q -C "$sub_tree" add -A
git_q -C "$sub_tree" commit -q -m "shipped by squash"
age "$sub_tree"
echo "ah-stranded-branch" > "$gh_merged_branch"

# --- 9. the submodule's worktrees are walked at all ---------------------------------------------
out="$(cd "$consumer2" && PATH="$sub_stub_dir:$PATH" bash "$prune2" --dry-run 2>&1)"
echo "$out" | grep -q "would remove ah-stranded-cerebro" \
  || fail "a stranded worktree of the submodule was never enumerated: $out"
pass "a_stranded_submodule_worktree_is_removed: the submodule's worktree list is walked"

# --- 10. the submodule's own git dir is not an agent worktree -----------------------------------
if echo "$out" | grep -qE "(remove|keeping) cerebro( |$|—)"; then
  fail "the submodule's own checkout was treated as an agent worktree: $out"
fi
[ -d "$sub/scripts" ] || fail "the submodule's own checkout was harmed"
pass "the_submodules_own_gitdir_is_not_a_worktree: the first entry is never reported or touched"

# --- 11. the removal uses the owning repository -------------------------------------------------
out="$(cd "$consumer2" && PATH="$sub_stub_dir:$PATH" bash "$prune2" 2>&1)"
echo "$out" | grep -q "removed ah-stranded-cerebro" || fail "it did not remove the stranded tree: $out"
[ ! -d "$sub_tree" ] || fail "the stranded tree is still on disk: $out"
git -C "$sub" worktree list --porcelain | grep -q "ah-stranded-cerebro" \
  && fail "the worktree registration survived, so it was removed from the wrong repository: $out"
git -C "$sub" branch --list ah-stranded-branch | grep -q . \
  && fail "the branch survived in the submodule: $out"
pass "a_stranded_submodule_worktree_is_removed_for_real: removal and branch deletion use the owner"

# --- 12. an unreachable submodule remote costs the submodule half only --------------------------
git_q -C "$sub" remote set-url origin "$work_dir/no-such-remote.git"
out="$(cd "$consumer2" && PATH="$sub_stub_dir:$PATH" bash "$prune2" --dry-run 2>&1)"
echo "$out" | grep -q "ah-squashed" \
  || fail "an unreachable submodule remote aborted the consumer's half of the sweep: $out"
pass "a failed submodule fetch skips the submodule half and leaves the consumer's alone"

# --- 13. a self-mounted cerebro is not swept twice ----------------------------------------------
# When cerebro serves its own fleet, `.claude/cerebro` is a symlink back to the checkout root, so
# the two roots are the SAME repository and its worktree list would otherwise be walked twice —
# every tree enumerated once per owner, tallies inflated, and an already-removed tree reported as
# kept on its second pass.
selfmount="$work_dir/selfmount"
mkdir -p "$selfmount/.claude"
git init -q -b main "$selfmount"
mkdir -p "$selfmount/.cerebro"
cat > "$selfmount/.cerebro/project.conf" <<'CONF'
disk_floor_gb 8
CONF
mkdir -p "$selfmount/scripts"
for s in consumer-root project-conf default-branch roster prune-worktrees.sh; do
  ln -s "$repo_root/scripts/$s" "$selfmount/scripts/$s"
done
ln -s ".." "$selfmount/.claude/cerebro"
git_q -C "$selfmount" add -A
git_q -C "$selfmount" commit -q -m "init"
git_q -C "$selfmount" remote add origin "$work_dir/selfmount-origin.git"
git init -q --bare "$work_dir/selfmount-origin.git"
git_q -C "$selfmount" push -q -u origin main

self_tree="$selfmount/.cerebro/worktrees/ah-self"
git_q -C "$selfmount" worktree add -q "$self_tree" -b ah-self-branch
echo work > "$self_tree/work.txt"
git_q -C "$self_tree" add -A
git_q -C "$self_tree" commit -q -m "not merged"
age "$self_tree"

out="$(cd "$selfmount" && PATH="$sub_stub_dir:$PATH" bash "$selfmount/scripts/prune-worktrees.sh" --dry-run 2>&1)"
[ "$(echo "$out" | grep -c "ah-self")" = "1" ] \
  || fail "a self-mounted cerebro enumerated its worktrees twice: $out"
pass "a self-mounted cerebro is walked once, not twice"

echo "all prune-worktrees assertions passed"
