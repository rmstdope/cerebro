#!/usr/bin/env bash
#
# R6, as a navigator meets it: a row shows an agent alive only while its session's process runs
# and still names that agent. A SYSTEM suite (.cerebro/test-architecture.md): it builds the real
# `cerebro-tui', runs it on a pseudo-terminal against a throwaway consumer, writes three state files
# through the real `agent-state', each naming the pid of a process this suite started, and reads
# each agent's row the way a person reads it. Then it ends one of those processes and, pressing
# nothing, waits for that row to say so. The rule under it (`model::session_liveness',
# `model::derive_fleet', and its bash twin `scripts/agent-alive', over tests/lib/session-args.cases)
# is unit-tested; this proves the path through the process scan, the state read and the render.
#
# The fixture:
#   - three roster rows, `Rogue', `Beast' and `Storm', with no `autostart' or `standby' word, so
#     nothing is started whether or not this view takes the supervision lease. A `claude' stub that
#     refuses, in case.
#   - three pretend sessions, each a sleeper whose argv carries one argument, the way
#     `scripts/launch' opens a session's prompt with the marker sentence:
#       Rogue's carries Rogue's marker at this consumer's root    -> alive, its phase and bead shown
#       Beast's carries no marker at all: a recycled pid           -> dead, no bead
#       Storm's carries the marker of Gambit, another agent        -> dead, no bead
#     The sentence is `scripts/session-marker.sh''s, never typed here (scripts/marker-readers).
#   - a `bd' stub that answers `list' and `ready' with an empty board, so a bead id on screen can
#     only be a fleet row's; everything else it refuses. A `gh' stub that refuses.
#
# The fleet pane refreshes on its own every `FLEET_REFRESH_INTERVAL' (5 s); the suite waits for it
# with bounded polls that fail with the screen and the view's stderr. It never waits on the lease.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md).
#
#     bash tests/fleet-alive.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-alive needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------
#
# Debug, as tests/fleet-keys.sh and tests/fleet-board.sh build it, so they share one build.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer ---------------------------------------------------------------------------------

consumer="$(consumer_new alive --copy)"
scripts="$consumer/.cerebro/cerebro/scripts"
cat > "$consumer/.cerebro/roster.conf" <<'ROSTER'
Rogue  producer
Beast  producer
Storm  producer
ROSTER

hints="$("$scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    list|ready) echo '[]'; exit 0 ;;
  esac
done
echo "stub bd: not part of this suite: $*" >&2
exit 1
STUB
printf '#!/bin/sh\necho "stub gh: not part of this suite" >&2\nexit 1\n' > "$stubs/gh"
printf '#!/bin/sh\necho "stub claude: nothing is started in this suite" >&2\nexit 1\n' > "$stubs/claude"
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"

# --- the pretend sessions -------------------------------------------------------------------------
#
# A session, to the view, is a process whose argv carries the marker. A sleeper with one argument
# is that, and nothing else; its pid is what the state file names.
source "$scripts/session-marker.sh"

sleepers=()
suite_cleanup() {
  kill "${view_pid:-}" "${sleepers[@]}" 2>/dev/null || true
  pkill -f "$work_dir" 2>/dev/null || true
  wait 2>/dev/null || true
}

# start_session <argument>: start a sleeper carrying ARGUMENT, and set `started' to its pid.
start_session() {
  bash -c 'while :; do sleep 1; done' "$1" </dev/null >/dev/null 2>&1 &
  started=$!
  sleepers+=("$started")
}

start_session "$(cerebro_marker_sentence Rogue "$shared")"
rogue_pid="$started"
start_session "a recycled pid, somebody else's process in $work_dir"
beast_pid="$started"
start_session "$(cerebro_marker_sentence Gambit "$shared")"
storm_pid="$started"

# Each agent's state file, through the one writer, naming its sleeper.
write_state() {
  ( cd "$consumer" && "$scripts/agent-state" "$1" working --bead "$2" --phase build --pid "$3" ) \
    || fail "agent-state refused to write $1's state file"
}
write_state Rogue cb-r6rogue "$rogue_pid"
write_state Beast cb-r6beast "$beast_pid"
write_state Storm cb-r6storm "$storm_pid"

# --- the view, on a pty ---------------------------------------------------------------------------

keys="$work_dir/keys.fifo"
screen="$work_dir/screen.txt"
view_err="$work_dir/view.err"
mkfifo "$keys"

(
  cd "$consumer"
  export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 60 200 -- "$binary"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!

exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

evidence() {
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- sleepers ---\n'
  ps -o pid=,args= -p "$rogue_pid,$beast_pid,$storm_pid" 2>/dev/null || true
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

# row_of <Name>: the fleet pane's line for NAME - its name followed by its role, `● Rogue producer
# build  cb-…'. The name alone is not enough: it also titles the detail pane (`┌Rogue──') and
# heads its History line (`Rogue working 0m').
row_of() { grep -E -m1 "(^|[^[:alnum:]])$1 +producer( |$)" "$screen" 2>/dev/null || true; }
# row_says <Name> <word>: NAME's row carries WORD as a word of its own.
row_says() {
  local row
  row="$(row_of "$1")"
  grep -Eq "(^|[[:space:]])$2([[:space:]]|$)" <<<"$row"
}
on_screen() { grep -Fq -- "$1" "$screen" 2>/dev/null; }
off_screen() { ! on_screen "$1"; }

# --- alive while the process runs and names the agent ---------------------------------------------

wait_until 30 "Rogue's row to show its live session" row_says Rogue build
on_screen cb-r6rogue || fail "Rogue is shown alive but its bead is not drawn$(evidence)"
row_says Rogue dead && fail "Rogue's row reads dead with its session running$(evidence)"
pass "a state file whose pid runs and carries the agent's marker draws the row alive, with its phase and bead"

# --- a running pid that does not name the agent is not alive ----------------------------------------

kill -0 "$beast_pid" 2>/dev/null || fail "Beast's sleeper is not running; the case proves nothing"
kill -0 "$storm_pid" 2>/dev/null || fail "Storm's sleeper is not running; the case proves nothing"
wait_until 10 "Beast's row to read dead" row_says Beast dead
wait_until 10 "Storm's row to read dead" row_says Storm dead
off_screen cb-r6beast || fail "Beast's bead is drawn though its pid is not its session$(evidence)"
off_screen cb-r6storm || fail "Storm's bead is drawn though its pid is another agent's session$(evidence)"
pass "a state file naming a live pid that carries no marker, or another agent's, draws the row dead"

# --- the process ends, and the row follows without a key ---------------------------------------------

kill "$rogue_pid"
wait "$rogue_pid" 2>/dev/null || true
# One fleet cadence is 5 s; 30 allows for a slow read on a busy runner.
wait_until 30 "Rogue's row to read dead once its process ended" row_says Rogue dead
off_screen cb-r6rogue || fail "Rogue's bead is still drawn after its session ended$(evidence)"
pass "with no key pressed, a row whose session process ends reads dead and drops its bead"

# --- the view leaves cleanly ----------------------------------------------------------------------

press q
for ((i = 0; i < 100; i++)); do
  kill -0 "$view_pid" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$view_pid" 2>/dev/null && fail "q: the view did not exit$(evidence)"
set +e
wait "$view_pid"
view_status=$?
set -e
[ "$view_status" -eq 0 ] || fail "q: the view exited $view_status$(evidence)"
pass "q closes the view, status 0"

suite_passed
