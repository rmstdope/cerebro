#!/usr/bin/env bash
#
# Proves `scripts/producer-park`: the only producer hand-back path for a
# genuine UX or scope decision. An unplanned UX-agreed bead is designed by its
# producer, not parked; this script only records a decision that must return to
# the navigator.
#
#     bash tests/producer-park.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new repo --link producer-park consumer-root)"
script="$consumer/.claude/cerebro/scripts/producer-park"
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

# --- a genuine decision is parked, released, and pushed -----------------------------------------

reset "$mine"
run Storm cb-x ux "The mockup omits the empty state" >/dev/null \
  || fail "a UX decision is parked"
log="$(cat "$stub/bd.log")"
grep -q -- "update cb-x --remove-label planned --add-label human --add-label needs-ui-decision" <<<"$log" \
  || fail "the update removes planned and records both parking labels: $log"
grep -q -- "--set-metadata paused_at=" <<<"$log" \
  || fail "the update records when the pause began: $log"
grep -q -- "--if-assignee Storm --if-status in_progress" <<<"$log" \
  || fail "the update is compare-and-swapped on the producer's claim: $log"
grep -q -- "unclaim cb-x --if-assignee Storm" <<<"$log" \
  || fail "the producer releases only its own claim: $log"
[[ "$(tail -1 "$stub/bd.log")" == *"dolt push"* ]] \
  || fail "the parking transition is pushed: $log"
pass "parks a UX decision with needs-ui-decision, releases it, and pushes"

# --- scope is the other explicit reason ----------------------------------------------------------

reset "$mine"
run Storm cb-x scope "The requested API contract is undecided" >/dev/null \
  || fail "a scope decision is parked"
grep -q -- "needs-ui-decision" "$stub/bd.log" \
  || fail "a scope decision still records needs-ui-decision"
pass "parks a scope decision"

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

# --- legacy planned work stays on the legacy hand-back path -------------------------------------

reset '[{"id":"cb-x","status":"in_progress","assignee":"Storm","labels":["planned"]}]'
status=0
out="$(run Storm cb-x ux "The mockup is ambiguous" 2>"$work_dir/err")" || status=$?
[[ $status -eq 1 && -z "$out" ]] || fail "a non-UX bead is rejected"
! grep -qE "update|unclaim|dolt push" "$stub/bd.log" \
  || fail "a non-UX bead is not changed"
pass "does not park planned legacy work"

# --- a claim lost between the read and update changes nothing ------------------------------------

reset "$mine"
status=0
out="$(BD_UPDATE_EXIT=13 run Storm cb-x ux "The mockup is ambiguous" 2>"$work_dir/err")" || status=$?
[[ $status -eq 13 && -z "$out" ]] || fail "a lost update precondition is returned to the producer"
! grep -qE "unclaim|dolt push" "$stub/bd.log" \
  || fail "a lost update precondition does not release or push"
pass "does not mutate further after losing the producer claim"

suite_passed
