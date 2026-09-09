#!/usr/bin/env bash
#
# Proves scripts/agent-asking flips a state file to `asking` while a question is in front of the
# navigator and back again when it is answered, and that it does so without ever failing a question
# or printing to stdout - both load-bearing, because the script is wired as a `PreToolUse` and a
# `PostToolUse` hook: a wrong exit erases the navigator's prompt, and its stdout reaches the model's
# context.
#
# It is also the protection cb-yug's second half needed: the sidecar write moves onto
# scripts/state-write.sh, and every case here must pass unchanged across that move.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-asking.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

new_fixture() {
  consumer_new "$(fixture_name)" --link roster agent-state consumer-root agent-asking
}

run_state() {
  local tmp="$1"; shift
  "$tmp/.claude/cerebro/scripts/agent-state" "$@"
}

# agent-asking takes its name from the environment, exactly as agent-turn does.
run_asking() {
  local tmp="$1" name="$2"; shift 2
  CEREBRO_AGENT_NAME="$name" "$tmp/.claude/cerebro/scripts/agent-asking" "$@"
}

state_file() {
  printf '%s/.cerebro/state/%s.state.json' "$1" "$2"
}

sidecar_file() {
  printf '%s/.cerebro/state/%s.prequestion.json' "$1" "$2"
}

# --- characterises-a-round-trip ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
out="$(run_asking "$tmp" Cyclops begin)"
[[ -z "$out" ]] || fail "characterises-a-round-trip: begin wrote to stdout: $out"
[[ "$(jq -r '.state' "$f")" == "asking" ]] || fail "characterises-a-round-trip: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "cb-1" ]] || fail "characterises-a-round-trip: bead changed"
[[ "$(jq -r '.phase' "$f")" == "build" ]] || fail "characterises-a-round-trip: phase changed"
[[ -f "$s" ]] || fail "characterises-a-round-trip: no sidecar"
got="$(jq -S -c '{state, bead, phase}' "$s")"
[[ "$got" == '{"bead":"cb-1","phase":"build","state":"working"}' ]] \
  || fail "characterises-a-round-trip: sidecar holds $got"
out="$(run_asking "$tmp" Cyclops end)"
[[ -z "$out" ]] || fail "characterises-a-round-trip: end wrote to stdout: $out"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "characterises-a-round-trip: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "cb-1" ]] || fail "characterises-a-round-trip: bead changed on end"
[[ "$(jq -r '.phase' "$f")" == "build" ]] || fail "characterises-a-round-trip: phase changed on end"
[[ ! -e "$s" ]] || fail "characterises-a-round-trip: the sidecar survived end"
rm -rf "$tmp"
pass "characterises-a-round-trip"

# --- begin-records-idle-and-end-brings-it-back-as-working ---
# `idle` is the sleep loop and nothing else: an answered question means work. And it invents
# neither a bead nor a phase on the way back.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops idle --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
out="$(run_asking "$tmp" Cyclops begin)"
[[ -z "$out" ]] || fail "begin-records-idle: begin wrote to stdout: $out"
[[ "$(jq -r '.state' "$s")" == "idle" ]] || fail "begin-records-idle: sidecar state=$(jq -r '.state' "$s")"
[[ "$(jq -r '.state' "$f")" == "asking" ]] || fail "begin-records-idle: state=$(jq -r '.state' "$f")"
out="$(run_asking "$tmp" Cyclops end)"
[[ -z "$out" ]] || fail "begin-records-idle: end wrote to stdout: $out"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "begin-records-idle: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "null" ]] || fail "begin-records-idle: invented a bead"
[[ "$(jq -r '.phase' "$f")" == "null" ]] || fail "begin-records-idle: invented a phase"
rm -rf "$tmp"
pass "begin-records-idle-and-end-brings-it-back-as-working"

# --- begin-on-a-file-already-asking-writes-no-sidecar ---
# The agent wrote `asking` itself, which is the documented belt-and-braces copy. A sidecar written
# now would record `asking` as the state to go back to, and `end` would restore the very thing it
# exists to clear.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops asking --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
before="$(cat "$f")"
out="$(run_asking "$tmp" Cyclops begin)"
[[ -z "$out" ]] || fail "begin-on-a-file-already-asking: wrote to stdout: $out"
[[ "$before" == "$(cat "$f")" ]] || fail "begin-on-a-file-already-asking: the state file changed"
[[ ! -e "$s" ]] || fail "begin-on-a-file-already-asking: a sidecar was written"
rm -rf "$tmp"
pass "begin-on-a-file-already-asking-writes-no-sidecar"

# --- begin-on-a-file-already-asking-removes-a-stale-sidecar ---
# Any sidecar lying here is from an earlier question a session died in the middle of; `end` would
# otherwise restore a bead from before that crash.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops asking --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
printf '{"state":"working","bead":"cb-old","phase":"review"}\n' > "$s"
out="$(run_asking "$tmp" Cyclops begin)"
[[ -z "$out" ]] || fail "begin-removes-a-stale-sidecar: wrote to stdout: $out"
[[ ! -e "$s" ]] || fail "begin-removes-a-stale-sidecar: the stale sidecar survived"
out="$(run_asking "$tmp" Cyclops end)"
[[ -z "$out" ]] || fail "begin-removes-a-stale-sidecar: end wrote to stdout: $out"
[[ "$(jq -r '.bead' "$f")" == "cb-1" ]] || fail "begin-removes-a-stale-sidecar: end restored cb-old"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "begin-removes-a-stale-sidecar: state=$(jq -r '.state' "$f")"
rm -rf "$tmp"
pass "begin-on-a-file-already-asking-removes-a-stale-sidecar"

# --- end-with-no-sidecar-flips-asking-to-working ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops asking --bead cb-9 --phase review --pid 42
f="$(state_file "$tmp" Cyclops)"
out="$(run_asking "$tmp" Cyclops end)"
[[ -z "$out" ]] || fail "end-with-no-sidecar: wrote to stdout: $out"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "end-with-no-sidecar: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "cb-9" ]] || fail "end-with-no-sidecar: bead changed"
[[ "$(jq -r '.phase' "$f")" == "review" ]] || fail "end-with-no-sidecar: phase changed"
rm -rf "$tmp"
pass "end-with-no-sidecar-flips-asking-to-working"

# --- end-with-no-sidecar-on-a-file-that-is-not-asking-changes-nothing ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-9 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
out="$(run_asking "$tmp" Cyclops end)"
[[ -z "$out" ]] || fail "end-on-a-file-that-is-not-asking: wrote to stdout: $out"
[[ "$before" == "$(cat "$f")" ]] || fail "end-on-a-file-that-is-not-asking: the file changed"
rm -rf "$tmp"
pass "end-with-no-sidecar-on-a-file-that-is-not-asking-changes-nothing"

# --- no-agent-name-does-nothing ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
before="$(cat "$f")"
for mode in begin end; do
  status=0
  out="$(env -u CEREBRO_AGENT_NAME "$tmp/.claude/cerebro/scripts/agent-asking" "$mode")" || status=$?
  [[ $status -eq 0 ]] || fail "no-agent-name-does-nothing: $mode exited $status"
  [[ -z "$out" ]] || fail "no-agent-name-does-nothing: $mode wrote to stdout: $out"
done
[[ "$before" == "$(cat "$f")" ]] || fail "no-agent-name-does-nothing: the file changed"
[[ ! -e "$s" ]] || fail "no-agent-name-does-nothing: a sidecar was written"
rm -rf "$tmp"
pass "no-agent-name-does-nothing"

# --- no-state-file-does-nothing ---
# It must never invent one: a file with no `state` would draw a fleet row no agent has ever written.
tmp="$(new_fixture)"
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
for mode in begin end; do
  status=0
  out="$(run_asking "$tmp" Cyclops "$mode")" || status=$?
  [[ $status -eq 0 ]] || fail "no-state-file-does-nothing: $mode exited $status"
  [[ -z "$out" ]] || fail "no-state-file-does-nothing: $mode wrote to stdout: $out"
done
[[ ! -e "$f" ]] || fail "no-state-file-does-nothing: a state file was created"
[[ ! -e "$s" ]] || fail "no-state-file-does-nothing: a sidecar was created"
rm -rf "$tmp"
pass "no-state-file-does-nothing"

# --- an-unknown-mode-exits-two-with-a-usage-line ---
# The deliberate divergence from scripts/agent-turn, which tests/agent-turn.sh records from its own
# side; asserted here so the pair cannot drift silently.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
status=0
out="$(run_asking "$tmp" Cyclops frobnicate 2>"$tmp/err")" || status=$?
[[ $status -eq 2 ]] || fail "an-unknown-mode-exits-two: exited $status"
[[ -z "$out" ]] || fail "an-unknown-mode-exits-two: wrote to stdout: $out"
grep -q 'usage' "$tmp/err" || fail "an-unknown-mode-exits-two: no usage line on stderr"
[[ "$before" == "$(cat "$f")" ]] || fail "an-unknown-mode-exits-two: the file changed"
rm -rf "$tmp"
pass "an-unknown-mode-exits-two-with-a-usage-line"

# --- no-mode-at-all-exits-two ---
tmp="$(new_fixture)"
status=0
out="$(run_asking "$tmp" Cyclops 2>"$tmp/err")" || status=$?
[[ $status -eq 2 ]] || fail "no-mode-at-all-exits-two: exited $status"
[[ -z "$out" ]] || fail "no-mode-at-all-exits-two: wrote to stdout: $out"
grep -q 'usage' "$tmp/err" || fail "no-mode-at-all-exits-two: no usage line on stderr"
rm -rf "$tmp"
pass "no-mode-at-all-exits-two"

# --- the-sidecar-temp-name-carries-the-writing-pid ---
# Two separate PROCESSES, because `$$` in a subshell is still the parent's pid: the colliding
# writers here are two hook processes under one agent name, and a fixed `<file>.tmp` lets each `mv`
# the other's half-written object.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
s="$(sidecar_file "$tmp" Cyclops)"
mv_log="$work_dir/agent-asking-mv-calls.log"
: > "$mv_log"
mv_stub_dir="$work_dir/agent-asking-mv-stub"
mkdir -p "$mv_stub_dir"
# The real mv is resolved HERE, before the stub shadows it: a pass-through that cannot find it
# would make this case green for the wrong reason.
real_mv="$(command -v mv)"
[[ -n "$real_mv" ]] || fail "the-sidecar-temp-name-carries-the-writing-pid: no real mv"
cat > "$mv_stub_dir/mv" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*) ;; *) printf '%s\n' "\$a" >> "$mv_log"; break ;; esac
done
exec "$real_mv" "\$@"
STUB
chmod +x "$mv_stub_dir/mv"
PATH="$mv_stub_dir:$PATH" run_asking "$tmp" Cyclops begin
# Back to `working`, or the second begin takes the already-asking short circuit and writes nothing.
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
PATH="$mv_stub_dir:$PATH" run_asking "$tmp" Cyclops begin
# agent-state's own renames target the STATE file's temp names; only the sidecar's are this case.
movs="$(grep -F "$s." "$mv_log" || true)"
[[ "$(printf '%s\n' "$movs" | grep -c .)" == "2" ]] \
  || fail "the-sidecar-temp-name-carries-the-writing-pid: expected 2 renames, got '$movs'"
first="$(printf '%s\n' "$movs" | sed -n 1p)"
second="$(printf '%s\n' "$movs" | sed -n 2p)"
[[ "$first" =~ ^"$s"\.[0-9]+\.tmp$ ]] \
  || fail "the-sidecar-temp-name-carries-the-writing-pid: '$first' is not <sidecar>.<pid>.tmp"
[[ "$first" != "$second" ]] \
  || fail "the-sidecar-temp-name-carries-the-writing-pid: two processes shared '$first'"
rm -rf "$tmp" "$mv_stub_dir"
pass "the-sidecar-temp-name-carries-the-writing-pid"

# --- a-failing-jq-leaves-no-temp-beside-the-sidecar ---
# The redirection creates the temp file before jq runs, and the directory it would be left in is
# polled every five seconds by both fleet views.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
stub_dir="$work_dir/agent-asking-jq-stub"
mkdir -p "$stub_dir"
real_jq="$(command -v jq)"
[[ -n "$real_jq" ]] || fail "a-failing-jq-leaves-no-temp: no real jq to pass through to"
cat > "$stub_dir/jq" <<STUB
#!/usr/bin/env bash
# Reads (so the guards pass), then fails on the sidecar's own object.
case "\$*" in
  *'{state: \$state, bead: \$bead, phase: \$phase}'*) exit 1 ;;
  *) exec "$real_jq" "\$@" ;;
esac
STUB
chmod +x "$stub_dir/jq"
status=0
out="$(CEREBRO_AGENT_NAME=Cyclops PATH="$stub_dir:$PATH" \
        "$tmp/.claude/cerebro/scripts/agent-asking" begin)" || status=$?
[[ $status -eq 0 ]] || fail "a-failing-jq-leaves-no-temp: exited $status"
[[ -z "$out" ]] || fail "a-failing-jq-leaves-no-temp: wrote to stdout: $out"
[[ "$before" == "$(cat "$f")" ]] || fail "a-failing-jq-leaves-no-temp: the state file changed"
leftovers="$(find "$tmp/.cerebro/state" -name '*.tmp' 2>/dev/null)"
[[ -z "$leftovers" ]] || fail "a-failing-jq-leaves-no-temp: left behind: $leftovers"
rm -rf "$tmp" "$stub_dir"
pass "a-failing-jq-leaves-no-temp-beside-the-sidecar"

# --- a-missing-state-write-library-does-not-fail-the-question ---
# The deliberate divergence from agent-state and agent-turn: they source the library above their
# guards, so a missing one is loud. This script's non-zero exit is a question the navigator never
# gets asked, so it may not be.
#
# The refusal is at the ONE call site that needs the library rather than over the whole script, so
# `end' - which needs none - is never disabled by this script's own guard. (It still restores
# nothing here, because `scripts/agent-state' sources the same library and is the thing that would
# have to write; that is agent-state's loud failure, not a silent one of ours.)
tmp="$(new_fixture)"
run_state "$tmp" Cyclops asking --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
s="$(sidecar_file "$tmp" Cyclops)"
printf '{"state":"working","bead":"cb-1","phase":"build"}\n' > "$s"
rm -f "$tmp/.claude/cerebro/scripts/state-write.sh"
status=0
out="$(run_asking "$tmp" Cyclops begin)" || status=$?
[[ $status -eq 0 ]] || fail "a-missing-state-write-library: begin exited $status"
[[ -z "$out" ]] || fail "a-missing-state-write-library: begin wrote to stdout: $out"
# begin took the already-`asking' short circuit, which removes a stale sidecar; put one back so
# `end' has a restore path to reach.
printf '{"state":"working","bead":"cb-1","phase":"build"}\n' > "$s"
status=0
out="$(run_asking "$tmp" Cyclops end)" || status=$?
[[ $status -eq 0 ]] || fail "a-missing-state-write-library: end exited $status"
[[ -z "$out" ]] || fail "a-missing-state-write-library: end wrote to stdout: $out"
# It reached the restore path rather than exiting at a guard of its own: the sidecar is consumed.
[[ ! -e "$s" ]] || fail "a-missing-state-write-library: end did not reach its restore path"
rm -rf "$tmp"
pass "a-missing-state-write-library-does-not-fail-the-question"

suite_passed
