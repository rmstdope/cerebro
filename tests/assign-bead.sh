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
printf 'Rogue implementer\nXavier planner\nBeast ux\nIceman build-design\nCerebro orchestrator\n' > "$consumer/.cerebro/roster.conf"
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

# cb-10d.2.1: stub candidate scripts for the planning roles, placed in the fixture's own scripts
# directory (nothing real is linked there under these names). Each logs its name and arguments and
# prints $CANDIDATES_JSON.
for cand in plan-candidates stage-candidates; do
  cat > "$consumer/.claude/cerebro/scripts/$cand" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_DIR/candidates.log"
printf '%s' "${CANDIDATES_JSON:-[]}"
STUB
  chmod +x "$consumer/.claude/cerebro/scripts/$cand"
done

reset() {
  rm -f "$stub/bd.log" "$stub/candidates.log" "$state"/*.handover "$state"/*.state.json
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

# --- cb-10d.2.1: the planning roles are assigned, never claimed ----------------------------------

unassigned='[{"id":"cb-x","status":"open","assignee":null}]'
candidates='[{"id":"cb-x","priority":2}]'

reset "$unassigned"
err="$(CANDIDATES_JSON="$candidates" run Iceman cb-x 2>&1 >/dev/null)" || fail "a build-design agent is exit 0, got: $err"
grep -qxF -- "--actor Iceman -C $consumer update cb-x --assignee Iceman --if-assignee " "$stub/bd.log" \
  || fail "the assignment is made as Iceman with an empty --if-assignee, got: $(cat "$stub/bd.log")"
! grep -q -- "--claim" "$stub/bd.log" || fail "a build-design agent's bead is not claimed"
assign_line="$(grep -n -- "update cb-x --assignee" "$stub/bd.log" | cut -d: -f1)"
push_line="$(grep -n -- "dolt push" "$stub/bd.log" | cut -d: -f1)"
[[ -n "$push_line" && "$assign_line" -lt "$push_line" ]] || fail "the assignment comes before the push"
[[ "$(cat "$stub/candidates.log")" == "stage-candidates build-design" ]] \
  || fail "a build-design agent is served from stage-candidates build-design, got: $(cat "$stub/candidates.log")"
[[ "$(cat "$state/Iceman.handover")" == "cb-x" ]] || fail "the handover file names cb-x"
[[ "$err" == *"assign-bead: cb-x is assigned to Iceman"* ]] || fail "stderr says assigned, got: $err"
pass "assigns a build-design agent without claiming"

reset "$unassigned"
CANDIDATES_JSON="$candidates" run Beast cb-x 2>/dev/null || fail "a ux agent is exit 0"
[[ "$(cat "$stub/candidates.log")" == "stage-candidates ux" ]] \
  || fail "a ux agent is served from stage-candidates ux, got: $(cat "$stub/candidates.log")"
grep -q -- "--actor Beast .*update cb-x --assignee Beast --if-assignee" "$stub/bd.log" || fail "a ux agent is assigned as Beast"
pass "a ux agent is assigned from the ux queue"

reset "$unassigned"
CANDIDATES_JSON="$candidates" run Xavier cb-x 2>/dev/null || fail "a planner is exit 0"
[[ "$(cat "$stub/candidates.log")" == "plan-candidates " ]] \
  || fail "a planner is served from plan-candidates, got: '$(cat "$stub/candidates.log")'"
! grep -q -- "--claim" "$stub/bd.log" || fail "a planner's bead is not claimed"
pass "a planner is assigned from plan-candidates"

reset "$unassigned"
status=0; err="$(CANDIDATES_JSON="$candidates" run Cerebro cb-x 2>&1 >/dev/null)" || status=$?
[[ $status -eq 2 ]] || fail "an orchestrator is exit 2, got $status"
[[ "$err" == *orchestrator* ]] || fail "the refusal names the role, got: $err"
[[ ! -e "$stub/bd.log" ]] || ! grep -q update "$stub/bd.log" || fail "an orchestrator writes nothing"
pass "an orchestrator is refused with exit 2"

reset '[{"id":"cb-x","status":"open","assignee":"Iceman"}]'
CANDIDATES_JSON='[]' run Iceman cb-x 2>/dev/null || fail "a bead already Iceman's is exit 0"
! grep -q update "$stub/bd.log" || fail "a bead already Iceman's is not assigned again"
! grep -q "dolt push" "$stub/bd.log" || fail "a bead already Iceman's is not pushed"
pass "a planning bead already the agent's is exit 0 with no write"

reset "$unassigned"
status=0; err="$(BD_UPDATE_EXIT=13 CANDIDATES_JSON="$candidates" run Iceman cb-x 2>&1 >/dev/null)" || status=$?
[[ $status -eq 3 ]] || fail "a lost assignment race is exit 3, got $status"
[[ "$err" == *"taken by somebody else"* ]] || fail "a lost race says so, got: $err"
[[ ! -e "$state/Iceman.handover" ]] || fail "a lost race writes no handover"
pass "losing the assignment race is exit 3"

reset "$unassigned"
status=0; CANDIDATES_JSON='[]' run Iceman cb-x 2>/dev/null || status=$?
[[ $status -eq 3 ]] || fail "a bead not in the role's queue is exit 3, got $status"
! grep -q update "$stub/bd.log" || fail "a bead not in the queue is not assigned"
pass "a bead not in the role's queue is exit 3"

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
