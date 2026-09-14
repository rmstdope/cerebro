#!/usr/bin/env bash
#
# Proves `scripts/assign-bead <Name> <id>`: the fleet view's hand-over of a bead to an implementer
# before its session starts (cb-10d.1). It claims AS the agent, writes the handover file before the
# push, and never lets the advisory push decide its exit status.
#
#     bash tests/assign-bead.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link assign-bead assignable-beads roster consumer-root)"
printf 'Rogue implementer\nXavier planner\n' > "$consumer/.cerebro/roster.conf"
state="$consumer/.cerebro/state"
stub="$work_dir/stub"
mkdir -p "$stub"

# A stub `bd`: one argv line per call in bd.log, `show`/`ready` answered from fixture files, and
# `update`/`dolt` exit codes from the environment.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
sub=""; skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -C|--actor) skip=1 ;; -*) ;; *) sub="$a"; break ;; esac
done
case "$sub" in
  show)  cat "$STUB_DIR/show.json" ;;
  ready) cat "$STUB_DIR/ready.json" ;;
  update) exit "${BD_UPDATE_EXIT:-0}" ;;
  dolt)  exit "${BD_PUSH_EXIT:-0}" ;;
esac
exit 0
STUB
chmod +x "$stub/bd"

reset() {
  rm -f "$stub/bd.log" "$state"/*.handover "$state"/*.state.json
  printf '%s' "$1" > "$stub/show.json"
  printf '%s' "${2:-[]}" > "$stub/ready.json"
}

run() {
  STUB_DIR="$stub" PATH="$stub:$PATH" bash "$consumer/.claude/cerebro/scripts/assign-bead" "$@"
}

open='[{"id":"cb-x","status":"open","assignee":""}]'
ready='[{"id":"cb-x","priority":1}]'

# --- claims as the agent and writes the handover before pushing ---------------------------------

reset "$open" "$ready"
run Rogue cb-x 2>/dev/null || fail "an assignable bead is exit 0"
grep -n -- "--actor Rogue .*update cb-x --claim" "$stub/bd.log" >/dev/null \
  || fail "the claim is made as Rogue, got: $(cat "$stub/bd.log")"
claim_line="$(grep -n -- "update cb-x --claim" "$stub/bd.log" | cut -d: -f1)"
push_line="$(grep -n -- "dolt push" "$stub/bd.log" | cut -d: -f1)"
[[ -n "$push_line" && "$claim_line" -lt "$push_line" ]] || fail "the claim comes before the push"
[[ "$(cat "$state/Rogue.handover")" == "cb-x" ]] || fail "the handover file names cb-x"
pass "claims as the agent and writes the handover before pushing"

# --- a bead not in assignable-beads is exit 3 and claims nothing --------------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Gambit"}]' '[]'
status=0; run Rogue cb-x 2>/dev/null || status=$?
[[ $status -eq 3 ]] || fail "an unavailable bead is exit 3, got $status"
! grep -q -- "--claim" "$stub/bd.log" || fail "an unavailable bead is not claimed"
[[ ! -e "$state/Rogue.handover" ]] || fail "an unavailable bead writes no handover"
pass "a bead not in assignable-beads is exit 3 and claims nothing"

# --- a bead already Rogue's is exit 0 without a second claim or a push --------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Rogue"}]' '[]'
run Rogue cb-x 2>/dev/null || fail "a bead already Rogue's is exit 0"
! grep -q -- "--claim" "$stub/bd.log" || fail "a bead already Rogue's is not claimed again"
! grep -q -- "dolt push" "$stub/bd.log" || fail "a bead already Rogue's is not pushed"
[[ "$(cat "$state/Rogue.handover")" == "cb-x" ]] || fail "a bead already Rogue's still gets a handover"
pass "a bead already Rogue's is exit 0 without a second claim or a push"

# --- a bead already Rogue's that Rogue's state file names gets no handover file ------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Rogue"}]' '[]'
mkdir -p "$state"
printf '{"state":"working","bead":"cb-x"}\n' > "$state/Rogue.state.json"
run Rogue cb-x 2>/dev/null || fail "a reported bead is still exit 0"
[[ ! -e "$state/Rogue.handover" ]] || fail "an agent that has reported acquires no handover"
pass "a bead already Rogue's that Rogue's state file names gets no handover file"

# --- a planner is refused with exit 2 -----------------------------------------------------------

reset "$open" "$ready"
status=0; run Xavier cb-x 2>/dev/null || status=$?
[[ $status -eq 2 ]] || fail "a planner is exit 2, got $status"
[[ ! -e "$stub/bd.log" ]] || ! grep -q -- "--claim" "$stub/bd.log" || fail "a planner claims nothing"
pass "a planner is refused with exit 2"

# --- a failed claim is exit 1 and writes no handover --------------------------------------------

reset "$open" "$ready"
status=0; BD_UPDATE_EXIT=1 run Rogue cb-x 2>/dev/null || status=$?
[[ $status -eq 1 ]] || fail "a failed claim is exit 1, got $status"
[[ ! -e "$state/Rogue.handover" ]] || fail "a failed claim writes no handover"
pass "a failed claim is exit 1 and writes no handover"

# --- a failed push is still exit 0, says so on stderr, and keeps the handover -------------------

reset "$open" "$ready"
err="$(BD_PUSH_EXIT=1 run Rogue cb-x 2>&1 >/dev/null)" || fail "a failed push is still exit 0"
[[ "$err" == *"push failed"* ]] || fail "a failed push says so on stderr, got: $err"
[[ "$(cat "$state/Rogue.handover")" == "cb-x" ]] || fail "a failed push keeps the handover"
pass "a failed push is still exit 0, says so on stderr, and keeps the handover"

suite_passed
