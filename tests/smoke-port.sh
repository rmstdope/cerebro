#!/usr/bin/env bash
#
# Proves scripts/smoke-port reserves a browser-suite port block for exactly one command: it takes a
# free block atomically, exports the project's own port variable, runs the command, and releases the
# block however the command ends.
#
# The load-bearing cases are the ones about the reservation rather than the export. A block that is
# merely CHECKED free - which is what every implementer did by hand before this script existed - is
# free at one instant and taken by the time the suite runs an hour later; three retrospectives paid
# for that gap one at a time (ah-lbd9.3, ah-lbd9.4, ah-ty3s.3).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/smoke-port.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# Every script smoke-port INVOKES is named: tests/lib/place-scripts follows `source' lines only, so
# a fixture linking smoke-port alone would die the moment it ran project-conf.
new_fixture() {
  consumer_new "$(fixture_name)" --link smoke-port project-conf consumer-root
}

# Writes a fixture's .cerebro/project.conf from the lines given.
declare_conf() {
  local tmp="$1"
  shift
  mkdir -p "$tmp/.cerebro"
  printf '%s\n' "$@" >"$tmp/.cerebro/project.conf"
}

# A base far from anything the fleet or the machine actually serves on. The suite asserts absolute
# port numbers, so a fixture declaring the project's REAL base fails the moment a browser suite is
# running beside it - which is exactly when this suite is most likely to be run.
test_base=39170
first_block=$((test_base + 10))
second_block=$((test_base + 20))

# The background run of `smoke-port-skips-a-block-a-live-run-holds', so it can be killed however
# this suite ends. Its command waits on a file inside the fixture, and the EXIT trap removes the
# fixture without the wait noticing - so an assertion that fails between starting it and releasing
# it would leave a shell spinning at twenty wakeups a second, for ever. The gate run that produces
# one is a red one, which is the run an implementer repeats immediately (ah-dksm review, delta
# round, finding 1).
live_holder=""
live_stop=""
listener=""
suite_cleanup() {
  # RELEASE the wait; do not signal the wrapper. `$live_holder' is the smoke-port wrapper, which
  # has a trap of its own - and bash defers a trap until the foreground child returns, so a SIGTERM
  # to it is queued behind the very loop it would end. Both processes then survive the fixture's
  # removal. suite_cleanup runs BEFORE the trap's `rm -rf' (tests/lib/consumer.sh), so the stop
  # file can still be written, which is what the loop is actually waiting for.
  [[ -n "$live_stop" ]] && touch "$live_stop" 2>/dev/null
  [[ -n "$live_holder" ]] && wait "$live_holder" 2>/dev/null
  # The bound socket is the other stray, and it poisons the NEXT run rather than living for ever:
  # a second `s.bind' fails, and the case then goes red with "could not bind" - a different failure
  # for a reason that is not the defect.
  [[ -n "$listener" ]] && kill "$listener" 2>/dev/null
  return 0
}

smoke_port() {
  # $1 = fixture root, rest = args
  local tmp="$1"
  shift
  "$tmp/.claude/cerebro/scripts/smoke-port" "$@"
}

lock_dir() {
  printf '%s/.cerebro/state/smoke-ports' "$1"
}

# --- smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared ---
# A project with no blocks has no problem to solve, so the wrapper must be safe to write into
# generic agent prose: it says so on stderr and gets out of the way.
tmp="$(new_fixture)"
declare_conf "$tmp" "install pnpm install"
set +e
out="$(smoke_port "$tmp" -- /bin/sh -c 'echo ran; exit 7' 2>"$tmp/err")"
status=$?
set -e
[[ $status -eq 7 ]] \
  || fail "smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared: exit $status"
[[ "$out" == "ran" ]] \
  || fail "smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared: stdout '$out'"
grep -q "port_base" "$tmp/err" \
  || fail "smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared: stderr said nothing about port_base: $(cat "$tmp/err")"
[[ -d "$(lock_dir "$tmp")" ]] \
  && fail "smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared: made a reservation directory"
rm -rf "$tmp"
pass "smoke-port-runs-the-command-unchanged-when-no-port-base-is-declared"

# --- smoke-port-refuses-a-missing-separator ---
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_env SMOKE_PORT_BASE"
set +e
out="$(smoke_port "$tmp" /bin/sh -c 'echo ran' 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "smoke-port-refuses-a-missing-separator: expected exit 2, got $status"
grep -q "usage" <<<"$out" || fail "smoke-port-refuses-a-missing-separator: got: $out"
rm -rf "$tmp"
pass "smoke-port-refuses-a-missing-separator"

# --- smoke-port-refuses-a-port-base-with-no-port-env ---
# A misdeclaration rather than an absence: the blocks exist and nothing says which variable carries
# them, so exporting nothing would run the suite on whatever default it has.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base"
set +e
out="$(smoke_port "$tmp" -- /bin/sh -c 'echo ran' 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] \
  || fail "smoke-port-refuses-a-port-base-with-no-port-env: expected exit 2, got $status"
grep -q "port_base" <<<"$out" \
  || fail "smoke-port-refuses-a-port-base-with-no-port-env: message does not name port_base: $out"
grep -q "port_env" <<<"$out" \
  || fail "smoke-port-refuses-a-port-base-with-no-port-env: message does not name port_env: $out"
rm -rf "$tmp"
pass "smoke-port-refuses-a-port-base-with-no-port-env"

# --- smoke-port-exports-the-projects-port-variable-and-returns-the-command-status ---
# Block k = 1, not k = 0: the base block overlaps whatever dev servers the project itself
# declares - launch_desktop_port, in this consumer - which is why the hand-written snippet this
# replaces also started one block up.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
set +e
out="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE; exit 3' 2>"$tmp/err")"
status=$?
set -e
[[ $status -eq 3 ]] \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: exit $status"
[[ "$out" == "$first_block" ]] \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: got '$out', wanted $first_block"
grep -q "SMOKE_PORT_BASE=$first_block" "$tmp/err" \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: stderr did not name the block: $(cat "$tmp/err")"
rm -rf "$tmp"
pass "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status"

# --- smoke-port-skips-a-block-a-live-run-holds ---
# The case the whole script exists for: two runs in one checkout, overlapping in time.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
# The first run holds its block until this suite says otherwise, rather than for a fixed sleep: a
# `sleep' would be dead wall-clock on every gate run, and bash defers the kill's trap until a
# foreground sleep returns anyway - so `wait' would pay the whole of it (ah-dksm review, finding 4).
smoke_port "$tmp" -- /bin/sh -c "echo started >'$tmp/started'
                                 while [ ! -f '$tmp/stop' ]; do sleep 0.05; done" >/dev/null 2>&1 &
first=$!
live_holder=$first
live_stop="$tmp/stop"
cleanup_add "$tmp"
for _ in $(seq 1 100); do
  [[ -f "$tmp/started" ]] && break
  sleep 0.1
done
[[ -f "$tmp/started" ]] || fail "smoke-port-skips-a-block-a-live-run-holds: the first run never started"
second="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$second" == "$second_block" ]] \
  || fail "smoke-port-skips-a-block-a-live-run-holds: the second run got '$second', wanted $second_block"
touch "$tmp/stop"
wait "$first" 2>/dev/null || true
live_holder=""
live_stop=""
pass "smoke-port-skips-a-block-a-live-run-holds"

# --- smoke-port-releases-its-block-when-the-command-ends ---
# The lease is exactly the run. Nothing else clears it - no end-pass hook, no janitor sweep - so a
# reservation that outlived its command would be a block lost for an hour.
smoke_port "$tmp" -- /bin/sh -c ":" >/dev/null 2>&1
[[ -e "$(lock_dir "$tmp")/$first_block.lock" ]] \
  && fail "smoke-port-releases-its-block-when-the-command-ends: $first_block.lock survived the command"
rm -rf "$tmp"
pass "smoke-port-releases-its-block-when-the-command-ends"

# --- smoke-port-takes-a-block-whose-holder-is-gone ---
# A run killed with SIGKILL leaves its lock behind, and the next caller must be able to reclaim it.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
dead=$(bash -c 'echo $$')
printf '%s %s %s\n' "$dead" "$(date +%s)" "a run that is over" >"$(lock_dir "$tmp")/$first_block.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "$first_block" ]] \
  || fail "smoke-port-takes-a-block-whose-holder-is-gone: got '$got', wanted $first_block"
rm -rf "$tmp"
pass "smoke-port-takes-a-block-whose-holder-is-gone"

# --- smoke-port-leaves-a-recent-live-holder-alone ---
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
printf '%s %s %s\n' "$$" "$(date +%s)" "this very suite" >"$(lock_dir "$tmp")/$first_block.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "$second_block" ]] \
  || fail "smoke-port-leaves-a-recent-live-holder-alone: got '$got', wanted $second_block"
rm -rf "$tmp"
pass "smoke-port-leaves-a-recent-live-holder-alone"

# --- smoke-port-reclaims-a-holder-older-than-an-hour ---
# A live pid and an hour-old reservation is a pid that has been reused, not a slow run: the whole
# gate is minutes. Same number and same reasoning as the consumer's gate lock.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
printf '%s %s %s\n' "$$" "$(( $(date +%s) - 7200 ))" "two hours ago" >"$(lock_dir "$tmp")/$first_block.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "$first_block" ]] \
  || fail "smoke-port-reclaims-a-holder-older-than-an-hour: got '$got', wanted $first_block"
rm -rf "$tmp"
pass "smoke-port-reclaims-a-holder-older-than-an-hour"

# --- smoke-port-skips-a-block-whose-port-is-listening ---
# The orphan case: a `vite preview' that outlived an interrupted run, or a foreign checkout's
# server. Nothing reserved it, so only the probe can see it - and it prints the pid, because a
# block this script will never take is one somebody has to kill by hand.
#
# Skipped, with a reason, when the machine cannot bind a socket or cannot see one: this suite runs
# on developer laptops and in CI, and a case that cannot set its own scene must not be a red gate.
if ! command -v python3 >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
  pass "smoke-port-skips-a-block-whose-port-is-listening (skipped: python3 or lsof is not on PATH)"
  pass "smoke-port-exhausts-and-exits-3 (skipped: python3 or lsof is not on PATH)"
else
  tmp="$(new_fixture)"
  cleanup_add "$tmp"
  declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
  python3 -c 'import socket,sys,time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
sys.stderr.write("bound\\n")
sys.stderr.flush()
time.sleep(30)' $first_block 2>"$tmp/bound" &
  binder=$!
  listener=$binder
  for _ in $(seq 1 100); do
    grep -q bound "$tmp/bound" 2>/dev/null && break
    sleep 0.1
  done
  grep -q bound "$tmp/bound" 2>/dev/null \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: could not bind $first_block"

  got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>"$tmp/err")"
  [[ "$got" == "$second_block" ]] \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: got '$got', wanted $second_block"
  grep -q "$first_block" "$tmp/err" \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: stderr did not name the port: $(cat "$tmp/err")"
  grep -q "$binder" "$tmp/err" \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: stderr did not name the holding pid $binder: $(cat "$tmp/err")"
  [[ -e "$(lock_dir "$tmp")/$first_block.lock" ]] \
    && fail "smoke-port-skips-a-block-whose-port-is-listening: kept a reservation on the block it rejected"
  pass "smoke-port-skips-a-block-whose-port-is-listening"

  # --- smoke-port-exhausts-and-exits-3 ---
  # With one block to try and that block listening, there is nowhere to run: say what held it and
  # exit 3, rather than running the suite on whatever port it defaults to.
  set +e
  out="$(smoke_port "$tmp" --blocks 1 -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>&1)"
  status=$?
  set -e
  [[ $status -eq 3 ]] || fail "smoke-port-exhausts-and-exits-3: expected exit 3, got $status ($out)"
  grep -q "$first_block" <<<"$out" || fail "smoke-port-exhausts-and-exits-3: message does not name $first_block: $out"
  kill "$binder" 2>/dev/null || true
  wait "$binder" 2>/dev/null || true
  listener=""
  rm -rf "$tmp"
  pass "smoke-port-exhausts-and-exits-3"
fi

# --- smoke-port-refuses-a-blocks-flag-with-no-value ---
# The flag's own argument loop is the one place a usage error can HANG rather than exit: a `shift 2'
# that fails leaves the flag in place for the case to match again, for ever. So it is tested, not
# reasoned about (ah-dksm review, findings 2 and 3).
tmp="$(new_fixture)"
cleanup_add "$tmp"
declare_conf "$tmp" "port_base $test_base" "port_env SMOKE_PORT_BASE"
set +e
out="$(smoke_port "$tmp" --blocks 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] \
  || fail "smoke-port-refuses-a-blocks-flag-with-no-value: expected exit 2, got $status"
grep -q "blocks" <<<"$out" \
  || fail "smoke-port-refuses-a-blocks-flag-with-no-value: message does not name the flag: $out"
pass "smoke-port-refuses-a-blocks-flag-with-no-value"

# --- smoke-port-refuses-a-blocks-count-that-is-not-a-positive-integer ---
for bad in 0 x -1; do
  set +e
  out="$(smoke_port "$tmp" --blocks "$bad" -- /bin/sh -c ":" 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] \
    || fail "smoke-port-refuses-a-blocks-count-that-is-not-a-positive-integer: --blocks $bad gave exit $status"
done
rm -rf "$tmp"
pass "smoke-port-refuses-a-blocks-count-that-is-not-a-positive-integer"

# --- smoke-port-names-the-listening-port-of-a-block-it-reclaimed ---
# The one branch the delta reshaped: a block whose lock is a ghost AND whose port is listening. The
# reclaim succeeds and the probe then refuses it, so the diagnosis must be `(listening)' with the
# holding pid - not `(taken)', which now means only that a live rival won the race in between. The
# exit-3 line is the whole diagnosis an agent gets for a stuck run (ah-dksm review, finding 6).
if ! command -v python3 >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
  pass "smoke-port-names-the-listening-port-of-a-block-it-reclaimed (skipped: python3 or lsof is not on PATH)"
else
  tmp="$(new_fixture)"
  cleanup_add "$tmp"
  declare_conf "$tmp" "port_base $test_base" "port_block_size 10" "port_env SMOKE_PORT_BASE"
  python3 -c 'import socket,sys,time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
sys.stderr.write("bound\\n")
sys.stderr.flush()
time.sleep(30)' "$first_block" 2>"$tmp/bound" &
  binder=$!
  listener=$binder
  for _ in $(seq 1 100); do
    grep -q bound "$tmp/bound" 2>/dev/null && break
    sleep 0.1
  done
  grep -q bound "$tmp/bound" 2>/dev/null \
    || fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: could not bind $first_block"

  # A ghost's lock over the listening block: the reclaim must succeed and the probe must then win.
  mkdir -p "$(lock_dir "$tmp")"
  dead=$(bash -c 'echo $$')
  printf '%s %s %s\n' "$dead" "$(date +%s)" "a run that is over" >"$(lock_dir "$tmp")/$first_block.lock"

  set +e
  out="$(smoke_port "$tmp" --blocks 1 -- /bin/sh -c ":" 2>"$tmp/err2")"
  status=$?
  set -e
  out="$out$(cat "$tmp/err2")"
  [[ $status -eq 3 ]] \
    || fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: expected exit 3, got $status ($out)"
  # The SUMMARY line, not the probe's own message: the probe says "already listening" whichever
  # branch refused the block, so an assertion over the whole output passes against the shape this
  # case exists to pin. What is being tested is the diagnosis the exit-3 line carries.
  summary="$(grep "every block tried was taken" <<<"$out" || true)"
  [[ -n "$summary" ]] \
    || fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: no exhaustion line: $out"
  grep -q "$first_block(listening)" <<<"$summary" \
    || fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: summary does not blame the listening port: $summary"
  # The probe's own line, not the whole output: the block's ports are in there too, and a pid that
  # collided with one would make a bare search pass having proved nothing.
  grep -q "held by pid .*$binder" "$tmp/err2" \
    || fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: did not name the holding pid $binder: $(cat "$tmp/err2")"
  [[ -e "$(lock_dir "$tmp")/$first_block.lock" ]] \
    && fail "smoke-port-names-the-listening-port-of-a-block-it-reclaimed: kept the reservation it refused"
  kill "$binder" 2>/dev/null || true
  wait "$binder" 2>/dev/null || true
  listener=""
  rm -rf "$tmp"
  pass "smoke-port-names-the-listening-port-of-a-block-it-reclaimed"
fi

suite_passed
