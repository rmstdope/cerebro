#!/usr/bin/env bash
#
# R12, as a navigator meets it: a session that dies on a launcher refusal shows the refusal on its
# row, and is not started again until the navigator presses `s'. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# against a throwaway consumer it supervises, lets the producer trigger start Rogue, has the
# launcher refuse, and reads the screen and the launches the view made. The rules under it
# (`lifecycle::classify_exit' reading status 2 as a refusal, `App::parked_names' keeping a refused
# row out of standby, `SessionHost::note_refusal' and the refused pane in `ui') are unit-tested in
# fleet-view/src, and `tests/launch-refused.sh' proves the launcher's own errors.jsonl line; this
# proves the path through all of them, which is where cb-ccl's day-long refusal went unseen.
#
# The fixture:
#   - one roster row, `Rogue producer standby', and one ranked UX-agreed bead, cb-r1, so the
#     producer trigger is due as soon as the view has read the board.
#   - `role_start_spacing_producer 1'. That is what lets the "not started again" window below fail:
#     a producer has no wake interval, one failed start backs off by 0 seconds, and the
#     unchanged-work guard needs an end later than the start, which a refused launch never leaves.
#     So were a refusal NOT parked, the view would start Rogue again on its next supervision tick
#     (5 s), not after the default 30 s spacing.
#   - a stub `scripts/launch' in the copied consumer, the view's one way to start a session. Each
#     call is logged. The first refuses as the real launcher does - `cerebro: <sentence>' on stderr,
#     status 2 - and every later one is a live pass: `working' through the real `agent-state', then a
#     sleeper whose argv carries the marker sentence, so the row reads as alive.
#   - a file-per-bead `bd' stub (the shape tests/fleet-view-restart.sh uses) and a `gh' stub that
#     answers `[]'.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md).
#
# Every wait is a bounded poll that fails with the screen, the view's stderr and what it launched.
#
#     bash tests/fleet-refused.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-refused needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------
#
# Debug, as tests/fleet-keys.sh builds it, so the suites share one incremental build.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer -----------------------------------------------------------------------------------

consumer="$(consumer_new refused --copy)"
scripts="$consumer/.cerebro/cerebro/scripts"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
launches="$fixture/launches"
mkdir -p "$stubs" "$beads"
: > "$launches"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name                 Refused
default_branch               main
audience_noun                navigator
gate_fast                    true
gate_full                    true
role_start_spacing_producer  1
CONF
printf 'Rogue  producer  standby\n' > "$consumer/.cerebro/roster.conf"

jq -n '{
  id: "cb-r1", title: "fixture cb-r1", status: "open", priority: 1, issue_type: "task",
  labels: ["ux:agreed"], assignee: "", owner: "test",
  created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
}' > "$beads/cb-r1.json"

# --- stub bd: one JSON file per bead, every call logged ----------------------------------------------
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/bd.log"
actor=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly|--quiet|-q) shift ;;
    -C) shift 2 ;;
    --actor) actor="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
dir="$FIXTURE/beads"
all() { cat "$dir"/*.json | jq -s 'sort_by(.id)'; }
cmd="${1:-}"
shift || true
case "$cmd" in
  list)
    statuses=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) statuses="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$statuses" ]]; then
      all | jq --arg s "$statuses" '($s | split(",")) as $want | [ .[] | select(.status as $x | $want | index($x)) ]'
    else
      all | jq '[ .[] | select(.status != "closed") ]'
    fi
    ;;
  ready)
    all | jq '[ .[] | select(.status == "open" and (.assignee // "") == "") ]' ;;
  show)
    [[ -f "$dir/$1.json" ]] || { echo "no issue found: $1" >&2; exit 1; }
    jq -s . "$dir/$1.json" ;;
  dolt|heartbeat|update|unclaim) ;;
  *) echo '[]' ;;
esac
STUB

cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB

# --- stub launch: refuse once, then a live pass --------------------------------------------------------
#
# The refusal is said exactly as `scripts/launch-refused' says it and the caller exits as
# `scripts/launch' does: one `cerebro: ' line on stderr, then status 2, with nothing between that
# could fail first (.cerebro/traps.md, "An advisory step can eat the exit status").
cat > "$scripts/launch" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/session-marker.sh"
name="$1"
printf 'START %s\n' "$*" >> "$FIXTURE/launches"
if [[ "$(grep -c '^START ' "$FIXTURE/launches")" -eq 1 ]]; then
  echo "cerebro: agents/producer.md is missing from this fixture" >&2
  exit 2
fi
"$here/agent-state" "$name" working --phase build --pid $$
exec bash -c 'while :; do sleep 1; done' "$(cerebro_marker_sentence "$name" "$CEREBRO_CONSUMER_SHARED_ROOT")"
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$scripts/launch"

# --- the view, on a pty -------------------------------------------------------------------------------

keys="$work_dir/keys.fifo"
screen="$work_dir/screen.txt"
view_err="$work_dir/view.err"
mkfifo "$keys"

hints="$("$scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

export FIXTURE="$fixture"
(
  cd "$consumer"
  export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 50 200 -- "$binary"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!

suite_cleanup() {
  kill "$view_pid" 2>/dev/null || true
  # A session the view left behind carries the fixture's root in its marker sentence.
  pkill -f "rooted at $shared/" 2>/dev/null || true
  wait "$view_pid" 2>/dev/null || true
}

exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

state="$shared/.cerebro/state"
evidence() {
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- launches ---\n'
  cat "$launches" 2>/dev/null || true
  printf -- '--- decisions (tail) ---\n'
  tail -n 8 "$state/decisions.jsonl" 2>/dev/null || true
  printf -- '--- errors (tail) ---\n'
  tail -n 8 "$state/errors.jsonl" 2>/dev/null || true
}

# wait_until <seconds> <what> <command...>: poll every 0.2 s for up to SECONDS.
wait_until() {
  local seconds="$1" what="$2" i
  shift 2
  for ((i = 0; i < seconds * 5; i++)); do
    if "$@"; then return 0; fi
    kill -0 "$view_pid" 2>/dev/null || fail "the view exited while waiting for: $what$(evidence)"
    sleep 0.2
  done
  fail "after ${seconds}s, timed out waiting for: $what$(evidence)"
}

on_screen() { grep -Fq -- "$1" "$screen" 2>/dev/null; }
off_screen() { ! grep -Fq -- "$1" "$screen" 2>/dev/null; }
starts() { grep -c '^START ' "$launches" 2>/dev/null || true; }
starts_are() { [ "$(starts)" -eq "$1" ]; }
# on_screen, once the refusal has happened: a second start before `s' is the failure, whatever the
# screen says, so it is checked first and named as what it is. Without this a refusal treated as a
# crash is restarted inside a tick and reads as "not drawn".
held_on_screen() {
  starts_are 1 || fail "the view started a refused row again without s$(evidence)"
  on_screen "$1"
}

# --- the trigger starts Rogue, and the launcher refuses ---------------------------------------------

wait_until 90 "the producer trigger to start Rogue on cb-r1" starts_are 1
grep -q '^START Rogue .*--bead cb-r1' "$launches" \
  || fail "the trigger's start was not Rogue on cb-r1$(evidence)"
pass "the view starts a standby producer on the ready bead"

# --- the refusal is drawn on the row --------------------------------------------------------------------
#
# The row's verdict, and - the row being the only one, and so selected - the Session pane with the
# launcher's own sentence, its `cerebro: ' prefix taken off, and the way back.
wait_until 30 "the row's verdict to read ✗ refused" held_on_screen '✗ refused'
wait_until 10 "the Session pane to title the refusal" held_on_screen 'Rogue — launch refused'
on_screen 'agents/producer.md is missing from this fixture' \
  || fail "the Session pane does not carry the launcher's sentence$(evidence)"
off_screen 'cerebro: agents/producer.md' \
  || fail "the Session pane kept the launcher's \`cerebro: ' prefix$(evidence)"
on_screen 'Press s to try again.' || fail "the Session pane does not say how to try again$(evidence)"
pass "the refusal is drawn on Rogue's row, in the launcher's own words"

# --- and it is not started again by itself ------------------------------------------------------------
#
# Four supervision ticks: with refusals not parked, spacing 1 and no backoff after one failure, the
# trigger would have started Rogue again on the first of them.
for ((tick = 0; tick < 20; tick++)); do
  starts_are 1 || fail "the view started a refused row again without s$(evidence)"
  kill -0 "$view_pid" 2>/dev/null || fail "the view exited while holding the refused row$(evidence)"
  sleep 1
done
starts_are 1 || fail "the view started a refused row again without s$(evidence)"
on_screen '✗ refused' || fail "the refusal left the row by itself$(evidence)"
pass "a refused row is not started again over four supervision ticks"

# --- s starts it again ----------------------------------------------------------------------------------

press s
wait_until 20 "s to start Rogue again" starts_are 2
wait_until 20 "the refusal to leave the row once Rogue is up" off_screen '✗ refused'
wait_until 20 "the Session pane to stop showing the refusal" off_screen 'launch refused'
# And the row reads alive - the live marker and the started pass's own phase - not a row the view
# still draws dead or standby.
wait_until 20 "Rogue's row to read alive, in its build phase" grep -Eq '● Rogue +producer +build' "$screen"
pass "s starts the refused row again, Rogue reads alive, and the refusal leaves it"

suite_passed
