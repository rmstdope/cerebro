#!/usr/bin/env bash
#
# Proves `tests/lib/consumer.sh` - the one fabricator every bash suite sources for its work
# directory, its `fail`/`pass`, and the two throwaway-consumer shapes the suites actually build.
#
# It exists because the library is the only thing under `tests/` that no other suite can prove:
# every migrated suite is a regression test for the *use* of it, but nothing else asserts what
# `consumer_new` or `consumer_with_submodule` actually build. When a later bead extends the surface,
# this is what keeps it honest.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/consumer-lib.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

# --- fail and pass ------------------------------------------------------------------------------
#
# Every suite exits non-zero at its first failed assertion, which is the whole error protocol here.
# `fail` is run in a subshell so this suite survives asserting about it.
set +e
out="$( ( fail "x" ) 2>&1 )"
status=$?
set -e
[[ $status -eq 1 ]] || fail "fail should exit 1, got $status"
[[ "$out" == "FAIL: x" ]] || fail "fail should print 'FAIL: x' on stderr, got: $out"
[[ "$(pass "y")" == "ok - y" ]] || fail "pass should print 'ok - y', got: $(pass "y")"
pass "fail exits 1 and names the assertion; pass prints an ok line"

# --- suite_passed, and the fabricator the death cases share -----------------------------------------

# fabricate_suite <name> <body> -> the path of a runnable throwaway suite that sources the library.
# The body is written verbatim to a file rather than interpolated into `bash -c', so it may contain
# any quoting - which the death cases in the last section need.
fabricate_suite() {
  local path="$work_dir/$1.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'repo_root=%q\n' "$repo_root"
    printf 'source "$repo_root/tests/lib/consumer.sh"\n'
    printf '%s\n' "$2"
  } > "$path"
  echo "$path"
}

# run_suite <path> -> sets $out (stdout and stderr together) and $status.
run_suite() {
  set +e
  out="$(bash "$1" 2>&1)"
  status=$?
  set -e
}

s="$(fabricate_suite passes 'suite_passed')"
run_suite "$s"
[[ $status -eq 0 ]] || fail "suite_passed: a suite that reaches its end should exit 0, got $status
$out"
[[ "$out" == "$s: all assertions passed" ]] \
  || fail "suite_passed: expected '$s: all assertions passed', got: $out"
pass "suite_passed prints the suite's summary line and exits 0"

# --- reading text without a pipe ------------------------------------------------------------------

text="$(printf 'ARG:--model\nARG:sonnet\nARG:--effort\nARG:high')"
arg_follows "$text" '^ARG:--model$' '^ARG:sonnet$' || fail "arg_follows: --model is followed by sonnet"
arg_follows "$text" '^ARG:--model$' '^ARG:high$' && fail "arg_follows: --model is not followed by high"
arg_follows "$text" '^ARG:--absent$' '^ARG:.*$' && fail "arg_follows: an absent flag follows nothing"
pass "arg_follows answers about the line after the flag, and refuses an absent flag"

lines="$(printf 'alpha\nbeta\ngamma')"
[[ "$(line_of "$lines" '^beta$')" == "2" ]] \
  || fail "line_of: beta is line 2, got: $(line_of "$lines" '^beta$')"
[[ -z "$(line_of "$lines" '^delta$')" ]] \
  || fail "line_of: an absent pattern gives nothing, got: $(line_of "$lines" '^delta$')"
pass "line_of gives the first matching line number, and nothing when there is no match"

meta="$(printf 'running\nok   /tmp/x.sh (0.4s)\ndone')"
[[ "$(line_of_fixed "$meta" 'ok   /tmp/x.sh (')" == "2" ]] \
  || fail "line_of_fixed: the ok line is line 2, got: $(line_of_fixed "$meta" 'ok   /tmp/x.sh (')"
[[ -z "$(line_of_fixed "$meta" 'ok   /tmp/y.sh (')" ]] \
  || fail "line_of_fixed: an absent substring gives nothing"
pass "line_of_fixed matches a substring with regex metacharacters in it"

args="$(printf 'ARG:--model\nARG:sonnet\nARG:--effort\nARG:high\nARG:--model\nARG:opus')"
[[ "$(arg_value "$args" '--model')" == "sonnet" ]] \
  || fail "arg_value: the first --model is sonnet, got: $(arg_value "$args" '--model')"
[[ -z "$(arg_value "$args" '--absent')" ]] || fail "arg_value: an absent flag gives nothing"
[[ -z "$(arg_value "$(printf 'ARG:--effort\nARG:--model')" '--model')" ]] \
  || fail "arg_value: a flag on the last line gives nothing"
pass "arg_value gives the value after the first occurrence, and nothing for an absent flag"

# The defect itself: written as a variable piped into `grep -n' and then into `head -1', this is the
# shape that loses the race - the reader exits at the first line and the writer dies of SIGPIPE. As
# a here-string there is no writer to kill, so an early match is an answer rather than a failure.
big="$(seq 1 200000)"
[[ "$(line_of "$big" '^1$')" == "1" ]] \
  || fail "line_of: the first of 200000 lines is line 1, got: $(line_of "$big" '^1$')"
unset big
pass "a helper reading 200000 lines answers about the first one without failing"

# --- the work directory -------------------------------------------------------------------------
#
# Physical, because consumer-root, sync-symlinks.sh and the sweeps all resolve paths physically and
# on macOS `mktemp -d` hands back /var/... for /private/var/... - a fixture that keeps the logical
# spelling compares two names for one directory and fails for no reason.
[[ -d "$work_dir" ]] || fail "work_dir should exist, got: $work_dir"
[[ "$work_dir" == /* ]] || fail "work_dir should be absolute, got: $work_dir"
[[ "$work_dir" == "$(cd "$work_dir" && pwd -P)" ]] \
  || fail "work_dir should be physical, got $work_dir for $(cd "$work_dir" && pwd -P)"
pass "work_dir is one absolute, physical directory, created on source"

# --- consumer_new: the default shape --------------------------------------------------------------
c="$(consumer_new plain)"
[[ "$c" == "$work_dir/plain" ]] || fail "consumer_new should echo \$work_dir/<name>, got: $c"
[[ "$(git -C "$c" rev-list --count HEAD)" == "1" ]] \
  || fail "consumer_new should leave one commit, got $(git -C "$c" rev-list --count HEAD)"
[[ "$(git -C "$c" rev-parse --abbrev-ref HEAD)" == "main" ]] \
  || fail "consumer_new should default to main, got $(git -C "$c" rev-parse --abbrev-ref HEAD)"
[[ -d "$c/.claude/cerebro/scripts" ]] || fail "consumer_new should make .claude/cerebro/scripts"
[[ -d "$c/.cerebro" ]] || fail "consumer_new should make .cerebro"
pass "consumer_new: a git working tree with one commit, on main, with the two harness directories"

# The branch is a parameter because while every fixture said `main` and every script said `main`,
# the two agreed and nothing could catch a consumer whose branch is called something else.
c="$(consumer_new trunk --branch trunk)"
[[ "$(git -C "$c" rev-parse --abbrev-ref HEAD)" == "trunk" ]] \
  || fail "consumer_new --branch trunk: got $(git -C "$c" rev-parse --abbrev-ref HEAD)"
pass "consumer_new --branch: the consumer is on the branch it was asked for"

# --- consumer_new --link ---------------------------------------------------------------------------
c="$(consumer_new linked --link consumer-root project-conf)"
for s in consumer-root project-conf; do
  [[ -L "$c/.claude/cerebro/scripts/$s" ]] || fail "--link $s: not a symlink"
  [[ "$(readlink "$c/.claude/cerebro/scripts/$s")" == "$repo_root/scripts/$s" ]] \
    || fail "--link $s: points at $(readlink "$c/.claude/cerebro/scripts/$s")"
done
[[ "$("$c/.claude/cerebro/scripts/consumer-root")" == "$c" ]] \
  || fail "--link: the linked consumer-root should print $c, got $("$c/.claude/cerebro/scripts/consumer-root")"
pass "consumer_new --link: each script is a symlink into this checkout, and resolves the consumer"

# --- consumer_new --copy ---------------------------------------------------------------------------
#
# Narrowed to what a fixture consumer needs: `cp -R "$repo_root"` dragged in whatever happened to be
# present - a local .cerebro/, the .git, byte-compiled elisp - so the fixture was neither hermetic
# nor cheap (ah-qled.11). `emacs/` is deliberately absent: no bash suite reads it, and it is the
# largest thing in the tree.
c="$(consumer_new copied --copy)"
for d in scripts agents skills hooks; do
  [[ -d "$c/.claude/cerebro/$d" ]] || fail "--copy: $d missing under .claude/cerebro"
done
[[ ! -e "$c/.claude/cerebro/emacs" ]] || fail "--copy: emacs/ should not be copied"
[[ ! -e "$c/.claude/cerebro/.git" ]] || fail "--copy: .git should not be copied"
pass "consumer_new --copy: scripts, agents, skills and hooks only"

# --- consumer_new --origin, and advance_origin ------------------------------------------------------
#
# A clone, never `git init` + `remote add`: only a clone sets refs/remotes/origin/HEAD, and
# tests/default-branch.sh exists to test exactly that.
c="$(consumer_new cloned --origin --branch trunk)"
[[ "$(git -C "$c" symbolic-ref refs/remotes/origin/HEAD)" == "refs/remotes/origin/trunk" ]] \
  || fail "--origin: origin/HEAD is $(git -C "$c" symbolic-ref refs/remotes/origin/HEAD)"
[[ -d "$work_dir/cloned-up" ]] || fail "--origin: the second clone <name>-up should exist"
advance_origin cloned 2
git -C "$c" fetch -q
[[ "$(git -C "$c" rev-list --count HEAD..origin/trunk)" == "2" ]] \
  || fail "advance_origin 2: behind by $(git -C "$c" rev-list --count HEAD..origin/trunk)"
pass "consumer_new --origin clones a seeded origin; advance_origin puts the consumer behind it"

# --- consumer_with_submodule ------------------------------------------------------------------------
#
# A REAL submodule, not a copied directory, and that is the supported shape rather than a
# convenience of the fixture: consumer-root asks git which working tree contains this checkout as a
# submodule, which answers for a submodule and nothing else.
c="$(consumer_with_submodule alt vendor/cerebro)"
[[ "$("$c/vendor/cerebro/scripts/consumer-root")" == "$c" ]] \
  || fail "consumer_with_submodule: consumer-root printed $("$c/vendor/cerebro/scripts/consumer-root"), wanted $c"
grep -q "vendor/cerebro" <<<"$(git -C "$c" submodule status)" \
  || fail "consumer_with_submodule: submodule status does not list vendor/cerebro"
pass "consumer_with_submodule: a real submodule at the mount, whose consumer-root resolves the consumer"

# --- the refusals ------------------------------------------------------------------------------------
#
# A name with a slash would put the consumer outside $work_dir, where the one cleanup trap cannot
# reach it.
set +e
out="$( ( consumer_new "bad/name" ) 2>&1 )"
status=$?
set -e
[[ $status -eq 1 ]] || fail "consumer_new bad/name: expected exit 1, got $status"
grep -q "bad/name" <<<"$out" || fail "consumer_new bad/name: the refusal should name it, got: $out"
pass "consumer_new refuses a name containing a slash"

# A name twice re-inits the first consumer's directory and the second case then runs against the
# first's state - silently. It cost this bead a red suite, so it is a refusal rather than a rule.
set +e
out="$( ( consumer_new plain ) 2>&1 )"
status=$?
set -e
[[ $status -eq 1 ]] || fail "consumer_new twice: expected exit 1, got $status"
grep -q "already exists" <<<"$out" || fail "consumer_new twice: got: $out"
pass "consumer_new refuses a name it has already built"

# A fabricator wrapping consumer_new is called as `x="$(new_fixture)"`, so a counter incremented
# inside it never survives the subshell - which is exactly how every fixture got one name.
a="$(fixture_name)"
b="$( (fixture_name) )"
[[ "$a" != "$b" ]] || fail "fixture_name: two calls gave the same name, $a"
[[ "$a" == fixture-* && "$b" == fixture-* ]] || fail "fixture_name: unexpected shape, $a and $b"
[[ "$(fixture_name state)" == state-* ]] || fail "fixture_name <prefix>: got $(fixture_name state)"
[[ ! -e "$work_dir/$a" ]] || fail "fixture_name should leave no directory behind, $a exists"
pass "fixture_name is unique across subshells, takes a prefix, and creates nothing"

# --- cleanup ------------------------------------------------------------------------------------------
#
# The trap is installed by the library in the *suite's* shell, which is why a migrated suite must
# never write a trap of its own - it would silently replace this one.
sourced="$(bash -c '
  set -euo pipefail
  repo_root="'"$repo_root"'"
  source "$repo_root/tests/lib/consumer.sh"
  echo "$work_dir"
  suite_passed >/dev/null')"
[[ -n "$sourced" ]] || fail "cleanup: the sourced shell printed no work_dir"
[[ ! -e "$sourced" ]] || fail "cleanup: $sourced survived the sourcing shell"
pass "the library's EXIT trap removes its work directory"

marker="$work_dir/suite-cleanup-ran"
bash -c '
  set -euo pipefail
  repo_root="'"$repo_root"'"
  suite_cleanup() { touch "'"$marker"'"; }
  source "$repo_root/tests/lib/consumer.sh"
  suite_passed >/dev/null' >/dev/null
[[ -e "$marker" ]] || fail "cleanup: suite_cleanup was not called"
pass "a suite's own suite_cleanup hook runs before the work directory goes"

extra="$work_dir/extra-registered"
bash -c '
  set -euo pipefail
  repo_root="'"$repo_root"'"
  source "$repo_root/tests/lib/consumer.sh"
  mkdir -p "'"$extra"'"
  cleanup_add "'"$extra"'"
  suite_passed >/dev/null' >/dev/null
[[ ! -e "$extra" ]] || fail "cleanup_add: $extra survived the sourcing shell"
pass "cleanup_add registers a path outside the work directory with the same trap"

# --- what the library is allowed to need ----------------------------------------------------------------
#
# bash and git only. `tests/launchers.sh` and `tests/consumer-fixture.sh` run the scripts under test
# with a narrowed PATH or a stub tracker, and that must stay possible - so the library may never
# reach for jq, bd, gh or a package manager.
narrow="$work_dir/narrow-bin"
mkdir -p "$narrow"
for b in bash git mktemp dirname rm ln cp mkdir readlink; do
  p="$(command -v "$b")" && ln -sf "$p" "$narrow/$b"
done
PATH="$narrow" bash -c '
  set -euo pipefail
  repo_root="'"$repo_root"'"
  source "$repo_root/tests/lib/consumer.sh"
  [ -d "$work_dir" ]
  suite_passed >/dev/null' \
  || fail "the library should source with nothing but bash and git on PATH"
pass "the library sources under set -euo pipefail with no jq, bd or gh on PATH"

# --- a suite that dies is never green -------------------------------------------------------------
#
# The defect this section exists for: under `set -euo pipefail` a fatal shell error reaches the EXIT
# trap with `$?` already 0, so a suite that asserted nothing used to print `ok' in the gate. The
# markers, not the status, are what the trap reads - see the library's header for why.

s="$(fabricate_suite dies-on-source 'source /nope/no-such-library.sh
suite_passed')"
run_suite "$s"
[[ $status -ne 0 ]] || fail "a suite that dies on a bad source must not exit 0
$out"
grep -q "died before reaching suite_passed" <<<"$out" \
  || fail "a bad source: the diagnostic should name suite_passed, got: $out"
pass "a suite that dies on a bad source is reported failed, not green"

s="$(fabricate_suite dies-on-unbound 'echo "$no_such_variable"
suite_passed')"
run_suite "$s"
[[ $status -ne 0 ]] || fail "a suite that dies on an unbound variable must not exit 0
$out"
pass "a suite that dies on an unbound variable is reported failed, not green"

s="$(fabricate_suite dies-midway 'pass "the first assertion"
false
suite_passed')"
run_suite "$s"
[[ $status -ne 0 ]] || fail "a suite that dies after its first assertion must not exit 0
$out"
pass "a suite that dies after some assertions have passed is reported failed"

s="$(fabricate_suite fails-an-assertion 'fail "a real assertion"')"
run_suite "$s"
[[ $status -eq 1 ]] || fail "a failed assertion should still exit 1, got $status
$out"
grep -q "^FAIL: a real assertion$" <<<"$out" \
  || fail "a failed assertion should print its own message, got: $out"
grep -q "died before reaching suite_passed" <<<"$out" \
  && fail "a failed assertion must not be reported as a death, got: $out"
pass "a failed assertion is reported as itself, not as a death"

marker="$work_dir/died-but-cleaned"
s="$(fabricate_suite dies-but-cleans "cleanup_add $marker
mkdir -p $marker
source /nope/no-such-library.sh")"
run_suite "$s"
[[ ! -e "$marker" ]] || fail "a dying suite must still have its cleanup run: $marker survived"
pass "the work directory and registered paths still go when the suite dies"

suite_passed
