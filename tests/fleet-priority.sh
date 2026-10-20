#!/usr/bin/env bash
#
# R17, as a navigator meets it: on the Work pane, 0-4 set the selected bead's priority, `+' makes
# it more urgent (the NUMBER goes down), `-' less, and `u' puts back the last change. A SYSTEM suite
# (.cerebro/test-architecture.md): it builds the real `cerebro-tui', runs it on a pseudo-terminal
# against a throwaway consumer whose `bd' logs every call and keeps a board file, presses each key
# and reads the exact `bd' command it caused, the header sentence and the redrawn row. The pieces
# under the keys (`main::route_key', `lifecycle::priority_action', `lifecycle::set_priority', the
# write worker, `App::begin_write'/`finish_write') are unit-tested in fleet-view/src; this proves
# the path through them, where a wrong mapping would re-rank a real bead with no confirmation.
#
# The fixture:
#   - one roster row, `Forge architect standby': no planning role, so the work read runs no
#     `stage-candidates'; standby, so nothing is started. A `claude' stub that refuses, in case.
#   - a board of one bead, `cb-rank', open, `ux:agreed', at P2: the Work cursor is seated on it by
#     the first read, and it is the only row a cursor can stand on.
#   - a `bd' stub that logs every call, answers `list' from the board file and `ready' with an empty
#     list, applies `update <id> --priority <n>' to the board file, and answers `dolt push' with 0.
#     The row shows the asked-for priority from the keystroke on (`App::begin_write''s overlay), so
#     each step waits for a board read the view made AFTER the write's push before it reads the row:
#     that proves the write is followed by a refresh, and that the row drawn once the board answers
#     still says P<n>. It cannot tell the overlay from the board, which agree by then.
#     Anything else is refused, as in tests/fleet-board.sh: the Sweeps reads are not R17's.
#   - a `gh' stub that refuses.
#
# Only the writes are compared - the `update' and `dolt' lines of the log - and each step compares
# exactly the lines it added, so a stray write from an earlier step fails the next one. A step that
# must write nothing (`2' on a P2 bead, a second `u') is followed by a step that does write, whose
# lines would then be wrong; and the total is checked once the view has exited.
#
# The view is never waited on for the lease (docs/retrospectives/cb-eguq.md): the priority keys are
# outside it. The binary is built with `cargo build' and run by this suite itself - never as
# cargo's child (.cerebro/traps.md). Every wait is a bounded poll that fails with the screen, the
# view's stderr and the bd log.
#
#     bash tests/fleet-priority.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-priority needs $tool on PATH"
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

# --- the consumer and its board ---------------------------------------------------------------------

consumer="$(consumer_new priority --copy)"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

board="$work_dir/board.json"
bd_log="$work_dir/bd.log"
: > "$bd_log"
cat > "$board" <<'JSON'
[
  {"id":"cb-rank","title":"Bead the navigator re-ranks","status":"open","issue_type":"task",
   "priority":2,"labels":["ux:agreed"],"updated_at":"2026-10-20T00:00:00Z"}
]
JSON

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cat > "$stubs/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bd_log"
case "\$1" in
  update)
    if [ "\$#" -eq 4 ] && [ "\$3" = --priority ]; then
      jq --arg id "\$2" --argjson to "\$4" 'map(if .id == \$id then .priority = \$to else . end)' \
        "$board" > "$board.tmp" || exit 1
      mv "$board.tmp" "$board"
      exit 0
    fi ;;
  dolt)
    [ "\$*" = "dolt push" ] && exit 0 ;;
esac
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

# The board writes the view has made, in order: the `update' and `dolt' lines of the bd log.
writes() { grep -E '^(update|dolt) ' "$bd_log" 2>/dev/null || true; }
write_count() { writes | wc -l | tr -d ' '; }
writes_at_least() { [ "$(write_count)" -ge "$1" ]; }
# board_read_after <line>: the view's own board read (`list --status ...') is logged below LINE.
board_read_after() { awk -v after="$1" 'NR > after && / list --status / { found = 1 } END { exit !found }' "$bd_log"; }

# key <key> <to> <sentence>: press KEY, and expect exactly one write of `--priority TO' and its
# push - nothing before them, nothing else - then SENTENCE in the header and the row at P<TO>.
key() {
  local pressed="$1" to="$2" sentence="$3" before added expected pushed_at
  before="$(write_count)"
  press "$pressed"
  wait_until 30 "'$pressed' to write P$to" writes_at_least $((before + 2))
  added="$(writes | tail -n +$((before + 1)))"
  pushed_at="$(grep -n '^dolt push$' "$bd_log" | tail -1 | cut -d: -f1)"
  expected="$(printf 'update cb-rank --priority %s\ndolt push' "$to")"
  [ "$added" = "$expected" ] ||
    fail "'$pressed': the board writes were
$added
not
$expected$(evidence)"
  # Followed by the header's ` | ', so the dim provisional line (`…') does not count: this is the
  # sentence the write's own answer set.
  wait_until 30 "'$pressed': the header to say '$sentence'" on_screen "$sentence \\|"
  wait_until 60 "'$pressed': a board read after the write's push" board_read_after "$pushed_at"
  wait_until 30 "'$pressed': the row to read P$to" on_screen "cb-rank +P$to "
}

# no_write <key> <sentence>: press KEY and expect SENTENCE in the header. That no write followed is
# proven by the next `key' step, whose added lines would then not be exactly its own.
no_write() {
  press "$1"
  wait_until 30 "'$1': the header to say '$2'" on_screen "$2 \\|"
}

# --- Work focus, the cursor on the bead -------------------------------------------------------------

wait_until 30 "the work pane to draw the bead" on_screen 'cb-rank +P2 '
press $'\eOQ'   # F2: focus the Work pane
wait_until 30 "Work focus with the cursor on a bead" on_screen '0-4/\+/-/u priority'
pass "F2 focuses the Work pane with the cursor on cb-rank, at P2"

# --- each digit sets exactly its own priority ---------------------------------------------------------

key 0 0 'cb-rank: P2 → P0'
key 1 1 'cb-rank: P0 → P1'
key 3 3 'cb-rank: P1 → P3'
key 4 4 'cb-rank: P3 → P4'
key 2 2 'cb-rank: P4 → P2'
pass "0-4 each write bd update cb-rank --priority <digit>, then bd dolt push"

no_write 2 'cb-rank is already P2'

# --- + is more urgent, - less ---------------------------------------------------------------------

key + 1 'cb-rank: P2 → P1'
pass "'2' on a P2 bead writes nothing; + writes the next more urgent priority, P1"
key - 2 'cb-rank: P1 → P2'
pass "- writes the next less urgent priority, P2"

# --- u puts back the last change, once ------------------------------------------------------------

key u 1 'cb-rank: back to P1'
pass "u writes the priority before the last change, P1"
no_write u 'nothing to undo'
key 0 0 'cb-rank: P1 → P0'
pass "a second u writes nothing and says there is nothing to undo"

# --- the view leaves cleanly, having written nothing else ------------------------------------------------

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
[ "$(write_count)" -eq 18 ] || fail "the view made $(write_count) board write lines, not 18$(evidence)"
pass "q closes the view, status 0, after exactly the nine writes and nine pushes the keys asked for"

suite_passed
