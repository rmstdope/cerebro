#!/usr/bin/env bash
#
# R10, as a navigator meets it: RET on a Fleet row focuses that agent's hosted session, and what
# the navigator then types reaches the agent in it. A SYSTEM suite (.cerebro/test-architecture.md):
# it builds the real `cerebro-tui', runs it on a pseudo-terminal against a throwaway consumer,
# presses the keys, and asserts what the agent received - read by the agent from its own terminal,
# the only place "typed to the agent" can be observed. The rules under the keys (`App::on_key''s
# Enter under Fleet focus, cb-d31; `route_key''s live-session branch; `session::key_bytes') are
# unit-tested in fleet-view/src; this proves the path through them.
#
# The path:
#   - RET on a row with no session refuses with `Forge has no session' (cb-d31's empty pane).
#   - `s' starts Forge; RET focuses its Session pane.
#   - a line typed there, `q' and `k' in it, arrives at the agent whole: neither key was the view's,
#     so the view does not quit and asks no kill question.
#   - F1 gives the keyboard back to the view: `k' then asks, and `y' kills.
#
# The fixture is tests/fleet-keys.sh's: one roster row, `Forge architect standby', selected on load
# and launched without a board; `bd' and `gh' stubs that refuse. The stub `claude' writes `working'
# through the real `scripts/agent-state', records its pid, then appends every line it reads from
# its terminal to `<Name>.typed'.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md). Every wait is a bounded
# poll that fails with the screen and the view's stderr; there is no sleep.
#
#     bash tests/fleet-type.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-type needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------

build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer -----------------------------------------------------------------------------------

# Named `typing', a length no other suite running the view uses (fleet-keys `keys', 4;
# fleet-board `board', 5; fleet-view-restart `restart', 7). The lease port `scripts/fleet-supervisor' derives depends on
# the root's length alone (two cksums XOR-ed cancel to a function of the length; cb-ebqd), and
# every suite's root is one `mktemp -d' plus its name, so two suites whose names have the same
# length meet on one port in a parallel gate and both go read-only.
consumer="$(consumer_new typing --copy)"
state="$consumer/.cerebro/state"
stub_state="$consumer/.cerebro/stub"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

stubs="$work_dir/stubs"
mkdir -p "$stubs" "$stub_state"
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
# A session: report in as an agent does, then keep every line typed to it.
set -u
scripts="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/cerebro/scripts"
dir="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/stub"
"$scripts/agent-state" "$BEADS_ACTOR" working --pid $$
echo $$ > "$dir/$BEADS_ACTOR.pid"
echo "stub session for $BEADS_ACTOR"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$dir/$BEADS_ACTOR.typed"
done
# A terminal that closed: stay until killed, as an agent waiting on its pane would.
while :; do sleep 1; done
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

exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

evidence() {
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- supervision lease ---\n'
  (cd "$consumer" && "$consumer/.cerebro/cerebro/scripts/fleet-supervisor" --endpoint 2>&1) || true
  cat "$state/supervisor.json" 2>/dev/null || echo "(no record)"
  printf -- '--- typed to the agent ---\n'
  cat "$stub_state/Forge.typed" 2>/dev/null || echo "(nothing)"
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
started() { [ -s "$stub_state/Forge.pid" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }
typed() { grep -Fxq -- "$1" "$stub_state/Forge.typed" 2>/dev/null; }

wait_until "the view to supervise and publish its armed set" test -s "$state/standby.json"
wait_until "Forge's row" on_screen 'Forge +architect +standby'
pass "the view supervises the fixture and draws Forge's row"

# --- RET on an empty pane refuses -------------------------------------------------------------------

press $'\r'
wait_until "the no-session notice" on_screen 'Forge has no session'
pass "RET on a row with no session says so and moves nowhere"

# --- s, then RET: the keyboard is the agent's -------------------------------------------------------

press s
wait_until "the stub agent to start" started
agent="$(cat "$stub_state/Forge.pid")"
wait_until "Forge's row to read working" on_screen 'Forge +architect +working'
wait_until "the agent's first line in its pane" on_screen 'stub session for Forge'

press $'\r'
# `q' would quit the view and `k' would ask to kill Forge, were either the view's.
press $'hello q k\r'
wait_until "the typed line to reach the agent" typed 'hello q k'
on_screen 'Kill Forge\?' && fail "a key typed to the agent opened the view's kill question$(evidence)"
kill -0 "$view_pid" 2>/dev/null || fail "a key typed to the agent quit the view$(evidence)"
kill -0 "$agent" 2>/dev/null || fail "the agent died while being typed to$(evidence)"
pass "RET focuses Forge's session, and a line typed there reaches the agent whole"

# --- F1: the keyboard is the view's again ----------------------------------------------------------

press $'\eOP'
press k
wait_until "the kill question" on_screen 'Kill Forge\?  y / n'
press y
wait_until "the stub agent to be killed" gone "$agent"
[ "$(grep -c . "$stub_state/Forge.typed")" -eq 1 ] \
  || fail "F1, k or y reached the agent as well$(evidence)"
pass "F1 gives the keyboard back: k asks the view's question, not the agent"

# --- the view leaves cleanly --------------------------------------------------------------------------

wait_until "Forge's row to read dead" on_screen 'Forge +architect +dead'
press q
for ((i = 0; i < 100; i++)); do
  kill -0 "$view_pid" 2>/dev/null || break
  sleep 0.2
done
kill -0 "$view_pid" 2>/dev/null && fail "q: the view did not exit with nothing hosted$(evidence)"
set +e
wait "$view_pid"
view_status=$?
set -e
[ "$view_status" -eq 0 ] || fail "q: the view exited $view_status$(evidence)"
pass "q with nothing hosted closes the view, status 0"

suite_passed
