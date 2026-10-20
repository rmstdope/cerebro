#!/usr/bin/env bash
#
# R18, as a navigator meets it: `x' on a Sweeps finding runs the exact bd command the finding maps
# to, and only after the navigator confirms. A SYSTEM suite (.cerebro/test-architecture.md): it
# builds the real `cerebro-tui', runs it on a pseudo-terminal against a throwaway consumer whose
# `bd' yields one stale epic to the real `scripts/sweep-epics.sh', presses `x' and declines, then
# presses `x' and confirms, and reads what `bd' was asked to do each time. The mapping under it
# (`sweeps::finding_command', held to tests/lib/sweep-findings.json) and the prompt's keys are
# unit-tested in fleet-view/src; this proves the path through them.
#
# The fixture:
#   - one roster row, `Forge architect standby': no planning role and nothing started. A `claude'
#     stub that refuses, in case.
#   - a `bd' stub that logs every call. `epic status' answers one epic, cb-epic, whose two children
#     closed long ago - an epic-close finding - until `close' has run, and then nothing; `children'
#     answers those two children; `list' and `ready' answer an empty board, so the Work cursor's
#     only place is the finding; `close' and `dolt push' succeed. Anything else is refused.
#   - a `gh' stub that refuses.
#   - an origin, because `sweep-verdicts.sh' fetches it and refuses without one, and one sweep that
#     fails fails the whole section.
#
# What ran is read from the stub's log, which is the command itself rather than the view's account
# of it: the decisions log's `sweep' line is written only by a supervising view, and this suite
# never waits on the lease (two suites' leases can collide, docs/retrospectives/cb-eguq.md).
#
# The binary is built with `cargo build' and run by this suite itself - never as cargo's child,
# which would hand every session cargo's environment (.cerebro/traps.md).
#
# Every wait is a bounded poll that fails with the screen, the view's stderr and the bd calls.
#
#     bash tests/fleet-sweep-x.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-sweep-x needs $tool on PATH"
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

consumer="$(consumer_new sweepx --origin --copy)"
printf 'Forge  architect  standby\n' > "$consumer/.cerebro/roster.conf"

bd_log="$work_dir/bd.log"
closed="$work_dir/epic-closed"
: > "$bd_log"

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cat > "$stubs/bd" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bd_log"
for arg in "\$@"; do
  case "\$arg" in
    epic)
      if [ -e "$closed" ]; then echo '[]'; else
        echo '[{"epic":{"id":"cb-epic","title":"An epic whose children are done"}}]'
      fi
      exit 0 ;;
    children)
      echo '[{"id":"cb-epic.1","status":"closed","closed_at":"2026-01-01T00:00:00Z"},
             {"id":"cb-epic.2","status":"closed","closed_at":"2026-01-02T00:00:00Z"}]'
      exit 0 ;;
    list|ready) echo '[]'; exit 0 ;;
    close) : > "$closed"; exit 0 ;;
    dolt) exit 0 ;;
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

on_screen() { grep -Fq -- "$1" "$screen" 2>/dev/null; }
off_screen() { ! grep -Fq -- "$1" "$screen" 2>/dev/null; }

# The calls that change something: every bd call whose verb is not one of the reads above. The verb
# is the first word that is not `-C <dir>' or a flag.
writes() {
  awk '{
    for (i = 1; i <= NF; i++) {
      if ($i == "-C") { i++; continue }
      if ($i ~ /^-/) continue
      if ($i !~ /^(epic|children|list|ready|show)$/) print
      next
    }
  }' "$bd_log"
}
writes_are() { [ "$(writes)" = "$1" ]; }

prompt='run bd close cb-epic ?  y / n'

# --- the finding is drawn ------------------------------------------------------------------------------

wait_until 60 "the Sweeps section to draw the epic-close finding" on_screen 'close cb-epic —'
[ -z "$(writes)" ] || fail "the view wrote to bd before any key was pressed$(evidence)"
pass "the real sweep-epics.sh finding is drawn under Sweeps"

# --- x, declined ---------------------------------------------------------------------------------------

press x
wait_until 10 "x to ask before running anything" on_screen "$prompt"
[ -z "$(writes)" ] || fail "x ran a command before the navigator answered$(evidence)"
press n
wait_until 10 "n to take the question away" off_screen "$prompt"
[ -z "$(writes)" ] || fail "a declined x ran a command$(evidence)"
pass "x asks with the mapped command, and n takes the question away"

# --- x, confirmed --------------------------------------------------------------------------------------
#
# The write worker runs requests in the order they were pressed, so anything the decline had queued
# would land in the log before this close; the log holding exactly these two calls is the proof that
# the decline ran nothing, as well as that the confirm ran the right thing.
press x
wait_until 10 "x to ask again" on_screen "$prompt"
press y
wait_until 20 "bd's writes to be exactly \`close cb-epic', then \`dolt push'" \
  writes_are "$(printf 'close cb-epic\ndolt push')"
wait_until 10 "the notice to say what ran" on_screen 'ran bd close cb-epic'
pass "the declined x ran nothing, and x then y ran exactly bd close cb-epic, then bd dolt push"

# The section is read again at once, and the closed epic is no longer a finding.
wait_until 30 "the closed epic to leave the Sweeps section" off_screen 'close cb-epic —'
writes_are "$(printf 'close cb-epic\ndolt push')" || fail "the re-read wrote to bd$(evidence)"
pass "the Sweeps section is re-read after the write, and the finding is gone"

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
