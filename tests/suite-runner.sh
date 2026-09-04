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

# The default log root, which no call in this suite may write to. Recorded before any case runs and
# checked again at the end: the outer run creates its directory and prunes once, both before it
# launches any suite (scripts/suite-runner:120-147), so this set does not change while this suite
# runs - unless this suite changes it. That is the whole failure cb-kf8 was diagnosed from, and it
# is cheaper to detect here, by name, than in eight unrelated suites.
default_log_root="$repo_root/.cerebro/state/suite-logs"
default_runs_before="$(ls "$default_log_root" 2>/dev/null || true)"

# Every call to the script goes through `run', including the ones that need the two streams apart
# or GITHUB_ACTIONS set - those two needs are what used to drive calls out of a helper, and both
# are now things `run' can do.
#
# `run' prepends `--log-dir "$work_dir/logdir"' unless the call already carries a `--log-dir' of
# its own. That is the invariant the whole gate depends on and the reason the helper exists: this
# suite runs inside the gate, the gate runs `suite-runner' too (tests/gate:51, with no --log-dir),
# and with the cwd-relative default both would use $repo_root/.cerebro/state/suite-logs - where the
# inner run's prune-at-start (scripts/suite-runner:120-147, keep_runs=3) deletes the outer run's
# directory while it is still being written to. cb-kf8 spent a gate run and its diagnosis on that,
# reported as eight unrelated suites failing on a missing file. The guard at the end of this file
# is what now catches it directly.
#
# After a call:
#   $status  the exit status
#   $out     stdout alone
#   $err     stderr alone
#   $both    the two concatenated, stdout first - what the old merged `2>&1' capture gave any
#            assertion that only asks whether a line is present somewhere. Concatenation is not
#            interleaving, and no assertion in this file needs interleaving; the ones that care
#            which stream carried a line use $out or $err.
#
# A leading `--ci' runs the script with GITHUB_ACTIONS=true instead of unset. It is consumed by
# `run' and never reaches the script, which knows only --jobs and --log-dir
# (scripts/suite-runner:78). It must come first, and `run' refuses it anywhere else rather than
# passing it through as a directory argument.
out=""
err=""
both=""
status=0
run() {
  local ci=""
  if [[ "${1:-}" == "--ci" ]]; then
    ci=yes
    shift
  fi

  local a has_log_dir=""
  for a in "$@"; do
    if [[ "$a" == "--ci" ]]; then
      fail "run: --ci must be the first argument"
    fi
    if [[ "$a" == "--log-dir" ]]; then
      has_log_dir=yes
    fi
  done

  # Never expanded while empty: "${args[@]}" on an empty array is an unbound-variable error under
  # `set -u' in bash 3.2, which is the bash macOS ships. It cannot be empty - either the caller
  # brought a --log-dir or the two elements below were added.
  local -a args=()
  if [[ -z "$has_log_dir" ]]; then
    args+=(--log-dir "$work_dir/logdir")
  fi
  args+=("$@")

  # Every call carries a CEREBRO_PROTECTED_STATE_DIR under $work_dir unless the caller set one in
  # the environment for that call, for the --log-dir paragraph's reason (cb-xhu.1): this suite runs
  # inside the gate, the outer run exports the REAL protected directory, and an inner call that
  # inherited it would be asserting against the navigator's own live logs.
  local guard="${CEREBRO_PROTECTED_STATE_DIR-$work_dir/protected}"

  local out_file="$work_dir/run.out" err_file="$work_dir/run.err"
  set +e
  if [[ -n "$ci" ]]; then
    CEREBRO_PROTECTED_STATE_DIR="$guard" GITHUB_ACTIONS=true \
      bash "$script" "${args[@]}" >"$out_file" 2>"$err_file"
  else
    CEREBRO_PROTECTED_STATE_DIR="$guard" \
      env -u GITHUB_ACTIONS bash "$script" "${args[@]}" >"$out_file" 2>"$err_file"
  fi
  status=$?
  set -e

  out="$(cat "$out_file")"
  err="$(cat "$err_file")"
  both="$(cat "$out_file" "$err_file")"
}

# --- 1. usage, and a directory with no suites in it ---

# Inline, not through `run': this case is the no-argument refusal, and `run' would give it a
# --log-dir. It writes no logs, so the guard at the end of the file is unaffected.
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
$both"

mkdir -p "$work_dir/suites"
printf 'not a directory\n' >"$work_dir/a-file"
run "$work_dir/a-file"
[[ $status -eq 2 ]] || fail "a non-directory: expected exit 2, got $status
$both"
grep -q "$work_dir/a-file" <<<"$both" || fail "a non-directory: the refusal does not name the path
$both"

run "$work_dir/suites"
[[ $status -eq 0 ]] || fail "an empty directory: expected exit 0, got $status
$both"
[[ "$(tail -n 1 <<<"$out")" == "all suites passed" ]] || fail "an empty directory: last line is not 'all suites passed'
$both"

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
$both"
grep -qF -- "-- $work_dir/suites/a-pass.sh" <<<"$both" || fail "no '-- <path>' line for a-pass.sh
$both"
grep -qF -- "ok   $work_dir/suites/a-pass.sh (" <<<"$both" || fail "no 'ok   <path> (' line for a-pass.sh
$both"
grep -qF -- "ok   $work_dir/suites/c-pass.sh (" <<<"$both" || fail "no 'ok   <path> (' line for c-pass.sh
$both"

# The whole point of the bead: the name is on the terminal before the suite starts, so a stall is
# read as "hung in a-pass.sh" rather than "the gate is hung".
named="$(line_of_fixed "$both" "-- $work_dir/suites/a-pass.sh")"
result="$(line_of_fixed "$both" "ok   $work_dir/suites/a-pass.sh (")"
[[ -n "$named" && -n "$result" && $named -lt $result ]] || fail "a-pass.sh is named at line $named, after its result at line $result
$both"

grep -q '^ok - a$' <<<"$both" && fail "a passing suite's own output was printed
$both"
[[ "$(tail -n 1 <<<"$out")" == "all suites passed" ]] || fail "two passing suites: last line is not 'all suites passed'
$both"

pass "every suite is named before it runs and a passing suite is quiet"

# --- 3. a failing suite's output is replayed, and the remaining suites still run ---

printf '#!/usr/bin/env bash\necho "b stdout"\necho "b stderr" >&2\nexit 1\n' >"$work_dir/suites/b-fail.sh"

run "$work_dir/suites"
[[ $status -eq 1 ]] || fail "one failing suite: expected exit 1, got $status
$both"
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

run --ci "$work_dir/suites"
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

run "$work_dir/suites"
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
$both"
  grep -q '^usage: ' <<<"$both" || fail "--jobs $bad: no usage line
$both"
done

run --jobs "$work_dir/suites"
[[ $status -eq 2 ]] || fail "--jobs with no number: expected exit 2, got $status
$both"
grep -q '^usage: ' <<<"$both" || fail "--jobs with no number: no usage line
$both"

run --jobs 2
[[ $status -eq 2 ]] || fail "--jobs 2 with no directory: expected exit 2, got $status
$both"

run --jobs 1 "$work_dir/suites"
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
# The point of the bead that made the runner parallel (cb-x05), and the property is that the two
# suites' lifetimes OVERLAP - not that their total elapsed time falls under a threshold. Elapsed
# time is a proxy, and this is the one case in the gate whose subject is the gate's own scheduler
# while being run by it, alongside one suite per processor. cb-1h8: each fixture records the second
# it started and the second it ended, and the assertion is on those four numbers.
#
# The recording alone would not be enough, and the review of cb-1h8 is why this says so: load
# lengthens the sleep but it also delays a fork, so two RECORDED windows could still miss each
# other on a saturated machine - the same direction as the sighting this bead came from. So each
# fixture writes its start, then WAITS for its sibling's start before sleeping, bounded so a serial
# run still terminates. Overlap at --jobs 2 is then a fact the fixtures create rather than a
# measurement of the scheduler, and no assertion here depends on how busy the machine is. At
# --jobs 1 the first fixture waits out the bound and the second finds the mark already there, so
# the windows still cannot touch.
#
# Their own directory, so cases 1-5 are untouched by the sleeping.

mkdir -p "$work_dir/slow"
marks="$work_dir/marks"
# `sleep 1' in an integer loop, not `sleep 0.1': bash 3.2 is the floor and a whole second is what
# both platforms' sleep certainly take. The bound is what a serial run pays, once.
for f in d-slow e-slow; do
  other=e-slow
  # `if', not `[[ ... ]] && ...': the pair returns 1 when it does not match, and this suite runs
  # `set -euo pipefail'. See .cerebro/traps.md.
  if [[ "$f" == e-slow ]]; then other=d-slow; fi
  printf '#!/usr/bin/env bash\nmkdir -p "%s"\ndate +%%s >"%s/%s.start"\nw=0\nwhile [ $w -lt 5 ] && [ ! -f "%s/%s.start" ]; do sleep 1; w=$((w+1)); done\nsleep 2\ndate +%%s >"%s/%s.end"\nexit 0\n' \
    "$marks" "$marks" "$f" "$marks" "$other" "$marks" "$f" >"$work_dir/slow/$f.sh"
done

# The four recorded seconds, as $ds $de $es $ee, and a one-line summary for a failure message.
# `date +%s' is what bash 3.2 and the coreutils macOS ships can both give; sub-second resolution
# is not available and is not needed against a 2-second sleep.
windows=""
read_windows() {
  local f
  for f in d-slow e-slow; do
    [[ -f "$marks/$f.start" && -f "$marks/$f.end" ]] \
      || fail "$1: $f.sh recorded no window under $marks
$(ls "$marks" 2>/dev/null)
$both"
  done
  ds="$(cat "$marks/d-slow.start")"; de="$(cat "$marks/d-slow.end")"
  es="$(cat "$marks/e-slow.start")"; ee="$(cat "$marks/e-slow.end")"
  windows="d-slow $ds..$de, e-slow $es..$ee"
}

# Two windows overlap when the later start is strictly before the earlier end. Sequential suites
# can only touch at a boundary - e-slow starts when d-slow has already ended - so the strict
# comparison reads a serial run as no overlap however the seconds truncate.
overlapping() {
  local later_start="$ds" earlier_end="$de"
  # `if', not `[[ ... ]] && ...': a `&&' pair that does not match returns 1, and .cerebro/traps.md
  # is about exactly that status reaching somewhere it was not meant to.
  if [[ $es -gt $later_start ]]; then later_start="$es"; fi
  if [[ $ee -lt $earlier_end ]]; then earlier_end="$ee"; fi
  [[ $later_start -lt $earlier_end ]]
}

rm -rf "$marks"
run --jobs 2 "$work_dir/slow"
[[ $status -eq 0 ]] || fail "--jobs 2 on two sleeping suites: expected exit 0, got $status
$both"
for f in d-slow e-slow; do
  grep -qF -- "ok   $work_dir/slow/$f.sh (" <<<"$both" || fail "--jobs 2: no 'ok' line for $f.sh
$both"
done
read_windows "--jobs 2"
overlapping || fail "--jobs 2: the two suites did not overlap ($windows)
$both"

rm -rf "$marks"
run --jobs 1 "$work_dir/slow"
[[ $status -eq 0 ]] || fail "--jobs 1 on two sleeping suites: expected exit 0, got $status
$both"
read_windows "--jobs 1"
! overlapping || fail "--jobs 1: the two suites overlapped ($windows) - it did not serialise
$both"

# At --jobs 1 at most one name is ahead of its result, which is the property a stalled run relies on.
named="$(line_of_fixed "$both" "-- $work_dir/slow/e-slow.sh")"
first_result="$(line_of_fixed "$both" "ok   $work_dir/slow/d-slow.sh (")"
[[ -n "$named" && -n "$first_result" && $named -gt $first_result ]] || fail "--jobs 1: e-slow.sh is named at line $named, before d-slow.sh's result at $first_result
$both"

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
$both"
grep -qF -- "FAIL $work_dir/killed/f-killed.sh (" <<<"$both" || fail "a killed suite has no 'FAIL' line
$both"
grep -qF -- "== output of $work_dir/killed/f-killed.sh ==" <<<"$both" || fail "a killed suite has no replay header
$both"

# And the path the header actually names: the job that was running the suite is killed too, so no
# result is ever written. `cat' of a missing .rc prints nothing, which is not 0.
mkdir -p "$work_dir/vanished"
printf '#!/usr/bin/env bash\nkill -9 $PPID\nsleep 5\n' >"$work_dir/vanished/g-vanished.sh"

run "$work_dir/vanished"
[[ $status -eq 1 ]] || fail "a suite whose job vanished: expected exit 1, got $status
$both"
grep -qF -- "== output of $work_dir/vanished/g-vanished.sh ==" <<<"$both" \
  || fail "a suite whose job vanished has no replay header
$both"
[[ "$(tail -n 1 <<<"$out")" != "all suites passed" ]] || fail "a suite whose job vanished was reported as a pass
$both"

pass "a suite that is killed is reported failed, not passed"

# --- 8. --log-dir is parsed, in either order with --jobs ---
#
# cb-kf8: every run keeps each suite's full output on disk, because the only record of a red gate
# used to be terminal scrollback and the next run is what destroyed it.

mkdir -p "$work_dir/green"
printf '#!/usr/bin/env bash\necho "ok - a"\nexit 0\n' >"$work_dir/green/a-pass.sh"
printf '#!/usr/bin/env bash\necho "ok - c"\nexit 0\n' >"$work_dir/green/c-pass.sh"

run --log-dir "$work_dir/l1" "$work_dir/green"
[[ $status -eq 0 ]] || fail "--log-dir before the directory: expected exit 0, got $status
$both"

run --jobs 2 --log-dir "$work_dir/l2" "$work_dir/green"
[[ $status -eq 0 ]] || fail "--jobs then --log-dir: expected exit 0, got $status
$both"

run --log-dir "$work_dir/l3" --jobs 2 "$work_dir/green"
[[ $status -eq 0 ]] || fail "--log-dir then --jobs: expected exit 0, got $status
$both"

run --log-dir
[[ $status -eq 2 ]] || fail "--log-dir with no value: expected exit 2, got $status
$both"
grep -q '^usage: ' <<<"$both" || fail "--log-dir with no value: no usage line
$both"

pass "--log-dir is accepted before and after --jobs, and a missing value is a usage error"

# --- 9. every suite's output is kept, named after the suite ---
#
# Passing suites included: a flake that passed on this run is exactly the cb-qrm shape - failed
# once inside the gate, passed on every re-run - and its passing output is what you need.

run --log-dir "$work_dir/logs" "$work_dir/suites"
[[ $status -eq 1 ]] || fail "a run over a, b, c: expected exit 1, got $status
$both"

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

run --log-dir "$work_dir/logs2" "$work_dir/suites"
grep -qF -- "logs kept (last 3 runs): $work_dir/logs2/" <<<"$err" \
  || fail "a red run does not name the log directory on stderr
$err"

run --log-dir "$work_dir/logs3" "$work_dir/green"
[[ $status -eq 0 ]] || fail "a green run: expected exit 0, got $status
$both"
! grep -q 'logs kept' <<<"$both" || fail "a green run said something about logs
$both"

pass "a red run names the log directory on stderr and a green run says nothing about logs"

# --- 11. the log root keeps three runs ---
#
# The run directory carries $$, so five sequential runs produce five distinct names even inside one
# second: the case must not depend on the clock advancing.

created=""
i=0
while [[ $i -lt 5 ]]; do
  run --log-dir "$work_dir/retain" "$work_dir/green"
  [[ $status -eq 0 ]] || fail "retention run $i: expected exit 0, got $status
$both"
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

# --- 12. a run never deletes its own directory, whatever else is in the log root ---
#
# cb-1h8. The prune globs the root and drops the lexically first entries, and the run's own
# directory is in that glob. The name is <YYYYmmdd>-<HHMMSS>-<pid>, so two runs inside one second
# are ordered by pid as a STRING, where 10000 sorts before 9999 - and a gate running one suite per
# processor forks hard enough to cross that boundary. A run that sorted ahead of three siblings
# deleted the directory it was about to write every log into, then failed every suite with
# "No such file or directory" and exited 1. That was read once as a timing flake and cost a gate
# cycle plus a baseline run against origin/main (docs/retrospectives/cb-4z6.1.md).
#
# Four siblings named 2999... sort after any real run, so the run under test is lexically first and
# is what the old prune removed. Nothing here depends on a pid: the ordering is forced by name.

mkdir -p "$work_dir/selfprune"
i=0
while [[ $i -lt 4 ]]; do
  mkdir -p "$work_dir/selfprune/29991231-235959-$i"
  i=$((i+1))
done

run --log-dir "$work_dir/selfprune" "$work_dir/green"
[[ $status -eq 0 ]] || fail "a run whose directory sorts first: expected exit 0, got $status
$both"

# `|| true': grep exits 1 on no match, and a non-zero command substitution in an assignment is
# fatal under `set -e'. See .cerebro/traps.md.
mine="$(ls "$work_dir/selfprune" | grep -v '^2999' || true)"
[[ -n "$mine" ]] || fail "the run deleted its own log directory
$(ls "$work_dir/selfprune")
$both"
# Exactly one, before $mine is used as a path: two lines would make the next assertion read a
# two-line path and report "holds no log", which is not what would have happened.
[[ "$(grep -c . <<<"$mine" | tr -d ' ')" == 1 ]] \
  || fail "the log root holds more than one run of this suite's own:
$mine"
[[ -f "$work_dir/selfprune/$mine/a-pass.sh.log" ]] \
  || fail "the run's own directory survived but holds no log for a-pass.sh
$(ls "$work_dir/selfprune/$mine" 2>/dev/null)"

left="$(ls "$work_dir/selfprune")"
[[ "$(wc -l <<<"$left" | tr -d ' ')" == 3 ]] \
  || fail "the log root should still hold three runs, and holds:
$left"

pass "a run keeps its own log directory and prunes only older ones"

# --- 13. a log root that cannot be created falls back and does not fail the run ---
#
# Logging is a convenience and must never be the reason a green gate is red.

printf 'not a directory\n' >"$work_dir/blocked"

run --log-dir "$work_dir/blocked/logs" "$work_dir/green"
[[ $status -eq 0 ]] || fail "an unwritable log root over passing suites: expected exit 0, got $status
$both"
grep -q 'cannot write logs to' <<<"$both" || fail "an unwritable log root did not warn on stderr
$both"
! grep -q 'logs kept' <<<"$both" || fail "the fallback named a durable log directory
$both"

run --log-dir "$work_dir/blocked/logs" "$work_dir/suites"
[[ $status -eq 1 ]] || fail "an unwritable log root over a failing suite: expected exit 1, got $status
$both"
grep -q '^b stdout$' <<<"$both" || fail "the fallback lost the failing suite's replay
$both"
! grep -q 'logs kept' <<<"$both" || fail "the fallback named a durable log directory on a red run
$both"

pass "a log directory that cannot be created warns on stderr and the run still answers"

# --- 14. the default log root is .cerebro/state/suite-logs, relative to the caller's cwd ---
#
# A subshell `cd', so this suite's own directory is not moved.

mkdir -p "$work_dir/cwd-probe"
# Inline, not through `run': this case exercises the cwd-relative default, which is precisely the
# flag `run' exists to supply. The subshell `cd' puts that default under $work_dir/cwd-probe rather
# than the repository root, so the guard at the end of the file is unaffected.
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

# --- 15. the reported path is absolute, whatever cwd the run was started from ---
#
# The bead (cb-wxr): the log directory is WRITTEN relative to the caller's cwd, which is what gives
# each consumer its own log root, but the line a red run leaves behind is READ from somewhere else
# - an implementer runs the gate in .cerebro/worktrees/<Name> and the reader is in the shared
# checkout. cb-azi lost a flake's only log that way.
#
# Inline with a subshell `cd', not through `run': this case is about the cwd-relative default,
# which is precisely the flag `run' exists to supply, and the `cd' keeps the default root under
# $work_dir so the guard at the end of this file is unaffected.

mkdir -p "$work_dir/cwd-red"
set +e
err="$(cd "$work_dir/cwd-red" && env -u GITHUB_ACTIONS bash "$script" "$work_dir/suites" 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "a red run from another cwd: expected exit 1, got $status
$err"

printed="$(sed -n 's/^logs kept (last 3 runs): //p' <<<"$err")"
[[ -n "$printed" ]] || fail "a red run did not name its log directory
$err"
[[ "$printed" == /* ]] || fail "the reported log directory is not absolute: '$printed'
A reader in another directory cannot find it. See cb-wxr."
[[ -d "$printed" ]] || fail "the reported log directory does not exist when resolved from $PWD: '$printed'"
[[ -f "$printed/b-fail.sh.log" ]] || fail "no b-fail.sh.log under the reported directory '$printed'
$(ls "$printed" 2>/dev/null)"
[[ "$printed" == "$work_dir/cwd-red/.cerebro/state/suite-logs/"* ]] \
  || fail "the reported directory is not under the caller's own log root: '$printed'"

pass "a relative log root is reported as an absolute path that resolves from any working directory"

# --- 16. the fallback names an absolute path too ---
#
# A log root that cannot be created names a directory that does not exist, so it cannot be resolved
# by anything - which is exactly why it has to be printed in full: the reader's only question is
# where the run tried to write.

mkdir -p "$work_dir/cwd-blocked"
printf 'not a directory\n' >"$work_dir/cwd-blocked/blocked"
set +e
both="$(cd "$work_dir/cwd-blocked" && env -u GITHUB_ACTIONS bash "$script" --log-dir blocked/logs "$work_dir/green" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "an unwritable relative log root over passing suites: expected exit 0, got $status
$both"
grep -qF -- "cannot write logs to $work_dir/cwd-blocked/blocked/logs" <<<"$both" \
  || fail "the fallback did not name the log root it could not create as an absolute path
$both"

pass "the log root that could not be created is named as an absolute path"

# --- 17. a suite that writes into the protected directory makes the run red (cb-xhu.1) ---
#
# The rule "every suite builds its fixtures under its own $work_dir" was prose and nothing checked
# it: `tests/launch-refused.sh' wrote 249 false lines into this checkout's own errors.jsonl, the
# file the navigator is sent to by name. The guard is refused at `scripts/jsonl-log.sh'; this is
# where the refusal becomes a red run naming the suite.

mkdir -p "$work_dir/protected" "$work_dir/violating"
cat >"$work_dir/violating/writes.sh" <<EOF
#!/usr/bin/env bash
source "$repo_root/scripts/jsonl-log.sh"
cerebro_jsonl_append "\$CEREBRO_PROTECTED_STATE_DIR/errors.jsonl" '{"x":1}' || true
exit 0
EOF

run "$work_dir/violating"
[[ $status -eq 1 ]] || fail "a violating suite: expected exit 1, got $status
$both"
grep -qF -- "suite-runner: these suites wrote to the fleet's live logs under $work_dir/protected" <<<"$err" \
  || fail "the violation block's first line is missing from stderr
$err"
grep -qF -- "$work_dir/violating/writes.sh -> $work_dir/protected/errors.jsonl" <<<"$err" \
  || fail "the block does not name the suite and the path it tried to write
$err"
grep -qF -- 'the write was refused, and the run is red' <<<"$err" \
  || fail "the block does not say the write was refused
$err"
! grep -q 'all suites passed' <<<"$out" || fail "a violating run still said all suites passed
$out"
[[ ! -e "$work_dir/protected/errors.jsonl" ]] || fail "the guarded write was not refused"
pass "a suite that writes into the protected directory makes the run red and is named"

# --- 18. a violation and a failing suite are both reported ---

mkdir -p "$work_dir/violating-and-red"
cp "$work_dir/violating/writes.sh" "$work_dir/violating-and-red/a-writes.sh"
printf '#!/usr/bin/env bash\necho "boom"\nexit 1\n' >"$work_dir/violating-and-red/b-fails.sh"

run "$work_dir/violating-and-red"
[[ $status -eq 1 ]] || fail "a violation and a failure: expected exit 1, got $status
$both"
grep -q 'FAILED:.*b-fails.sh' <<<"$err" || fail "the failing suite was not named
$err"
grep -qF -- "these suites wrote to the fleet's live logs" <<<"$err" \
  || fail "the violation block is missing when a suite also failed
$err"
pass "a violation and a failing suite are both reported"

# --- 19. a run with no violation still says all suites passed ---

mkdir -p "$work_dir/protected-empty"
run "$work_dir/green"
[[ $status -eq 0 ]] || fail "a clean run: expected exit 0, got $status
$both"
grep -q 'all suites passed' <<<"$out" || fail "a clean run did not say all suites passed
$out"
! grep -q "wrote to the fleet's live logs" <<<"$err" || fail "a clean run printed the violation block
$err"
pass "a run with no violation still says all suites passed"

# --- 20. an empty guard variable turns the guard off ---
#
# `${VAR+set}' rather than `${VAR:-}': an explicitly empty value means "guard off" and the runner
# must not overwrite it with the computed one.

mkdir -p "$work_dir/violating-unguarded"
cat >"$work_dir/violating-unguarded/writes.sh" <<EOF
#!/usr/bin/env bash
source "$repo_root/scripts/jsonl-log.sh"
cerebro_jsonl_append "$work_dir/unguarded-target.jsonl" '{"x":1}' || exit 1
exit 0
EOF
CEREBRO_PROTECTED_STATE_DIR="" run "$work_dir/violating-unguarded"
[[ $status -eq 0 ]] || fail "an empty guard: expected exit 0, got $status
$both"
! grep -q "wrote to the fleet's live logs" <<<"$err" || fail "an empty guard still reported a violation
$err"
[[ -f "$work_dir/unguarded-target.jsonl" ]] || fail "an empty guard refused the write"
pass "an empty guard variable turns the guard off"

default_runs_after="$(ls "$default_log_root" 2>/dev/null || true)"
[[ "$default_runs_after" == "$default_runs_before" ]] || fail "a call in this suite wrote to the default log root at $default_log_root.
Every call must carry --log-dir under \$work_dir; go through \`run', which supplies one.
before:
$default_runs_before
after:
$default_runs_after"
suite_passed
