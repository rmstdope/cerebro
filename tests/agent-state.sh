#!/usr/bin/env bash
#
# Proves scripts/agent-state writes the state file's contract correctly: field validation,
# the `since` / `phase_since` rules (ah-u3i), atomic writes, and tolerance of an old-format file
# with no phase fields.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-state.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

# A fixture tree with its own scripts/ directory, symlinked to the real scripts, so
# agent-state's own root-derivation (../../../ from .claude/cerebro/scripts) resolves inside
# the fixture rather than the real repo. run-implementer is symlinked alongside it because
# agent-state consults it for the roster. implementer-state (the deprecation shim) is symlinked
# too, so a caller still using the old name is exercised the same way a real consumer would hit it.
new_fixture() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.claude/cerebro/scripts"
  ln -s "$repo_root/scripts/run-implementer" "$tmp/.claude/cerebro/scripts/run-implementer"
  ln -s "$repo_root/scripts/agent-state" "$tmp/.claude/cerebro/scripts/agent-state"
  ln -s "$repo_root/scripts/implementer-state" "$tmp/.claude/cerebro/scripts/implementer-state"
  printf '%s' "$tmp"
}

run_state() {
  # $1 = fixture root, rest = args to agent-state
  local tmp="$1"
  shift
  "$tmp/.claude/cerebro/scripts/agent-state" "$@"
}

state_file() {
  printf '%s/.claude/agents-state/%s.state.json' "$1" "$2"
}

# --- writes-all-fields ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
[[ -f "$f" ]] || fail "writes-all-fields: no state file written"
state="$(jq -r '.state' "$f")"; [[ "$state" == "working" ]] || fail "writes-all-fields: state=$state"
bead="$(jq -r '.bead' "$f")"; [[ "$bead" == "ah-f9c" ]] || fail "writes-all-fields: bead=$bead"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "build" ]] || fail "writes-all-fields: phase=$phase"
pid="$(jq -r '.pid' "$f")"; [[ "$pid" == "42" ]] || fail "writes-all-fields: pid=$pid"
since="$(jq -r '.since' "$f")"
phase_since="$(jq -r '.phase_since' "$f")"
[[ "$since" == "$phase_since" ]] || fail "writes-all-fields: since ($since) != phase_since ($phase_since) on first write"
echo "$since" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || fail "writes-all-fields: since is not ISO-8601 Z: $since"
rm -rf "$tmp"
pass "writes-all-fields"

# --- rejects-off-roster-name ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" NotAnXMan working --bead ah-f9c --phase build --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "rejects-off-roster-name: expected exit 2, got $status"
[[ -f "$(state_file "$tmp" NotAnXMan)" ]] && fail "rejects-off-roster-name: file was written"
rm -rf "$tmp"
pass "rejects-off-roster-name"

# --- rejects-unknown-state ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Cyclops frobnicating --bead ah-f9c --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "rejects-unknown-state: expected exit 2, got $status"
[[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "rejects-unknown-state: file was written"
rm -rf "$tmp"
pass "rejects-unknown-state"

# --- rejects-unknown-phase ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Cyclops working --bead ah-f9c --phase launch --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "rejects-unknown-phase: expected exit 2, got $status"
[[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "rejects-unknown-phase: file was written"
rm -rf "$tmp"
pass "rejects-unknown-phase"

# --- rejects-phase-with-idle ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Cyclops idle --phase build --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "rejects-phase-with-idle: expected exit 2, got $status"
[[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "rejects-phase-with-idle: file was written"
rm -rf "$tmp"
pass "rejects-phase-with-idle"

# --- rejects-phase-with-done ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Cyclops done --bead ah-f9c --phase merge --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "rejects-phase-with-done: expected exit 2, got $status"
rm -rf "$tmp"
pass "rejects-phase-with-done"

# --- roster-check-is-not-a-regex ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" '.*' working --bead ah-f9c --phase build --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "roster-check-is-not-a-regex: expected exit 2, got $status"
rm -rf "$tmp"
pass "roster-check-is-not-a-regex"

# --- requires-pid ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Cyclops working --bead ah-f9c --phase build 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "requires-pid: expected exit 2, got $status"
[[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "requires-pid: file was written"
rm -rf "$tmp"
pass "requires-pid"

# --- phase-change-keeps-since ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 1
f="$(state_file "$tmp" Cyclops)"
since1="$(jq -r '.since' "$f")"
phase_since1="$(jq -r '.phase_since' "$f")"
sleep 1
run_state "$tmp" Cyclops working --bead ah-f9c --phase review --pid 1
since2="$(jq -r '.since' "$f")"
phase_since2="$(jq -r '.phase_since' "$f")"
[[ "$since1" == "$since2" ]] || fail "phase-change-keeps-since: since changed ($since1 -> $since2)"
[[ "$phase_since2" != "null" && -n "$phase_since2" ]] || fail "phase-change-keeps-since: phase_since is missing"
[[ "$phase_since2" != "$phase_since1" ]] || fail "phase-change-keeps-since: phase_since did not advance"
[[ "$phase_since2" > "$since2" ]] || fail "phase-change-keeps-since: phase_since ($phase_since2) is not after since ($since2)"
rm -rf "$tmp"
pass "phase-change-keeps-since"

# --- state-change-resets-since ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase review --pid 1
f="$(state_file "$tmp" Cyclops)"
since1="$(jq -r '.since' "$f")"
phase_since1="$(jq -r '.phase_since' "$f")"
sleep 1
run_state "$tmp" Cyclops asking --bead ah-f9c --phase review --pid 1
since2="$(jq -r '.since' "$f")"
phase_since2="$(jq -r '.phase_since' "$f")"
[[ "$since2" != "$since1" ]] || fail "state-change-resets-since: since did not change on state change"
[[ "$phase_since2" == "$phase_since1" ]] || fail "state-change-resets-since: phase_since changed ($phase_since1 -> $phase_since2) though phase was unchanged"
rm -rf "$tmp"
pass "state-change-resets-since"

# --- no-phase-is-null ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops idle --pid 1
f="$(state_file "$tmp" Cyclops)"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "null" ]] || fail "no-phase-is-null: phase=$phase"
phase_since="$(jq -r '.phase_since' "$f")"; [[ "$phase_since" == "null" ]] || fail "no-phase-is-null: phase_since=$phase_since"
rm -rf "$tmp"
pass "no-phase-is-null"

# --- old-format-file-is-fine ---
tmp="$(new_fixture)"
mkdir -p "$tmp/.claude/agents-state"
f="$(state_file "$tmp" Cyclops)"
cat > "$f" <<'EOF'
{"state":"working","bead":"ah-f9c","since":"2026-08-14T09:00:00Z","pid":1}
EOF
run_state "$tmp" Cyclops working --bead ah-f9c --phase gate --pid 1
since="$(jq -r '.since' "$f")"
[[ "$since" == "2026-08-14T09:00:00Z" ]] || fail "old-format-file-is-fine: since not preserved, got $since"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "gate" ]] || fail "old-format-file-is-fine: phase=$phase"
rm -rf "$tmp"
pass "old-format-file-is-fine"

# --- no-tmp-left-behind ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 1
leftover="$(find "$tmp/.claude/agents-state" -name '*.tmp' 2>/dev/null)"
[[ -z "$leftover" ]] || fail "no-tmp-left-behind: found $leftover"
rm -rf "$tmp"
pass "no-tmp-left-behind"

# --- shim-writes-same-file-and-warns ---
tmp="$(new_fixture)"
out="$("$tmp/.claude/cerebro/scripts/implementer-state" Cyclops working --bead ah-f9c --phase build --pid 1 2>&1)"
f="$(state_file "$tmp" Cyclops)"
[[ -f "$f" ]] || fail "shim-writes-same-file-and-warns: no state file written"
state="$(jq -r '.state' "$f")"; [[ "$state" == "working" ]] || fail "shim-writes-same-file-and-warns: state=$state"
grep -q "renamed to agent-state" <<<"$out" \
  || fail "shim-writes-same-file-and-warns: no deprecation line, got: $out"
rm -rf "$tmp"
pass "shim-writes-same-file-and-warns"

echo "All agent-state tests passed."
