#!/usr/bin/env bash
#
# Proves scripts/state-write.sh renames a whole file over the target or leaves the target alone
# (ah-za5i), and that two processes writing one target never share a scratch path - the fault that
# killed eleven sessions with `mv: rename ... No such file or directory' when `scripts/agent-state'
# and `scripts/agent-turn' each wrote the same state file through a FIXED `<file>.tmp'.
#
# It needs no consumer fixture: it sources the library under test directly and calls the function,
# with every file it touches under `$work_dir`.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/state-write.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

source "$repo_root/scripts/state-write.sh"

# --- the-temp-name-carries-the-writing-pid ---
# The case this bead exists to buy, and it must run two separate PROCESSES: `$$' in a subshell is
# still the parent's pid, so two subshells of one shell would prove nothing.
mv_log="$work_dir/mv-calls.log"
stub_dir="$work_dir/mv-stub"
mkdir -p "$stub_dir"
# The real mv is resolved HERE, before the stub shadows it: a pass-through that cannot find its
# tool makes the case green for the wrong reason (tests/agent-turn.sh's jq stub records the same).
real_mv="$(command -v mv)"
[[ -n "$real_mv" ]] || fail "the-temp-name-carries-the-writing-pid: no real mv to pass through to"
cat > "$stub_dir/mv" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*) ;; *) printf '%s\n' "\$a" >> "$mv_log"; break ;; esac
done
exec "$real_mv" "\$@"
STUB
chmod +x "$stub_dir/mv"

harness="$work_dir/harness.sh"
cat > "$harness" <<HARNESS
#!/usr/bin/env bash
set -euo pipefail
source "$repo_root/scripts/state-write.sh"
cerebro_state_write_atomic "\$1" printf 'x'
HARNESS
chmod +x "$harness"

target="$work_dir/pid.json"
PATH="$stub_dir:$PATH" "$harness" "$target"
PATH="$stub_dir:$PATH" "$harness" "$target"
[[ "$(wc -l < "$mv_log" | tr -d ' ')" == "2" ]] || fail "the-temp-name-carries-the-writing-pid: expected 2 mv calls, got $(cat "$mv_log")"
first="$(sed -n 1p "$mv_log")"
second="$(sed -n 2p "$mv_log")"
[[ "$first" =~ ^"$target"\.[0-9]+\.tmp$ ]] || fail "the-temp-name-carries-the-writing-pid: '$first' is not <target>.<pid>.tmp"
[[ "$second" =~ ^"$target"\.[0-9]+\.tmp$ ]] || fail "the-temp-name-carries-the-writing-pid: '$second' is not <target>.<pid>.tmp"
[[ "$first" != "$second" ]] || fail "the-temp-name-carries-the-writing-pid: two processes shared '$first'"
pass "the-temp-name-carries-the-writing-pid"

# --- writes-what-the-command-produced ---
t="$work_dir/happy.json"
status=0
cerebro_state_write_atomic "$t" printf '{"a":1}' || status=$?
[[ $status -eq 0 ]] || fail "writes-what-the-command-produced: returned $status"
[[ "$(cat "$t")" == '{"a":1}' ]] || fail "writes-what-the-command-produced: holds '$(cat "$t")'"
pass "writes-what-the-command-produced"

# --- it-creates-a-target-that-does-not-exist-yet ---
t="$work_dir/fresh.json"
[[ ! -e "$t" ]] || fail "it-creates-a-target-that-does-not-exist-yet: fixture already exists"
cerebro_state_write_atomic "$t" printf 'new' || fail "it-creates-a-target-that-does-not-exist-yet: returned non-zero"
[[ "$(cat "$t")" == "new" ]] || fail "it-creates-a-target-that-does-not-exist-yet: holds '$(cat "$t")'"
pass "it-creates-a-target-that-does-not-exist-yet"

# --- a-failing-command-leaves-the-target-alone ---
t="$work_dir/keep.json"
printf 'original' > "$t"
status=0
cerebro_state_write_atomic "$t" bash -c 'printf half; exit 1' || status=$?
[[ $status -eq 1 ]] || fail "a-failing-command-leaves-the-target-alone: returned $status"
[[ "$(cat "$t")" == "original" ]] || fail "a-failing-command-leaves-the-target-alone: holds '$(cat "$t")'"
pass "a-failing-command-leaves-the-target-alone"

# --- a-failing-command-leaves-no-temp-behind ---
d="$work_dir/no-litter"
mkdir -p "$d"
t="$d/f.json"
printf 'original' > "$t"
cerebro_state_write_atomic "$t" bash -c 'printf half; exit 1' || true
leftovers="$(find "$d" -name '*.tmp')"
[[ -z "$leftovers" ]] || fail "a-failing-command-leaves-no-temp-behind: left behind: $leftovers"
pass "a-failing-command-leaves-no-temp-behind"

# --- a-failing-rename-leaves-no-temp-behind ---
d="$work_dir/mv-fails"
mkdir -p "$d"
t="$d/f.json"
printf 'original' > "$t"
fail_mv_dir="$work_dir/mv-fail-stub"
mkdir -p "$fail_mv_dir"
printf '#!/usr/bin/env bash
exit 1
' > "$fail_mv_dir/mv"
chmod +x "$fail_mv_dir/mv"
status=0
PATH="$fail_mv_dir:$PATH" cerebro_state_write_atomic "$t" printf 'x' || status=$?
[[ $status -eq 1 ]] || fail "a-failing-rename-leaves-no-temp-behind: returned $status"
[[ "$(cat "$t")" == "original" ]] || fail "a-failing-rename-leaves-no-temp-behind: the target changed"
leftovers="$(find "$d" -name '*.tmp')"
[[ -z "$leftovers" ]] || fail "a-failing-rename-leaves-no-temp-behind: left behind: $leftovers"
pass "a-failing-rename-leaves-no-temp-behind"

# --- it-prints-nothing-of-its-own ---
# On success and on both failure paths: a library sourced into a `UserPromptSubmit' hook may not
# print, since that hook's stdout is added to the model's context.
t="$work_dir/quiet.json"
out="$( { cerebro_state_write_atomic "$t" printf 'x'; } 2>&1 )"
[[ -z "$out" ]] || fail "it-prints-nothing-of-its-own: success printed '$out'"
out="$( { cerebro_state_write_atomic "$t" bash -c 'exit 1' || true; } 2>&1 )"
[[ -z "$out" ]] || fail "it-prints-nothing-of-its-own: a failing command printed '$out'"
out="$( { PATH="$fail_mv_dir:$PATH" cerebro_state_write_atomic "$t" printf 'x' || true; } 2>&1 )"
[[ -z "$out" ]] || fail "it-prints-nothing-of-its-own: a failing rename printed '$out'"
pass "it-prints-nothing-of-its-own"

suite_passed
