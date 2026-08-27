#!/usr/bin/env bash
#
# Proves scripts/end-pass is the one place a pass is ended: it writes `waiting' through
# scripts/agent-state for any agent on the roster, and refuses - in agent-state's own voice - a
# name that is not on it, a missing or malformed pid, and any argument at all beyond `--pid'.
#
# The last case is the load-bearing one: end-pass must go THROUGH agent-state rather than write the
# state file itself, so there is one writer and the two cannot drift. A reimplementation would pass
# every other case here and fail that one.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/end-pass.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# Both scripts are named: end-pass INVOKES agent-state as a subprocess rather than sourcing it, and
# tests/lib/place-scripts follows `source' lines only - so a fixture linking end-pass alone would
# die at the invocation.
new_fixture() {
  consumer_new "$(fixture_name)" --link roster end-pass agent-state consumer-root
}

run_end_pass() {
  # $1 = fixture root, rest = args to end-pass
  local tmp="$1"
  shift
  "$tmp/.claude/cerebro/scripts/end-pass" "$@"
}

state_file() {
  printf '%s/.cerebro/state/%s.state.json' "$1" "$2"
}

# --- end-pass-writes-waiting ---
tmp="$(new_fixture)"
run_end_pass "$tmp" Moira --pid 42
f="$(state_file "$tmp" Moira)"
[[ -f "$f" ]] || fail "end-pass-writes-waiting: no state file written"
[[ "$(jq -r '.state' "$f")" == "waiting" ]] \
  || fail "end-pass-writes-waiting: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "null" ]] \
  || fail "end-pass-writes-waiting: bead=$(jq -r '.bead' "$f")"
[[ "$(jq -r '.phase' "$f")" == "null" ]] \
  || fail "end-pass-writes-waiting: phase=$(jq -r '.phase' "$f")"
[[ "$(jq -r '.pid' "$f")" == "42" ]] \
  || fail "end-pass-writes-waiting: pid=$(jq -r '.pid' "$f")"
rm -rf "$tmp"
pass "end-pass-writes-waiting"

# --- end-pass-works-for-an-implementer-name ---
# `waiting' is every agent's end-of-pass state since cb-1or.1, so the script is not interactive-only.
tmp="$(new_fixture)"
run_end_pass "$tmp" Cyclops --pid 42
f="$(state_file "$tmp" Cyclops)"
[[ -f "$f" ]] || fail "end-pass-works-for-an-implementer-name: no state file written"
[[ "$(jq -r '.state' "$f")" == "waiting" ]] \
  || fail "end-pass-works-for-an-implementer-name: state=$(jq -r '.state' "$f")"
rm -rf "$tmp"
pass "end-pass-works-for-an-implementer-name"

# --- end-pass-refuses-a-name-not-on-the-roster ---
tmp="$(new_fixture)"
set +e
out="$(run_end_pass "$tmp" NotAnXMan --pid 42 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "end-pass-refuses-a-name-not-on-the-roster: expected exit 2, got $status"
grep -q "is not on the roster" <<<"$out" \
  || fail "end-pass-refuses-a-name-not-on-the-roster: wrong message, got: $out"
[[ -f "$(state_file "$tmp" NotAnXMan)" ]] \
  && fail "end-pass-refuses-a-name-not-on-the-roster: file was written"
rm -rf "$tmp"
pass "end-pass-refuses-a-name-not-on-the-roster"

# --- end-pass-refuses-a-missing-pid ---
tmp="$(new_fixture)"
set +e
out="$(run_end_pass "$tmp" Moira 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "end-pass-refuses-a-missing-pid: expected exit 2, got $status"
grep -q -- "--pid is required" <<<"$out" \
  || fail "end-pass-refuses-a-missing-pid: wrong message, got: $out"
[[ -f "$(state_file "$tmp" Moira)" ]] && fail "end-pass-refuses-a-missing-pid: file was written"
rm -rf "$tmp"
pass "end-pass-refuses-a-missing-pid"

# --- end-pass-refuses-a-non-numeric-pid ---
tmp="$(new_fixture)"
set +e
out="$(run_end_pass "$tmp" Moira --pid nine 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "end-pass-refuses-a-non-numeric-pid: expected exit 2, got $status"
grep -q -- "--pid is required" <<<"$out" \
  || fail "end-pass-refuses-a-non-numeric-pid: wrong message, got: $out"
[[ -f "$(state_file "$tmp" Moira)" ]] && fail "end-pass-refuses-a-non-numeric-pid: file was written"
rm -rf "$tmp"
pass "end-pass-refuses-a-non-numeric-pid"

# --- end-pass-refuses-an-unknown-argument ---
# There is no state word and no phase to get wrong: a name and a pid are the whole argument list.
tmp="$(new_fixture)"
set +e
out="$(run_end_pass "$tmp" Moira --phase plan --pid 42 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "end-pass-refuses-an-unknown-argument: expected exit 2, got $status"
grep -q "unknown argument" <<<"$out" \
  || fail "end-pass-refuses-an-unknown-argument: wrong message, got: $out"
[[ -f "$(state_file "$tmp" Moira)" ]] \
  && fail "end-pass-refuses-an-unknown-argument: file was written"
rm -rf "$tmp"
pass "end-pass-refuses-an-unknown-argument"

# --- end-pass-appends-a-transition ---
# What pins that end-pass goes THROUGH agent-state rather than writing the state file itself: a
# reimplementation would pass every case above and fail this one.
tmp="$(new_fixture)"
run_end_pass "$tmp" Moira --pid 42
line="$(tail -1 "$tmp/.cerebro/state/transitions.jsonl")"
[[ "$(jq -r '.agent' <<<"$line")" == "Moira" ]] \
  || fail "end-pass-appends-a-transition: agent=$(jq -r '.agent' <<<"$line")"
[[ "$(jq -r '.to' <<<"$line")" == "waiting" ]] \
  || fail "end-pass-appends-a-transition: to=$(jq -r '.to' <<<"$line")"
rm -rf "$tmp"
pass "end-pass-appends-a-transition"

suite_passed
