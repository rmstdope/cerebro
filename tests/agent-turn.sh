#!/usr/bin/env bash
#
# Proves scripts/agent-turn writes and clears the state file's `turn_ended` field (cb-ykz.1), and
# that it does so without ever failing or printing to stdout - both load-bearing, because the script
# is wired as a `Stop` and a `UserPromptSubmit` hook: a non-zero exit from the second erases the
# navigator's prompt, and its stdout is added to the model's context.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/agent-turn.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

new_fixture() {
  consumer_new "$(fixture_name)" --link roster agent-state consumer-root agent-turn
}

run_state() {
  local tmp="$1"; shift
  "$tmp/.claude/cerebro/scripts/agent-state" "$@"
}

# agent-turn takes its name from the environment, exactly as agent-asking does.
run_turn() {
  local tmp="$1" name="$2"; shift 2
  CEREBRO_AGENT_NAME="$name" "$tmp/.claude/cerebro/scripts/agent-turn" "$@"
}

state_file() {
  printf '%s/.cerebro/state/%s.state.json' "$1" "$2"
}

iso_z='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# --- stamps-turn-ended ---
# Compare field by field rather than the whole file's bytes: jq may reorder keys.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(jq -S '{state, phase, bead, since, phase_since, pid}' "$f")"
out="$(run_turn "$tmp" Cyclops ended)"
[[ -z "$out" ]] || fail "stamps-turn-ended: wrote to stdout: $out"
ended="$(jq -r '.turn_ended' "$f")"
grep -qE "$iso_z" <<<"$ended" || fail "stamps-turn-ended: turn_ended is not ISO-8601 Z: $ended"
after="$(jq -S '{state, phase, bead, since, phase_since, pid}' "$f")"
[[ "$before" == "$after" ]] || fail "stamps-turn-ended: other fields changed:
$before
--
$after"
rm -rf "$tmp"
pass "stamps-turn-ended"

# --- resumed-clears-it ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
run_turn "$tmp" Cyclops ended
before="$(jq -S '{state, phase, bead, since, phase_since, pid}' "$f")"
out="$(run_turn "$tmp" Cyclops resumed)"
[[ -z "$out" ]] || fail "resumed-clears-it: wrote to stdout: $out"
[[ "$(jq -r '.turn_ended' "$f")" == "null" ]] \
  || fail "resumed-clears-it: turn_ended=$(jq -r '.turn_ended' "$f")"
after="$(jq -S '{state, phase, bead, since, phase_since, pid}' "$f")"
[[ "$before" == "$after" ]] || fail "resumed-clears-it: other fields changed"
rm -rf "$tmp"
pass "resumed-clears-it"

# --- resumed-on-a-clear-file-is-a-no-op ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
out="$(run_turn "$tmp" Cyclops resumed)"
[[ -z "$out" ]] || fail "resumed-on-a-clear-file-is-a-no-op: wrote to stdout: $out"
first="$(cat "$f")"
out="$(run_turn "$tmp" Cyclops resumed)"
[[ -z "$out" ]] || fail "resumed-on-a-clear-file-is-a-no-op: wrote to stdout: $out"
[[ "$first" == "$(cat "$f")" ]] || fail "resumed-on-a-clear-file-is-a-no-op: the file changed"
rm -rf "$tmp"
pass "resumed-on-a-clear-file-is-a-no-op"

# --- a-second-ended-overwrites ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
out="$(run_turn "$tmp" Cyclops ended)"
[[ -z "$out" ]] || fail "a-second-ended-overwrites: wrote to stdout: $out"
first="$(jq -r '.turn_ended' "$f")"
sleep 1.1
out="$(run_turn "$tmp" Cyclops ended)"
[[ -z "$out" ]] || fail "a-second-ended-overwrites: wrote to stdout: $out"
second="$(jq -r '.turn_ended' "$f")"
grep -qE "$iso_z" <<<"$second" || fail "a-second-ended-overwrites: not ISO-8601 Z: $second"
[[ "$second" > "$first" ]] || fail "a-second-ended-overwrites: $second is not later than $first"
rm -rf "$tmp"
pass "a-second-ended-overwrites"

# --- agent-state-clears-it ---
# The same fact as tests/agent-state.sh's own case, asserted from this side because this is where
# the pair is a contract rather than one script's output.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
out="$(run_turn "$tmp" Cyclops ended)"
[[ -z "$out" ]] || fail "agent-state-clears-it: wrote to stdout: $out"
[[ "$(jq -r '.turn_ended' "$f")" != "null" ]] || fail "agent-state-clears-it: nothing was stamped"
run_state "$tmp" Cyclops working --bead cb-1 --phase gate --pid 42
[[ "$(jq -r '.turn_ended' "$f")" == "null" ]] \
  || fail "agent-state-clears-it: turn_ended=$(jq -r '.turn_ended' "$f")"
rm -rf "$tmp"
pass "agent-state-clears-it"

# --- no-agent-name-does-nothing ---
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
status=0
out="$(env -u CEREBRO_AGENT_NAME "$tmp/.claude/cerebro/scripts/agent-turn" ended)" || status=$?
[[ $status -eq 0 ]] || fail "no-agent-name-does-nothing: exited $status"
[[ -z "$out" ]] || fail "no-agent-name-does-nothing: wrote to stdout: $out"
[[ "$before" == "$(cat "$f")" ]] || fail "no-agent-name-does-nothing: the file changed"
rm -rf "$tmp"
pass "no-agent-name-does-nothing"

# --- no-state-file-does-nothing ---
# It never creates one: a file invented here would carry no `state`, and both readers would report
# a row no agent has ever written.
tmp="$(new_fixture)"
f="$(state_file "$tmp" Cyclops)"
status=0
out="$(run_turn "$tmp" Cyclops ended)" || status=$?
[[ $status -eq 0 ]] || fail "no-state-file-does-nothing: exited $status"
[[ -z "$out" ]] || fail "no-state-file-does-nothing: wrote to stdout: $out"
[[ ! -e "$f" ]] || fail "no-state-file-does-nothing: a state file was created"
rm -rf "$tmp"
pass "no-state-file-does-nothing"

# --- an-unparsable-file-is-left-alone ---
tmp="$(new_fixture)"
mkdir -p "$tmp/.cerebro/state"
f="$(state_file "$tmp" Cyclops)"
printf '{ not json' > "$f"
status=0
out="$(run_turn "$tmp" Cyclops ended)" || status=$?
[[ $status -eq 0 ]] || fail "an-unparsable-file-is-left-alone: exited $status"
[[ -z "$out" ]] || fail "an-unparsable-file-is-left-alone: wrote to stdout: $out"
[[ "$(cat "$f")" == '{ not json' ]] || fail "an-unparsable-file-is-left-alone: contents changed"
[[ ! -e "$f.tmp" ]] || fail "an-unparsable-file-is-left-alone: a .tmp file was left behind"
rm -rf "$tmp"
pass "an-unparsable-file-is-left-alone"

# --- an-unknown-mode-exits-zero ---
# The deliberate divergence from scripts/agent-asking: exit 2 from a `UserPromptSubmit` hook erases
# the navigator's prompt, and exit 2 from `Stop` refuses to let the session stop.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
status=0
out="$(run_turn "$tmp" Cyclops frobnicate 2>"$tmp/err")" || status=$?
[[ $status -eq 0 ]] || fail "an-unknown-mode-exits-zero: exited $status"
[[ -z "$out" ]] || fail "an-unknown-mode-exits-zero: wrote to stdout: $out"
grep -q 'usage' "$tmp/err" || fail "an-unknown-mode-exits-zero: no usage line on stderr"
[[ "$before" == "$(cat "$f")" ]] || fail "an-unknown-mode-exits-zero: the file changed"
rm -rf "$tmp"
pass "an-unknown-mode-exits-zero"

# --- no-mode-at-all-exits-zero ---
tmp="$(new_fixture)"
status=0
out="$(run_turn "$tmp" Cyclops 2>/dev/null)" || status=$?
[[ $status -eq 0 ]] || fail "no-mode-at-all-exits-zero: exited $status"
[[ -z "$out" ]] || fail "no-mode-at-all-exits-zero: wrote to stdout: $out"
rm -rf "$tmp"
pass "no-mode-at-all-exits-zero"

# --- a-failing-jq-leaves-no-tmp-behind ---
# The redirection creates the tmp file before jq runs, so a failing jq would otherwise leave litter
# in a directory both fleet views poll every five seconds.
tmp="$(new_fixture)"
run_state "$tmp" Cyclops working --bead cb-1 --phase build --pid 42
f="$(state_file "$tmp" Cyclops)"
before="$(cat "$f")"
stub_dir="$(mktemp -d "$work_dir/jq-stub-XXXXXX")"
# The real jq is resolved HERE, before the stub shadows it, rather than assumed to be at a path:
# a pass-through that cannot find jq would make agent-turn's parse guard exit 0 early and this
# case pass without ever reaching the write path it exists to test - green for the wrong reason.
real_jq="$(command -v jq)"
[[ -n "$real_jq" ]] || fail "a-failing-jq-leaves-no-tmp-behind: no real jq to pass through to"
cat > "$stub_dir/jq" <<STUB
#!/usr/bin/env bash
# Parses (so the guard passes), then fails on the write.
case "\$*" in
  *turn_ended*) exit 1 ;;
  *) exec "$real_jq" "\$@" ;;
esac
STUB
chmod +x "$stub_dir/jq"
status=0
out="$(CEREBRO_AGENT_NAME=Cyclops PATH="$stub_dir:$PATH" \
        "$tmp/.claude/cerebro/scripts/agent-turn" ended)" || status=$?
[[ $status -eq 0 ]] || fail "a-failing-jq-leaves-no-tmp-behind: exited $status"
[[ -z "$out" ]] || fail "a-failing-jq-leaves-no-tmp-behind: wrote to stdout: $out"
[[ "$before" == "$(cat "$f")" ]] || fail "a-failing-jq-leaves-no-tmp-behind: the file changed"
leftovers="$(find "$tmp/.cerebro/state" -name '*.tmp' 2>/dev/null)"
[[ -z "$leftovers" ]] || fail "a-failing-jq-leaves-no-tmp-behind: left behind: $leftovers"
rm -rf "$tmp" "$stub_dir"
pass "a-failing-jq-leaves-no-tmp-behind"

suite_passed
