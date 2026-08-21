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

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

git_c() { git -c user.name=test -c user.email=test@example.com "$@"; }

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
ln -s "$repo_root/scripts/consumer-root" "$consumer/.claude/cerebro/scripts/consumer-root"
ln -s "$repo_root/scripts/prune-worktrees.sh" "$consumer/.claude/cerebro/scripts/prune-worktrees.sh"

# The one number: the consumer's own build floor, which this sweep must reuse rather than invent a
# second one beside it.
cat > "$consumer/scripts/diskPreflight.ts" <<'TS'
export const FREE_SPACE_FLOOR_GB = 8;
TS

git_c -C "$consumer" add -A
git_c -C "$consumer" commit -q -m "init"
git_c -C "$consumer" remote add origin "$origin"
git_c -C "$consumer" push -q -u origin main

prune="$consumer/.claude/cerebro/scripts/prune-worktrees.sh"

# Each agent tree is live: an untracked file keeps it, exactly as a working implementer's would.
# Its `target/` is aged by hand.
make_tree() {
  local name="$1" minutes="$2"
  local tree="$consumer/.cerebro/worktrees/$name"
  git_c -C "$consumer" worktree add -q "$tree" -b "$name-branch"
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

echo "all prune-worktrees assertions passed"
