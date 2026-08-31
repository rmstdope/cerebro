#!/usr/bin/env bash
#
# Proves scripts/request-review classifies the outcome of asking for GitHub's automatic review
# (cb-6uc). Its exit status is what decides whether an implementer may merge on a review it
# obtained for itself, so the safe direction is the whole design: an outright refusal from GitHub
# exits 3, and ANY failure the script does not recognise exits 1 - never 3, because 3 is what
# authorises a merge without a person.
#
# `gh` is stubbed on PATH, the way tests/launch-preflight.sh stubs `claude`: the real thing would
# need a network, a token and a pull request. The stubs print their refusals to STDERR, which is
# where `gh` puts its errors - a stub printing to stdout would let a script that only reads stdout
# pass here and exit 1 on every genuine refusal in the field.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/request-review.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir, cleanup_add and its trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/request-review"

# --- the stub -------------------------------------------------------------------------------------
#
# link_utils <dir>  ->  symlinks the external utilities the script needs into <dir>, so a case can
# run with <dir> as its WHOLE PATH. That is what makes the "gh missing from PATH" case honest: with
# /usr/bin on PATH it would find the runner's own `gh` (ubuntu-latest ships one at /usr/bin/gh) and
# test nothing - or worse, edit a real pull request 42. `bash` is here because the stub's own
# `#!/usr/bin/env bash` resolves `bash` through PATH, and `grep` because the script matches with it.
link_utils() {
  local dir="$1" util
  for util in grep bash; do
    ln -sf "$(command -v "$util")" "$dir/$util"
  done
}

# stub_gh <exit status> [message on stderr]  ->  echoes a directory to put at the head of PATH.
#
# Each case gets its own, under $work_dir: suites run in parallel and a shared stub would let one
# case read another's recorded argv. The stub records its whole argument list, one call per line, in
# `<dir>/argv` - a file whose ABSENCE is itself an assertion in the --print-refusals case.
stub_gh() {
  local status="$1" message="${2:-}" dir
  dir="$(mktemp -d "$work_dir/stub.XXXXXX")"
  cat > "$dir/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$dir/argv"
[[ -n "$message" ]] && echo "$message" >&2
exit $status
STUB
  chmod +x "$dir/gh"
  link_utils "$dir"
  echo "$dir"
}

# run_with <stub dir> <args...>  ->  the script's exit status in \$run_status, its stderr in
# \$run_stderr and its stdout in \$run_stdout. PATH is the stub directory and NOTHING else, so no
# `gh` on the machine running the suite can ever be reached.
run_with() {
  local dir="$1"; shift
  run_stdout=""; run_stderr=""; run_status=0
  local err_file="$work_dir/stderr.$$"
  run_stdout="$(PATH="$dir" "$script" "$@" 2>"$err_file")" || run_status=$?
  run_stderr="$(cat "$err_file")"
  rm -f "$err_file"
}

# --- a successful request exits 0 and asks @copilot on that PR ------------------------------------
#
# The argv is compared whole and in order rather than one grep per token: the order is the property
# a second implementation would get wrong (tests/agent-cli.sh makes the same argument).
dir="$(stub_gh 0)"
run_with "$dir" 42
[[ "$run_status" -eq 0 ]] || fail "a successful request should exit 0, got $run_status"
recorded="$(cat "$dir/argv")"
[[ "$recorded" = "pr edit 42 --add-reviewer @copilot" ]] ||
  fail "expected 'pr edit 42 --add-reviewer @copilot', got '$recorded'"
pass "a successful request exits 0 and asks @copilot on that PR"

# --- the two refusals GitHub has actually given ---------------------------------------------------
dir="$(stub_gh 1 'Reviews may only be requested from collaborators')"
run_with "$dir" 42
[[ "$run_status" -eq 3 ]] || fail "the collaborators refusal should exit 3, got $run_status"
pass "the collaborators refusal exits 3"

dir="$(stub_gh 1 "Could not resolve user with login 'copilot'")"
run_with "$dir" 42
[[ "$run_status" -eq 3 ]] || fail "the unresolved-login refusal should exit 3, got $run_status"
pass "the unresolved-login refusal exits 3"

# `gh` quotes the login it was given, and that has been seen as both 'copilot' and 'Copilot'.
dir="$(stub_gh 1 "could not resolve user with login 'Copilot'")"
run_with "$dir" 42
[[ "$run_status" -eq 3 ]] || fail "a refusal in another case should still exit 3, got $run_status"
pass "a refusal is matched whatever its case"

# --- the safe direction ---------------------------------------------------------------------------
#
# These three are what the script exists for. Each asserts inequality with 3 as well as equality
# with 1, so a regression names itself rather than reading as an off-by-one.
dir="$(stub_gh 1 'error connecting to api.github.com: dial tcp: lookup api.github.com: no such host')"
run_with "$dir" 42
[[ "$run_status" -ne 3 ]] || fail "an unrecognised gh failure must never exit 3 - that authorises a merge"
[[ "$run_status" -eq 1 ]] || fail "an unrecognised gh failure should exit 1, got $run_status"
pass "an unrecognised gh failure exits 1, not 3"

empty_dir="$(mktemp -d "$work_dir/nogh.XXXXXX")"
link_utils "$empty_dir"    # everything the script needs EXCEPT gh, and PATH is this directory alone
run_with "$empty_dir" 42
[[ "$run_status" -ne 3 ]] || fail "gh missing from PATH must never exit 3"
[[ "$run_status" -eq 1 ]] || fail "gh missing from PATH should exit 1, got $run_status"
pass "gh missing from PATH exits 1, not 3"

dir="$(stub_gh 1 'error connecting to api.github.com: no such host')"
run_with "$dir" 42
grep -F -q -- 'no such host' <<< "$run_stderr" ||
  fail "an unrecognised failure should put gh's own output on stderr, got '$run_stderr'"
pass "an unrecognised failure puts gh's own output on stderr"

# --- usage ----------------------------------------------------------------------------------------
dir="$(stub_gh 0)"
run_with "$dir"
[[ "$run_status" -eq 2 ]] || fail "no argument should exit 2, got $run_status"
pass "no argument exits 2"

dir="$(stub_gh 0)"
run_with "$dir" 42 43
[[ "$run_status" -eq 2 ]] || fail "two arguments should exit 2, got $run_status"
pass "two arguments exit 2"

# --- the refusal patterns are readable, and reading them calls nothing -----------------------------
dir="$(stub_gh 0)"
run_with "$dir" --print-refusals
[[ "$run_status" -eq 0 ]] || fail "--print-refusals should exit 0, got $run_status"
lines="$(grep -c . <<< "$run_stdout")"
[[ "$lines" -eq 2 ]] || fail "--print-refusals should print two patterns, got $lines line(s)"
[[ ! -e "$dir/argv" ]] || fail "--print-refusals must not call gh"
pass "--print-refusals prints the patterns and never calls gh"

suite_passed
