#!/usr/bin/env bash
#
# Proves the three sweeps take atlantis-hud's build layout and git conventions from the consumer's
# own declaration rather than from literals in their source (ah-qled.4).
#
# Four things were hardcoded, and two of them in a destructive script:
#
#   * `prune-worktrees.sh` deleted a directory called `target`, so a Node consumer's `node_modules/`
#     was never reclaimed and a consumer whose SOURCE lives in `target/` lost it;
#   * it kept one tree by the literal name `psylocke`, so a consumer that renames its verifier had
#     that tree deleted mid-verification;
#   * it asked GitHub, via `gh`, whether work had landed, so a GitLab or PR-less consumer read
#     "not merged" for ever and the janitor reclaimed nothing;
#   * `sweep-claims.sh` and `sweep-stalled.sh` matched a Conventional-Commits subject and a
#     `<id>-` branch prefix, so a consumer naming branches `feature/PROJ-123` saw every live claim
#     as stalled and every bead as undelivered.
#
# THE SAFETY PROPERTY COMES FIRST: `reclaim_dirs` defaults to EMPTY, so the destructive behaviour is
# opt-in. An unconfigured consumer never has a directory deleted, at any age or under any pressure.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/project-sweeps.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

git_c() { git -c user.name=test -c user.email=test@example.com "$@"; }

# --- stubs ---------------------------------------------------------------------------------------
# `df` so the test decides what the disk looks like, and `gh` so `landed_on_main` never asks the
# network. `gh` answers "no merged PR", which is also what it answers for a consumer that has none.
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

beads_file="$work_dir/beads.json"
echo '[]' > "$beads_file"
cat > "$stub_dir/bd" <<STUB
#!/usr/bin/env bash
cat "$beads_file"
STUB
chmod +x "$stub_dir/bd"

export PATH="$stub_dir:$PATH"
gb_free() { echo $(( $1 * 1024 * 1024 )) > "$free_kb_file"; }

stamp_for() {
  # $1 = minutes ago, as a `touch -t` argument. LOCAL time, not UTC: `touch -t` reads its argument
  # as local time, and stamping in UTC ages every file by the machine's own offset.
  date -d "@$(( $(date +%s) - $1 * 60 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r $(( $(date +%s) - $1 * 60 )) +%Y%m%d%H%M.%S
}

# --- a throwaway consumer ------------------------------------------------------------------------
# Its default branch is `trunk`, not `main`, so nothing here can pass by agreeing with a literal.
branch="trunk"
origin="$work_dir/origin.git"
git init -q --bare "$origin"

consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts" "$consumer/scripts"
git init -q -b "$branch" "$consumer"
for s in consumer-root project-conf default-branch roster \
         prune-worktrees.sh sweep-claims.sh sweep-stalled.sh; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done


conf="$consumer/.claude/cerebro-project.conf"
# Every case declares the same build floor, which is where the floor lives since ah-qled.7.2 - it
# used to be read out of a consumer's TypeScript. The pressure path is off entirely without it, so
# it belongs with `default_branch' in the preamble rather than in each case; the one case that is
# ABOUT its absence writes the file itself.
write_conf() {
  { printf 'default_branch %s\n' "$branch"; printf 'disk_floor_gb 8\n'; cat; } > "$conf"
}
write_conf </dev/null

git_c -C "$consumer" add -A
git_c -C "$consumer" commit -q -m "init"
git_c -C "$consumer" remote add origin "$origin"
git_c -C "$consumer" push -q -u origin "$branch"

prune="$consumer/.claude/cerebro/scripts/prune-worktrees.sh"

# A live agent tree: an untracked file keeps it, exactly as a working implementer's would. Every
# build directory named is created and aged by hand.
make_tree() {
  local name="$1" minutes="$2" base="${3:-.cerebro}"; shift 3 2>/dev/null || shift 2
  local tree="$consumer/$base/worktrees/$name" d
  mkdir -p "$(dirname "$tree")"
  git_c -C "$consumer" worktree add -q "$tree" -b "$name-branch"
  echo scratch > "$tree/untracked.txt"
  for d in "$@"; do
    mkdir -p "$tree/$d/deps"
    head -c 200000 /dev/zero > "$tree/$d/deps/blob.o"
    find "$tree/$d" -exec touch -h -t "$(stamp_for "$minutes")" {} +
  done
}

present() {
  local p
  for p in "$@"; do [ -e "$p" ] || return 1; done
}

run_prune() { (cd "$consumer" && env "$@" bash "$prune" 2>&1); }

# =================================================================================================
# 1. THE SAFETY PROPERTY: with no `reclaim_dirs`, nothing is ever deleted
# =================================================================================================
make_tree ah-cold 5000 .cerebro target node_modules
make_tree psylocke 5000 .cerebro target node_modules

gb_free 5   # hard against the 8 GB floor: maximum pressure
out="$(run_prune PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=1)"
present "$consumer/.cerebro/worktrees/ah-cold/target" \
        "$consumer/.cerebro/worktrees/ah-cold/node_modules" \
        "$consumer/.cerebro/worktrees/psylocke/target" \
        "$consumer/.cerebro/worktrees/psylocke/node_modules" \
  || fail "an unconfigured consumer had a directory reclaimed: $out"
grep -qi "reclaim" <<<"$out" && fail "it spoke of reclaiming with no reclaim_dirs declared: $out"
pass "with no reclaim_dirs declared, nothing is reclaimed at any age or under any pressure"

# A consumer whose SOURCE lives in target/ keeps it. Same property, stated the way it bites.
[ -f "$consumer/.cerebro/worktrees/ah-cold/target/deps/blob.o" ] \
  || fail "a consumer whose source lives in target/ lost it"
pass "a consumer whose source lives in target/ and declares nothing keeps it"

# =================================================================================================
# 2. What is declared is what goes
# =================================================================================================
write_conf <<'CONF'
reclaim_dirs target node_modules
CONF

mkdir -p "$consumer/.cerebro/worktrees/ah-cold/src"
echo keep > "$consumer/.cerebro/worktrees/ah-cold/src/main.rs"
find "$consumer/.cerebro/worktrees/ah-cold/src" -exec touch -h -t "$(stamp_for 5000)" {} +

# Roomy on purpose: only the outer COLD_TARGET_MINUTES bound is in play, and the verifier's tree —
# psylocke, on the built-in roster this fixture has not yet overridden — is what it reclaims from.
# That is the one path that walks EVERY declared directory rather than picking a single coldest one,
# so it is where "all of them, not just the first" can be asserted at all.
gb_free 40
out="$(run_prune PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=1)"
[ -d "$consumer/.cerebro/worktrees/psylocke/target" ] \
  && fail "the first declared dir was not reclaimed from the kept tree: $out"
[ -d "$consumer/.cerebro/worktrees/psylocke/node_modules" ] \
  && fail "only the first declared dir went — the second was never reclaimed: $out"
grep -q "psylocke/target" <<<"$out" || fail "the log did not name target: $out"
grep -q "psylocke/node_modules" <<<"$out" || fail "the log did not name node_modules: $out"
present "$consumer/.cerebro/worktrees/ah-cold/src/main.rs" \
  || fail "an undeclared directory was reclaimed: $out"
pass "every declared directory is reclaimed, not just the first, and an undeclared one is left alone"

# =================================================================================================
# 3. The verifier is found on the roster, not named in the source
# =================================================================================================
cat > "$consumer/.claude/cerebro-roster" <<'ROSTER'
Oracle    verifier
Cyclops   implementer
ROSTER

# Oracle's tree at BOTH paths — the exception is by name, not by location — and `psylocke`, who is
# nobody on this roster and must now be swept like any other tree.
make_tree oracle 5000 .cerebro target
# The same basename at the legacy path — the exception is by NAME, not by location — so it needs a
# branch of its own; two worktrees cannot hold one branch.
mkdir -p "$consumer/.claude/worktrees"
git_c -C "$consumer" worktree add -q "$consumer/.claude/worktrees/oracle" -b oracle-legacy-branch
echo scratch > "$consumer/.claude/worktrees/oracle/untracked.txt"

gb_free 40
out="$(run_prune PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999)"
grep -q "keeping oracle" <<<"$out" || fail "the renamed verifier's tree was not kept: $out"
[ "$(grep -c "keeping oracle —" <<<"$out")" = "2" ] \
  || fail "the verifier exception did not hold at both paths: $out"
grep -q "keeping psylocke — it is" <<<"$out" \
  && fail "psylocke was still exempt by name on a roster that does not list her: $out"
pass "the verifier exception follows the roster, at either path, and no name literal survives"

# Case-insensitively, as the code always matched: the roster says `Oracle`, the tree is `oracle`.
pass "the roster name is matched case-insensitively, as the lowercased literal was"

# A roster with no verifier at all keeps nobody by that exception, and still deletes nothing it
# should not — every tree here is live, so every one is kept for an ordinary reason.
cat > "$consumer/.claude/cerebro-roster" <<'ROSTER'
Cyclops   implementer
ROSTER
out="$(run_prune PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=99999)"
grep -q "it is .*verification tree" <<<"$out" \
  && fail "a roster with no verifier still granted the exception: $out"
present "$consumer/.cerebro/worktrees/oracle" "$consumer/.claude/worktrees/oracle" \
  || fail "a roster with no verifier deleted a live tree: $out"
pass "a roster with no verifier grants the exception to nobody and deletes nothing extra"

# `.claude/worktrees/` is still swept. It is NOT vestigial: a live tree sits there in atlantis-hud
# today (ah-aln5 decides which path is canonical), and dropping it would leave that tree unmanaged.
grep -q "keeping oracle" <<<"$out" || fail ".claude/worktrees/ is no longer swept at all: $out"
pass ".claude/worktrees/ is still swept, so a live tree there is not left unmanaged"

# =================================================================================================
# 4. `merged_check: none` still reclaims — it is not "skip the check"
# =================================================================================================
# `landed_on_main`'s rev-list test cannot see a SQUASH merge, and with no `gh` to ask, a squash
# -merging consumer would keep every delivered worktree for ever. So `none` pairs the rev-list test
# with the staleness bound: a clean tree nobody has written to in far longer than a whole tree is
# ever left alone for is finished with, whoever merged it and however.
rm -f "$consumer/.claude/cerebro-roster"
squashed="$consumer/.cerebro/worktrees/ah-squash"
git_c -C "$consumer" worktree add -q "$squashed" -b ah-squash-branch
git_c -C "$squashed" commit -q --allow-empty -m "feat(ah-squash): delivered, then squashed"
# `-h`: this worktree has the consumer's tracked symlinks into the real cerebro checkout in
# it, and `touch` without `-h` follows them — aging the wrong files and leaving these warm.
find "$squashed" -exec touch -h -t "$(stamp_for 5000)" {} +

write_conf <<'CONF'
merged_check none
CONF
out="$(run_prune STALE_MINUTES=1 COLD_TARGET_MINUTES=1440)"
[ -d "$squashed" ] && fail "with merged_check none a squash-merged tree was kept for ever: $out"
pass "merged_check none reclaims a squash-merged tree via the staleness bound"

# And it is a BOUND, not a free pass: a tree touched moments ago is still kept.
warm="$consumer/.cerebro/worktrees/ah-warm"
git_c -C "$consumer" worktree add -q "$warm" -b ah-warm-branch
git_c -C "$warm" commit -q --allow-empty -m "feat(ah-warm): still being worked on"
out="$(run_prune STALE_MINUTES=1 COLD_TARGET_MINUTES=1440)"
present "$warm" || fail "merged_check none removed a tree that is still being written to: $out"
pass "merged_check none keeps a tree that is still warm"

# --- an arbitrary command can answer for a consumer with neither gh nor squash merges ------------
cat > "$work_dir/merged-oracle" <<'CMD'
#!/usr/bin/env bash
[ "$1" = "ah-warm-branch" ]
CMD
chmod +x "$work_dir/merged-oracle"
write_conf <<CONF
merged_check $work_dir/merged-oracle {branch}
CONF
find "$warm" -exec touch -h -t "$(stamp_for 60)" {} +
out="$(run_prune STALE_MINUTES=1)"
[ -d "$warm" ] && fail "the consumer's own merged check said merged and the tree survived: $out"
pass "merged_check <command> lets a consumer answer whether work landed"

# =================================================================================================
# 5. Delivery and branches are patterns, and the defaults reproduce today exactly
# =================================================================================================
git_c -C "$consumer" commit -q --allow-empty -m "feat(ah-conv): the conventional-commits subject"
git_c -C "$consumer" commit -q --allow-empty -m "PROJ-9 done: an id that is not a scope at all"
git_c -C "$consumer" push -q origin "$branch"

cat > "$beads_file" <<'JSON'
[{"id": "ah-conv", "assignee": "Cyclops", "title": "conventional"},
 {"id": "PROJ-9",  "assignee": "Storm",   "title": "not conventional"}]
JSON

claims="$consumer/.claude/cerebro/scripts/sweep-claims.sh"
write_conf </dev/null
out="$(cd "$consumer" && "$claims" --json)"
[ "$(jq -r '.[] | select(.id=="ah-conv") | .on_main' <<<"$out")" = "true" ] \
  || fail "the default commit_ref_pattern no longer detects today's delivery: $out"
[ "$(jq -r '.[] | select(.id=="PROJ-9") | .on_main' <<<"$out")" = "false" ] \
  || fail "the default pattern matched a subject it never did before: $out"
pass "the default commit_ref_pattern reproduces today's delivery detection exactly"

write_conf <<'CONF'
commit_ref_pattern {id} done:
CONF
out="$(cd "$consumer" && "$claims" --json)"
[ "$(jq -r '.[] | select(.id=="PROJ-9") | .on_main' <<<"$out")" = "true" ] \
  || fail "{id} is not substituted anywhere in the subject, only prefixed: $out"
pass "commit_ref_pattern substitutes {id} anywhere in the subject, not as a prefix"

# The mockup exclusion is this project's convention, so it is declared rather than built in.
git_c -C "$consumer" commit -q --allow-empty -m "docs(ah-mock): mockup"
git_c -C "$consumer" push -q origin "$branch"
cat > "$beads_file" <<'JSON'
[{"id": "ah-mock", "assignee": "Beast", "title": "mockup only"}]
JSON
write_conf </dev/null
out="$(cd "$consumer" && "$claims" --json)"
[ "$(jq -r '.[0].on_main' <<<"$out")" = "true" ] \
  || fail "nothing is excluded by default, so a mockup commit should read as delivery: $out"
write_conf <<'CONF'
non_delivery_commit_pattern docs({id}): mockup
CONF
out="$(cd "$consumer" && "$claims" --json)"
[ "$(jq -r '.[0].docs_only' <<<"$out")" = "true" ] \
  || fail "a declared non_delivery_commit_pattern did not exclude the mockup commit: $out"
pass "non_delivery_commit_pattern is declared, defaults to excluding nothing, and substitutes {id}"

# --- branch_pattern -----------------------------------------------------------------------------
stalled="$consumer/.claude/cerebro/scripts/sweep-stalled.sh"
git_c -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/PROJ-7" -b feature/PROJ-7-work
# A commit of its own, so "resolved the branch" and "measured from the branch" are distinguishable.
git_c -C "$consumer/.cerebro/worktrees/PROJ-7" commit -q --allow-empty -m "PROJ-7 work in progress"
git_c -C "$consumer" worktree add -q "$consumer/.cerebro/worktrees/ah-plain" -b ah-plain-work
cat > "$beads_file" <<'JSON'
[{"id": "PROJ-7", "assignee": "Storm", "title": "namespaced branch"},
 {"id": "ah-plain", "assignee": "Rogue", "title": "today's branch"}]
JSON

write_conf </dev/null
out="$(cd "$consumer" && "$stalled" --json)"
[ "$(jq -r '.[] | select(.id=="ah-plain") | .branch' <<<"$out")" = "ah-plain-work" ] \
  || fail "the default branch_pattern no longer resolves today's branches: $out"
[ "$(jq -r '.[] | select(.id=="PROJ-7") | .branch' <<<"$out")" = "null" ] \
  || fail "the default pattern matched a branch it never did before: $out"
pass "the default branch_pattern reproduces today's branch resolution exactly"

write_conf <<'CONF'
branch_pattern feature/{id}-*
CONF
out="$(cd "$consumer" && "$stalled" --json)"
[ "$(jq -r '.[] | select(.id=="PROJ-7") | .branch' <<<"$out")" = "feature/PROJ-7-work" ] \
  || fail "branch_pattern feature/{id}-* did not resolve a namespaced branch: $out"
[ "$(jq -r '.[] | select(.id=="PROJ-7") | .progress_source' <<<"$out")" = "commit" ] \
  || fail "a live namespaced branch still reads as measured from the claim: $out"
pass "branch_pattern feature/{id}-* resolves a namespaced branch, so live work stops reading as stalled"

# =================================================================================================
# 6. --dry-run stays honest through all of it
# =================================================================================================
write_conf <<'CONF'
reclaim_dirs target node_modules
CONF
make_tree ah-dry 5000 .cerebro target node_modules
gb_free 5
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=1 bash "$prune" --dry-run 2>&1)"
grep -q "would reclaim" <<<"$out" || fail "--dry-run named nothing it would take: $out"
present "$consumer/.cerebro/worktrees/ah-dry/target" \
        "$consumer/.cerebro/worktrees/ah-dry/node_modules" \
  || fail "--dry-run reclaimed something: $out"
pass "--dry-run names what it would take and takes nothing"

# =================================================================================================
# 7. A consumer that declares no build floor loses the PRESSURE path, keeping only the outer bound
# =================================================================================================
#
# The floor is the consumer's own `disk_floor_gb` (ah-qled.7.2) and its absence is meaningful: the
# same absence `disk-preflight` reads as "no preflight at all". Neither invents a number, so the two
# can never disagree - not even about not knowing.
printf 'default_branch %s\nreclaim_dirs target\n' "$branch" > "$conf"
make_tree ah-nofloor 5000 .cerebro target
gb_free 1   # as much pressure as this fixture can produce
out="$(cd "$consumer" && PRESSURE_COLD_MINUTES=30 COLD_TARGET_MINUTES=100000 bash "$prune" 2>&1)"
present "$consumer/.cerebro/worktrees/ah-nofloor/target" \
  || fail "with no disk_floor_gb declared, the pressure path took a build tree anyway: $out"
pass "no declared floor disables the pressure path rather than inventing a number for it"

# The outer bound is untouched by any of this: it never asks what the disk looks like, so a floor it
# cannot read cannot disable it. See reclaim_cold_target, which the psylocke exception above already
# exercises.

echo "all project-sweeps assertions passed"
