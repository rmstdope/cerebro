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

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# A fixture tree with its own scripts/ directory, symlinked to the real scripts, so
# agent-state's own root-derivation (via scripts/consumer-root --shared) resolves inside
# the fixture rather than the real repo. roster is symlinked alongside it because agent-state
# consults it for the fleet.
# A git repo, since consumer-root --shared asks git for the main .git directory.
new_fixture() {
  consumer_new "$(fixture_name)" --link roster agent-state consumer-root
}

run_state() {
  # $1 = fixture root, rest = args to agent-state
  local tmp="$1"
  shift
  "$tmp/.claude/cerebro/scripts/agent-state" "$@"
}

state_file() {
  printf '%s/.cerebro/state/%s.state.json' "$1" "$2"
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
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$since" \
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

# --- accepts-a-consumer-phase-word (ah-qled.5.2) ---
# The phase vocabulary is a shape, not a closed list: a consumer that adds a role of its own
# invents a word for it, and this script must record it rather than refusing to write at all.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase index --pid 1
f="$(state_file "$tmp" Cyclops)"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "index" ]] || fail "accepts-a-consumer-phase-word: phase=$phase"
rm -rf "$tmp"
pass "accepts-a-consumer-phase-word"

# --- accepts-a-hyphenated-phase-word (ah-qled.5.2) ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase deep-clean --pid 1
f="$(state_file "$tmp" Cyclops)"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "deep-clean" ]] \
  || fail "accepts-a-hyphenated-phase-word: phase=$phase"
rm -rf "$tmp"
pass "accepts-a-hyphenated-phase-word"

# --- a-shipped-phase-word-still-works (ah-qled.5.2) ---
tmp="$(new_fixture)"
run_state "$tmp" Xavier working --bead ah-f9c --phase plan --pid 1
f="$(state_file "$tmp" Xavier)"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "plan" ]] || fail "a-shipped-phase-word-still-works: phase=$phase"
rm -rf "$tmp"
pass "a-shipped-phase-word-still-works"

# --- rejects-malformed-phase (ah-qled.5.2) ---
# A malformed word is still a typo worth catching at the call: lower-case letters, digits and
# hyphens, starting with a letter and not ending with one.
for bad in 'Plan Bead' 'Plan' '-plan' 'plan-' '' '2plan' 'plan_b'; do
  tmp="$(new_fixture)"
  set +e
  out="$(run_state "$tmp" Cyclops working --bead ah-f9c --phase "$bad" --pid 1 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "rejects-malformed-phase: '$bad' expected exit 2, got $status"
  [[ "$out" == *"cerebro--phases"* ]] \
    || fail "rejects-malformed-phase: '$bad' message does not point at cerebro--phases: $out"
  [[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "rejects-malformed-phase: '$bad' wrote a file"
  rm -rf "$tmp"
done
pass "rejects-malformed-phase"

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
mkdir -p "$tmp/.cerebro/state"
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
leftover="$(find "$tmp/.cerebro/state" -name '*.tmp' 2>/dev/null)"
[[ -z "$leftover" ]] || fail "no-tmp-left-behind: found $leftover"
rm -rf "$tmp"
pass "no-tmp-left-behind"

# --- ah-2n3.2: the five interactive agents write the same file ---

# --- interactive-agent-writes ---
tmp="$(new_fixture)"
run_state "$tmp" Xavier working --phase triage --pid 42
f="$(state_file "$tmp" Xavier)"
[[ -f "$f" ]] || fail "interactive-agent-writes: no state file written"
state="$(jq -r '.state' "$f")"; [[ "$state" == "working" ]] || fail "interactive-agent-writes: state=$state"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "triage" ]] || fail "interactive-agent-writes: phase=$phase"
rm -rf "$tmp"
pass "interactive-agent-writes"

# --- interactive-agent-asking-with-bead-and-role-phase ---
tmp="$(new_fixture)"
run_state "$tmp" Psylocke asking --bead ah-xyz --phase verify --pid 7
f="$(state_file "$tmp" Psylocke)"
state="$(jq -r '.state' "$f")"; [[ "$state" == "asking" ]] || fail "interactive-agent-asking-with-bead-and-role-phase: state=$state"
bead="$(jq -r '.bead' "$f")"; [[ "$bead" == "ah-xyz" ]] || fail "interactive-agent-asking-with-bead-and-role-phase: bead=$bead"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "verify" ]] || fail "interactive-agent-asking-with-bead-and-role-phase: phase=$phase"
rm -rf "$tmp"
pass "interactive-agent-asking-with-bead-and-role-phase"

# --- done-is-refused-from-every-name ---
# cb-1or.2 retired `done': it is an unknown word now, from an interactive name and from an
# implementer's alike, and neither writes a file.
tmp="$(new_fixture)"
for who in Forge Cyclops; do
  set +e
  out="$(run_state "$tmp" "$who" done --bead ah-f9c --pid 1 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "done-is-refused-from-every-name: $who expected exit 2, got $status"
  grep -q "unknown state 'done'" <<<"$out" \
    || fail "done-is-refused-from-every-name: $who wrong message, got: $out"
  [[ -f "$(state_file "$tmp" "$who")" ]] && fail "done-is-refused-from-every-name: $who file was written"
done
rm -rf "$tmp"
pass "done-is-refused-from-every-name"

# --- off-roster-non-interactive-name-still-refused ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Nobody working --phase build --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "off-roster-non-interactive-name-still-refused: expected exit 2, got $status"
grep -q "is not on the roster" <<<"$out" \
  || fail "off-roster-non-interactive-name-still-refused: wrong message, got: $out"
rm -rf "$tmp"
pass "off-roster-non-interactive-name-still-refused"

# --- an-implementer-name-can-use-a-role-phase-word-too ---
# The vocabulary is a union, not checked per role (cerebro.el's `cerebro--phases' makes the same
# trade) - a wrong word in a column is not worth a per-role table in bash.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --phase triage --pid 1
f="$(state_file "$tmp" Cyclops)"
phase="$(jq -r '.phase' "$f")"; [[ "$phase" == "triage" ]] || fail "an-implementer-name-can-use-a-role-phase-word-too: phase=$phase"
rm -rf "$tmp"
pass "an-implementer-name-can-use-a-role-phase-word-too"

# --- from-a-worktree-copy-writes-to-the-shared-checkout (ah-e0w) ---
# An implementer that inits the submodule inside its own bead worktree (the remedy ah-4ao, ah-axj
# and ah-aao prescribe) invokes agent-state relative to THAT copy. The state file must still land
# in the main checkout the fleet view reads, never in the worktree's own .cerebro/state/.
tmp="$(new_fixture)"
worktree="$tmp/.cerebro/worktrees/ah-f9c"
git -C "$tmp" worktree add -q "$worktree" -b ah-f9c-branch
# link_scripts rather than four `ln -s` by hand, so the sourced libraries come with the scripts:
# a fixture that places a script without them dies at its `source` line (cb-ue0, cb-ge0).
link_scripts "$worktree" agent-state roster consumer-root

"$worktree/.claude/cerebro/scripts/agent-state" Cyclops working --bead ah-f9c --pid 42

f="$(state_file "$tmp" Cyclops)"
[[ -f "$f" ]] || fail "from-a-worktree-copy-writes-to-the-shared-checkout: no state file in the main checkout"
state="$(jq -r '.state' "$f")"; [[ "$state" == "working" ]] \
  || fail "from-a-worktree-copy-writes-to-the-shared-checkout: state=$state"
[[ ! -d "$worktree/.cerebro/state" ]] \
  || fail "from-a-worktree-copy-writes-to-the-shared-checkout: a copy was also written in the worktree"
rm -rf "$tmp"
pass "from-a-worktree-copy-writes-to-the-shared-checkout"

# --- transition-log: a transition appends one line to the log (ah-hiib.1) ---
log_file() {
  printf '%s/.cerebro/state/transitions.jsonl' "$1"
}

tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
l="$(log_file "$tmp")"
[[ -f "$l" ]] || fail "transition-log-appends: no log written"
[[ "$(wc -l < "$l" | tr -d ' ')" == "1" ]] || fail "transition-log-appends: expected one line"
jq -e . "$l" >/dev/null || fail "transition-log-appends: line does not parse as JSON"
[[ "$(jq -r '.agent' "$l")" == "Cyclops" ]] || fail "transition-log-appends: agent"
[[ "$(jq -r '.to' "$l")" == "working" ]] || fail "transition-log-appends: to"
[[ "$(jq -r '.phase' "$l")" == "build" ]] || fail "transition-log-appends: phase"
[[ "$(jq -r '.bead' "$l")" == "ah-f9c" ]] || fail "transition-log-appends: bead"
[[ "$(jq -r '.pid' "$l")" == "42" ]] || fail "transition-log-appends: pid"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$(jq -r '.ts' "$l")" \
  || fail "transition-log-appends: ts is not ISO-8601 Z"
rm -rf "$tmp"
pass "transition-log-appends"

# --- transition-log: the first write records a null from ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops idle --pid 42
l="$(log_file "$tmp")"
[[ "$(jq -r '.from' "$l")" == "null" ]] || fail "transition-log-first-from-null: from=$(jq -r '.from' "$l")"
[[ "$(jq -r '.changed' "$l")" == "true" ]] || fail "transition-log-first-from-null: changed should be true"
rm -rf "$tmp"
pass "transition-log-first-from-null"

# --- transition-log: a state change records both states ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops idle --pid 42
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
l="$(log_file "$tmp")"
[[ "$(wc -l < "$l" | tr -d ' ')" == "2" ]] || fail "transition-log-records-both-states: expected two lines"
last="$(tail -1 "$l")"
[[ "$(jq -r '.from' <<<"$last")" == "idle" ]] || fail "transition-log-records-both-states: from"
[[ "$(jq -r '.to' <<<"$last")" == "working" ]] || fail "transition-log-records-both-states: to"
[[ "$(jq -r '.changed' <<<"$last")" == "true" ]] || fail "transition-log-records-both-states: changed"
rm -rf "$tmp"
pass "transition-log-records-both-states"

# --- transition-log: a repeat records changed false ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
l="$(log_file "$tmp")"
[[ "$(wc -l < "$l" | tr -d ' ')" == "2" ]] || fail "transition-log-repeat-changed-false: expected two lines"
last="$(tail -1 "$l")"
[[ "$(jq -r '.changed' <<<"$last")" == "false" ]] || fail "transition-log-repeat-changed-false: changed"
[[ "$(jq -r '.from' <<<"$last")" == "working" ]] || fail "transition-log-repeat-changed-false: from"
rm -rf "$tmp"
pass "transition-log-repeat-changed-false"

# --- transition-log: a phase-only change is recorded ---
# `since` deliberately ignores a phase change; the log must not.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
run_state "$tmp" Cyclops working --bead ah-f9c --phase ci --pid 42
l="$(log_file "$tmp")"
last="$(tail -1 "$l")"
[[ "$(jq -r '.phase' <<<"$last")" == "ci" ]] || fail "transition-log-phase-only: phase"
[[ "$(jq -r '.changed' <<<"$last")" == "false" ]] || fail "transition-log-phase-only: state and bead did not change"
rm -rf "$tmp"
pass "transition-log-phase-only"

# --- transition-log: an unwritable log still writes the state file ---
# The log is deliberately unable to fail the script: the state file is what the fleet view reads.
tmp="$(new_fixture)"
mkdir -p "$tmp/.cerebro/state/transitions.jsonl"    # a directory where the log wants to be
set +e
out="$(run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "transition-log-never-fatal: exit $status"
[[ -z "$out" ]] || fail "transition-log-never-fatal: printed '$out'"
f="$(state_file "$tmp" Cyclops)"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "transition-log-never-fatal: state file not written"
rm -rf "$tmp"
pass "transition-log-never-fatal"

# --- transition-log: concurrent writes leave whole lines ---
# Distinct agent names, two calls each: 20 concurrent appends to the one shared log, with no two
# writers sharing a state file (that file's own write is per-agent and not what this pins).
tmp="$(new_fixture)"
# The names come from the roster rather than being spelled out, so a consumer with its own fleet
# runs this case too (ah-qled.5.1). Ten of them: 20 concurrent appends is what this pins.
# From the FIXTURE's roster, not this checkout's. The intent is unchanged - the names come from a
# roster rather than being spelled out, so a consumer with its own fleet runs this case too - but
# this checkout is now a consumer itself with four implementers on it (cb-i3l.3), and ten distinct
# names is what twenty concurrent appends need. The fixture declares no fleet, so it answers with
# the shipped table.
concurrent_names="$("$tmp/.claude/cerebro/scripts/roster" --implementers | sed -n 1,10p)"
[[ "$(printf '%s\n' "$concurrent_names" | grep -c .)" == "10" ]] \
  || fail "transition-log-concurrent: the roster names fewer than ten implementers"
for n in $concurrent_names; do
  ( run_state "$tmp" "$n" working --bead ah-f9c --phase build --pid 42
    run_state "$tmp" "$n" idle --pid 42 ) &
done
wait
l="$(log_file "$tmp")"
[[ "$(wc -l < "$l" | tr -d ' ')" == "20" ]] || fail "transition-log-concurrent: expected 20 lines, got $(wc -l < "$l")"
jq -c . "$l" >/dev/null || fail "transition-log-concurrent: a line does not parse as JSON"
rm -rf "$tmp"
pass "transition-log-concurrent"

# --- transition-log: an oversized log is rotated, once ---
tmp="$(new_fixture)"
mkdir -p "$tmp/.cerebro/state"
l="$(log_file "$tmp")"
head -c 6000000 /dev/zero | tr '\0' 'x' > "$l"
run_state "$tmp" Cyclops working --bead ah-f9c --phase build --pid 42
[[ -f "$tmp/.cerebro/state/transitions.1.jsonl" ]] || fail "transition-log-rotates: no rotated generation"
[[ "$(wc -l < "$l" | tr -d ' ')" == "1" ]] || fail "transition-log-rotates: new log should hold one line"
# One generation only: rotating again replaces it rather than accumulating.
head -c 6000000 /dev/zero | tr '\0' 'x' > "$l"
run_state "$tmp" Cyclops idle --pid 42
[[ ! -f "$tmp/.cerebro/state/transitions.2.jsonl" ]] || fail "transition-log-rotates: a second generation was kept"
rm -rf "$tmp"
pass "transition-log-rotates"

# --- ah-hiib.3: `waiting` - a role that has ended its turn and expects to be woken ---

# --- waiting-records-a-wake-at ---
tmp="$(new_fixture)"
run_state "$tmp" Moira waiting --wake-in 600 --pid 42
f="$(state_file "$tmp" Moira)"
[[ -f "$f" ]] || fail "waiting-records-a-wake-at: no state file written"
state="$(jq -r '.state' "$f")"; [[ "$state" == "waiting" ]] || fail "waiting-records-a-wake-at: state=$state"
wake_at="$(jq -r '.wake_at' "$f")"
[[ "$wake_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "waiting-records-a-wake-at: wake_at=$wake_at"
since="$(jq -r '.since' "$f")"
# 600 seconds later than `since`, to the second: the script computes one from the other.
since_epoch="$(python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$since")"
wake_epoch="$(python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$wake_at")"
[[ $((wake_epoch - since_epoch)) -eq 600 ]] \
  || fail "waiting-records-a-wake-at: wake_at is $((wake_epoch - since_epoch))s after since, wanted 600"
rm -rf "$tmp"
pass "waiting-records-a-wake-at"

# --- a-state-that-is-not-waiting-has-a-null-wake-at ---
tmp="$(new_fixture)"
run_state "$tmp" Moira working --phase sweep --pid 42
[[ "$(jq -r '.wake_at' "$(state_file "$tmp" Moira)")" == "null" ]] \
  || fail "a-state-that-is-not-waiting-has-a-null-wake-at: wake_at was set"
rm -rf "$tmp"
pass "a-state-that-is-not-waiting-has-a-null-wake-at"

# --- waiting-from-an-implementer-records-a-wake-at ---
# Since cb-1or.1 `waiting` is every agent's end-of-pass state, an implementer's included: it
# ends a pass with nothing in flight, so there is no bead on the file.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops waiting --wake-in 600 --pid 42
f="$(state_file "$tmp" Cyclops)"
[[ -f "$f" ]] || fail "waiting-from-an-implementer-records-a-wake-at: no state file was written"
[[ "$(jq -r '.state' "$f")" == "waiting" ]] \
  || fail "waiting-from-an-implementer-records-a-wake-at: state was $(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "null" ]] \
  || fail "waiting-from-an-implementer-records-a-wake-at: bead was $(jq -r '.bead' "$f")"
since="$(jq -r '.since' "$f")"
wake_at="$(jq -r '.wake_at' "$f")"
since_epoch="$(python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$since")"
wake_epoch="$(python3 -c 'import sys,calendar,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")))' "$wake_at")"
[[ $((wake_epoch - since_epoch)) -eq 600 ]] \
  || fail "waiting-from-an-implementer-records-a-wake-at: wake_at is $((wake_epoch - since_epoch))s after since, wanted 600"
rm -rf "$tmp"
pass "waiting-from-an-implementer-records-a-wake-at"

# --- waiting-without-wake-in-is-refused ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Moira waiting --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "waiting-without-wake-in-is-refused: expected exit 2, got $status"
grep -q -- "--wake-in is required with waiting" <<<"$out" \
  || fail "waiting-without-wake-in-is-refused: wrong message, got: $out"
[[ -f "$(state_file "$tmp" Moira)" ]] && fail "waiting-without-wake-in-is-refused: file was written"
# The same refusal holds for an implementer, which may write `waiting` since cb-1or.1.
set +e
out="$(run_state "$tmp" Cyclops waiting --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "waiting-without-wake-in-is-refused: expected exit 2 for an implementer, got $status"
grep -q -- "--wake-in is required with waiting" <<<"$out" \
  || fail "waiting-without-wake-in-is-refused: wrong message for an implementer, got: $out"
[[ -f "$(state_file "$tmp" Cyclops)" ]] && fail "waiting-without-wake-in-is-refused: implementer file was written"
rm -rf "$tmp"
pass "waiting-without-wake-in-is-refused"

# --- wake-in-is-refused-without-waiting ---
tmp="$(new_fixture)"
set +e
out="$(run_state "$tmp" Moira idle --wake-in 600 --pid 1 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "wake-in-is-refused-without-waiting: expected exit 2, got $status"
grep -q -- "--wake-in is only valid with waiting" <<<"$out" \
  || fail "wake-in-is-refused-without-waiting: wrong message, got: $out"
rm -rf "$tmp"
pass "wake-in-is-refused-without-waiting"

# --- wake-in-must-be-a-positive-integer ---
tmp="$(new_fixture)"
for bad in 0 -5 soon 6.5; do
  set +e
  out="$(run_state "$tmp" Moira waiting --wake-in "$bad" --pid 1 2>&1)"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "wake-in-must-be-a-positive-integer: '$bad' gave exit $status"
done
rm -rf "$tmp"
pass "wake-in-must-be-a-positive-integer"

# --- waiting-is-logged-like-any-other-state ---
tmp="$(new_fixture)"
run_state "$tmp" Moira working --phase sweep --pid 42
run_state "$tmp" Moira waiting --wake-in 300 --pid 42
line="$(tail -1 "$tmp/.cerebro/state/transitions.jsonl")"
[[ "$(jq -r '.to' <<<"$line")" == "waiting" ]] || fail "waiting-is-logged-like-any-other-state: to=$(jq -r '.to' <<<"$line")"
[[ "$(jq -r '.from' <<<"$line")" == "working" ]] || fail "waiting-is-logged-like-any-other-state: from wrong"
[[ "$(jq -r '.changed' <<<"$line")" == "true" ]] || fail "waiting-is-logged-like-any-other-state: changed wrong"
rm -rf "$tmp"
pass "waiting-is-logged-like-any-other-state"

# --- a-failing-log-jq-writes-no-line-and-does-not-fail-the-write ---
#
# The log block is `{ ... } 2>/dev/null || true', so errexit is suspended inside it: an unchecked
# `line="$(jq ...)"' that failed would leave `line' empty and the append after it would write a
# blank line. `--argjson' appears at the log invocation and nowhere else in the script, so a stub
# that fails on it and execs the real jq otherwise fails exactly that one call (cb-ge0).
real_jq="$(command -v jq)"
tmp="$(new_fixture)"
stub_dir="$work_dir/argjson-stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == --argjson ]] && exit 127; done
exec "$real_jq" "\$@"
STUB
chmod +x "$stub_dir/jq"
status=0
PATH="$stub_dir:$PATH" run_state "$tmp" Rogue working --bead cb-ge0 --phase build --pid 42 || status=$?
[[ $status -eq 0 ]] || fail "a-failing-log-jq: agent-state exited $status - an unwritable log must never bring an agent down"
f="$(state_file "$tmp" Rogue)"
[[ -f "$f" ]] || fail "a-failing-log-jq: no state file written"
[[ "$(jq -r '.state' "$f")" == "working" ]] || fail "a-failing-log-jq: state=$(jq -r '.state' "$f")"
[[ "$(jq -r '.bead' "$f")" == "cb-ge0" ]] || fail "a-failing-log-jq: bead=$(jq -r '.bead' "$f")"
[[ "$(jq -r '.pid' "$f")" == "42" ]] || fail "a-failing-log-jq: pid=$(jq -r '.pid' "$f")"
# Either outcome is correct - no log at all, or a log with no blank line in it. Asserting the file
# is absent would pin an implementation detail rather than the behaviour.
log="$tmp/.cerebro/state/transitions.jsonl"
if [[ -f "$log" ]] && grep -q '^$' "$log"; then
  fail "a-failing-log-jq: a blank line was appended to transitions.jsonl"
fi
rm -rf "$tmp" "$stub_dir"
pass "a-failing-log-jq-writes-no-line-and-does-not-fail-the-write"

suite_passed
