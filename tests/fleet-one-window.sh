#!/usr/bin/env bash
#
# R11, as a navigator meets it: only the first window on a checkout operates the fleet; a second
# draws and acts on nothing, and takes over when the first closes. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs TWO of it on two
# pseudo-terminals against one throwaway consumer, and asserts what each window shows and what the
# fleet was left with. The rules underneath - the lease (`supervisor::SupervisorLease',
# `reconcile_supervision'), the refusal (`lifecycle::refusal_for') and the header (`ui.rs') - are
# unit-tested in fleet-view/src; this proves the path through them.
#
# Who holds the lease is read from `.cerebro/state/supervisor.json', whose `pid' is written only by
# a window that bound the lease. It is diagnosis, never the lock (the bind is), which is why it is
# a fair witness here: a second window that wrote it would have taken the lease.
#
# The fixture is tests/fleet-keys.sh's: one roster row, `Forge architect standby' (selected on load,
# handed no bead, and not started by its own trigger within this suite, which an architect's hourly
# wake floor holds); a stub `claude' that reports `working' through the real `scripts/agent-state' and records
# its pid; `bd' and `gh' stubs that refuse.
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child
# (.cerebro/traps.md). Every wait is a bounded poll that fails with both screens; there is no sleep.
# The takeover waits on the view's own five-second reconcile (`SUPERVISION_INTERVAL'), with no key
# pressed, because that is how a person meets it.
#
#     bash tests/fleet-one-window.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq pgrep; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-one-window needs $tool on PATH"
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

consumer="$(consumer_new onewindow --copy)"
state="$consumer/.cerebro/state"
stub_state="$consumer/.cerebro/stub"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

stubs="$work_dir/stubs"
mkdir -p "$stubs" "$stub_state"
cat > "$stubs/claude" <<'STUB'
#!/usr/bin/env bash
# A session: report in as an agent does, then wait to be killed.
set -u
scripts="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/cerebro/scripts"
dir="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/stub"
"$scripts/agent-state" "$BEADS_ACTOR" working --pid $$
echo $$ > "$dir/$BEADS_ACTOR.pid"
# One line per session ever started, so a start that lands late is still counted.
echo $$ >> "$dir/$BEADS_ACTOR.starts"
echo "stub session for $BEADS_ACTOR"
while :; do sleep 0.2; done
STUB
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' bd > "$stubs/bd"
printf '#!/bin/sh\necho "stub %s: the board is not part of this suite" >&2\nexit 1\n' gh > "$stubs/gh"
chmod +x "$stubs/claude" "$stubs/bd" "$stubs/gh"

hints="$("$consumer/.cerebro/cerebro/scripts/consumer-root" --hints)"
{ IFS= read -r root; IFS= read -r shared; IFS= read -r mount; } <<<"$hints"
[ -n "$shared" ] || fail "consumer-root --hints gave no shared root for the fixture"

# --- the two windows, each on its own pty -------------------------------------------------------------
#
# open_window <A|B>: start one view on the checkout. Its pty-drive pid lands in `driver_<w>', its
# keys go through fd 7 (A) or 8 (B), its screen is $work_dir/<w>.screen.
driver_A="" driver_B="" must_live=""
open_window() {
  local w="$1"
  mkfifo "$work_dir/$w.keys"
  (
    cd "$consumer"
    export CEREBRO_CONSUMER_ROOT="$root" CEREBRO_CONSUMER_SHARED_ROOT="$shared" \
           CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$consumer/.cerebro/cerebro/scripts" \
           PATH="$stubs:$PATH" TERM=xterm-256color
    exec python3 -I "$repo_root/tests/lib/pty-drive" "$work_dir/$w.keys" "$work_dir/$w.screen" \
      50 200 -- "$binary"
  ) </dev/null >/dev/null 2>"$work_dir/$w.err" &
  printf -v "driver_$w" '%s' "$!"
  # Held open read-write for the whole suite, so the open never blocks: a key is one printf.
  if [ "$w" = A ]; then exec 7<>"$work_dir/A.keys"; else exec 8<>"$work_dir/B.keys"; fi
}

suite_cleanup() {
  kill "$driver_A" "$driver_B" 2>/dev/null || true
  # Whatever a view started and did not get to end: every stub's path names $work_dir.
  pkill -f "$work_dir" 2>/dev/null || true
  wait 2>/dev/null || true
}

press() { if [ "$1" = A ]; then printf '%s' "$2" >&7; else printf '%s' "$2" >&8; fi; }

evidence() {
  local w
  for w in A B; do
    printf '\n--- window %s screen ---\n' "$w"
    cat "$work_dir/$w.screen" 2>/dev/null || echo "(no screen yet)"
    printf -- '--- window %s stderr ---\n' "$w"
    cat "$work_dir/$w.err" 2>/dev/null || true
  done
  printf -- '--- supervisor.json ---\n'
  cat "$state/supervisor.json" 2>/dev/null || echo "(none)"
  printf -- '--- decisions.jsonl ---\n'
  cat "$state/decisions.jsonl" 2>/dev/null || echo "(none)"
}

# wait_until <what> <command...>: poll for up to 60 s - a ceiling, not a cost: under the whole gate
# in parallel a start through the real `scripts/launch' has taken more than 20 s. A window named
# in $must_live that exits fails the wait at once; window A leaves that list before it is closed.
wait_until() {
  local what="$1" i w d
  shift
  for ((i = 0; i < 300; i++)); do
    if "$@"; then return 0; fi
    for w in $must_live; do
      d="driver_$w"
      kill -0 "${!d}" 2>/dev/null || fail "window $w exited while waiting for: $what$(evidence)"
    done
    sleep 0.2
  done
  fail "timed out waiting for: $what$(evidence)"
}

on_screen() { grep -Eq "$2" "$work_dir/$1.screen" 2>/dev/null; }
# The cerebro-tui pty-drive forked for a window: the one child of its driver.
tui_pid() { local p; p="$(pgrep -P "$1" 2>/dev/null)" || return 0; printf '%s' "${p%%$'\n'*}"; }
holder_is() { [ -n "$1" ] && jq -e --argjson p "$1" '.pid == $p' "$state/supervisor.json" >/dev/null 2>&1; }
decided() { jq -se "map(select($1)) | length > 0" "$state/decisions.jsonl" >/dev/null 2>&1; }
started() { [ -s "$stub_state/Forge.pid" ]; }
published() { [ -e "$state/sessions/Forge.json" ]; }
gone() { ! kill -0 "$1" 2>/dev/null; }

supervising='Cerebro — supervising'
read_only='Cerebro — read-only; another window is driving this fleet'
refusal='This view is read-only; it starts and stops nothing'

# --- the first window operates the fleet ----------------------------------------------------------------

open_window A
must_live="A"
wait_until "window A to supervise" on_screen A "$supervising"
has_tui() { [ -n "$(tui_pid "$1")" ]; }
wait_until "window A's tui process" has_tui "$driver_A"
tui_A="$(tui_pid "$driver_A")"
wait_until "the lease record to name window A" holder_is "$tui_A"
wait_until "Forge's row in window A" on_screen A 'Forge +architect +standby'
wait_until "window A to publish its armed set" test -s "$state/standby.json"
pass "the first window on the checkout supervises it and holds the lease"

# --- a second window draws, and acts on nothing ---------------------------------------------------------

open_window B
must_live="A B"
wait_until "window B to say it is read-only" on_screen B "$read_only"
wait_until "Forge's row in window B" on_screen B 'Forge +architect +[a-z]+'
wait_until "window B's tui process" has_tui "$driver_B"
tui_B="$(tui_pid "$driver_B")"
on_screen A "$supervising" || fail "window A stopped supervising when window B opened$(evidence)"
pass "a second window draws the fleet and says another window is driving it"

press B s
wait_until "window B's refusal" on_screen B "$refusal"
# A start that got past the refusal would land seconds later, through the real `scripts/launch';
# it is caught by the count of starts before and after the takeover, below. A read-only view's
# logger is off, so a `start' line here would witness window A, which nobody asked to start.
started && fail "s in the read-only window started Forge$(evidence)"
holder_is "$tui_A" || fail "the lease record no longer names window A$(evidence)"
pass "s in the second window is refused on its screen, and nothing is started"

# --- the first window closes; the second takes over --------------------------------------------------

must_live="B"
press A q
wait_until "window A to exit" gone "$driver_A"
set +e
wait "$driver_A"
status_A=$?
set -e
[ "$status_A" -eq 0 ] || fail "q: window A exited $status_A$(evidence)"
wait_until "window B to take over" on_screen B "$supervising"
wait_until "the lease record to name window B" holder_is "$tui_B"
pass "when the first window closes, the second takes over the fleet with no key pressed"

# A start that leaked from step 3's s and has landed by now fails here. One that lands later is
# caught by the count of starts at the end, or, if it made B refuse its own s, by the start line
# below: a read-only window logs nothing, so only B's own start writes it.
[ -e "$stub_state/Forge.starts" ] && fail "s in the read-only window started Forge, late$(evidence)"
press B s
wait_until "the stub agent to start" started
wait_until "the session publication" published
wait_until "the start line" decided '.event == "start" and .agent == "Forge" and .by == "navigator"'
pass "s in the window that took over starts Forge"

forge="$(cat "$stub_state/Forge.pid")"
wait_until "Forge's row to read working" on_screen B 'Forge +architect +working'
press B k
wait_until "the kill question" on_screen B 'Kill Forge\?  y / n'
press B y
wait_until "the stub agent to be killed" gone "$forge"
[ "$(wc -l < "$stub_state/Forge.starts" | tr -d ' ')" -eq 1 ] \
  || fail "Forge was started more than once: $(cat "$stub_state/Forge.starts")$(evidence)"
must_live=""
press B q
wait_until "window B to exit" gone "$driver_B"
set +e
wait "$driver_B"
status_B=$?
set -e
[ "$status_B" -eq 0 ] || fail "q: window B exited $status_B$(evidence)"
pass "the window that took over kills its session and closes, status 0"

suite_passed
