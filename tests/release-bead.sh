#!/usr/bin/env bash
#
# Proves `scripts/release-bead <Name> <id>`: the fleet view's give-back of a bead an implementer it
# handed never ran on (cb-10d.1). Every answer is one word on stdout with exit 0, because the view's
# command runner throws stdout away on a non-zero exit.
#
#     bash tests/release-bead.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link release-bead roster consumer-root)"
printf 'Rogue producer\nXavier ux\nIceman ux\n' > "$consumer/.cerebro/roster.conf"
scripts="$consumer/.cerebro/cerebro/scripts"
state="$consumer/.cerebro/state"
mkdir -p "$state"
stub="$work_dir/stub"
mkdir -p "$stub"

# A stub agent-alive: its exit code is $ALIVE_EXIT (default 1, not alive).
cat > "$scripts/agent-alive" <<'STUB'
#!/usr/bin/env bash
exit "${ALIVE_EXIT:-1}"
STUB
chmod +x "$scripts/agent-alive"

# A stub `bd`: argv in bd.log; `show` answers show.json, or show2.json once an unclaim has run.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
sub=""; skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C|--actor) skip=1 ;; -*) ;; *) sub="$a"; break ;; esac
done
case "$sub" in
  show)
    if [ -f "$STUB_DIR/unclaimed" ] && [ -f "$STUB_DIR/show2.json" ]; then cat "$STUB_DIR/show2.json"
    else cat "$STUB_DIR/show.json"; fi ;;
  unclaim) touch "$STUB_DIR/unclaimed"; exit "${BD_UNCLAIM_EXIT:-0}" ;;
  update) exit "${BD_UPDATE_EXIT:-0}" ;;
  close) exit "${BD_CLOSE_EXIT:-0}" ;;
  dolt) exit "${BD_PUSH_EXIT:-0}" ;;
esac
exit 0
STUB
chmod +x "$stub/bd"

reset() {
  rm -f "$stub/bd.log" "$stub/unclaimed" "$stub/show2.json"
  printf '%s' "$1" > "$stub/show.json"
  printf 'cb-x\n' > "$state/Rogue.handover"
}

run() {
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$scripts/release-bead" "$@"
}

mine='[{"id":"cb-x","status":"in_progress","assignee":"Rogue"}]'

# --- releases a bead the agent never ran on and says released -----------------------------------

reset "$mine"
out="$(run Rogue cb-x 2>/dev/null)" || fail "released is exit 0"
[[ "$out" == "released" ]] || fail "stdout is exactly released, got: $out"
grep -q -- "--actor Rogue .*unclaim cb-x --if-assignee Rogue" "$stub/bd.log" \
  || fail "the unclaim is compare-and-swapped on Rogue, got: $(cat "$stub/bd.log")"
[[ ! -e "$state/Rogue.handover" ]] || fail "a released bead's handover is removed"
pass "releases a bead the agent never ran on and says released"

# --- an open unassigned bead says free and removes the handover ---------------------------------

reset '[{"id":"cb-x","status":"open","assignee":""}]'
out="$(run Rogue cb-x 2>/dev/null)" || fail "free is exit 0"
[[ "$out" == "free" ]] || fail "stdout is exactly free, got: $out"
! grep -q unclaim "$stub/bd.log" || fail "a free bead is not unclaimed"
[[ ! -e "$state/Rogue.handover" ]] || fail "a free bead's handover is removed"
pass "an open unassigned bead says free and removes the handover"

# --- a bead held by another agent says elsewhere and unclaims nothing ---------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Gambit"}]'
out="$(run Rogue cb-x 2>/dev/null)" || fail "elsewhere is exit 0"
[[ "$out" == "elsewhere" ]] || fail "stdout is exactly elsewhere, got: $out"
! grep -q unclaim "$stub/bd.log" || fail "another agent's bead is not unclaimed"
[[ ! -e "$state/Rogue.handover" ]] || fail "an elsewhere bead's handover is removed"
pass "a bead held by another agent says elsewhere and unclaims nothing"

# --- a lost compare-and-swap re-reads and says elsewhere ----------------------------------------

reset "$mine"
printf '%s' '[{"id":"cb-x","status":"in_progress","assignee":"Gambit"}]' > "$stub/show2.json"
out="$(BD_UNCLAIM_EXIT=1 run Rogue cb-x 2>/dev/null)" || fail "a lost CAS is exit 0"
[[ "$out" == "elsewhere" ]] || fail "a lost CAS says elsewhere, got: $out"
pass "a lost compare-and-swap re-reads and says elsewhere"

# --- a failed unclaim on a bead still Rogue's is exit 1 -----------------------------------------

reset "$mine"
status=0; out="$(BD_UNCLAIM_EXIT=1 run Rogue cb-x 2>/dev/null)" || status=$?
[[ $status -eq 1 ]] || fail "an unclaim that failed with the bead still Rogue's is exit 1, got $status"
pass "a failed unclaim on a bead still Rogue's is exit 1"

# --- cb-10d.2.1: a planning role's assignment is cleared, not unclaimed ---------------------------

assigned='[{"id":"cb-x","status":"open","assignee":"Iceman"}]'

reset "$assigned"
printf 'cb-x\n' > "$state/Iceman.handover"
out="$(run Iceman cb-x 2>/dev/null)" || fail "a released assignment is exit 0"
[[ "$out" == "released" ]] || fail "stdout is exactly released, got: $out"
grep -qxF -- "--actor Iceman -C $consumer update cb-x --assignee  --if-assignee Iceman" "$stub/bd.log" \
  || fail "the assignee is cleared compare-and-swapped on Iceman, got: $(cat "$stub/bd.log")"
! grep -q unclaim "$stub/bd.log" || fail "an assignment is not unclaimed"
grep -q "dolt push" "$stub/bd.log" || fail "a released assignment is pushed"
[[ ! -e "$state/Iceman.handover" ]] || fail "a released assignment's handover is removed"
pass "releases an open bead assigned to the agent and says released"

reset "$assigned"
out="$(BD_UPDATE_EXIT=13 run Iceman cb-x 2>/dev/null)" || fail "a lost assignment is exit 0"
[[ "$out" == "elsewhere" ]] || fail "a lost assignment says elsewhere, got: $out"
pass "an assignment somebody else took says elsewhere"

reset "$assigned"
status=0; out="$(BD_UPDATE_EXIT=1 run Iceman cb-x 2>/dev/null)" || status=$?
[[ $status -eq 1 ]] || fail "a failed unassign is exit 1, got $status"
[[ -z "$out" ]] || fail "a failed unassign prints nothing, got: $out"
pass "a failed unassign is exit 1"

# --- a live agent says running and touches nothing ----------------------------------------------

reset "$mine"
out="$(ALIVE_EXIT=0 run Rogue cb-x 2>/dev/null)" || fail "running is exit 0"
[[ "$out" == "running" ]] || fail "stdout is exactly running, got: $out"
[[ ! -e "$stub/bd.log" ]] || fail "a running agent touches the board, got: $(cat "$stub/bd.log")"
[[ -e "$state/Rogue.handover" ]] || fail "a running agent's handover is kept"
pass "a live agent says running and touches nothing"

# --- a handover naming a different bead is left alone -------------------------------------------

reset "$mine"
printf 'cb-y\n' > "$state/Rogue.handover"
out="$(run Rogue cb-x 2>/dev/null)" || fail "released is exit 0"
[[ "$(cat "$state/Rogue.handover")" == "cb-y" ]] || fail "a handover for another bead is left alone"
pass "a handover naming a different bead is left alone"

# --- cb-10d.3: --worktree removes a recorded tree only when nothing in it can be lost ------------

tidy="$(consumer_new tidy --origin --link release-bead roster consumer-root default-branch project-conf)"
printf 'Rogue producer\nGambit producer\n' > "$tidy/.cerebro/roster.conf"
cp "$scripts/agent-alive" "$tidy/.cerebro/cerebro/scripts/agent-alive"
tstate="$tidy/.cerebro/state"
mkdir -p "$tstate/worktrees"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo 0
STUB
chmod +x "$stub/gh"
origin_url="$(git -C "$tidy" remote get-url origin)"

recorded_tree() {
  git_q -C "$tidy" remote set-url origin "$origin_url"
  rm -f "$tstate"/Rogue.state.json "$tstate"/Rogue.handover
  git -C "$tidy" worktree remove --force "$tidy/.cerebro/worktrees/$1" >/dev/null 2>&1 || true
  git -C "$tidy" branch -D "$1" >/dev/null 2>&1 || true
  git_q -C "$tidy" worktree add -q "$tidy/.cerebro/worktrees/$1" -b "$1" origin/main
  printf '%s\n' "$2" > "$tstate/worktrees/$1"
}

tidy_run() {
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$tidy/.cerebro/cerebro/scripts/release-bead" "$@"
}
tree="$tidy/.cerebro/worktrees/cb-x"
record="$tstate/worktrees/cb-x"

recorded_tree cb-x Rogue
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)" || fail "removed is exit 0"
[[ "$out" == "removed" ]] || fail "stdout is exactly removed, got: $out"
[[ ! -e "$tree" && ! -e "$record" ]] || fail "the tree and its record are gone"
! git -C "$tidy" show-ref --verify --quiet refs/heads/cb-x || fail "the branch is gone"
pass "a recorded, clean, landed tree is removed with its branch and its record"

recorded_tree cb-x Rogue
touch "$tree/scratch.txt"
err="$(tidy_run --worktree Rogue cb-x 2>&1 >"$work_dir/out")" || fail "kept is exit 0"
[[ "$(cat "$work_dir/out")" == "kept it has uncommitted or untracked changes" ]] || fail "kept says why, got: $(cat "$work_dir/out")"
[[ "$err" == *"release-bead: keeping cb-x — it has uncommitted or untracked changes"* ]] || fail "stderr keeps the pruner's shape, got: $err"
[[ -e "$tree" && ! -e "$record" ]] || fail "a kept tree stays and its record goes"
pass "an untracked file keeps the tree and says why"

recorded_tree cb-x Rogue
echo more >> "$tree/file.txt"; git_q -C "$tree" commit -q -am more
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "kept it holds work that is not on main yet" ]] || fail "an unpushed commit keeps, got: $out"
pass "an unpushed commit keeps the tree"

recorded_tree cb-x Gambit
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "gone" && -e "$tree" && -e "$record" ]] || fail "another agent's tree is untouched, got: $out"
pass "a tree recorded for another agent is not touched"

recorded_tree cb-x Rogue
rm -f "$record"
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "gone" && -e "$tree" ]] || fail "an unrecorded tree is untouched, got: $out"
pass "an unrecorded tree is never touched"

recorded_tree cb-x Rogue
git_q -C "$tidy" worktree remove --force "$tree"
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "gone" && ! -e "$record" ]] || fail "a vanished tree is gone and its record goes, got: $out"
pass "a tree the watcher already removed is gone and its record goes"

recorded_tree cb-x Rogue
printf '{"bead":"cb-x"}\n' > "$tstate/Rogue.state.json"
git_q -C "$tidy" remote set-url origin "$work_dir/nowhere.git"
out="$(ALIVE_EXIT=0 tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "running" && -e "$tree" && -e "$record" ]] || fail "a live agent on its bead keeps its tree, got: $out"
pass "a live agent on this bead keeps its tree"

recorded_tree cb-x Rogue
printf '{"bead":"cb-y"}\n' > "$tstate/Rogue.state.json"
out="$(ALIVE_EXIT=0 tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "removed" ]] || fail "a live agent on another bead does not keep this tree, got: $out"
pass "a live agent on another bead does not keep this tree"

recorded_tree cb-x Rogue
printf '{"bead":null}\n' > "$tstate/Rogue.state.json"
printf 'cb-y\n' > "$tstate/Rogue.handover"
out="$(ALIVE_EXIT=0 tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "removed" ]] || fail "an unreported agent handed another bead does not keep this tree, got: $out"
recorded_tree cb-x Rogue
printf '{"bead":null}\n' > "$tstate/Rogue.state.json"
out="$(ALIVE_EXIT=0 tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "running" ]] || fail "an unreported agent with no handover keeps the tree, got: $out"
pass "a live agent that has not reported, handed another bead, does not keep this tree"

recorded_tree cb-x Rogue
git_q -C "$tidy" remote set-url origin "$work_dir/nowhere.git"
status=0; out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)" || status=$?
[[ $status -eq 0 && "$out" == "retry" && -e "$tree" && -e "$record" ]] || fail "an unreachable origin is retry, got $status: $out"
git_q -C "$tidy" remote set-url origin "$origin_url"
pass "an unreachable origin is retry and touches nothing"

recorded_tree cb-x Rogue
real_default="$(readlink "$tidy/.cerebro/cerebro/scripts/default-branch")"
rm "$tidy/.cerebro/cerebro/scripts/default-branch"
cat > "$tidy/.cerebro/cerebro/scripts/default-branch" <<STUB
#!/usr/bin/env bash
printf 'Gambit\n' > "$record"
exec "$real_default" "\$@"
STUB
chmod +x "$tidy/.cerebro/cerebro/scripts/default-branch"
out="$(tidy_run --worktree Rogue cb-x 2>/dev/null)"
[[ "$out" == "gone" && -e "$tree" && "$(cat "$record")" == "Gambit" ]] \
  || fail "a record rewritten mid-run is left to its new owner, got: $out"
rm "$tidy/.cerebro/cerebro/scripts/default-branch"
ln -s "$real_default" "$tidy/.cerebro/cerebro/scripts/default-branch"
pass "a record adopted by another agent mid-run is not touched"

status=0; out="$(tidy_run --worktree Rogue ../x 2>/dev/null)" || status=$?
[[ $status -eq 2 && -z "$out" ]] || fail "an id with a slash is exit 2, got $status: $out"
status=0; out="$(tidy_run --worktree Rogue .x 2>/dev/null)" || status=$?
[[ $status -eq 2 ]] || fail "an id starting with a dot is exit 2, got $status"
pass "an id with a slash is a usage error"

# --- cb-10d.4: a push that fails after a write is a failed release --------------------------------

reset "$mine"
status=0; out="$(BD_PUSH_EXIT=1 run Rogue cb-x 2>"$work_dir/err")" || status=$?
[[ $status -eq 1 ]] || fail "a push that fails after an unclaim is exit 1, got $status: $out"
grep -q "bd dolt push failed" "$work_dir/err" || fail "stderr names the push, got: $(cat "$work_dir/err")"
pass "a push that fails after an unclaim exits 1"

reset "$assigned"
status=0; out="$(BD_PUSH_EXIT=1 run Iceman cb-x 2>/dev/null)" || status=$?
[[ $status -eq 1 ]] || fail "a push that fails after an unassign is exit 1, got $status: $out"
pass "a push that fails after an unassign exits 1"

# --- cb-10d.4: --ended takes back what a gone session still holds --------------------------------

ended="$(consumer_new ended --origin --link release-bead roster consumer-root default-branch project-conf bead-delivery.sh)"
printf 'Rogue producer\nIceman ux\n' > "$ended/.cerebro/roster.conf"
cp "$scripts/agent-alive" "$ended/.cerebro/cerebro/scripts/agent-alive"
estate="$ended/.cerebro/state"
mkdir -p "$estate"
ended_origin="$(git -C "$ended" remote get-url origin)"
git_q -C "$work_dir/ended-up" commit -q --allow-empty -m "feat(cb-d): done"
git_q -C "$work_dir/ended-up" push -q origin HEAD

ended_reset() {
  rm -f "$stub/bd.log" "$stub/unclaimed" "$stub/show2.json" "$estate/Rogue.state.json"
  printf '%s' "$1" > "$stub/show.json"
  git_q -C "$ended" remote set-url origin "$ended_origin"
}
ended_run() {
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$ended/.cerebro/cerebro/scripts/release-bead" --ended "$@"
}
held='[{"id":"cb-d","status":"in_progress","assignee":"Rogue","labels":[]}]'
undelivered='[{"id":"cb-u","status":"in_progress","assignee":"Rogue"}]'

ended_reset "$held"
out="$(ended_run Rogue cb-d 2>/dev/null)" || fail "closed is exit 0"
[[ "$out" == "closed" ]] || fail "stdout is exactly closed, got: $out"
grep -qxF -- "--actor Rogue -C $ended close cb-d --reason Delivered; closed by the fleet view, Rogue did not" "$stub/bd.log" \
  || fail "the close names the fleet view, got: $(cat "$stub/bd.log")"
[[ "$(tail -1 "$stub/bd.log")" == *"dolt push" ]] || fail "the close is pushed, got: $(cat "$stub/bd.log")"
pass "a gone implementer's delivered claim is closed and pushed"

ended_reset "$undelivered"
out="$(ended_run Rogue cb-u 2>/dev/null)" || fail "kept is exit 0"
[[ "$out" == "kept its work is not on main" ]] || fail "an undelivered claim is kept, got: $out"
! grep -qE "close|dolt push" "$stub/bd.log" || fail "a kept claim writes nothing, got: $(cat "$stub/bd.log")"
pass "an undelivered claim is kept and nothing is written"

ended_reset '[{"id":"cb-d","status":"in_progress","assignee":"Rogue","labels":["planned","verification:failed"]}]'
out="$(ended_run Rogue cb-d 2>/dev/null)"
[[ "$out" == "kept it was reopened by a failed verification" ]] || fail "a reopened bead is kept, got: $out"
! grep -q close "$stub/bd.log" || fail "a reopened bead is never closed"
pass "a reopened bead is kept whatever main holds"

ended_reset '[{"id":"cb-d","status":"open","assignee":"Iceman"}]'
git_q -C "$ended" remote set-url origin "$work_dir/nowhere.git"
out="$(ended_run Iceman cb-d 2>/dev/null)" || fail "released is exit 0"
[[ "$out" == "released" ]] || fail "an open assignment is released without a fetch, got: $out"
grep -qxF -- "--actor Iceman -C $ended update cb-d --assignee  --if-assignee Iceman" "$stub/bd.log" \
  || fail "the assignee is cleared, got: $(cat "$stub/bd.log")"
pass "a planning role's open assignment is cleared without a fetch"

ended_reset "$held"
printf '{"bead":"cb-d"}\n' > "$estate/Rogue.state.json"
out="$(ALIVE_EXIT=0 ended_run Rogue cb-d 2>/dev/null)"
[[ "$out" == "running" && ! -e "$stub/bd.log" ]] || fail "a live agent on this bead is running, got: $out"
pass "a live agent on this bead is running"

ended_reset "$held"
printf '{"bead":"cb-y"}\n' > "$estate/Rogue.state.json"
out="$(ALIVE_EXIT=0 ended_run Rogue cb-d 2>/dev/null)"
[[ "$out" == "closed" ]] || fail "a live agent on another bead does not keep its old claim, got: $out"
pass "a live agent on another bead does not keep its old claim"

ended_reset '[{"id":"cb-d","status":"in_progress","assignee":"Storm"}]'
out="$(ended_run Rogue cb-d 2>/dev/null)"
[[ "$out" == "elsewhere" ]] && ! grep -qE "close|update|unclaim" "$stub/bd.log" \
  || fail "somebody else's claim is elsewhere, got: $out"
pass "somebody else's claim is elsewhere"

ended_reset '[{"id":"cb-d","status":"open","assignee":"","labels":["Rogue"]}]'
out="$(ended_run Rogue cb-d 2>/dev/null)"
[[ "$out" == "elsewhere" ]] || fail "an open unassigned bead is elsewhere, got: $out"
pass "an open unassigned bead is elsewhere"

ended_reset "$held"
git_q -C "$ended" remote set-url origin "$work_dir/nowhere.git"
status=0; out="$(ended_run Rogue cb-d 2>/dev/null)" || status=$?
[[ $status -eq 0 && "$out" == "retry" ]] && ! grep -q close "$stub/bd.log" \
  || fail "an unreachable origin is retry, got $status: $out"
pass "an unreachable origin is retry and writes nothing"

ended_reset "$held"
status=0; out="$(BD_CLOSE_EXIT=1 ended_run Rogue cb-d 2>/dev/null)" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "a refused close is exit 1 with nothing on stdout, got $status: $out"
pass "a refused close exits 1"

ended_reset "$held"
status=0; out="$(BD_PUSH_EXIT=1 ended_run Rogue cb-d 2>"$work_dir/err")" || status=$?
[[ $status -eq 1 ]] || fail "a push that fails after a close is exit 1, got $status"
grep -q "bd dolt push failed" "$work_dir/err" || fail "stderr names the push, got: $(cat "$work_dir/err")"
pass "a push that fails after a close exits 1"

status=0; out="$(ended_run Rogue ../x 2>/dev/null)" || status=$?
[[ $status -eq 2 && -z "$out" ]] || fail "an id with a slash is exit 2, got $status: $out"
pass "an id with a slash is a usage error for --ended"

suite_passed
