#!/usr/bin/env bash
#
# R9, as a navigator meets it: `s' starts an agent in a session the fleet view hosts, `k' kills it,
# `f' tells it to finish and not start again. A SYSTEM suite (.cerebro/test-architecture.md): it
# builds the real `cerebro-tui', runs it on a pseudo-terminal against a throwaway consumer, presses
# the keys, and asserts what the view left behind after each - the agent's process, the view's
# session publication, the armed set it publishes, its decisions log and the stop flag. The rules
# under the keys (`lifecycle::start_outcome', `kill_outcome', `finish_outcome', `end_decision') are
# unit-tested in fleet-view/src; this proves the path through them, which is where cb-op0 broke: a
# start that did not arm and a `k' that did not disarm, so a killed row came back by itself.
#
# The fixture:
#   - one roster row, `Forge architect standby': the single row is selected on load, and an
#     architect is handed no bead, so `s' launches without a board.
#   - a stub `claude' that does what every agent does first - writes `working' through the real
#     `scripts/agent-state' - records its pid and argv, and runs the real `scripts/end-pass' when
#     the suite drops a `<Name>.end' file beside them.
#   - `bd' and `gh' stubs that refuse: the work pane fails apart from the fleet, and nothing here
#     reads the board.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md). The four roots are
# exported as `scripts/cerebro-tui' exports them; tests/cerebro-tui.sh proves that launcher.
#
# Every wait is a bounded poll that fails with the screen and the view's stderr. The one deliberate
# sleep is the window in which a name that should stay gone must not come back.
#
#     bash tests/fleet-keys.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-keys needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------
#
# Debug, not release: the gate's own `cargo test' builds into the same target directory, so a
# second build here is incremental. The path comes from cargo's own artifact line, the way
# scripts/cerebro-tui finds it, rather than from a guess at the target directory.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer -----------------------------------------------------------------------------------

consumer="$(consumer_new keys --copy)"
state="$consumer/.cerebro/state"
stub_state="$consumer/.cerebro/stub"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

stubs="$work_dir/stubs"
mkdir -p "$stubs" "$stub_state"
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
# A session: report in as an agent does, then wait to be told to end the pass, or to be killed.
set -u
scripts="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/cerebro/scripts"
dir="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/stub"
printf '%s\n' "$@" > "$dir/$BEADS_ACTOR.args"
"$scripts/agent-state" "$BEADS_ACTOR" working --pid $$
echo $$ > "$dir/$BEADS_ACTOR.pid"
echo "stub session for $BEADS_ACTOR"
while :; do
  if [ -e "$dir/$BEADS_ACTOR.end" ]; then
    rm -f "$dir/$BEADS_ACTOR.end"
    "$scripts/end-pass" "$BEADS_ACTOR" --pid $$
  fi
  sleep 0.2
done
STUB
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' bd > "$stubs/bd"
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' gh > "$stubs/gh"
chmod +x "$stubs/claude" "$stubs/bd" "$stubs/gh"

# --- the view, on a pty -------------------------------------------------------------------------------

keys="$work_dir/keys.fifo"
screen="$work_dir/screen.txt"
view_err="$work_dir/view.err"
mkfifo "$keys"

hints="$("$consumer/.cerebro/cerebro/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

(
  cd "$consumer"
  export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
         CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$consumer/.cerebro/cerebro/scripts" \
         PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 50 200 -- "$binary"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!

suite_cleanup() {
  kill "$view_pid" 2>/dev/null || true
  # Whatever the view started and did not get to end: every stub's argv names $work_dir.
  pkill -f "$work_dir" 2>/dev/null || true
  wait "$view_pid" 2>/dev/null || true
}

# Held open for the whole suite, read-write so the open never blocks on a reader that failed to
# start: a key is one printf into it.
exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

# What a failed wait says: the screen as the view last drew it, and anything it printed.
evidence() {
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- decisions.jsonl ---\n'
  cat "$state/decisions.jsonl" 2>/dev/null || echo "(none)"
}

# wait_until <what> <command...>: poll for up to 20 s.
wait_until() {
  local what="$1" i
  shift
  for ((i = 0; i < 100; i++)); do
    if "$@"; then return 0; fi
    kill -0 "$view_pid" 2>/dev/null || fail "the view exited while waiting for: $what$(evidence)"
    sleep 0.2
  done
  fail "timed out waiting for: $what$(evidence)"
}

on_screen() { grep -Eq "$1" "$screen" 2>/dev/null; }
armed() { jq -e --arg n "$1" '.names | index($n)' "$state/standby.json" >/dev/null 2>&1; }
disarmed() { jq -e --arg n "$1" '.names | index($n) | not' "$state/standby.json" >/dev/null 2>&1; }
decided() { jq -se "map(select($1)) | length > 0" "$state/decisions.jsonl" >/dev/null 2>&1; }
alive() { kill -0 "$1" 2>/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
stub_pid() { cat "$stub_state/Forge.pid" 2>/dev/null; }
started() { [ -s "$stub_state/Forge.pid" ]; }
published() { [ -e "$state/sessions/Forge.json" ]; }
unpublished() { [ ! -e "$state/sessions/Forge.json" ]; }

# The view publishes its armed set only while it supervises, so this is also the wait for the lease.
wait_until "the view to supervise and publish its armed set" test -s "$state/standby.json"
wait_until "Forge's row" on_screen 'Forge +architect +standby'
pass "the view supervises the fixture and draws Forge's row"

# --- s: start, hosted, armed -------------------------------------------------------------------------

press s
wait_until "the stub agent to start" started
first="$(stub_pid)"
alive "$first" || fail "s: the stub agent is not running"
grep -qx 'architect' "$stub_state/Forge.args" \
  || fail "s: the session was not started as the architect agent: $(cat "$stub_state/Forge.args")"
wait_until "the session publication" published
wait_until "the start line" decided '.event == "start" and .agent == "Forge" and .by == "navigator"'
armed Forge || fail "s: Forge is not in the armed set$(evidence)"
pass "s starts Forge in a hosted session, logs the start and arms the name"

suite_passed
