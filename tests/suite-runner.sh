#!/usr/bin/env bash
#
# Proves `scripts/suite-runner' - the one bash-suite loop, called by both `tests/gate' and CI - keeps
# the output contract cb-8cn was filed for: every suite is named on stdout BEFORE it starts, so a
# stalled suite is identifiable by name without a `ps'; a passing suite stays quiet; a failing
# suite's output is replayed in full; the remaining suites still run; and the GitHub annotations
# CI used to emit inline appear only under $GITHUB_ACTIONS.
#
# Fixtures only. This file is itself under `tests/*.sh', so pointing the script at `tests/' from in
# here would run the whole gate's suite set from inside one suite, recursively, until the harness
# killed it. Every case builds fake suites under $work_dir/suites instead.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/suite-runner.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

cd "$repo_root"

script="$repo_root/scripts/suite-runner"
[[ -f "$script" ]] || fail "scripts/suite-runner does not exist"
[[ -x "$script" ]] || fail "scripts/suite-runner is not executable"

# One call per case. `set +e' around it because a failing suite makes the script exit 1, which is an
# answer here and not a failure of the test. GITHUB_ACTIONS is unset so the suite passes when it is
# itself run from inside CI, where GitHub sets it to `true' for every job.
#
# Every ordinary call goes through `run', which prepends `--log-dir' under $work_dir. That is not
# tidiness: this suite runs inside the gate, and the gate runs `suite-runner' too. With the
# cwd-relative default both would use the same log root, and the inner run's prune-at-start would
# delete the outer run's own directory while it is still being written to. `run_raw' is the same
# call without the flag, for the two cases that must exercise the default and the fallback. The
# handful of cases that call the script inline rather than through `run' - they need stdout and
# stderr apart, or GITHUB_ACTIONS set - pass the same flag for the same reason.
out=""
status=0
run() {
  set +e
  out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logdir" "$@" 2>&1)"
  status=$?
  set -e
}

run_raw() {
  set +e
  out="$(env -u GITHUB_ACTIONS bash "$script" "$@" 2>&1)"
  status=$?
  set -e
}

# --- 1. usage, and a directory with no suites in it ---

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "no argument: expected exit 2, got $status
$out"
grep -q '^usage: ' <<<"$out" || fail "no argument: no usage line
$out"

run "$work_dir/suites" "$work_dir/suites"
[[ $status -eq 2 ]] || fail "two arguments: expected exit 2, got $status
$out"

mkdir -p "$work_dir/suites"
printf 'not a directory\n' >"$work_dir/a-file"
run "$work_dir/a-file"
[[ $status -eq 2 ]] || fail "a non-directory: expected exit 2, got $status
$out"
grep -q "$work_dir/a-file" <<<"$out" || fail "a non-directory: the refusal does not name the path
$out"

run "$work_dir/suites"
[[ $status -eq 0 ]] || fail "an empty directory: expected exit 0, got $status
$out"
[[ "$(tail -n 1 <<<"$out")" == "all suites passed" ]] || fail "an empty directory: last line is not 'all suites passed'
$out"

pass "no argument, a non-directory and an empty directory answer as documented"

# --- the fixture suites, in glob order a, b, c ---
#
# Named so `*.sh' sorts them a, b, c: case 3 asserts that c still ran after b failed, which only
# means anything if b comes first.

printf '#!/usr/bin/env bash\necho "ok - a"\nexit 0\n' >"$work_dir/suites/a-pass.sh"
printf '#!/usr/bin/env bash\necho "ok - c"\nexit 0\n' >"$work_dir/suites/c-pass.sh"

# --- 2. every suite is named before it runs, and a passing suite says nothing ---

run "$work_dir/suites"
[[ $status -eq 0 ]] || fail "two passing suites: expected exit 0, got $status
$out"
grep -qF -- "-- $work_dir/suites/a-pass.sh" <<<"$out" || fail "no '-- <path>' line for a-pass.sh
$out"
grep -qF -- "ok   $work_dir/suites/a-pass.sh (" <<<"$out" || fail "no 'ok   <path> (' line for a-pass.sh
$out"
grep -qF -- "ok   $work_dir/suites/c-pass.sh (" <<<"$out" || fail "no 'ok   <path> (' line for c-pass.sh
$out"

# The whole point of the bead: the name is on the terminal before the suite starts, so a stall is
# read as "hung in a-pass.sh" rather than "the gate is hung".
named="$(line_of_fixed "$out" "-- $work_dir/suites/a-pass.sh")"
result="$(line_of_fixed "$out" "ok   $work_dir/suites/a-pass.sh (")"
[[ -n "$named" && -n "$result" && $named -lt $result ]] || fail "a-pass.sh is named at line $named, after its result at line $result
$out"

grep -q '^ok - a$' <<<"$out" && fail "a passing suite's own output was printed
$out"
[[ "$(tail -n 1 <<<"$out")" == "all suites passed" ]] || fail "two passing suites: last line is not 'all suites passed'
$out"

pass "every suite is named before it runs and a passing suite is quiet"

# --- 3. a failing suite's output is replayed, and the remaining suites still run ---

printf '#!/usr/bin/env bash\necho "b stdout"\necho "b stderr" >&2\nexit 1\n' >"$work_dir/suites/b-fail.sh"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logdir" "$work_dir/suites" 2>/dev/null)"
status=$?
err="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logdir" "$work_dir/suites" 2>&1 >/dev/null)"
set -e
[[ $status -eq 1 ]] || fail "one failing suite: expected exit 1, got $status
$out"
grep -q '^b stdout$' <<<"$out" || fail "the failing suite's stdout was not replayed
$out"
grep -q '^b stderr$' <<<"$out" || fail "the failing suite's stderr was not replayed
$out"
grep -qF -- "FAIL $work_dir/suites/b-fail.sh (" <<<"$out" || fail "no 'FAIL <path> (' line for b-fail.sh
$out"
grep -qF -- "FAILED: $work_dir/suites/b-fail.sh" <<<"$err" || fail "stderr does not carry the FAILED summary
$err"
grep -q "FAILED:.*a-pass\.sh" <<<"$err" && fail "the FAILED summary names a suite that passed
$err"
grep -qF -- "ok   $work_dir/suites/c-pass.sh (" <<<"$out" || fail "c-pass.sh did not run after b-fail.sh failed
$out"

# The replay comes after every result line, not inline. Suites run at the same time now, so a
# multi-line replay printed while another suite is still reporting would interleave with it; the
# parent replays each failing suite once every job has ended, in glob order.
grep -qF -- "== output of $work_dir/suites/b-fail.sh ==" <<<"$out" \
  || fail "no '== output of <path> ==' header for b-fail.sh
$out"
header="$(line_of_fixed "$out" "== output of $work_dir/suites/b-fail.sh ==")"
last_result="$(grep -nE '^(ok   |FAIL )' <<<"$out" | tail -n 1 | cut -d: -f1)"
[[ -n "$header" && -n "$last_result" && $header -gt $last_result ]] || fail "b-fail.sh's replay is at line $header, before the last result line at $last_result
$out"
replay="$(line_of "$out" '^b stdout$')"
[[ -n "$replay" && -n "$header" && $replay -gt $header ]] || fail "b-fail.sh: 'b stdout' at line $replay does not follow its header at $header
$out"

pass "a failing suite's output is replayed and the remaining suites still run"

# --- 4. the GitHub annotations appear under GITHUB_ACTIONS and nowhere else ---

set +e
out="$(GITHUB_ACTIONS=true bash "$script" --log-dir "$work_dir/logdir" "$work_dir/suites" 2>/dev/null)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "under GITHUB_ACTIONS: expected exit 1, got $status
$out"
grep -qF -- "::group::$work_dir/suites/b-fail.sh" <<<"$out" || fail "no ::group:: for b-fail.sh
$out"
grep -q '^::endgroup::$' <<<"$out" || fail "no ::endgroup::
$out"
grep -qF -- "::error file=$work_dir/suites/b-fail.sh::$work_dir/suites/b-fail.sh failed" <<<"$out" \
  || fail "no ::error annotation for b-fail.sh
$out"

# The group wraps the replay, which is all a group can wrap now: the live -- / ok / FAIL lines of
# several suites interleave, and a group cannot span them.
group="$(line_of_fixed "$out" "::group::$work_dir/suites/b-fail.sh")"
header="$(line_of_fixed "$out" "== output of $work_dir/suites/b-fail.sh ==")"
endgroup="$(line_of "$out" '^::endgroup::$')"
error="$(line_of_fixed "$out" "::error file=$work_dir/suites/b-fail.sh::")"
[[ -n "$group" && -n "$header" && $group -lt $header ]] || fail "::group:: for b-fail.sh is at line $group, after its replay header at $header
$out"
[[ -n "$error" && -n "$endgroup" && $error -gt $endgroup ]] || fail "::error for b-fail.sh is at line $error, before ::endgroup:: at $endgroup
$out"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logdir" "$work_dir/suites" 2>/dev/null)"
set -e
grep -q '^::' <<<"$out" && fail "an annotation was printed outside GitHub Actions
$out"

pass "GitHub annotations appear under GITHUB_ACTIONS and nowhere else"

# --- 5. --jobs N, and what it refuses ---
#
# The option exists so the gate can be told how many suites to run at once; the default is one per
# processor, which is not assertable here (the number is the machine's). What is assertable is that
# a bad N is refused rather than rounded to something, and that `--jobs 1' - one suite at a time -
# still produces exactly the contract every other N produces.

for bad in 0 x -1 1.5; do
  run --jobs "$bad" "$work_dir/suites"
  [[ $status -eq 2 ]] || fail "--jobs $bad: expected exit 2, got $status
$out"
  grep -q '^usage: ' <<<"$out" || fail "--jobs $bad: no usage line
$out"
done

run --jobs "$work_dir/suites"
[[ $status -eq 2 ]] || fail "--jobs with no number: expected exit 2, got $status
$out"
grep -q '^usage: ' <<<"$out" || fail "--jobs with no number: no usage line
$out"

run --jobs 2
[[ $status -eq 2 ]] || fail "--jobs 2 with no directory: expected exit 2, got $status
$out"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logdir" --jobs 1 "$work_dir/suites" 2>/dev/null)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "--jobs 1: expected exit 1, got $status
$out"
for f in a-pass c-pass; do
  grep -qF -- "ok   $work_dir/suites/$f.sh (" <<<"$out" || fail "--jobs 1: no 'ok' line for $f.sh
$out"
done
grep -qF -- "FAIL $work_dir/suites/b-fail.sh (" <<<"$out" || fail "--jobs 1: no 'FAIL' line for b-fail.sh
$out"
grep -qF -- "== output of $work_dir/suites/b-fail.sh ==" <<<"$out" || fail "--jobs 1: no replay for b-fail.sh
$out"

pass "--jobs refuses a bad count and --jobs 1 keeps the contract"

# --- 6. suites actually run at the same time ---
#
# The point of the bead. Two suites that sleep 2s each finish in under 4s at --jobs 2 and take at
# least 4s at --jobs 1. Their own directory, so cases 1-5 are untouched by the sleeping.

mkdir -p "$work_dir/slow"
printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' >"$work_dir/slow/d-slow.sh"
printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' >"$work_dir/slow/e-slow.sh"

SECONDS=0
run --jobs 2 "$work_dir/slow"
parallel_secs=$SECONDS
[[ $status -eq 0 ]] || fail "--jobs 2 on two sleeping suites: expected exit 0, got $status
$out"
for f in d-slow e-slow; do
  grep -qF -- "ok   $work_dir/slow/$f.sh (" <<<"$out" || fail "--jobs 2: no 'ok' line for $f.sh
$out"
done
[[ $parallel_secs -lt 4 ]] || fail "--jobs 2 on two 2s suites took ${parallel_secs}s - they did not overlap
$out"

SECONDS=0
run --jobs 1 "$work_dir/slow"
serial_secs=$SECONDS
[[ $status -eq 0 ]] || fail "--jobs 1 on two sleeping suites: expected exit 0, got $status
$out"
[[ $serial_secs -ge 4 ]] || fail "--jobs 1 on two 2s suites took ${serial_secs}s - it did not serialise
$out"

# At --jobs 1 at most one name is ahead of its result, which is the property a stalled run relies on.
named="$(line_of_fixed "$out" "-- $work_dir/slow/e-slow.sh")"
first_result="$(line_of_fixed "$out" "ok   $work_dir/slow/d-slow.sh (")"
[[ -n "$named" && -n "$first_result" && $named -gt $first_result ]] || fail "--jobs 1: e-slow.sh is named at line $named, before d-slow.sh's result at $first_result
$out"

pass "suites run N at a time, and --jobs 1 is one at a time"

# --- 7. a suite that is killed rather than exiting is a failure ---
#
# The harness's ten-minute output ceiling and a stray `kill' both end a suite without an exit
# status for the runner to read. A missing result must read as a failure with an empty replay -
# never as a pass, which is how a killed gate would otherwise merge.

mkdir -p "$work_dir/killed"
printf '#!/usr/bin/env bash\nkill -9 $$\n' >"$work_dir/killed/f-killed.sh"

run "$work_dir/killed"
[[ $status -eq 1 ]] || fail "a killed suite: expected exit 1, got $status
$out"
grep -qF -- "FAIL $work_dir/killed/f-killed.sh (" <<<"$out" || fail "a killed suite has no 'FAIL' line
$out"
grep -qF -- "== output of $work_dir/killed/f-killed.sh ==" <<<"$out" || fail "a killed suite has no replay header
$out"

# And the path the header actually names: the job that was running the suite is killed too, so no
# result is ever written. `cat' of a missing .rc prints nothing, which is not 0.
mkdir -p "$work_dir/vanished"
printf '#!/usr/bin/env bash\nkill -9 $PPID\nsleep 5\n' >"$work_dir/vanished/g-vanished.sh"

run "$work_dir/vanished"
[[ $status -eq 1 ]] || fail "a suite whose job vanished: expected exit 1, got $status
$out"
grep -qF -- "== output of $work_dir/vanished/g-vanished.sh ==" <<<"$out" \
  || fail "a suite whose job vanished has no replay header
$out"
[[ "$(tail -n 1 <<<"$out")" != "all suites passed" ]] || fail "a suite whose job vanished was reported as a pass
$out"

pass "a suite that is killed is reported failed, not passed"

# --- 8. --log-dir is parsed, in either order with --jobs ---
#
# cb-kf8: every run keeps each suite's full output on disk, because the only record of a red gate
# used to be terminal scrollback and the next run is what destroyed it.

mkdir -p "$work_dir/green"
printf '#!/usr/bin/env bash\necho "ok - a"\nexit 0\n' >"$work_dir/green/a-pass.sh"
printf '#!/usr/bin/env bash\necho "ok - c"\nexit 0\n' >"$work_dir/green/c-pass.sh"

run_raw --log-dir "$work_dir/l1" "$work_dir/green"
[[ $status -eq 0 ]] || fail "--log-dir before the directory: expected exit 0, got $status
$out"

run_raw --jobs 2 --log-dir "$work_dir/l2" "$work_dir/green"
[[ $status -eq 0 ]] || fail "--jobs then --log-dir: expected exit 0, got $status
$out"

run_raw --log-dir "$work_dir/l3" --jobs 2 "$work_dir/green"
[[ $status -eq 0 ]] || fail "--log-dir then --jobs: expected exit 0, got $status
$out"

run_raw --log-dir
[[ $status -eq 2 ]] || fail "--log-dir with no value: expected exit 2, got $status
$out"
grep -q '^usage: ' <<<"$out" || fail "--log-dir with no value: no usage line
$out"

pass "--log-dir is accepted before and after --jobs, and a missing value is a usage error"

# --- 9. every suite's output is kept, named after the suite ---
#
# Passing suites included: a flake that passed on this run is exactly the cb-qrm shape - failed
# once inside the gate, passed on every re-run - and its passing output is what you need.

run_raw --log-dir "$work_dir/logs" "$work_dir/suites"
[[ $status -eq 1 ]] || fail "a run over a, b, c: expected exit 1, got $status
$out"

runs="$(ls "$work_dir/logs")"
[[ "$(wc -l <<<"$runs" | tr -d ' ')" == 1 ]] || fail "expected exactly one run directory, got:
$runs"
[[ "$runs" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "the run directory is named '$runs', not <YYYYmmdd>-<HHMMSS>-<pid>"

for f in a-pass.sh c-pass.sh b-fail.sh; do
  [[ -f "$work_dir/logs/$runs/$f.log" ]] || fail "no durable log for $f at $work_dir/logs/$runs/$f.log
$(ls "$work_dir/logs/$runs")"
done
grep -q '^ok - a$' "$work_dir/logs/$runs/a-pass.sh.log" || fail "a-pass.sh.log does not hold a-pass.sh's own output
$(cat "$work_dir/logs/$runs/a-pass.sh.log")"
grep -q '^ok - c$' "$work_dir/logs/$runs/c-pass.sh.log" || fail "c-pass.sh.log does not hold c-pass.sh's own output
$(cat "$work_dir/logs/$runs/c-pass.sh.log")"
grep -q '^b stdout$' "$work_dir/logs/$runs/b-fail.sh.log" || fail "b-fail.sh.log does not hold b-fail.sh's stdout
$(cat "$work_dir/logs/$runs/b-fail.sh.log")"
grep -q '^b stderr$' "$work_dir/logs/$runs/b-fail.sh.log" || fail "b-fail.sh.log does not hold b-fail.sh's stderr
$(cat "$work_dir/logs/$runs/b-fail.sh.log")"

pass "every suite's full output is kept under the log directory, passing and failing alike"

# --- 10. a red run says where the logs are; a green one does not ---

set +e
err="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/logs2" "$work_dir/suites" 2>&1 >/dev/null)"
set -e
grep -qF -- "logs kept (last 3 runs): $work_dir/logs2/" <<<"$err" \
  || fail "a red run does not name the log directory on stderr
$err"

run_raw --log-dir "$work_dir/logs3" "$work_dir/green"
[[ $status -eq 0 ]] || fail "a green run: expected exit 0, got $status
$out"
! grep -q 'logs kept' <<<"$out" || fail "a green run said something about logs
$out"

pass "a red run names the log directory on stderr and a green run says nothing about logs"

# --- 11. the log root keeps three runs ---
#
# The run directory carries $$, so five sequential runs produce five distinct names even inside one
# second: the case must not depend on the clock advancing.

created=""
i=0
while [[ $i -lt 5 ]]; do
  run_raw --log-dir "$work_dir/retain" "$work_dir/green"
  [[ $status -eq 0 ]] || fail "retention run $i: expected exit 0, got $status
$out"
  newest="$(ls "$work_dir/retain" | tail -n 1)"
  created="$created"$'\n'"$newest"
  i=$((i+1))
done

left="$(ls "$work_dir/retain")"
[[ "$(wc -l <<<"$left" | tr -d ' ')" == 3 ]] || fail "after five runs the log root holds:
$left"
want="$(grep -v '^$' <<<"$created" | sort | tail -n 3)"
[[ "$left" == "$want" ]] || fail "the three kept runs are not the three newest.
kept:
$left
wanted:
$want"

pass "the log root keeps the three newest runs and deletes the rest"

# --- 12. a log root that cannot be created falls back and does not fail the run ---
#
# Logging is a convenience and must never be the reason a green gate is red.

printf 'not a directory\n' >"$work_dir/blocked"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/blocked/logs" "$work_dir/green" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "an unwritable log root over passing suites: expected exit 0, got $status
$out"
grep -q 'cannot write logs to' <<<"$out" || fail "an unwritable log root did not warn on stderr
$out"
! grep -q 'logs kept' <<<"$out" || fail "the fallback named a durable log directory
$out"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" --log-dir "$work_dir/blocked/logs" "$work_dir/suites" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "an unwritable log root over a failing suite: expected exit 1, got $status
$out"
grep -q '^b stdout$' <<<"$out" || fail "the fallback lost the failing suite's replay
$out"
! grep -q 'logs kept' <<<"$out" || fail "the fallback named a durable log directory on a red run
$out"

pass "a log directory that cannot be created warns on stderr and the run still answers"

# --- 13. the default log root is .cerebro/state/suite-logs, relative to the caller's cwd ---
#
# A subshell `cd', so this suite's own directory is not moved.

mkdir -p "$work_dir/cwd-probe"
set +e
out="$(cd "$work_dir/cwd-probe" && env -u GITHUB_ACTIONS bash "$script" "$work_dir/green" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "the default log root: expected exit 0, got $status
$out"
default_root="$work_dir/cwd-probe/.cerebro/state/suite-logs"
[[ -d "$default_root" ]] || fail "no log root at $default_root
$out"
runs="$(ls "$default_root")"
[[ -f "$default_root/$runs/a-pass.sh.log" ]] || fail "no a-pass.sh.log under $default_root/$runs
$(ls "$default_root/$runs" 2>/dev/null)"

pass "with no --log-dir, logs land under .cerebro/state/suite-logs in the caller's working directory"
suite_passed
