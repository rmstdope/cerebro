#!/usr/bin/env bash
#
# Drives the whole fleet against a consumer deliberately unlike the one cerebro grew up in
# (ah-qled.11). Every other suite here proves one script; this one proves that the scripts, taken
# together, still work when NOTHING about the consumer matches this project: no JavaScript at all,
# a default branch that is not `main`, its own project facts, its own fleet with a role cerebro does
# not ship, and no `bd` on PATH but a stub.
#
# That gap is why none of the coupling the sibling beads found was noticed by CI: CI only ever ran
# cerebro in place, so the mount point, the tracker's program name, the default branch and the
# install step were all invisible to it.
#
# GREEN BY CONSTRUCTION. Every assertion here passes today. A behaviour that does not work yet is
# written as a COMMENTED-OUT stub naming the bead that owns it, never as a red assertion: nothing
# merges red, so a failing assertion here would block every pull request in the repository until
# that bead landed. See the bead's plan for why that trade was made.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/consumer-fixture.sh
#
# It needs `git`, `jq` and `bash`. It deliberately needs no `bd`, `gh`, `pnpm` or `cargo` - the stub
# tracker below exists precisely so that cerebro's CI can stay free of them.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# -P throughout: consumer-root, sync-symlinks.sh and the sweeps all resolve paths physically, and on
# macOS mktemp hands back /var/... which is a symlink to /private/var/... - so a fixture that keeps
# the logical form compares two spellings of the same directory and fails for no reason.
work_dir="$(cd "$(mktemp -d)" && pwd -P)"
stub_dir="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work_dir" "$stub_dir"' EXIT

git_q() { git -c user.name=test -c user.email=test@example.com "$@"; }

# --- the stubs on PATH ---------------------------------------------------------------------------
#
# `claude` is looked up by launch-preflight and exec'd by launch; it is never a real session here.
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf 'BEADS_ACTOR=%s\n' "${BEADS_ACTOR:-<unset>}"
for a in "$@"; do printf 'ARG:%s\n' "$a"; done
STUB
chmod +x "$stub_dir/claude"

# The tracker. A test double, kept here rather than in scripts/ because it is not a shipped thing.
# It answers valid JSON and exits 0 for every subcommand the sweeps use, so a sweep that comes back
# dirty is cerebro's fault rather than the stub's - which is the whole point of having one.
cat > "$stub_dir/bd" <<'STUB'
#!/usr/bin/env bash
# bd [-C <dir>] <subcommand> ... --json
printf '[]\n'
exit 0
STUB
chmod +x "$stub_dir/bd"

# --- the consumer: every axis different from this project -----------------------------------------
#
# no package.json / no lockfile  -> prepare-worktree must take its no-install branch and say so
# branch `trunk`                 -> every hardcoded `origin/main`
# its own cerebro-project.conf   -> anything reading this project's values
# its own roster, one role       -> the roster table, and agent-state's phase words
#   cerebro does not ship
branch="trunk"
origin="$work_dir/origin.git"
consumer="$work_dir/consumer"

git init -q --bare -b "$branch" "$origin"
git init -q -b "$branch" "$consumer"
git_q -C "$consumer" remote add origin "$origin"

mkdir -p "$consumer/src" "$consumer/.claude/agents" "$consumer/doc/retro"
echo 'print("a consumer with no JavaScript in it")' > "$consumer/src/main.py"

# Only the directories the fixture needs, never `cp -R "$repo_root"`: that drags in whatever happens
# to be present at the time - a local .cerebro/, the .git, byte-compiled elisp - so the fixture stops
# being hermetic and starts being expensive (ah-qled.11, increment 4).
mkdir -p "$consumer/.claude/cerebro"
for d in scripts agents skills hooks; do
  [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$consumer/.claude/cerebro/"
done
scripts_at="$consumer/.claude/cerebro/scripts"

cat > "$consumer/.claude/cerebro-project.conf" <<'CONF'
project_name   Ledger
default_branch trunk
app_paths      ^src/
audience_noun  reader
gate_fast      true
gate_full      true
release_cmd    make release
retro_dir      doc/retro
# No `install': this consumer has no package manager at all, and that must be a no-op rather than a
# failure. No `release_watch': absent means there is nothing to watch after tagging, which is an
# ordinary state (ah-qled.7.3).
CONF

# Names that are not cerebro's, and `archivist` - a role cerebro does not ship. launch-preflight
# accepts such a role only when the CONSUMER supplies the agent file (see its three-case check), so
# the fixture supplies one; that is the supported shape, not a workaround.
cat > "$consumer/.claude/cerebro-roster" <<'ROSTER'
# the Ledger fleet

Ada        planner
Hopper     orchestrator
Babbage    archivist

Turing     implementer
Lovelace   implementer
ROSTER

cat > "$consumer/.claude/agents/archivist.md" <<'AGENT'
---
name: archivist
model: sonnet
effort: medium
---
The Ledger project's own role, which cerebro does not ship.
AGENT

git_q -C "$consumer" add -A
git_q -C "$consumer" commit -q -m "the Ledger project"
git_q -C "$consumer" push -q origin "$branch"

run_at() { PATH="$stub_dir:$PATH" bash "$scripts_at/$@"; }

# The names this consumer declared, which is what "no name from cerebro's own table" is asserted
# against - listing cerebro's names here would make this fixture name the very fleet it exists to
# stop assuming.
declared_names="$(sed -n 's/^\([A-Za-z][A-Za-z]*\)[[:space:]].*/\1/p' "$consumer/.claude/cerebro-roster")"

# --- the consumer is found, and its branch is its own ---------------------------------------------

[[ "$(run_at consumer-root)" == "$consumer" ]] \
  || fail "consumer-root: got $(run_at consumer-root), wanted $consumer"
[[ "$(run_at consumer-root --shared)" == "$consumer" ]] \
  || fail "consumer-root --shared: got $(run_at consumer-root --shared)"
pass "consumer-root resolves to the fixture, from the main checkout"

[[ "$(run_at default-branch 2>/dev/null)" == "trunk" ]] \
  || fail "default-branch: got $(run_at default-branch 2>/dev/null), wanted trunk"
pass "default-branch answers the consumer's own branch, not main"

# --- project facts are the consumer's ------------------------------------------------------------

[[ "$(run_at project-conf project_name 2>/dev/null)" == "Ledger" ]] || fail "project-conf project_name"
[[ "$(run_at project-conf audience_noun 2>/dev/null)" == "reader" ]] || fail "project-conf audience_noun"
[[ "$(run_at project-conf gate_fast 2>/dev/null)" == "true" ]] || fail "project-conf gate_fast"
[[ "$(run_at project-conf retro_dir 2>/dev/null)" == "doc/retro" ]] || fail "project-conf retro_dir"
[[ "$(run_at project-conf release_cmd 2>/dev/null)" == "make release" ]] || fail "project-conf release_cmd"
[[ "$(run_at project-conf nothing_declared fallback 2>/dev/null)" == "fallback" ]] \
  || fail "project-conf: an absent key should give the caller's default"
pass "project-conf answers from the consumer's own file, and defaults for an absent key"

# ah-qled.7.3: absent `release_watch' means nothing is watched after tagging - an ordinary state,
# so it must print nothing and still exit 0 rather than taking the release procedure down.
set +e
watch_out="$(run_at project-conf release_watch 2>/dev/null)"
watch_status=$?
set -e
[[ $watch_status -eq 0 ]] || fail "project-conf release_watch: expected exit 0, got $watch_status"
[[ -z "$watch_out" ]] || fail "project-conf release_watch: expected nothing, got '$watch_out'"
pass "an absent release_watch says nothing and exits 0 (ah-qled.7.3)"

[[ "$(run_at app-paths 2>/dev/null)" == "^src/" ]] || fail "app-paths: not the consumer's pattern"
[[ "$(run_at app-paths --classify src/main.py 2>/dev/null)" == "application" ]] \
  || fail "app-paths --classify src/main.py: expected application"
[[ "$(run_at app-paths --classify doc/retro/x.md 2>/dev/null)" == "invisible" ]] \
  || fail "app-paths --classify doc/retro/x.md: expected invisible"
pass "app-paths classifies by the consumer's own application paths"

# --- the fleet is the consumer's -----------------------------------------------------------------

roster_out="$(run_at roster)"
while IFS=$'\t' read -r name role kind; do
  [[ -n "$name" && -n "$role" && -n "$kind" ]] || fail "roster: row missing a field: $name/$role/$kind"
  printf '%s\n' "$declared_names" | grep -qx "$name" \
    || fail "roster: $name is not on the consumer's roster - cerebro's own table leaked in"
  if [[ "$role" == "implementer" ]]; then
    [[ "$kind" == "implementer" ]] || fail "roster: $name has role implementer but kind $kind"
  else
    [[ "$kind" == "interactive" ]] || fail "roster: $name has role $role but kind $kind"
  fi
done <<<"$roster_out"
pass "roster answers entirely from the consumer's file, with KIND still derived"

[[ "$(run_at roster --implementers)" == "$(printf 'Turing\nLovelace')" ]] \
  || fail "roster --implementers: got $(run_at roster --implementers)"
[[ "$(run_at roster --role archivist)" == "Babbage" ]] \
  || fail "roster --role archivist: a role cerebro does not ship should still be answered"
[[ "$(run_at roster --entry Ada)" == "$(printf 'Ada\tplanner\tinteractive')" ]] \
  || fail "roster --entry Ada: got $(run_at roster --entry Ada)"
pass "roster --implementers, --role and --entry all read the consumer's fleet"

# --- the links, and a launch for every role on that roster ----------------------------------------

run_at sync-symlinks.sh >/dev/null || fail "sync-symlinks.sh: non-zero exit"
for agent_file in "$repo_root"/agents/*.md; do
  link="$consumer/.claude/agents/$(basename "$agent_file")"
  [[ -L "$link" ]] || fail "sync-symlinks.sh: $link is not a symlink"
  [[ "$(readlink "$link")" != /* ]] || fail "sync-symlinks.sh: $link is absolute, not relative"
  [[ -f "$link" ]] || fail "sync-symlinks.sh: $link does not resolve"
done
for skill_dir in "$repo_root"/skills/*/; do
  [[ -f "$skill_dir/SKILL.md" ]] || continue
  link="$consumer/.claude/skills/$(basename "$skill_dir")"
  [[ -L "$link" ]] || fail "sync-symlinks.sh: $link is not a symlink"
  [[ "$(readlink "$link")" != /* ]] || fail "sync-symlinks.sh: $link is absolute, not relative"
  [[ -f "$link/SKILL.md" ]] || fail "sync-symlinks.sh: $link does not resolve to a skill"
done
[[ -f "$consumer/.claude/agents/archivist.md" && ! -L "$consumer/.claude/agents/archivist.md" ]] \
  || fail "sync-symlinks.sh: the consumer's own agent file was replaced by a link"
pass "sync-symlinks.sh links every agent and skill relatively, and leaves the consumer's own alone"

# Derived from the roster, never listed: a list here would be this suite keeping its own copy of the
# fleet, which is the drift the roster exists to end.
while IFS=$'\t' read -r name role _; do
  run_at launch-preflight "$role" "$name" >/dev/null 2>&1 \
    || fail "launch-preflight: refused $name ($role) on a current, correctly declared consumer"
done <<<"$roster_out"
pass "launch-preflight passes for every role on the consumer's own roster, archivist included"

# ah-qled.5.3: `launch <Name>` is the only way a session starts, for every role the consumer has -
# including the one cerebro does not ship - and the seven `run-*` shims are gone.
while IFS=$'\t' read -r name role _; do
  out="$(run_at launch "$name" 2>/dev/null)" || fail "launch $name: non-zero exit"
  grep -q "^BEADS_ACTOR=$name\$" <<<"$out" || fail "launch $name: BEADS_ACTOR not stamped"
  grep -qx "ARG:$role" <<<"$out" || fail "launch $name: --agent $role not passed"
done <<<"$roster_out"
shims="$(find "$repo_root/scripts" -maxdepth 1 -name 'run-*' | wc -l | tr -d ' ')"
[[ "$shims" == "0" ]] || fail "launch: $shims run-* shims survive; launch is meant to be the only way in"
pass "launch starts every role on the consumer's roster, and no run-* shim exists (ah-qled.5.3)"

# --- state: the consumer's own phase words (ah-qled.5.2) ------------------------------------------

run_at agent-state Babbage working --bead LEDG-1 --phase indexing --pid $$ >/dev/null \
  || fail "agent-state: refused the consumer's own phase word"
state_file="$consumer/.cerebro/state/Babbage.state.json"
[[ -f "$state_file" ]] || fail "agent-state: no state file at $state_file"
[[ "$(jq -r .phase "$state_file")" == "indexing" ]] \
  || fail "agent-state: phase not written, got $(jq -r .phase "$state_file")"
[[ "$(jq -r .bead "$state_file")" == "LEDG-1" ]] || fail "agent-state: bead not written"
pass "agent-state accepts a phase word this fleet has never used (ah-qled.5.2)"

# --- a worktree in a project with nothing to install ----------------------------------------------

install_log="$work_dir/prepare.log"
run_at prepare-worktree --path .cerebro/worktrees/LEDG-1 --branch LEDG-1-first --dry-run \
  >"$work_dir/prepare.out" 2>"$install_log" || fail "prepare-worktree: non-zero exit"
grep -q "no install declared or detected - installing nothing" "$install_log" \
  || fail "prepare-worktree: the no-install branch was not taken, or did not say so"
grep -q "would install with" "$install_log" \
  && fail "prepare-worktree: printed an install command in a project with no package manager"
grep -q "$consumer/.cerebro/worktrees/LEDG-1 " "$work_dir/prepare.out" \
  || fail "prepare-worktree: did not print the tree's path and sha"
[[ ! -e "$consumer/.cerebro/worktrees/LEDG-1" ]] \
  || fail "prepare-worktree: --dry-run created the tree it was only describing (ah-1rls)"
pass "prepare-worktree branches from trunk and installs nothing, saying so"

# ...and then for real, because everything below asks questions of a tree that has to exist. Until
# ah-1rls the dry run above created it, which is exactly the bug that bead was about.
run_at prepare-worktree --path .cerebro/worktrees/LEDG-1 --branch LEDG-1-first \
  >/dev/null 2>&1 || fail "prepare-worktree: non-zero exit on the real run"

# The same two roots, asked from inside a worktree of the consumer: the enclosing tree for anything
# acting on this tree, the shared checkout for anything the fleet reads.
wt_scripts="$consumer/.cerebro/worktrees/LEDG-1/.claude/cerebro/scripts"
[[ -x "$wt_scripts/consumer-root" ]] || fail "the worktree has no .claude/cerebro of its own"
[[ "$(PATH="$stub_dir:$PATH" bash "$wt_scripts/consumer-root")" == "$consumer/.cerebro/worktrees/LEDG-1" ]] \
  || fail "consumer-root from a worktree: expected the worktree itself"
[[ "$(PATH="$stub_dir:$PATH" bash "$wt_scripts/consumer-root" --shared)" == "$consumer" ]] \
  || fail "consumer-root --shared from a worktree: expected the main checkout"
pass "consumer-root answers both roots from inside a worktree of the consumer"

# --- the sweeps come back clean, driven by the stub tracker ---------------------------------------

for sweep in sweep-claims.sh sweep-epics.sh sweep-stalled.sh; do
  out="$(run_at "$sweep" --json)" || fail "$sweep: non-zero exit against an empty fleet"
  jq -e . >/dev/null 2>&1 <<<"$out" || fail "$sweep: did not print JSON: $out"
  # A clean sweep prints an array; the failure shape is an object carrying `error', so the type has
  # to be checked before the key is - `has' on an array is itself an error.
  jq -e 'type == "object" and has("error") | not' >/dev/null <<<"$out" \
    || fail "$sweep: reported an error rather than a clean sweep: $out"
done
pass "the claim, epic and stalled sweeps come back clean on a trunk-branched consumer"

run_at prune-worktrees.sh --dry-run >/dev/null || fail "prune-worktrees.sh: non-zero exit"
pass "prune-worktrees.sh sweeps a consumer whose worktrees hold nothing to reclaim"

# --- a consumer that vendors cerebro somewhere else entirely (ah-ohc2) ----------------------------
#
# Everything above is a consumer at the standard mount, `<consumer>/.claude/cerebro'. This one keeps
# cerebro as a submodule at `vendor/cerebro' and must still get its consumer root, its project facts
# and its own fleet.
#
# A REAL submodule, not a copied directory, and that is the supported shape rather than a
# convenience of the fixture: the resolution asks git which working tree contains this checkout as a
# submodule, which answers for a submodule and nothing else. An arbitrarily-PLACED copy - vendored
# by hand, outside the standard mount - is still unsupported, and scripts/consumer-root says so.
# (The stub this replaced sketched a plain `mkdir -p vendor/cerebro'; that is the unsupported case.)
cerebro_src="$work_dir/cerebro-src"
mkdir -p "$cerebro_src"
for d in scripts agents skills hooks; do
  [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$cerebro_src/"
done
git init -q "$cerebro_src"
git_q -C "$cerebro_src" add -A
git_q -C "$cerebro_src" commit -q -m "cerebro"

alt="$work_dir/alt"
git init -q -b "$branch" "$alt"
git_q -C "$alt" commit -q --allow-empty -m init
git_q -C "$alt" -c protocol.file.allow=always submodule add -q "$cerebro_src" vendor/cerebro
alt_root="$(cd "$alt" && pwd -P)"
alt_scripts="$alt/vendor/cerebro/scripts"

run_alt() { PATH="$stub_dir:$PATH" bash "$alt_scripts/$@"; }

[[ "$(run_alt consumer-root)" == "$alt_root" ]] \
  || fail "an alternative mount point: got $(run_alt consumer-root), wanted $alt_root"
[[ "$(run_alt consumer-root --shared)" == "$alt_root" ]] \
  || fail "an alternative mount point --shared: got $(run_alt consumer-root --shared)"
pass "consumer-root resolves a consumer that vendors cerebro at vendor/cerebro"

mkdir -p "$alt/.claude"
printf 'project_name Vendored\ngate_fast true\n' > "$alt/.claude/cerebro-project.conf"
[[ "$(run_alt project-conf project_name 2>/dev/null)" == "Vendored" ]] \
  || fail "project-conf from an alternative mount: got $(run_alt project-conf project_name 2>/dev/null)"
pass "project facts are the consumer's from an alternative mount, with no change to project-conf"

printf 'Ada  planner\nTuring  implementer\n' > "$alt/.claude/cerebro-roster"
[[ "$(run_alt roster)" == "$(printf 'Ada\tplanner\tinteractive\nTuring\timplementer\timplementer')" ]] \
  || fail "roster from an alternative mount: got $(run_alt roster)"
pass "the consumer's own fleet is found from an alternative mount"


# --- not yet: each of these is a bead, and a red assertion here would block the repository ---------
#
# ah-qled.7.2 (in progress) - the disk check and the retrospective sweep read the consumer's own
# `disk_floor_gb' and `retro_dir' rather than this project's values.
#   run_at disk-preflight >/dev/null || fail "disk-preflight: refused the consumer"
#   [[ "$(run_at retro-sightings "a symptom")" == *"doc/retro"* ]] || fail "retro-sightings: not the consumer's retro_dir"

echo "all consumer-fixture assertions passed"
