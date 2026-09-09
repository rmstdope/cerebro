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

suite_passed
