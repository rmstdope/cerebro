#!/usr/bin/env bash
#
# R5, as a navigator meets it: they open the fleet view from anywhere in the repository and see
# every roster agent as a row with its state, bead, phase and timers. A SYSTEM suite
# (.cerebro/test-architecture.md): the real `scripts/cerebro-tui' launcher is typed from a
# subdirectory of a throwaway consumer, execs the real `cerebro-tui' on a pseudo-terminal, and the
# suite reads the screen. The rules under it (`model::derive_fleet', `ui::row_line',
# `state_label', `for_column', `columns') are unit-tested in fleet-view/src; this proves the path
# through them: the launcher's root resolution from a subdirectory, the state files and process
# scan the view reads, and the rows it draws.
#
# The fixture:
#   - the launcher of the copied mount, run from `docs/notes/deep'. A stub `cargo' answers `build'
#     the way cargo does under --message-format=json-render-diagnostics, naming the debug binary
#     this suite built (the pattern tests/cerebro-tui.sh uses), so the launcher still execs the
#     binary itself and never runs it as cargo's child (.cerebro/traps.md). The copied mount has no
#     Cargo.toml, so an empty one is put beside its scripts: the launcher refuses a mount with no
#     workspace, and the stub never reads it.
#   - four roster rows, all `standby', so the view starts nothing:
#       Rogue      producer   working, cb-r5a, phase build, 2h03 on the bead, 12m in the phase
#       Gambit     producer   asking,  cb-r5b, phase review, 47m and 5m
#       Forge      architect  idle, no bead, 3m
#       Wolverine  bugfixer   no session and no state file; the board has no bugs to start it on
#   - a row reads alive only while a process carries the marker sentence (R6), so each of the first
#     three gets a sleeper whose argv carries it, from the sourced `scripts/session-marker.sh'. Its
#     state is written through the real `scripts/agent-state' with the sleeper's pid, then `since'
#     and `phase_since' are dated back so the timers have known values.
#   - `bd' answers every read with an empty list; `gh' and `claude' refuse.
#
# The pty is 40x90: below `ui::SPLIT_COLUMNS' (100) the panes stack and Fleet takes the whole
# width, above `ui::WIDE_COLUMNS' (64), which is where the Role and For columns are drawn. The view
# reads whether or not it supervises, so this suite never waits on the lease.
#
#     bash tests/fleet-rows.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_cleanup - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"
# cerebro_marker_sentence - the one bash spelling of the marker.
source "$repo_root/scripts/session-marker.sh"

for tool in cargo python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "fleet-rows needs $tool on PATH"
done

# --- the binary -----------------------------------------------------------------------------------
#
# Debug, as tests/fleet-keys.sh and tests/fleet-stale.sh build it, so they share one build.
build_log="$work_dir/cargo-build.log"
if ! artifacts="$(cargo build --locked --manifest-path "$repo_root/Cargo.toml" --bin cerebro-tui \
                    --message-format=json-render-diagnostics 2>"$build_log")"; then
  fail "cargo build of cerebro-tui failed: $(tail -20 "$build_log")"
fi
binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "cerebro-tui")
                 | .executable // empty' <<<"$artifacts" | tail -1)"
[ -x "$binary" ] || fail "cargo build named no cerebro-tui executable"

# --- the consumer and its roster ----------------------------------------------------------------------

consumer="$(consumer_new rows --copy)"
mount="$consumer/.cerebro/cerebro"
: > "$mount/Cargo.toml"
roster="$consumer/.cerebro/roster.conf"
cat > "$roster" <<'ROSTER'
Rogue      producer   standby
Gambit     producer   standby
Forge      architect  standby
Wolverine  bugfixer   standby
ROSTER

deep="$consumer/docs/notes/deep"
mkdir -p "$deep"

shared="$(cd "$consumer" && "$mount/scripts/consumer-root" --shared)"
[ -n "$shared" ] || fail "consumer-root --shared gave no root for the fixture"
state_dir="$shared/.cerebro/state"

stubs="$work_dir/stubs"
mkdir -p "$stubs"
cargo_log="$work_dir/cargo.log"
cat > "$stubs/cargo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cargo_log"
[ "\${1:-}" = build ] || { echo "stub cargo: only build is part of this suite" >&2; exit 1; }
printf '{"reason":"compiler-artifact","target":{"name":"cerebro-tui","kind":["bin"]},"executable":"%s","fresh":true}\n' "$binary"
printf '{"reason":"build-finished","success":true}\n'
STUB
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo '[]'
STUB
printf '#!/bin/sh\necho "stub gh: not part of this suite" >&2\nexit 1\n' > "$stubs/gh"
printf '#!/bin/sh\necho "stub claude: nothing is started in this suite" >&2\nexit 1\n' > "$stubs/claude"
chmod +x "$stubs/cargo" "$stubs/bd" "$stubs/gh" "$stubs/claude"

# --- the live sessions ----------------------------------------------------------------------------------

sleepers=()
suite_cleanup() {
  [ -n "${view_pid:-}" ] && kill "$view_pid" 2>/dev/null || true
  local pid
  for pid in "${sleepers[@]}"; do kill "$pid" 2>/dev/null || true; done
  pkill -f "$work_dir" 2>/dev/null || true
  [ -n "${view_pid:-}" ] && wait "$view_pid" 2>/dev/null || true
}

# session <name> <state> <since-seconds-ago> [<bead> <phase> <phase-seconds-ago>]
session() {
  local name="$1" state="$2" since_ago="$3" bead="${4:-}" phase="${5:-}" phase_ago="${6:-}"
  bash -c 'while :; do sleep 1; done' "$(cerebro_marker_sentence "$name" "$shared")" &
  local pid=$!
  sleepers+=("$pid")
  local args=("$name" "$state")
  [ -n "$bead" ] && args+=(--bead "$bead" --phase "$phase")
  (cd "$consumer" && "$mount/scripts/agent-state" "${args[@]}" --pid "$pid") \
    || fail "agent-state refused to write $name's $state"
  local file="$state_dir/$name.state.json"
  jq --argjson since "$since_ago" --arg phase_ago "$phase_ago" '
      .since = (now - $since | floor | todate)
    | if $phase_ago == "" then . else .phase_since = (now - ($phase_ago | tonumber) | floor | todate) end
    ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# Five seconds past each minute, so each timer reads the same for the next 55.
session Rogue  working $((2 * 3600 + 3 * 60 + 5)) cb-r5a build $((12 * 60 + 5))
session Gambit asking  $((47 * 60 + 5))           cb-r5b review $((5 * 60 + 5))
session Forge  idle    $((3 * 60 + 5))

# --- the view, opened from a subdirectory -----------------------------------------------------------------

keys="$work_dir/keys.fifo"
screen="$work_dir/screen.txt"
view_err="$work_dir/view.err"
mkfifo "$keys"

(
  cd "$deep"
  # Nothing of the consumer's roots is exported: finding them from here is the launcher's job.
  unset CEREBRO_CONSUMER_ROOT CEREBRO_CONSUMER_SHARED_ROOT CEREBRO_CONSUMER_MOUNT CEREBRO_SCRIPTS
  export PATH="$stubs:$PATH" TERM=xterm-256color
  exec python3 -I "$repo_root/tests/lib/pty-drive" "$keys" "$screen" 40 90 -- \
    "$mount/scripts/cerebro-tui"
) </dev/null >/dev/null 2>"$view_err" &
view_pid=$!

exec 7<>"$keys"
press() { printf '%s' "$1" >&7; }

evidence() {
  printf '\n--- screen ---\n'
  cat "$screen" 2>/dev/null || echo "(no screen yet)"
  printf -- '--- view stderr ---\n'
  cat "$view_err" 2>/dev/null || true
  printf -- '--- cargo calls ---\n'
  cat "$cargo_log" 2>/dev/null || true
  printf -- '--- state files ---\n'
  cat "$state_dir"/*.state.json 2>/dev/null || true
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

# row <name>: the Fleet pane's line for NAME - the line whose first word after the border (heavy
# while the pane has focus, as it does on open) and the glyph is the name. The Work and Session
# panes never open a line that way.
# Alternation and `[^ ]+', not a bracket and `.': the border and the glyph are multibyte, and
# under a C locale a bracket or a dot matches one byte of them.
row_start='^(│|┃)[^ ]+ '
row() { grep -E "$row_start$1 " "$screen" 2>/dev/null || true; }
row_count() { grep -cE "$row_start$1 " "$screen" 2>/dev/null || true; }
row_reads() {
  local name="$1" line
  shift
  line="$(row "$name")"
  local word
  for word in "$@"; do
    [[ "$line" == *"$word"* ]] || return 1
  done
}
all_rows_drawn() {
  local name
  for name in Rogue Gambit Forge Wolverine; do
    [ -n "$(row "$name")" ] || return 1
  done
  row_reads Rogue cb-r5a
}

# --- the rows ---------------------------------------------------------------------------------------------

wait_until 60 "the Fleet pane to draw every roster row" all_rows_drawn
grep -q '^build' "$cargo_log" || fail "the launcher never asked cargo to build$(evidence)"
pass "the launcher typed from docs/notes/deep opens the view on the consumer"

for name in Rogue Gambit Forge Wolverine; do
  [ "$(row_count "$name")" = 1 ] || fail "$name is not exactly one Fleet row$(evidence)"
done
order="$(grep -oE "$row_start(Rogue|Gambit|Forge|Wolverine) " "$screen" | awk '{print $NF}' | paste -sd' ' -)"
[ "$order" = "Rogue Gambit Forge Wolverine" ] ||
  fail "the Fleet rows are not in roster order: $order$(evidence)"
pass "every roster agent is exactly one row, in roster order"

row_reads Rogue producer build cb-r5a '2h03 12m' ||
  fail "Rogue's row does not read producer, build, cb-r5a, 2h03 12m: $(row Rogue)$(evidence)"
pass "a working row shows its role, its phase as the state, its bead and both timers"

row_reads Gambit producer asking cb-r5b '47m 5m' ||
  fail "Gambit's row does not read producer, asking, cb-r5b, 47m 5m: $(row Gambit)$(evidence)"
pass "an asking row shows asking, its bead and both timers"

row_reads Forge architect idle '3m' ||
  fail "Forge's row does not read architect, idle, 3m: $(row Forge)$(evidence)"
[[ "$(row Forge)" != *cb-* ]] || fail "Forge's idle row shows a bead: $(row Forge)$(evidence)"
pass "an idle row shows idle, no bead, and its timer"

row_reads Wolverine bugfixer standby ||
  fail "Wolverine's row does not read bugfixer, standby: $(row Wolverine)$(evidence)"
[[ "$(row Wolverine)" != *cb-* ]] || fail "Wolverine's standby row shows a bead: $(row Wolverine)$(evidence)"
pass "a roster agent with no session is still a row, standby"

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
