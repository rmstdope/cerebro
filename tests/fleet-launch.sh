#!/usr/bin/env bash
#
# R21, as a navigator meets it: a session the fleet view starts goes through `scripts/launch', on the
# CLI, model and effort `.cerebro/agents.conf' names, with the hooks wired so its row reads `asking'
# while a question is open and goes back when it is answered. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# against a throwaway consumer, presses `s', and reads what the session was handed and what its row
# says. The pieces are Script-level (tests/launchers.sh, tests/agent-cli.sh, tests/agent-asking.sh);
# this proves they are joined: an unwired hook does nothing, silently (CLAUDE.md, Gotchas).
#
# The fixture:
#   - one roster row, `Forge architect standby': the single row is selected on load, and an
#     architect is handed no bead, so `s' launches without a board.
#   - `.cerebro/agents.conf' naming a model and an effort for the architect role that no CLI default
#     could produce.
#   - a stub `claude' that does what Claude Code does with what `launch' hands it: records its argv,
#     writes `working' through the real `scripts/agent-state' as every agent does first, and when the
#     suite drops `Forge.ask' runs the PreToolUse command the file named by its own `--settings'
#     declares for the question tool, in the environment it inherited - exactly how a hook runs. On
#     `Forge.answer' it runs the PostToolUse one. So a lost `--settings', a wrong path, or a launcher
#     that does not export what the hooks read all leave the row at `working', and the suite red.
#   - `bd' and `gh' stubs that refuse: nothing here reads the board.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md).
#
# Every wait is a bounded poll that fails with the screen and the view's stderr; there is no sleep.
#
#     bash tests/fleet-launch.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-launch needs $tool on PATH"
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

consumer="$(consumer_new launch --copy)"
state="$consumer/.cerebro/state"
stub_state="$consumer/.cerebro/stub"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"
cat > "$consumer/.cerebro/agents.conf" <<'CONF'
default    tool=claude  model=r21-default-model  effort=high
architect  tool=claude  model=r21-architect-model  effort=low
CONF

stubs="$work_dir/stubs"
mkdir -p "$stubs" "$stub_state"
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
# A session: report in as an agent does, then run the question hooks its settings declare when told.
set -u
scripts="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/cerebro/scripts"
dir="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/stub"
printf '%s\n' "$@" > "$dir/$BEADS_ACTOR.args"
settings=""
prev=""
for arg in "$@"; do
  if [ "$prev" = --settings ]; then settings="$arg"; fi
  prev="$arg"
done
"$scripts/agent-state" "$BEADS_ACTOR" working --phase daily --pid $$
echo $$ > "$dir/$BEADS_ACTOR.pid"
echo "stub session for $BEADS_ACTOR"

# hook <event>: run every command <event> declares for the question tool, as Claude Code does - in a
# shell, with this session's environment. No settings, or none for the event, runs nothing.
hook() {
  [ -n "$settings" ] && [ -f "$settings" ] || return 0
  jq -r --arg e "$1" '.hooks[$e][]? | select(.matcher == "AskUserQuestion") | .hooks[].command' \
    "$settings" 2>/dev/null |
    while IFS= read -r cmd; do
      sh -c "$cmd" </dev/null >/dev/null 2>&1 || true
    done
}

while :; do
  if [ -e "$dir/$BEADS_ACTOR.ask" ]; then
    rm -f "$dir/$BEADS_ACTOR.ask"
    hook PreToolUse
    touch "$dir/$BEADS_ACTOR.asked"
  fi
  if [ -e "$dir/$BEADS_ACTOR.answer" ]; then
    rm -f "$dir/$BEADS_ACTOR.answer"
    hook PostToolUse
    touch "$dir/$BEADS_ACTOR.answered"
  fi
  sleep 0.2
done
STUB
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' bd > "$stubs/bd"
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' gh > "$stubs/gh"
chmod +x "$stubs/claude" "$stubs/bd" "$stubs/gh"

# --- the view, on a pty ---------------------------------------------------------------------------

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
  printf -- '--- session argv ---\n'
  cat "$stub_state/Forge.args" 2>/dev/null || echo "(none)"
  printf -- '--- Forge.state.json ---\n'
  cat "$state/Forge.state.json" 2>/dev/null || echo "(none)"
}

# wait_until <what> <command...>: poll for up to 30 s, which allows a slow first draw on a busy runner.
wait_until() {
  local what="$1" i
  shift
  for ((i = 0; i < 150; i++)); do
    if "$@"; then return 0; fi
    kill -0 "$view_pid" 2>/dev/null || fail "the view exited while waiting for: $what$(evidence)"
    sleep 0.2
  done
  fail "timed out waiting for: $what$(evidence)"
}

on_screen() { grep -Eq "$1" "$screen" 2>/dev/null; }
started() { [ -s "$stub_state/Forge.pid" ]; }
state_is() { [ "$(jq -r '.state // empty' "$state/Forge.state.json" 2>/dev/null)" = "$1" ]; }
# arg_after <flag>: the argv token that follows FLAG in what the session was handed; empty when the
# flag is absent, so the assertion that reads it fails with the evidence rather than errexit.
arg_after() { { grep -A1 -x -- "$1" "$stub_state/Forge.args" || true; } | sed -n 2p; }

wait_until "Forge's row" on_screen 'Forge +architect +standby'

# --- s: the session is started through launch, on agents.conf's model and effort -----------------

press s
wait_until "the stub agent to start" started
[ "$(arg_after --agent)" = architect ] \
  || fail "s: the session was not started as the architect agent$(evidence)"
[ "$(arg_after --model)" = r21-architect-model ] \
  || fail "s: the session is not on the model agents.conf names for the architect$(evidence)"
[ "$(arg_after --effort)" = low ] \
  || fail "s: the session is not at the effort agents.conf names for the architect$(evidence)"
# A working row's State column shows its phase (ui::state_label), so `daily' on the row is `working'.
# Compared physically: launch names it through `scripts/..', and a temporary directory may sit
# behind a symlink.
settings="$(arg_after --settings)"
[ -f "$settings" ] || fail "s: the session was handed no hook settings file (got '$settings')$(evidence)"
[ "$(cd "$(dirname "$settings")" && pwd -P)/$(basename "$settings")" = \
  "$(cd "$consumer/.cerebro/cerebro/hooks" && pwd -P)/session-state.settings.json" ] \
  || fail "s: the session was not handed the consumer's hook settings (got '$settings')$(evidence)"
wait_until "Forge's row to read its phase" on_screen 'Forge +architect +daily'
pass "s starts Forge through launch, on agents.conf's model and effort, with the hook settings"

# --- a question: the row reads asking while it is open, and working once answered ----------------

touch "$stub_state/Forge.ask"
wait_until "the session to open its question" test -e "$stub_state/Forge.asked"
wait_until "Forge's state file to read asking" state_is asking
wait_until "Forge's row to read asking" on_screen 'Forge +architect +asking'
pass "while the session's question is open, its hooks turn Forge's row to asking"

touch "$stub_state/Forge.answer"
wait_until "the session to have its answer" test -e "$stub_state/Forge.answered"
wait_until "Forge's state file to read working again" state_is working
[ "$(jq -r '.phase // empty' "$state/Forge.state.json")" = daily ] \
  || fail "the answered question lost the phase the session was in$(evidence)"
wait_until "Forge's row to read its phase again" on_screen 'Forge +architect +daily'
pass "once the question is answered, the row reads working again, showing the phase it was in"

# --- k, then q: the view leaves cleanly ----------------------------------------------------------

stub_pid="$(cat "$stub_state/Forge.pid")"
press k
wait_until "the kill question" on_screen 'Kill Forge\?  y / n'
press y
wait_until "the stub agent to be killed" eval '! kill -0 "$stub_pid" 2>/dev/null'

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
pass "k ends the session and q closes the view, status 0"

suite_passed
