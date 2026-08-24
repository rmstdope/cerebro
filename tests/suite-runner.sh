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
out=""
status=0
run() {
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
named="$(grep -nF -- "-- $work_dir/suites/a-pass.sh" <<<"$out" | head -n 1 | cut -d: -f1)"
result="$(grep -nF -- "ok   $work_dir/suites/a-pass.sh (" <<<"$out" | head -n 1 | cut -d: -f1)"
[[ $named -lt $result ]] || fail "a-pass.sh is named at line $named, after its result at line $result
$out"

grep -q '^ok - a$' <<<"$out" && fail "a passing suite's own output was printed
$out"
[[ "$(tail -n 1 <<<"$out")" == "all suites passed" ]] || fail "two passing suites: last line is not 'all suites passed'
$out"

pass "every suite is named before it runs and a passing suite is quiet"

# --- 3. a failing suite's output is replayed, and the remaining suites still run ---

printf '#!/usr/bin/env bash\necho "b stdout"\necho "b stderr" >&2\nexit 1\n' >"$work_dir/suites/b-fail.sh"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" "$work_dir/suites" 2>/dev/null)"
status=$?
err="$(env -u GITHUB_ACTIONS bash "$script" "$work_dir/suites" 2>&1 >/dev/null)"
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

named="$(grep -nF -- "-- $work_dir/suites/b-fail.sh" <<<"$out" | head -n 1 | cut -d: -f1)"
replay="$(grep -n '^b stdout$' <<<"$out" | head -n 1 | cut -d: -f1)"
result="$(grep -nF -- "FAIL $work_dir/suites/b-fail.sh (" <<<"$out" | head -n 1 | cut -d: -f1)"
[[ $named -lt $replay && $replay -lt $result ]] || fail "b-fail.sh: name/replay/result out of order ($named, $replay, $result)
$out"

pass "a failing suite's output is replayed and the remaining suites still run"

# --- 4. the GitHub annotations appear under GITHUB_ACTIONS and nowhere else ---

set +e
out="$(GITHUB_ACTIONS=true bash "$script" "$work_dir/suites" 2>/dev/null)"
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

group="$(grep -nF -- "::group::$work_dir/suites/b-fail.sh" <<<"$out" | head -n 1 | cut -d: -f1)"
named="$(grep -nF -- "-- $work_dir/suites/b-fail.sh" <<<"$out" | head -n 1 | cut -d: -f1)"
[[ $group -lt $named ]] || fail "::group:: for b-fail.sh is at line $group, after its name at $named
$out"

set +e
out="$(env -u GITHUB_ACTIONS bash "$script" "$work_dir/suites" 2>/dev/null)"
set -e
grep -q '^::' <<<"$out" && fail "an annotation was printed outside GitHub Actions
$out"

pass "GitHub annotations appear under GITHUB_ACTIONS and nowhere else"
