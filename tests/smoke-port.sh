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
declare_conf "$tmp" "port_base 4173" "port_env SMOKE_PORT_BASE"
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
declare_conf "$tmp" "port_base 4173"
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
# Block k = 1, not k = 0: the base block overlaps whatever dev servers the project itself declares
# (here launch_desktop_port 4174), which is why the hand-written snippet this replaces also started
# one block up.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
set +e
out="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE; exit 3' 2>"$tmp/err")"
status=$?
set -e
[[ $status -eq 3 ]] \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: exit $status"
[[ "$out" == "4183" ]] \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: got '$out', wanted 4183"
grep -q "SMOKE_PORT_BASE=4183" "$tmp/err" \
  || fail "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status: stderr did not name the block: $(cat "$tmp/err")"
rm -rf "$tmp"
pass "smoke-port-exports-the-projects-port-variable-and-returns-the-command-status"

# --- smoke-port-skips-a-block-a-live-run-holds ---
# The case the whole script exists for: two runs in one checkout, overlapping in time.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
smoke_port "$tmp" -- /bin/sh -c "echo started >'$tmp/started'; sleep 20" >/dev/null 2>&1 &
first=$!
cleanup_add "$tmp"
for _ in $(seq 1 100); do
  [[ -f "$tmp/started" ]] && break
  sleep 0.1
done
[[ -f "$tmp/started" ]] || fail "smoke-port-skips-a-block-a-live-run-holds: the first run never started"
second="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$second" == "4193" ]] \
  || fail "smoke-port-skips-a-block-a-live-run-holds: the second run got '$second', wanted 4193"
kill "$first" 2>/dev/null || true
wait "$first" 2>/dev/null || true
pass "smoke-port-skips-a-block-a-live-run-holds"

# --- smoke-port-releases-its-block-when-the-command-ends ---
# The lease is exactly the run. Nothing else clears it - no end-pass hook, no janitor sweep - so a
# reservation that outlived its command would be a block lost for an hour.
smoke_port "$tmp" -- /bin/sh -c ":" >/dev/null 2>&1
[[ -e "$(lock_dir "$tmp")/4183.lock" ]] \
  && fail "smoke-port-releases-its-block-when-the-command-ends: 4183.lock survived the command"
rm -rf "$tmp"
pass "smoke-port-releases-its-block-when-the-command-ends"

# --- smoke-port-takes-a-block-whose-holder-is-gone ---
# A run killed with SIGKILL leaves its lock behind, and the next caller must be able to reclaim it.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
dead=$(bash -c 'echo $$')
printf '%s %s %s\n' "$dead" "$(date +%s)" "a run that is over" >"$(lock_dir "$tmp")/4183.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "4183" ]] \
  || fail "smoke-port-takes-a-block-whose-holder-is-gone: got '$got', wanted 4183"
rm -rf "$tmp"
pass "smoke-port-takes-a-block-whose-holder-is-gone"

# --- smoke-port-leaves-a-recent-live-holder-alone ---
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
printf '%s %s %s\n' "$$" "$(date +%s)" "this very suite" >"$(lock_dir "$tmp")/4183.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "4193" ]] \
  || fail "smoke-port-leaves-a-recent-live-holder-alone: got '$got', wanted 4193"
rm -rf "$tmp"
pass "smoke-port-leaves-a-recent-live-holder-alone"

# --- smoke-port-reclaims-a-holder-older-than-an-hour ---
# A live pid and an hour-old reservation is a pid that has been reused, not a slow run: the whole
# gate is minutes. Same number and same reasoning as the consumer's gate lock.
tmp="$(new_fixture)"
declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
mkdir -p "$(lock_dir "$tmp")"
printf '%s %s %s\n' "$$" "$(( $(date +%s) - 7200 ))" "two hours ago" >"$(lock_dir "$tmp")/4183.lock"
got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>/dev/null)"
[[ "$got" == "4183" ]] \
  || fail "smoke-port-reclaims-a-holder-older-than-an-hour: got '$got', wanted 4183"
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
  declare_conf "$tmp" "port_base 4173" "port_block_size 10" "port_env SMOKE_PORT_BASE"
  python3 -c 'import socket,sys,time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
sys.stderr.write("bound\\n")
sys.stderr.flush()
time.sleep(30)' 4183 2>"$tmp/bound" &
  binder=$!
  for _ in $(seq 1 100); do
    grep -q bound "$tmp/bound" 2>/dev/null && break
    sleep 0.1
  done
  grep -q bound "$tmp/bound" 2>/dev/null \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: could not bind 4183"

  got="$(smoke_port "$tmp" -- /bin/sh -c 'echo $SMOKE_PORT_BASE' 2>"$tmp/err")"
  [[ "$got" == "4193" ]] \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: got '$got', wanted 4193"
  grep -q "4183" "$tmp/err" \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: stderr did not name the port: $(cat "$tmp/err")"
  grep -q "$binder" "$tmp/err" \
    || fail "smoke-port-skips-a-block-whose-port-is-listening: stderr did not name the holding pid $binder: $(cat "$tmp/err")"
  [[ -e "$(lock_dir "$tmp")/4183.lock" ]] \
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
  grep -q "4183" <<<"$out" || fail "smoke-port-exhausts-and-exits-3: message does not name 4183: $out"
  kill "$binder" 2>/dev/null || true
  wait "$binder" 2>/dev/null || true
  rm -rf "$tmp"
  pass "smoke-port-exhausts-and-exits-3"
fi

suite_passed
