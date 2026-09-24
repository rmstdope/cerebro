#!/usr/bin/env bash
#
# Proves `scripts/producer-park`: the only producer hand-back path for a
# genuine UX or scope decision. An unplanned UX-agreed bead is designed by its
# producer, not parked; this script only records a decision somebody else must
# make - a UX question goes back to the UX stage, a scope question to the
# navigator.
#
#     bash tests/producer-park.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link producer-park consumer-root)"
script="$consumer/.cerebro/cerebro/scripts/producer-park"
stub="$work_dir/stub"
mkdir -p "$stub"

cat > "$stub/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/bd.log"
sub=""
skip=0
for arg in "$@"; do
  if [[ $skip -eq 1 ]]; then
    skip=0
    continue
  fi
  case "$arg" in
    -C|--actor) skip=1 ;;
    -*) ;;
    *) sub="$arg"; break ;;
  esac
done
case "$sub" in
  show) cat "$STUB_DIR/show.json" ;;
  update) exit "${BD_UPDATE_EXIT:-0}" ;;
  unclaim|dolt) exit "${BD_EXIT:-0}" ;;
esac
STUB
chmod +x "$stub/bd"

run() {
  STUB_DIR="$stub" PATH="$stub:$PATH" "$script" "$@"
}

reset() {
  rm -f "$stub/bd.log"
  printf '%s' "$1" > "$stub/show.json"
}

mine='[{"id":"cb-x","status":"in_progress","assignee":"Storm","labels":["ux:agreed","planned"]}]'

# --- a UX question goes straight back to the UX stage ---------------------------------------------
#
# Returning a UX question to the navigator's queue cost three sessions and a navigator turn before
# a designer ever saw it (cb-2cj4). Now `ux` sends the bead back to the UX stage itself: the agreed
# label comes off so `stage-candidates ux` offers it again and no producer re-takes it, the note
# carries the heading `agree-experience` reads a returned piece of work by, and nothing is parked
# for a person - no `human`, no `paused_at`.

reset "$mine"
run Storm cb-x ux "The mockup omits the empty state" >/dev/null \
  || fail "a UX decision is sent back"
log="$(cat "$stub/bd.log")"
grep -q -- "update cb-x --remove-label ux:agreed --remove-label ux:none --remove-label planned --add-label needs-ui-decision" <<<"$log" \
  || fail "the update takes the agreed label and the plan off and marks the open question: $log"
grep -q -- "--append-notes ## Sent back to the UX stage" <<<"$log" \
  || fail "the note carries the heading the UX stage reads a returned piece of work by: $log"
grep -q -- "The mockup omits the empty state" <<<"$log" \
  || fail "the note carries the reason: $log"
! grep -q -- "--add-label human" <<<"$log" \
  || fail "a UX question is the designer's, not the navigator's: $log"
! grep -q -- "paused_at=" <<<"$log" \
  || fail "a UX return is not a pause: $log"
grep -q -- "--if-assignee Storm --if-status in_progress" <<<"$log" \
  || fail "the update is compare-and-swapped on the producer's claim: $log"
grep -q -- "unclaim cb-x --if-assignee Storm" <<<"$log" \
  || fail "the producer releases only its own claim: $log"
[[ "$(tail -1 "$stub/bd.log")" == *"dolt push"* ]] \
  || fail "the return is pushed: $log"
pass "sends a UX question back to the UX stage, releases the bead, and pushes"

# --- a bead filed as invisible may still be sent to UX, and then stops being invisible -------------
#
# `ux:none` was the navigator's word at filing that nothing a person sees changes. A producer that
# finds otherwise may add the UX stop, never skip it: the label comes off with the return, so the
# bead is a UX candidate and no producer re-takes it (cb-uump).

reset '[{"id":"cb-x","status":"in_progress","assignee":"Storm","labels":["ux:none","planned"]}]'
run Storm cb-x ux "The migration changes the wording of the summary line" >/dev/null \
  || fail "a ux:none bead may be sent to the UX stage"
log="$(cat "$stub/bd.log")"
grep -q -- "--remove-label ux:none" <<<"$log" \
  || fail "the invisible-by-declaration label comes off with the return: $log"
grep -q -- "--add-label needs-ui-decision" <<<"$log" \
  || fail "the open question is marked: $log"
pass "sends a bead filed as invisible to the UX stage and removes ux:none"

# --- scope is the navigator's, and is parked ------------------------------------------------------

reset "$mine"
run Storm cb-x scope "The requested API contract is undecided" >/dev/null \
  || fail "a scope decision is parked"
log="$(cat "$stub/bd.log")"
grep -q -- "update cb-x --remove-label planned --add-label human " <<<"$log" \
  || fail "a scope decision is parked for the navigator with human: $log"
# `needs-ui-decision` would make the fleet view keep it parked after its blockers close and make
# Cerebro offer it to UX; a scope question is nobody's but the navigator's (cb-lcfq).
! grep -q -- "needs-ui-decision" <<<"$log" \
  || fail "a scope park is not a UI question: $log"
grep -q -- "--set-metadata paused_at=" <<<"$log" \
  || fail "a scope pause records when it began: $log"
! grep -q -- "remove-label ux:agreed" <<<"$log" \
  || fail "a scope question leaves the agreed experience standing: $log"
[[ "$(tail -1 "$stub/bd.log")" == *"dolt push"* ]] \
  || fail "the parking transition is pushed: $log"
pass "parks a scope decision for the navigator"

# --- anything else is refused before a board write ----------------------------------------------

for kind in build plan missing; do
  reset "$mine"
  status=0
  out="$(run Storm cb-x "$kind" "not a valid decision" 2>"$work_dir/err")" || status=$?
  [[ $status -eq 2 && -z "$out" && ! -e "$stub/bd.log" ]] \
    || fail "$kind is refused before reading or writing the board"
done
pass "refuses parking for a non-UX, non-scope reason"

# --- only the current producer can release the claimed bead -------------------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Rogue","labels":["ux:agreed"]}]'
status=0
out="$(run Storm cb-x ux "The mockup is ambiguous" 2>"$work_dir/err")" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "another producer's bead is rejected"
! grep -qE "update|unclaim|dolt push" "$stub/bd.log" \
  || fail "another producer's bead is not changed"
pass "does not park another producer's bead"

# --- a bead that never passed the UX gate is not producer work -------------------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Storm","labels":["planned"]}]'
status=0
out="$(run Storm cb-x ux "The mockup is ambiguous" 2>"$work_dir/err")" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "a bead with neither ux:agreed nor ux:none is rejected"
! grep -qE "update|unclaim|dolt push" "$stub/bd.log" \
  || fail "a non-producer bead is not changed"
pass "refuses a bead that carries neither ux:agreed nor ux:none"

# --- a claim lost between the read and update changes nothing ------------------------------------

reset "$mine"
status=0
out="$(BD_UPDATE_EXIT=13 run Storm cb-x ux "The mockup is ambiguous" 2>"$work_dir/err")" || status=$?
[[ $status -eq 13 && -z "$out" ]] || fail "a lost update precondition is returned to the producer"
! grep -qE "unclaim|dolt push" "$stub/bd.log" \
  || fail "a lost update precondition does not release or push"
pass "does not mutate further after losing the producer claim"

suite_passed
