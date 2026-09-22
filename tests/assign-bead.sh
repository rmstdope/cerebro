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

consumer="$(consumer_new repo --origin --link assign-bead assignable-beads roster consumer-root)"
printf 'Rogue implementer\nCyclops producer\nBishop bugfixer\nXavier planner\nBeast ux\nIceman build-design\nCerebro orchestrator\n' > "$consumer/.cerebro/roster.conf"
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
for cand in plan-candidates stage-candidates bugfix-candidates; do
  cat > "$consumer/.claude/cerebro/scripts/$cand" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_DIR/candidates.log"
printf '%s' "${CANDIDATES_JSON:-[]}"
STUB
  chmod +x "$consumer/.claude/cerebro/scripts/$cand"
done

# cb-10d.3: stub disk-preflight and prepare-worktree, logging into the same bd.log so order is
# assertable. prepare-worktree makes a real tree on success and a bare directory on failure.
cat > "$consumer/.claude/cerebro/scripts/disk-preflight" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_DIR/bd.log"
exit "${PREFLIGHT_EXIT:-0}"
STUB
cat > "$consumer/.claude/cerebro/scripts/prepare-worktree" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >> "$STUB_DIR/bd.log"
path="$2"; branch="$4"
if [ "${PREPARE_EXIT:-0}" = 0 ]; then
  git -C "$CONSUMER" worktree add -q "$path" -b "$branch" origin/main >/dev/null 2>&1
  echo "$path abc123"
else
  mkdir -p "$path"
fi
exit "${PREPARE_EXIT:-0}"
STUB
chmod +x "$consumer/.claude/cerebro/scripts/disk-preflight" "$consumer/.claude/cerebro/scripts/prepare-worktree"

reset() {
  rm -f "$stub/bd.log" "$stub/candidates.log" "$state"/*.handover "$state"/*.state.json
  rm -rf "$state/worktrees"
  for t in "$consumer"/.cerebro/worktrees/*; do
    [ -e "$t" ] || continue
    git -C "$consumer" worktree remove --force "$t" >/dev/null 2>&1 || rm -rf "$t"
  done
  git -C "$consumer" worktree prune
  for b in $(git -C "$consumer" for-each-ref --format='%(refname:short)' 'refs/heads/cb-*'); do
    git -C "$consumer" branch -D "$b" >/dev/null 2>&1
  done
  printf '%s' "$1" > "$stub/show.json"
  printf '%s' "${2:-[]}" > "$stub/ready.json"
}

run() {
  CONSUMER="$consumer" STUB_DIR="$stub" PATH="$stub:$PATH" bash "$consumer/.claude/cerebro/scripts/assign-bead" "$@"
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

# --- producers use the same claimed-worktree lifecycle -------------------------------------------

reset "$open" "$ready"
run Cyclops cb-x 2>/dev/null || fail "an assignable producer bead is exit 0"
grep -q -- "--actor Cyclops .*update cb-x --claim" "$stub/bd.log" \
  || fail "a producer claims as Cyclops, got: $(cat "$stub/bd.log")"
[[ "$(cat "$state/Cyclops.handover")" == "cb-x" ]] || fail "a producer handover names cb-x"
pass "a producer claims its UX-agreed bead and receives a handover"

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
CANDIDATES_JSON="$candidates" run Bishop cb-x 2>/dev/null || fail "a bugfixer is exit 0"
[[ "$(cat "$stub/candidates.log")" == "bugfix-candidates " ]] \
  || fail "a bugfixer is served from bugfix-candidates, got: '$(cat "$stub/candidates.log")'"
grep -q -- "--actor Bishop .*update cb-x --claim" "$stub/bd.log" || fail "a bugfixer claims as Bishop"
pass "a bugfixer is claimed from bugfix-candidates"

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

# --- cb-10d.5: --given marks the handover given and says pushed or unpushed on stdout -----------

exact() { cat "$1"; printf '.'; }

reset "$open" "$ready"
out="$(run --given Rogue cb-x 2>/dev/null)" || fail "--given on an assignable bead is exit 0"
[[ "$out" == "pushed" ]] || fail "--given prints pushed, got: '$out'"
[[ "$(exact "$state/Rogue.handover")" == $'cb-x\ngiven\n.' ]] || fail "--given marks the handover given, got: $(cat "$state/Rogue.handover")"
claim_line="$(grep -n -- "update cb-x --claim" "$stub/bd.log" | cut -d: -f1)"
push_line="$(grep -n -- "dolt push" "$stub/bd.log" | cut -d: -f1)"
[[ -n "$claim_line" && -n "$push_line" && "$claim_line" -lt "$push_line" ]] || fail "--given claims and then pushes"
pass "--given marks the handover given and prints pushed"

reset "$open" "$ready"
out="$(BD_PUSH_EXIT=1 run --given Rogue cb-x 2>/dev/null)" || fail "--given with a failed push is exit 0"
[[ "$out" == "unpushed" ]] || fail "--given with a failed push prints unpushed, got: '$out'"
[[ "$(exact "$state/Rogue.handover")" == $'cb-x\ngiven\n.' ]] || fail "a failed push keeps the given handover"
pass "--given with a failed push prints unpushed and exits 0"

reset "$unassigned"
out="$(CANDIDATES_JSON="$candidates" run --given Iceman cb-x 2>/dev/null)" || fail "--given for a build-design agent is exit 0"
[[ "$out" == "pushed" ]] || fail "--given build-design prints pushed, got: '$out'"
grep -q -- "update cb-x --assignee Iceman" "$stub/bd.log" || fail "--given assigns Iceman"
[[ "$(exact "$state/Iceman.handover")" == $'cb-x\ngiven\n.' ]] || fail "--given build-design marks the handover given"
pass "--given assigns a build-design agent and marks the handover given"

reset '[{"id":"cb-x","status":"in_progress","assignee":"Rogue"}]' '[]'
out="$(run --given Rogue cb-x 2>/dev/null)" || fail "--given on a bead already Rogue's is exit 0"
[[ "$out" == "pushed" ]] || fail "--given on a bead already Rogue's prints pushed, got: '$out'"
! grep -q -- "update" "$stub/bd.log" || fail "--given on a bead already Rogue's writes nothing"
! grep -q -- "dolt push" "$stub/bd.log" || fail "--given on a bead already Rogue's pushes nothing"
[[ "$(exact "$state/Rogue.handover")" == $'cb-x\ngiven\n.' ]] || fail "--given on a bead already Rogue's marks the handover given"
pass "--given on a bead already the agent's prints pushed and marks the handover given"

reset "$open" "$ready"
out="$(run Rogue cb-x 2>/dev/null)" || fail "the plain claim is exit 0"
[[ -z "$out" ]] || fail "without --given nothing is printed on stdout, got: '$out'"
[[ "$(exact "$state/Rogue.handover")" == $'cb-x\n.' ]] || fail "without --given the handover is the bare id"
pass "without --given nothing is printed on stdout"

reset '[{"id":"cb-x","status":"in_progress","assignee":"Gambit"}]' '[]'
status=0; out="$(run --given Rogue cb-x 2>/dev/null)" || status=$?
[[ $status -eq 3 ]] || fail "--given keeps exit 3, got $status"
[[ -z "$out" ]] || fail "--given prints nothing on a refusal, got: '$out'"
pass "--given keeps every refusal's exit status and prints nothing"

# --- cb-10d.3: an implementer's tree is made and recorded -----------------------------------------

tree="$consumer/.cerebro/worktrees/cb-x"
line_of() { grep -n -- "$1" "$stub/bd.log" | head -1 | cut -d: -f1; }

reset "$open" "$ready"
run Rogue cb-x 2>/dev/null || fail "an implementer with a tree is exit 0"
p="$(line_of "disk-preflight --workload rust")"; c="$(line_of "update cb-x --claim")"
w="$(line_of "prepare-worktree --path $tree --branch cb-x")"; d="$(line_of "dolt push")"
[[ -n "$p" && -n "$c" && -n "$w" && -n "$d" && $p -lt $c && $c -lt $w && $w -lt $d ]] \
  || fail "preflight, claim, prepare, push in that order, got: $(cat "$stub/bd.log")"
[[ "$(cat "$state/worktrees/cb-x")" == "Rogue" ]] || fail "the tree is recorded for Rogue"
[[ "$(cat "$state/Rogue.handover")" == "cb-x" ]] || fail "the handover still names cb-x"
pass "an implementer's tree is made after the claim and recorded"

reset "$open" "$ready"
CANDIDATES_JSON="$candidates" run Bishop cb-x 2>/dev/null || fail "a bugfixer with a tree is exit 0"
grep -q "prepare-worktree" "$stub/bd.log" || fail "a bugfixer gets a prepared worktree"
[[ "$(cat "$state/worktrees/cb-x")" == "Bishop" ]] || fail "the tree is recorded for Bishop"
pass "a bugfixer is prepared like any claim-based builder"

reset '[{"id":"cb-x","status":"open","assignee":"","design":"run disk-preflight --workload non-rust first"}]' "$ready"
run Rogue cb-x 2>/dev/null || fail "a non-rust plan is exit 0"
grep -qx "disk-preflight --workload non-rust" "$stub/bd.log" || fail "a non-rust plan preflights non-rust, got: $(cat "$stub/bd.log")"
pass "a plan that declares non-rust preflights as non-rust"

reset "$open" "$ready"
status=0; PREFLIGHT_EXIT=1 run Rogue cb-x 2>/dev/null || status=$?
[[ $status -eq 4 ]] || fail "a refused preflight is exit 4, got $status"
! grep -q -- "--claim" "$stub/bd.log" || fail "a refused preflight claims nothing"
[[ ! -e "$state/Rogue.handover" && ! -e "$state/worktrees/cb-x" ]] || fail "a refused preflight writes nothing"
pass "a refused preflight claims nothing"

reset "$open" "$ready"
status=0; PREPARE_EXIT=1 run Rogue cb-x 2>/dev/null || status=$?
[[ $status -eq 4 ]] || fail "a failed preparation is exit 4, got $status"
[[ ! -e "$tree" && ! -e "$state/worktrees/cb-x" ]] || fail "a failed preparation leaves no tree and no record"
[[ "$(cat "$state/Rogue.handover")" == "cb-x" ]] || fail "a failed preparation keeps the handover"
pass "a failed preparation removes what it made and records nothing"

reset "$open" "$ready"
git -C "$consumer" branch -q cb-x origin/main
run Rogue cb-x 2>/dev/null || fail "a taken branch is exit 0"
grep -q -- "--branch cb-x-2" "$stub/bd.log" || fail "a taken branch moves to cb-x-2, got: $(cat "$stub/bd.log")"
reset "$open" "$ready"
git -C "$consumer" branch -q cb-x origin/main; git -C "$consumer" branch -q cb-x-2 origin/main
run Rogue cb-x 2>/dev/null || fail "two taken branches are exit 0"
grep -q -- "--branch cb-x-3" "$stub/bd.log" || fail "two taken branches move to cb-x-3"
pass "a taken branch name moves to the next free suffix"

reset "$open" "$ready"
git -C "$consumer" worktree add -q "$tree" -b cb-x origin/main
run Rogue cb-x 2>/dev/null || fail "a registered tree is adopted with exit 0"
! grep -q "prepare-worktree\|disk-preflight" "$stub/bd.log" || fail "an adopted tree is neither preflighted nor prepared"
[[ "$(cat "$state/worktrees/cb-x")" == "Rogue" ]] || fail "an adopted tree is recorded"
pass "a registered tree already there is adopted without preparing"

reset "$open" "$ready"
mkdir -p "$tree"
status=0; run Rogue cb-x 2>/dev/null || status=$?
[[ $status -eq 4 ]] || fail "a stray directory is exit 4, got $status"
! grep -q -- "--claim" "$stub/bd.log" || fail "a stray directory is refused before the claim"
pass "a stray directory at the path is refused before the claim"

reset '[{"id":"cb-x","status":"in_progress","assignee":"Rogue"}]' '[]'
run Rogue cb-x 2>/dev/null || fail "a bead already Rogue's with no tree is exit 0"
! grep -q -- "--claim" "$stub/bd.log" || fail "no second claim"
grep -q "prepare-worktree" "$stub/bd.log" || fail "the missing tree is made"
[[ "$(cat "$state/worktrees/cb-x")" == "Rogue" ]] || fail "the made tree is recorded"
pass "a bead already the implementer's gets its missing tree"

reset '[{"id":"cb-x","status":"open","assignee":null}]'
CANDIDATES_JSON='[{"id":"cb-x","priority":2}]' run Iceman cb-x 2>/dev/null || fail "a planning role is exit 0"
! grep -q "prepare-worktree\|disk-preflight" "$stub/bd.log" || fail "a planning role gets no tree"
[[ ! -e "$state/worktrees/cb-x" ]] || fail "a planning role gets no record"
pass "a planning role gets no tree"

suite_passed
