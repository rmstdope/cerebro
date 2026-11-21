#!/usr/bin/env bash
#
# Proves that every named hand-off in `scripts/candidate-label-policy.sh` sends a bead to the queue
# meant to take it, and to no other (cb-q6yb). The writers (`producer-park`, `reopen-failed`, and the
# three hand-offs agents apply by hand through `route_flags_for`) and the four queues
# (`stage-candidates`, `assignable-beads`, `bugfix-candidates`, `second-look-beads`) are run for
# real against one board,
# held by a `bd` that applies every write: each case asks the readers about the bead the writer has
# just changed, not about a fixture written to look like it. A writer and a reader that disagree
# about a label strand the bead, and every one of the four fixes this suite stands for (cb-b26a,
# cb-lcfq, cb-0elv.1, cb-0elv.5) was such a disagreement.
#
#     bash tests/label-routes.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --copy)"
scripts="$consumer/.cerebro/cerebro/scripts"
stub="$work_dir/stub"
mkdir -p "$stub"

# A board in one JSON file and a `bd` that keeps it: `show`, `list` and `ready` read it; `update`,
# `unclaim`, `reopen` and `set-state` change it the way bd does for the flags these scripts pass.
# `--if-assignee` and `--if-status` are honoured, since producer-park's writes are guarded by them.
cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
board="$STUB_DIR/board.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--actor) shift 2 ;;
    --readonly) shift ;;
    *) break ;;
  esac
done
sub="$1"; shift
edit() {
  local tmp="$board.tmp"
  jq "$@" "$board" > "$tmp" && mv "$tmp" "$board"
}
case "$sub" in
  show)
    jq --arg id "$1" '[ .[] | select(.id == $id) ]' "$board" ;;
  list)
    status=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) status="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq --arg status "$status" '[ .[] | select($status == "" or .status == $status) ]' "$board" ;;
  ready)
    with=(); without=(); unassigned=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) with+=("$2"); shift 2 ;;
        --exclude-label) without+=("$2"); shift 2 ;;
        --exclude-type|-n) shift 2 ;;
        --unassigned) unassigned=true; shift ;;
        *) shift ;;
      esac
    done
    json_list() { printf '%s\n' "$@" | jq -R . | jq -s 'map(select(. != ""))'; }
    jq --argjson with "$(json_list ${with[@]+"${with[@]}"})" \
       --argjson without "$(json_list ${without[@]+"${without[@]}"})" \
       --argjson unassigned "$unassigned" '
      [ .[] | select(.status == "open")
        | (.labels // []) as $ls
        | select(all($with[]; . as $l | $ls | index($l)))
        | select(any($without[]; . as $l | $ls | index($l)) | not)
        | select(($unassigned | not) or ((.assignee // "") == "")) ]' "$board" ;;
  update)
    id="$1"; shift
    filter='.'; if_assignee=""; if_status=""; guarded=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --remove-label) filter="$filter | .labels = ((.labels // []) - [\"$2\"])"; shift 2 ;;
        --add-label) filter="$filter | .labels = (((.labels // []) - [\"$2\"]) + [\"$2\"])"; shift 2 ;;
        --assignee) filter="$filter | .assignee = \"$2\""; shift 2 ;;
        --priority) filter="$filter | .priority = $2"; shift 2 ;;
        --priority=*) filter="$filter | .priority = ${1#--priority=}"; shift ;;
        --if-assignee) if_assignee="$2"; guarded=true; shift 2 ;;
        --if-status) if_status="$2"; shift 2 ;;
        --append-notes|--set-metadata) shift 2 ;;
        *) shift ;;
      esac
    done
    current="$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$board")"
    if $guarded && [[ "$(jq -r '.assignee // ""' <<<"$current")" != "$if_assignee" ]]; then exit 13; fi
    if [[ -n "$if_status" && "$(jq -r '.status' <<<"$current")" != "$if_status" ]]; then exit 13; fi
    edit --arg id "$id" "map(if .id == \$id then ($filter) else . end)" ;;
  unclaim)
    id="$1"; shift
    if [[ "${1:-}" == --if-assignee ]]; then
      current="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .assignee // ""' "$board")"
      if [[ "$current" != "$2" ]]; then exit 13; fi
    fi
    edit --arg id "$id" 'map(if .id == $id then .assignee = "" | .status = "open" else . end)' ;;
  reopen)
    edit --arg id "$1" 'map(if .id == $id then .status = "open" else . end)' ;;
  set-state)
    key="${2%%=*}"; value="${2#*=}"
    edit --arg id "$1" --arg key "$key" --arg value "$value" '
      map(if .id == $id
          then .labels = ([ (.labels // [])[] | select(startswith($key + ":") | not) ] + [$key + ":" + $value])
          else . end)' ;;
  dolt) ;;
  *) echo "label-routes stub: unexpected bd $sub" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub/bd"

with_board() {
  printf '%s' "$1" > "$stub/board.json"
}

bd_env() {
  STUB_DIR="$stub" PATH="$stub:$PATH" "$@"
}

# Which queues offer the bead: the names of the readers whose output carries it, space-separated.
offered_by() {
  local id="$1" out queues=""
  out="$(bd_env bash "$scripts/stage-candidates" ux)" || fail "stage-candidates failed"
  jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$out" >/dev/null && queues="$queues ux"
  out="$(bd_env bash "$scripts/assignable-beads")" || fail "assignable-beads failed"
  jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$out" >/dev/null && queues="$queues producer"
  out="$(bd_env bash "$scripts/bugfix-candidates")" || fail "bugfix-candidates failed"
  jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$out" >/dev/null && queues="$queues bugfixer"
  out="$(bd_env bash "$scripts/second-look-beads")" || fail "second-look-beads failed"
  grep -qxF "$id" <<<"$out" && queues="$queues verifier"
  printf '%s' "${queues# }"
}

sha="0123456789abcdef0123456789abcdef01234567"

# A hand-off an agent applies by hand, as its skill's snippet does: the named transitions' flags.
# The transitions are one word, or several separated by spaces (`"unpark send_to_ux"`).
apply_route() {
  local id="$1" transitions="$2"
  shift 2
  # shellcheck disable=SC2086 # the transitions are word-split on purpose
  bd_env bash -c 'source "$1/candidate-label-policy.sh" && route_flags_for $2 && bd update "$3" "${route_flags[@]}" "${@:4}"' \
    _ "$scripts" "$transitions" "$id" "$@" || fail "route_flags_for $transitions refused"
}

# The navigator's unpark (`agents/orchestrator.md`, *Unpark it*): the named `unpark` hand-off, so
# where an unparked bead goes is decided by the labels the park left under it.
unpark() {
  apply_route "$1" unpark
}

# --- producer-park: a UX question goes to the UX queue and nowhere else ----------------------------

for labels in '["ux:agreed","planned"]' '["ux:none","planned"]'; do
  with_board '[{"id":"cb-x","status":"in_progress","assignee":"Storm","priority":1,"issue_type":"task","labels":'"$labels"'}]'
  bd_env "$scripts/producer-park" Storm cb-x ux "The mockup omits the empty state" >/dev/null \
    || fail "producer-park refused a UX question on $labels"
  got="$(offered_by cb-x)"
  [[ "$got" == "ux" ]] || fail "a bead parked for a UX question ($labels) is offered by [$got], not by the UX queue alone"
done
pass "producer-park ux: an agreed or an invisible bead goes to the UX queue alone"

# --- producer-park: a scope question goes to the navigator, in no fleet queue ----------------------

with_board '[{"id":"cb-x","status":"in_progress","assignee":"Storm","priority":1,"issue_type":"task","labels":["ux:agreed","planned"]}]'
bd_env "$scripts/producer-park" Storm cb-x scope "The API contract is undecided" >/dev/null \
  || fail "producer-park refused a scope question"
got="$(offered_by cb-x)"
[[ -z "$got" ]] || fail "a bead parked for a scope question is offered by [$got]; it is the navigator's"
unpark cb-x
got="$(offered_by cb-x)"
[[ "$got" == "producer" ]] || fail "a scope-parked bead the navigator unparks is offered by [$got], not by the producer queue alone"
pass "producer-park scope: the bead waits for the navigator, and goes back to a producer when unparked"

# --- reopen-failed: a plan fault goes back to the UX queue -----------------------------------------

for labels in '["ux:agreed","planned"]' '["ux:none","planned"]'; do
  with_board '[{"id":"cb-x","status":"closed","assignee":"Storm","priority":2,"issue_type":"task","labels":'"$labels"'}]'
  bd_env "$scripts/reopen-failed" cb-x --sha "$sha" --notes "The banner never appears" --fault plan >/dev/null \
    || fail "reopen-failed refused a plan fault on $labels"
  got="$(offered_by cb-x)"
  [[ "$got" == "ux" ]] || fail "a plan-fault reopen of $labels is offered by [$got], not by the UX queue alone"
done
pass "reopen-failed plan: an agreed or an invisible bead goes to the UX queue alone"

# --- reopen-failed: a build fault goes back to a producer, a second look's mark gone ----------------

with_board '[{"id":"cb-x","status":"closed","assignee":"Storm","priority":2,"issue_type":"task","labels":["ux:agreed","planned","second-look","verdict:stale"]}]'
bd_env "$scripts/reopen-failed" cb-x --sha "$sha" --notes "The count is off by one" --fault build >/dev/null \
  || fail "reopen-failed refused a build fault"
got="$(offered_by cb-x)"
[[ "$got" == "producer" ]] || fail "a build-fault reopen is offered by [$got], not by the producer queue alone"
pass "reopen-failed build: the bead goes to the producer queue alone"

# --- reopen-failed: a bug goes back to the bugfixer, whatever fault was named -----------------------

for fault in plan build; do
  with_board '[{"id":"cb-x","status":"closed","assignee":"Bishop","priority":2,"issue_type":"bug","labels":["bugfix"]}]'
  bd_env "$scripts/reopen-failed" cb-x --sha "$sha" --notes "It still crashes" --fault "$fault" >/dev/null 2>&1 \
    || fail "reopen-failed refused a bug with --fault $fault"
  got="$(offered_by cb-x)"
  [[ "$got" == "bugfixer" ]] || fail "a bug reopened with --fault $fault is offered by [$got], not by the bugfixer alone"
done
pass "reopen-failed on a bug: the bead goes to the bugfixer queue alone, plan or build"

# --- Cerebro's send-back: a parked bead goes to the UX queue, whatever stage label it carried -------

for labels in '["ux:agreed","planned","human","pause:kept"]' '["ux:none","human"]'; do
  with_board '[{"id":"cb-x","status":"open","assignee":"","priority":1,"issue_type":"task","labels":'"$labels"'}]'
  apply_route cb-x "unpark send_to_ux"
  got="$(offered_by cb-x)"
  [[ "$got" == "ux" ]] || fail "a parked $labels bead Cerebro sends back is offered by [$got], not by the UX queue alone"
done
pass "unpark send_to_ux by hand: a parked bead goes to the UX queue alone"

# --- the UX agent's park: the navigator's, then back to the UX queue when unparked -----------------

with_board '[{"id":"cb-x","status":"open","assignee":"Xavier","priority":1,"issue_type":"task","labels":[]}]'
apply_route cb-x park_for_ui_decision --assignee ""
got="$(offered_by cb-x)"
[[ -z "$got" ]] || fail "a bead parked for a UI decision is offered by [$got]; it is the navigator's"
unpark cb-x
got="$(offered_by cb-x)"
[[ "$got" == "ux" ]] || fail "a UI-decision park the navigator unparks is offered by [$got], not by the UX queue alone"
pass "park_for_ui_decision by hand: the navigator's, then the UX queue's alone when unparked"

# --- the escalation (`beads-workflow`, *Escalating*): the navigator's, then back where it came from -

for case in 'task|["ux:agreed","planned"]|producer' 'bug|["bugfix"]|bugfixer'; do
  IFS='|' read -r type labels queue <<<"$case"
  with_board '[{"id":"cb-x","status":"in_progress","assignee":"Storm","priority":1,"issue_type":"'"$type"'","labels":'"$labels"'}]'
  apply_route cb-x park_for_navigator --if-assignee Storm
  bd_env bd unclaim cb-x --if-assignee Storm || fail "the escalation's guarded unclaim refused its own claim"
  got="$(offered_by cb-x)"
  [[ -z "$got" ]] || fail "an escalated $type is offered by [$got]; it is the navigator's"
  unpark cb-x
  got="$(offered_by cb-x)"
  [[ "$got" == "$queue" ]] || fail "an escalated $type the navigator unparks is offered by [$got], not by the $queue queue alone"
done
pass "park_for_navigator by hand: an escalated bead is the navigator's, then its builder queue's alone when unparked"

# --- a guarded escalation leaves another builder's claim alone ---------------------------------------

board='[{"id":"cb-x","status":"in_progress","assignee":"Rogue","priority":1,"issue_type":"task","labels":["ux:agreed","planned"]}]'
with_board "$board"
if bd_env bash -c 'source "$1/candidate-label-policy.sh" && route_flags_for park_for_navigator && bd update cb-x "${route_flags[@]}" --if-assignee Storm' _ "$scripts"; then
  fail "the escalation's update applied under another builder's claim"
fi
if bd_env bd unclaim cb-x --if-assignee Storm; then
  fail "the escalation's unclaim released another builder's claim"
fi
[[ "$(jq -c . "$stub/board.json")" == "$(jq -c . <<<"$board")" ]] \
  || fail "a guarded escalation under another builder's claim changed the bead: $(cat "$stub/board.json")"
pass "a guarded escalation leaves another builder's claim alone"

# --- the merge gate: the navigator merges; unparked, a producer finishes it -------------------------

with_board '[{"id":"cb-x","status":"in_progress","assignee":"Storm","priority":1,"issue_type":"task","labels":["ux:agreed","planned"]}]'
apply_route cb-x park_for_merge --if-assignee Storm
bd_env bd unclaim cb-x
got="$(offered_by cb-x)"
[[ -z "$got" ]] || fail "a bead parked at the merge gate is offered by [$got]; it is the navigator's"
jq -e '.[0].labels | index("planned")' "$stub/board.json" >/dev/null \
  || fail "the merge-gate park took the plan off; the producer who finishes it needs it"
unpark cb-x
got="$(offered_by cb-x)"
[[ "$got" == "producer" ]] || fail "a merge-gate park the navigator unparks is offered by [$got], not by the producer queue alone"
pass "park_for_merge by hand: the navigator's, plan kept, then a producer's when unparked"

# --- the second-look hand-back: the verifier's alone, until a fresh verdict clears it ---------------

for labels in '["ux:agreed","planned","verification:failed"]' '["ux:none","planned","verification:failed"]'; do
  with_board '[{"id":"cb-x","status":"in_progress","assignee":"Storm","priority":0,"issue_type":"task","labels":'"$labels"'}]'
  apply_route cb-x hand_to_verifier --if-assignee Storm
  bd_env bd unclaim cb-x
  got="$(offered_by cb-x)"
  [[ "$got" == "verifier" ]] || fail "a $labels bead handed to the verifier is offered by [$got], not by the verifier alone"
  apply_route cb-x fresh_verdict
  got="$(offered_by cb-x)"
  [[ "$got" != *verifier* ]] || fail "a fresh verdict left a $labels bead on the verifier's list [$got]"
done
pass "hand_to_verifier by hand: the verifier's alone, and off her list once she records a verdict"

# --- several transitions in one call: every one's flags; one unknown name refuses them all ----------

if out="$(bd_env bash -c 'source "$1/candidate-label-policy.sh"; route_flags_for unpark send_to_xu; s=$?; echo "${#route_flags[@]}"; exit $s' _ "$scripts" 2>/dev/null)"; then
  fail "route_flags_for accepted a list holding a transition it does not name"
fi
[[ "$out" == 0 ]] || fail "route_flags_for refused a list but left $out flags set; a caller ignoring the status would write half a change"
if bd_env bash -c 'source "$1/candidate-label-policy.sh" && route_flags_for' _ "$scripts" 2>/dev/null; then
  fail "route_flags_for accepted no transition at all"
fi
pass "route_flags_for refuses an empty list, or one holding an unknown name, leaving no flags"

# --- a hand-off with no name is refused, so a typo cannot apply an empty label change --------------

if bd_env bash -c 'source "$1/candidate-label-policy.sh" && route_flags_for send_to_xu' _ "$scripts" 2>/dev/null; then
  fail "route_flags_for accepted a transition it does not name"
fi
pass "route_flags_for refuses a transition it does not name"

suite_passed
