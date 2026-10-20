#!/usr/bin/env bash
#
# R8, as a navigator meets it: when bd or the fleet cannot be read, the last snapshot stays on
# screen marked stale, and the other pane is unaffected. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# against a throwaway consumer, takes each reader down in turn and reads the screen. The rules
# under it (`PaneContent::Stale', `App::finish_refresh', `App::finish_work_refresh', the stale
# titles in `ui.rs') are unit-tested in fleet-view/src; this proves the path through them.
#
# The fixture:
#   - one roster row, `Forge architect standby': no planning role, so the work read runs no
#     `stage-candidates'; standby, so nothing is started. A `claude' stub that refuses, in case.
#   - a `bd' stub that answers `list' with a board file and `ready' with an empty list, and refuses
#     every call while `$work_dir/bd-down' exists: that is how the board becomes unreadable.
#   - the fleet becomes unreadable through the real `scripts/roster': a malformed row in
#     `.cerebro/roster.conf' is refused with exit 2, so the view's fleet read fails. The work read
#     does not call the roster, so the two outages are independent of each other.
#   - a `gh' stub that refuses: the GitHub reads are not part of R8.
#
# `g' refreshes both panes at once, so the suite never waits out the 30-second work cadence. The
# view reads whether or not it supervises, so this suite never waits on the lease (two suites'
# leases can collide, docs/retrospectives/cb-eguq.md). The binary is built with `cargo build' and
# run by this suite itself - never as cargo's child (.cerebro/traps.md).
#
#     bash tests/fleet-stale.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-stale needs $tool on PATH"
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

# --- the consumer, its roster and its board -----------------------------------------------------------

consumer="$(consumer_new stale --copy)"
roster="$consumer/.cerebro/roster.conf"
write_roster() { cat > "$roster.tmp"; mv "$roster.tmp" "$roster"; }
printf 'Forge  architect  standby\n' | write_roster

board="$work_dir/board.json"
bd_down="$work_dir/bd-down"
bd_log="$work_dir/bd.log"
: > "$bd_log"

write_board() { cat > "$board.tmp"; mv "$board.tmp" "$board"; }
held='{"id":"cb-held","title":"Bead on the last good board","status":"open","issue_type":"task",
       "priority":4,"labels":[],"updated_at":"2026-10-20T00:00:00Z"}'
added='{"id":"cb-added","title":"Bead filed while the fleet was down","status":"open","issue_type":"task",
        "priority":4,"labels":[],"updated_at":"2026-10-20T00:05:00Z"}'
printf '[%s]\n' "$held" | write_board

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cat > "$stubs/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bd_log"
if [ -e "$bd_down" ]; then
  echo "stub bd: the board cannot be read" >&2
  exit 1
fi
for arg in "\$@"; do
  case "\$arg" in
    list) cat "$board"; exit 0 ;;
    ready) echo '[]'; exit 0 ;;
  esac
done
echo "stub bd: not part of this suite: \$*" >&2
exit 1
STUB
printf '#!/bin/sh\necho "stub gh: not part of this suite" >&2\nexit 1\n' > "$stubs/gh"
printf '#!/bin/sh\necho "stub claude: nothing is started in this suite" >&2\nexit 1\n' > "$stubs/claude"
chmod +x "$stubs/bd" "$stubs/gh" "$stubs/claude"

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
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 60 200 -- "$binary"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!

suite_cleanup() {
  kill "$view_pid" 2>/dev/null || true
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
  printf -- '--- roster.conf ---\n'
  cat "$roster" 2>/dev/null || true
  printf -- '--- bd calls (last 20) ---\n'
  tail -20 "$bd_log" 2>/dev/null || true
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

on_screen() { grep -Eq -- "$1" "$screen" 2>/dev/null; }
off_screen() { ! grep -Eq -- "$1" "$screen" 2>/dev/null; }
expect_on() { on_screen "$1" || fail "$2$(evidence)"; }
expect_off() { off_screen "$1" || fail "$2$(evidence)"; }

# A pane's title, as `ui::pane_title' spells it: `<Pane> — stale since HH:MM:SS' over a retained
# snapshot, `<Pane> unavailable' over none.
fleet_failed='Fleet — stale since|Fleet unavailable'
work_failed='Work — stale since|Work unavailable'

# --- both panes healthy ---------------------------------------------------------------------------------

wait_until 30 "the work pane to draw the board" on_screen 'cb-held'
wait_until 10 "the fleet pane to draw Forge" on_screen 'Forge'
expect_off "$fleet_failed|$work_failed" "a pane reads failed before anything was taken down"
# The fixture's path is on screen only as the head of a failure, which the fleet half relies on.
! grep -Fq -- "${consumer:0:40}" "$screen" 2>/dev/null ||
  fail "the fixture's path is on screen before any read failed$(evidence)"
pass "both panes draw: Forge in Fleet, cb-held in Work"

# --- bd cannot be read: Work keeps its board, marked stale; Fleet goes on ------------------------------------

touch "$bd_down"
# A row added while the board is down: Fleet showing it proves its reads still run and land.
printf 'Forge  architect  standby\nSage   qa         standby\n' | write_roster
press g
wait_until 20 "Work to read stale" on_screen 'Work — stale since'
expect_on 'cb-held' "the stale work pane dropped the last good board"
# The pane is narrower than the error, so the visible head of it is what a person reads.
expect_on 'bd exited with status .*: stub bd: the board' "the stale work pane does not say what failed"
wait_until 20 "Fleet to draw the row added while bd was down" on_screen 'Sage'
expect_off "$fleet_failed" "bd being unreadable marked the fleet pane failed"
pass "bd unreadable: Work keeps cb-held marked stale with the error, Fleet still refreshes"

rm -f "$bd_down"
press g
wait_until 20 "Work to recover once bd answers" off_screen "$work_failed"
expect_on 'cb-held' "the recovered work pane lost the board"
pass "bd back: the stale mark clears"

# --- the fleet cannot be read: Fleet keeps its rows, marked stale; Work goes on --------------------------------

printf 'Forge  architect  sometimes\nSage   qa         standby\n' | write_roster
# A bead filed while the fleet is down: Work showing it proves its reads still run and land.
printf '[%s,%s]\n' "$held" "$added" | write_board
press g
wait_until 20 "Fleet to read stale" on_screen 'Fleet — stale since'
expect_on 'Forge' "the stale fleet pane dropped Forge from the last good snapshot"
expect_on 'Sage' "the stale fleet pane dropped Sage from the last good snapshot"
# The failure line opens with the roster's full path, wider than the pane, so its first 40
# characters are what a person reads of it; the trailer under the retained rows says they are the
# last good snapshot.
roster_head="${consumer:0:40}"
grep -Fq -- "$roster_head" "$screen" 2>/dev/null ||
  fail "the stale fleet pane does not show the roster's failure ($roster_head...)$(evidence)"
expect_on 'The last successful fleet snapshot remains visible' "the stale fleet pane does not say its rows are the last good snapshot"
wait_until 20 "Work to draw the bead filed while the fleet was down" on_screen 'cb-added'
expect_off "$work_failed" "the fleet being unreadable marked the work pane failed"
pass "fleet unreadable: Fleet keeps Forge and Sage marked stale with the error, Work still refreshes"

printf 'Forge  architect  standby\nSage   qa         standby\n' | write_roster
press g
wait_until 20 "Fleet to recover once the roster reads" off_screen "$fleet_failed"
pass "fleet back: the stale mark clears"

# --- the view leaves cleanly ----------------------------------------------------------------------------

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
