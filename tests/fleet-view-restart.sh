#!/usr/bin/env bash
#
# System test for R15 (.cerebro/requirements.md): a role is not started again while its trigger
# names exactly the work its last pass was started for - and IS started again when that pass
# changed the work.
#
# The real `cerebro-tui', built from this checkout, runs in a pty over a throwaway consumer and
# supervises one producer, Rogue, on standby, with two ranked UX-agreed beads on the board. Nothing
# of the view is stubbed: its triggers, its unchanged-work guard, its session host and its ending of
# a pass that wrote `waiting' are the ones a navigator runs. What is stubbed is what this suite may
# not touch: `bd' (a JSON file per bead), `gh', and `scripts/launch', the view's one way to start a
# session - here a pretend pass that claims its bead with `bd update --claim' (what `assign-bead'
# does once it has made a worktree, which needs an origin this fixture has no use for), writes its
# state through the real `agent-state', does what the fixture scripted for that bead, and ends with
# the real `end-pass'.
#
# Three things are watched, in the order a person would see them:
#   1. the view starts Rogue on the first ready bead (cb-b1);
#   2. b1's pass merges and closes cb-b1. The queue the next start is measured against is the one
#      the pass FOUND, b1 included, so it reads as changed and Rogue is started on cb-b2. This is
#      the half cb-r9ac broke: with the fingerprint taken after the hand-off, the record already
#      lacked b1, the live queue equalled it, and the only bugfixer in atlantis-hud sat idle;
#   3. b2's pass gives cb-b2 back untouched. The queue is exactly as that pass found it, so the
#      guard holds the next start: the view writes an evaluation for Rogue with `held_by_guard',
#      and no third start follows.
#
# The view ends a pass `END_GRACE_SECONDS' (30) after its state file's `since' says `waiting'. The
# grace is the supervise table's to prove (tests/lib/supervise.cases), not R15's, so the pretend
# pass dates its `waiting' file back past it and the view ends the pass on its next tick: the
# grace's real half minute is not paid twice (cb-n53p). Every wait below is bounded, and a failure
# prints what the view logged and ran.
#
#     bash tests/fleet-view-restart.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add, suite_passed - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

for tool in cargo jq python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "this suite needs $tool on PATH"
done

# --- the binary ----------------------------------------------------------------------------------
#
# Built into the workspace's own target directory, which `cargo test' shares: cargo locks it, so
# this build and a parallel `cargo test' wait on each other rather than collide. Never `cargo run':
# the view hands its environment to every session it starts (traps.md).
cargo build --locked --quiet --manifest-path "$repo_root/Cargo.toml" -p cerebro-tui --bin cerebro-tui \
  || fail "cargo could not build cerebro-tui"
target_dir="$(cargo metadata --format-version 1 --no-deps --manifest-path "$repo_root/Cargo.toml" \
  | jq -r .target_directory)"
tui="$target_dir/debug/cerebro-tui"
[[ -x "$tui" ]] || fail "no binary at $tui after the build"

# --- the consumer --------------------------------------------------------------------------------

consumer="$(consumer_new restart --copy)"
mount="$consumer/.cerebro/cerebro"
scripts="$mount/scripts"
fixture="$work_dir/fixture"
stubs="$fixture/stubs"
beads="$fixture/beads"
mkdir -p "$stubs" "$beads" "$fixture/outcomes"

cat > "$consumer/.cerebro/project.conf" <<'CONF'
project_name   Restart
default_branch main
audience_noun  navigator
gate_fast      true
gate_full      true
CONF

cat > "$consumer/.cerebro/roster.conf" <<'ROSTER'
Rogue           producer        standby
ROSTER

# Two ranked beads a producer may take, and what each one's pass will do with it.
bead() {
  # <id> <priority>
  jq -n --arg id "$1" --argjson p "$2" '{
    id: $id, title: ("fixture " + $id), status: "open", priority: $p, issue_type: "task",
    labels: ["ux:agreed"], assignee: "", owner: "test",
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
  }' > "$beads/$1.json"
}
bead cb-b1 1
bead cb-b2 2
echo close    > "$fixture/outcomes/cb-b1"
echo giveback > "$fixture/outcomes/cb-b2"

# --- stub bd: one JSON file per bead, every call logged ------------------------------------------
cat > "$stubs/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FIXTURE/bd.log"
actor=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --readonly|--quiet|-q) shift ;;
    -C) shift 2 ;;
    --actor) actor="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
dir="$FIXTURE/beads"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
all() { cat "$dir"/*.json | jq -s 'sort_by(.id)'; }
edit() {
  # <id> <jq filter>
  local file="$dir/$1.json" tmp
  [[ -f "$file" ]] || { echo "no issue found: $1" >&2; exit 1; }
  tmp="$(mktemp "$dir/.edit-XXXXXX")"
  jq --arg now "$(now)" "$2 | .updated_at = \$now" "$file" > "$tmp"
  mv "$tmp" "$file"
}
cmd="${1:-}"
shift || true
case "$cmd" in
  list)
    statuses=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) statuses="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -n "$statuses" ]]; then
      all | jq --arg s "$statuses" '($s | split(",")) as $want | [ .[] | select(.status as $x | $want | index($x)) ]'
    else
      all | jq '[ .[] | select(.status != "closed") ]'
    fi
    ;;
  ready)
    all | jq '[ .[] | select(.status == "open" and (.assignee // "") == "") ]' ;;
  show)
    [[ -f "$dir/$1.json" ]] || { echo "no issue found: $1" >&2; exit 1; }
    jq -s . "$dir/$1.json" ;;
  update)
    id="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --claim)
          held="$(jq -r '.assignee // ""' "$dir/$id.json")"
          [[ -z "$held" ]] || { echo "already claimed by $held" >&2; exit 1; }
          edit "$id" ".assignee = \"$actor\" | .status = \"in_progress\""; shift ;;
        --if-assignee)
          held="$(jq -r '.assignee // ""' "$dir/$id.json")"
          [[ "$held" == "$2" ]] || { echo "assignee is $held" >&2; exit 1; }
          shift 2 ;;
        --assignee) edit "$id" ".assignee = \"$2\""; shift 2 ;;
        --status) edit "$id" ".status = \"$2\""; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  unclaim)
    edit "$1" '.assignee = "" | .status = "open"' ;;
  close)
    edit "$1" '.status = "closed" | .closed_at = .updated_at' ;;
  dolt|heartbeat) ;;
  *) echo '[]' ;;
esac
STUB

cat > "$stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/gh.log"
echo '[]'
STUB

# --- stub launch: a pretend pass, scripted per bead ----------------------------------------------
#
# The view starts a session as `<scripts>/launch <Name> --bead <id>' in a pty, and that is the one
# file replaced in the copied scripts. Everything the pass does to the board and the state file
# goes through the real scripts. It ends by exec'ing a sleeper whose argv carries the marker
# sentence, under the same pid the state file names, so the row reads as a live session until the
# view ends it.
cat > "$scripts/launch" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/session-marker.sh"
name="$1"; bead=""
[[ "${2:-}" == "--bead" ]] && bead="$3"
printf 'START %s %s\n' "$name" "$bead" >> "$FIXTURE/launches"
bd --actor "$name" update "$bead" --claim >> "$FIXTURE/launch.log" 2>&1
"$here/agent-state" "$name" working --bead "$bead" --phase build --pid $$
case "$(cat "$FIXTURE/outcomes/$bead")" in
  close)    bd --actor "$name" close "$bead" ;;
  giveback) bd --actor "$name" unclaim "$bead" ;;
esac
printf 'PASSED %s %s\n' "$name" "$bead" >> "$FIXTURE/launches"
"$here/end-pass" "$name" --pid $$
# The pass has ended; standing out the view's real end grace would add nothing R15 asks about. So
# the `waiting' file is dated ten minutes back, and the view ends the pass on its next tick. Written
# beside the file and moved over it, so the view never reads half of one.
state="$CEREBRO_CONSUMER_SHARED_ROOT/.cerebro/state/$name.state.json"
jq '.since = (now - 600 | floor | todate)' "$state" > "$state.tmp"
mv "$state.tmp" "$state"
exec bash -c 'while :; do sleep 1; done' "$(cerebro_marker_sentence "$name" "$CEREBRO_CONSUMER_SHARED_ROOT")"
STUB
chmod +x "$stubs/bd" "$stubs/gh" "$scripts/launch"

# --- the pty -------------------------------------------------------------------------------------
#
# python3's stdlib, because `script(1)' takes different arguments on util-linux and BSD and treats
# a closed stdin differently on each. The size is set on the slave before the child starts, so the
# first frame is drawn at 50x200. On SIGTERM it ends the view, which drops its sessions.
cat > "$fixture/pty.py" <<'PY'
import fcntl, os, signal, struct, sys, termios, time
capture, argv = sys.argv[1], sys.argv[2:]
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    if slave > 2:
        os.close(slave)
    os.execv(argv[0], argv)
os.close(slave)
def stop(*_):
    try:
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if os.waitpid(pid, os.WNOHANG)[0]:
                break
            time.sleep(0.1)
        else:
            os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, ChildProcessError):
        pass
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with open(capture, "ab", buffering=0) as out:
    while True:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        out.write(data)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else 1)
PY

view_pid=""
suite_cleanup() {
  if [[ -n "$view_pid" ]] && kill -0 "$view_pid" 2>/dev/null; then
    kill "$view_pid" 2>/dev/null || true
    wait "$view_pid" 2>/dev/null || true
  fi
  # A session the view left behind carries the fixture's root in its marker sentence.
  pkill -f "rooted at $consumer/" 2>/dev/null || true
  return 0
}

# On a failure, everything that says what the view saw and did.
explain() {
  {
    echo "--- launches";       cat "$fixture/launches" 2>/dev/null || true
    echo "--- launch.log";     tail -n 20 "$fixture/launch.log" 2>/dev/null || true
    echo "--- bd.log (tail)";  tail -n 30 "$fixture/bd.log" 2>/dev/null || true
    echo "--- beads";          jq -c '{id, status, assignee}' "$beads"/*.json 2>/dev/null || true
    echo "--- evaluations (tail)"
    tail -n 8 "$consumer/.cerebro/state/evaluations.jsonl" 2>/dev/null || true
    echo "--- decisions (tail)"
    tail -n 8 "$consumer/.cerebro/state/decisions.jsonl" 2>/dev/null || true
    # Every run logs fleet-history, fleet-health and sweep-verdicts.sh failing here: the fixture has
    # no transition log and the stub bd answers `[]'. Expected, and no part of what is asserted.
    echo "--- errors (tail; fleet-history, fleet-health and sweep errors are expected)"
    tail -n 8 "$consumer/.cerebro/state/errors.jsonl" 2>/dev/null || true
    echo "--- view exited: $(kill -0 "$view_pid" 2>/dev/null && echo no || echo yes)"
  } >&2
}

# wait_for <seconds> <what> <command...>: poll until the command succeeds, or fail naming <what>.
wait_for() {
  local bound="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + bound))
  until "$@"; do
    if ((SECONDS >= deadline)); then
      explain
      fail "after ${bound}s: $what"
    fi
    if ! kill -0 "$view_pid" 2>/dev/null; then
      explain
      fail "the fleet view exited while waiting for: $what"
    fi
    sleep 1
  done
}

starts() { grep -c '^START ' "$fixture/launches" 2>/dev/null || true; }
started_on() { grep -qx "START Rogue $1" "$fixture/launches" 2>/dev/null; }

# An evaluation for Rogue, written after the view ended cb-b2's pass, in which the guard held it.
# The view's `end' line names no bead (the state file it reads is `waiting', which carries none),
# so cb-b2's end is Rogue's second one.
held_after_second_end() {
  local ended
  ended="$(jq -r 'select(.event == "end" and .agent == "Rogue") | .ts' \
    "$consumer/.cerebro/state/decisions.jsonl" 2>/dev/null | sed -n 2p)"
  [[ -n "$ended" ]] || return 1
  jq -e --arg after "$ended" \
    'select(.agent == "Rogue" and .held_by_guard == true and .ts > $after)' \
    "$consumer/.cerebro/state/evaluations.jsonl" >/dev/null 2>&1
}

# --- run it --------------------------------------------------------------------------------------

export FIXTURE="$fixture"
(
  cd "$consumer"
  export PATH="$stubs:$PATH" \
    CEREBRO_CONSUMER_ROOT="$consumer" CEREBRO_CONSUMER_SHARED_ROOT="$consumer" \
    CEREBRO_CONSUMER_MOUNT="$mount" CEREBRO_SCRIPTS="$scripts" TERM=xterm-256color
  exec python3 "$fixture/pty.py" "$fixture/screen" "$tui"
) &
view_pid=$!

wait_for 90 "the view starting Rogue on the first ready bead, cb-b1" started_on cb-b1
pass "the fleet view starts a standby producer on the first ready bead"

wait_for 150 "the view starting Rogue again on cb-b2 after the pass that closed cb-b1 (cb-r9ac)" \
  started_on cb-b2
pass "a pass that closed its bead changed the work, and the next start follows (cb-r9ac)"

wait_for 150 "an evaluation holding Rogue by the unchanged-work guard after cb-b2 was given back" \
  held_after_second_end
[[ "$(starts)" == 2 ]] || { explain; fail "expected two starts and no third, got: $(starts)"; }
pass "a pass that gave its bead back untouched is held by the unchanged-work guard"

suite_passed
