#!/usr/bin/env bash
#
# R7, as a navigator meets it: the board drawn as work queues - Claimed, Ready to produce, Waiting
# on you, Merged unverified, Unplanned - that refresh on their own. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# against a throwaway consumer whose `bd' answers from a board file, reads which queue each bead is
# drawn under, then changes the board and, pressing nothing, waits for the pane to show the change.
# The rules under it (`model::partition_beads', `app::sections_body', `App::on_tick') are
# unit-tested in fleet-view/src; this proves the path through them.
#
# The fixture:
#   - one roster row, `Forge architect standby': no planning role, so the work read runs no
#     `stage-candidates'; standby, so nothing is started. A `claude' stub that refuses, in case.
#   - a `bd' stub that logs every call and answers `list' with the board file and `ready' with an
#     empty list. The view's own `bd list' and the real scripts it runs (`assignable-beads',
#     `bugfix-candidates', `second-look-beads' through `work-beads') all go through it. Anything
#     else is refused: the Sweeps section's reads (`epic status', …) are not R7's, so the pane's
#     first line reads `Sweeps 0  sweep-verdicts failed' and the suite does not mind. A refused
#     read on R7's own path still fails it, because the beads are then never drawn.
#   - a `gh' stub that refuses: the GitHub reads are not part of R7.
#
# The view reads the board whether or not it supervises, so this suite never waits on the lease
# (two suites' leases can collide, docs/retrospectives/cb-eguq.md).
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md).
#
# Every wait is a bounded poll that fails with the screen and the view's stderr. The refresh is the
# view's own 30-second cadence (`WORK_REFRESH_INTERVAL'); there is no key that shortens it, so the
# suite waits one real interval for it.
#
#     bash tests/fleet-board.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-board needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------
#
# Debug, as tests/fleet-keys.sh builds it, so the two share one incremental build.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer and its board ---------------------------------------------------------------------

consumer="$(consumer_new board --copy)"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

board="$work_dir/board.json"
bd_log="$work_dir/bd.log"
: > "$bd_log"

# One bead per queue R7 names, plus Unplanned. `bd list --brief --json' omits keys it has no value
# for, so each bead carries only what the view reads.
write_board() { cat > "$board.tmp"; mv "$board.tmp" "$board"; }
write_board <<'JSON'
[
  {"id":"cb-claimed","title":"Bead somebody is building","status":"in_progress","issue_type":"task",
   "priority":1,"assignee":"Rogue","labels":["ux:agreed","planned"],"updated_at":"2026-10-20T00:00:00Z"},
  {"id":"cb-agreed","title":"Bead ready for a producer","status":"open","issue_type":"task",
   "priority":1,"labels":["ux:agreed"],"updated_at":"2026-10-20T00:00:00Z"},
  {"id":"cb-parked","title":"Bead parked for the navigator","status":"open","issue_type":"task",
   "priority":2,"labels":["human"],"updated_at":"2026-10-20T00:00:00Z",
   "metadata":{"paused_at":"2026-10-20T00:00:00Z"}},
  {"id":"cb-merged","title":"Bead merged and not verified","status":"closed","issue_type":"task",
   "priority":2,"labels":[],"updated_at":"2026-10-20T00:00:00Z"},
  {"id":"cb-fresh","title":"Bead nobody has looked at","status":"open","issue_type":"task",
   "priority":4,"labels":[],"updated_at":"2026-10-20T00:00:00Z"}
]
JSON

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cat > "$stubs/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bd_log"
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
  printf -- '--- bd calls ---\n'
  cat "$bd_log" 2>/dev/null || true
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

on_screen() { grep -Eq "$1" "$screen" 2>/dev/null; }
off_screen() { ! grep -Eq "$1" "$screen" 2>/dev/null; }

# The queue a bead is drawn under: the last `<Title> <count>' header above the line holding its id,
# read the way a person reads the pane. The headers are the eight `app::sections_body' names.
section_of() {
  awk -v id="$1" '
    match($0, /(Claimed|Planned, unclaimed|Being planned|Ready to produce|Unplanned|Waiting on you|Second look|Merged, unverified) [0-9]+/) {
      section = substr($0, RSTART, RLENGTH)
    }
    index($0, id) { print section; exit }
  ' "$screen" 2>/dev/null
}
in_section() { [ "$(section_of "$1")" = "$2" ]; }
list_calls() { grep -c -- ' list ' "$bd_log" 2>/dev/null || true; }

# expect_in <id> <header>: one assertion, failing with the screen.
expect_in() {
  in_section "$1" "$2" || fail "$1 is drawn under '$(section_of "$1")', not '$2'$(evidence)"
}

# --- the board, as queues -----------------------------------------------------------------------------

wait_until 30 "the work pane to draw the board" on_screen 'cb-fresh'
expect_in cb-claimed "Claimed 1"
expect_in cb-agreed "Ready to produce 1"
expect_in cb-parked "Waiting on you 1"
expect_in cb-merged "Merged, unverified 1"
expect_in cb-fresh "Unplanned 1"
pass "the board is drawn as work queues: Claimed, Ready to produce, Waiting on you, Merged unverified, Unplanned"

# --- the board changes, and the queues follow without a key ----------------------------------------------
#
# cb-agreed is claimed, cb-merged is verified, and a new bead is parked for the navigator.
reads_before="$(list_calls)"
write_board <<'JSON'
[
  {"id":"cb-claimed","title":"Bead somebody is building","status":"in_progress","issue_type":"task",
   "priority":1,"assignee":"Rogue","labels":["ux:agreed","planned"],"updated_at":"2026-10-20T00:00:00Z"},
  {"id":"cb-agreed","title":"Bead ready for a producer","status":"in_progress","issue_type":"task",
   "priority":1,"assignee":"Bishop","labels":["ux:agreed","planned"],"updated_at":"2026-10-20T00:05:00Z"},
  {"id":"cb-parked","title":"Bead parked for the navigator","status":"open","issue_type":"task",
   "priority":2,"labels":["human"],"updated_at":"2026-10-20T00:00:00Z",
   "metadata":{"paused_at":"2026-10-20T00:00:00Z"}},
  {"id":"cb-merged","title":"Bead merged and not verified","status":"closed","issue_type":"task",
   "priority":2,"labels":["verification:passed"],"updated_at":"2026-10-20T00:05:00Z"},
  {"id":"cb-fresh","title":"Bead nobody has looked at","status":"open","issue_type":"task",
   "priority":4,"labels":[],"updated_at":"2026-10-20T00:00:00Z"},
  {"id":"cb-newly","title":"Bead parked since the last read","status":"open","issue_type":"task",
   "priority":1,"labels":["human"],"updated_at":"2026-10-20T00:05:00Z",
   "metadata":{"paused_at":"2026-10-20T00:05:00Z"}}
]
JSON

# One cadence is 30 s, counted from the last read's start; 75 s allows for a slow read either side.
wait_until 75 "the pane to show the new board on its own" on_screen 'cb-newly'
wait_until 5 "the claimed bead to move" in_section cb-agreed "Claimed 2"
expect_in cb-claimed "Claimed 2"
expect_in cb-newly "Waiting on you 2"
expect_in cb-parked "Waiting on you 2"
expect_in cb-fresh "Unplanned 1"
off_screen 'cb-merged' || fail "a verified bead is still drawn$(evidence)"
on_screen 'Merged, unverified 0' || fail "Merged, unverified does not read 0$(evidence)"
off_screen 'Ready to produce' || fail "the emptied Ready to produce section is still drawn$(evidence)"
[ "$(list_calls)" -gt "$reads_before" ] || fail "the view showed a new board without reading bd again$(evidence)"
pass "with no key pressed, the queues refresh: claimed, verified and newly parked beads move"

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
