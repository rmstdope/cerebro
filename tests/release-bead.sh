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
printf 'Rogue implementer\nXavier planner\nIceman build-design\n' > "$consumer/.cerebro/roster.conf"
scripts="$consumer/.claude/cerebro/scripts"
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

suite_passed
