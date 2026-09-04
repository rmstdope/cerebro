#!/usr/bin/env bash
#
# Proves scripts/jsonl-log.sh is a writer that refuses rather than a writer that trusts (cb-ge0).
# The whole point of the library is that a caller inside an `|| true` group - where errexit is
# suspended, so a failed `line="$(jq ...)"` leaves `line` empty and carries on - cannot append that
# empty line by forgetting to check it. So the refusals are the cases that matter here, and each
# one asserts that nothing was written as well as that the status was non-zero.
#
# It needs no consumer fixture: it sources the library under test directly and calls the function,
# with every file it touches under `$work_dir`.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/jsonl-log.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

source "$repo_root/scripts/jsonl-log.sh"

# --- appends one line and returns 0 -------------------------------------------------------------

log="$work_dir/one-line.jsonl"
status=0
cerebro_jsonl_append "$log" '{"a":1}' || status=$?
[ "$status" -eq 0 ] || fail "appending a JSON object returned $status"
[ "$(cat "$log")" = '{"a":1}' ] || fail "the log holds '$(cat "$log")' rather than the one line"
[ "$(wc -l < "$log" | tr -d ' ')" = "1" ] || fail "the log holds more than one line"
pass "appends one line and returns 0"

# --- appends rather than truncating --------------------------------------------------------------

log="$work_dir/two-lines.jsonl"
cerebro_jsonl_append "$log" '{"n":1}'
cerebro_jsonl_append "$log" '{"n":2}'
[ "$(sed -n 1p "$log")" = '{"n":1}' ] || fail "the first line was lost: $(sed -n 1p "$log")"
[ "$(sed -n 2p "$log")" = '{"n":2}' ] || fail "the second line is wrong: $(sed -n 2p "$log")"
[ "$(wc -l < "$log" | tr -d ' ')" = "2" ] || fail "two appends left $(wc -l < "$log") lines"
pass "appends rather than truncating"

# --- creates the file when it does not exist -----------------------------------------------------

log="$work_dir/absent/nested.jsonl"
mkdir -p "$work_dir/absent"
if [ -e "$log" ]; then fail "the fixture's log exists before the first append"; fi
cerebro_jsonl_append "$log" '{"first":true}'
[ "$(cat "$log")" = '{"first":true}' ] || fail "the created file holds '$(cat "$log")'"
pass "creates the file when it does not exist"

# --- refuses an empty line -----------------------------------------------------------------------

log="$work_dir/empty-line.jsonl"
status=0
cerebro_jsonl_append "$log" "" || status=$?
[ "$status" -ne 0 ] || fail "an empty line was accepted"
if [ -e "$log" ]; then fail "an empty line created $log"; fi
pass "refuses an empty line"

# --- refuses a line that is not a JSON object ----------------------------------------------------

log="$work_dir/not-an-object.jsonl"
for bad in "not json" "[1,2]"; do
  status=0
  cerebro_jsonl_append "$log" "$bad" || status=$?
  [ "$status" -ne 0 ] || fail "'$bad' was accepted"
  if [ -e "$log" ]; then fail "'$bad' created $log"; fi
done
pass "refuses a line that is not a JSON object"

# --- refuses an empty path -----------------------------------------------------------------------

before="$(ls -A "$work_dir" | sort)"
status=0
cerebro_jsonl_append "" '{"a":1}' || status=$?
[ "$status" -ne 0 ] || fail "an empty path was accepted"
[ "$(ls -A "$work_dir" | sort)" = "$before" ] || fail "an empty path wrote something into $work_dir"
pass "refuses an empty path"

# --- the guard: a path under CEREBRO_PROTECTED_STATE_DIR is refused ------------------------------
#
# cb-xhu.1. The gate's suites must build every fixture under their own $work_dir; one that resolves
# the real shared root and appends there writes into the fleet's live logs, which is what the
# navigator is sent to by name. `scripts/suite-runner' sets the guard for the whole run; here the
# function is exercised directly, because in production both callers sit inside `{ ... } || true'
# groups that would swallow a mistake in it.

mkdir -p "$work_dir/guarded" "$work_dir/guardedX"

status=0
CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded" \
  cerebro_jsonl_append "$work_dir/guarded/errors.jsonl" '{"a":1}' || status=$?
[ "$status" -ne 0 ] || fail "a write under the guard was accepted"
if [ -e "$work_dir/guarded/errors.jsonl" ]; then fail "a guarded write created the file"; fi
pass "a path under CEREBRO_PROTECTED_STATE_DIR is refused and nothing is written"

# The `/' in the `"$guard"/*' pattern is what makes this a path-component test rather than a string
# prefix one: a sibling directory whose name starts with the guard's is not protected.
status=0
CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded" \
  cerebro_jsonl_append "$work_dir/guardedX/errors.jsonl" '{"a":1}' || status=$?
[ "$status" -eq 0 ] || fail "a sibling sharing the guard's prefix was refused ($status)"
[ "$(cat "$work_dir/guardedX/errors.jsonl")" = '{"a":1}' ] || fail "the sibling's line was not written"
pass "a path outside the guard is written as before"

status=0
( unset CEREBRO_PROTECTED_STATE_DIR
  cerebro_jsonl_append "$work_dir/unset-guard.jsonl" '{"a":1}' ) || status=$?
[ "$status" -eq 0 ] || fail "an unset guard refused a write ($status)"
[ -f "$work_dir/unset-guard.jsonl" ] || fail "an unset guard wrote nothing"
pass "an unset guard writes as before"

status=0
CEREBRO_PROTECTED_STATE_DIR="" \
  cerebro_jsonl_append "$work_dir/empty-guard.jsonl" '{"a":1}' || status=$?
[ "$status" -eq 0 ] || fail "an empty guard refused a write ($status)"
[ -f "$work_dir/empty-guard.jsonl" ] || fail "an empty guard wrote nothing"
pass "an empty guard writes as before"

# The guard covers the directory itself, not only what is under it.
status=0
CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded/" \
  cerebro_jsonl_append "$work_dir/guarded/trailing.jsonl" '{"a":1}' || status=$?
[ "$status" -ne 0 ] || fail "a guard with a trailing slash did not protect its directory"
pass "a guard with a trailing slash protects the same directory"

# --- the refusal is recorded with the suite that caused it ---------------------------------------

report="$work_dir/report"
status=0
CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded" \
CEREBRO_PROTECTED_STATE_REPORT="$report" \
CEREBRO_SUITE_NAME="tests/fake.sh" \
  cerebro_jsonl_append "$work_dir/guarded/errors.jsonl" '{"a":1}' || status=$?
[ "$status" -ne 0 ] || fail "the recorded write was not refused"
[ "$(cat "$report")" = "$(printf 'tests/fake.sh\t%s' "$work_dir/guarded/errors.jsonl")" ] \
  || fail "the report holds '$(cat "$report")'"
pass "a refused write is recorded as <suite> tab <path> when a report file is named"

before="$(ls -A "$work_dir" | sort)"
status=0
( unset CEREBRO_PROTECTED_STATE_REPORT
  CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded" \
    cerebro_jsonl_append "$work_dir/guarded/errors.jsonl" '{"a":1}' ) || status=$?
[ "$status" -ne 0 ] || fail "a refused write with no report named was accepted"
[ "$(ls -A "$work_dir" | sort)" = "$before" ] || fail "a refused write with no report named wrote something"
pass "a refused write with no report file named is still refused"

report2="$work_dir/report2"
status=0
( unset CEREBRO_SUITE_NAME
  CEREBRO_PROTECTED_STATE_DIR="$work_dir/guarded" \
  CEREBRO_PROTECTED_STATE_REPORT="$report2" \
    cerebro_jsonl_append "$work_dir/guarded/errors.jsonl" '{"a":1}' ) || status=$?
[ "$status" -ne 0 ] || fail "a refused write with no suite name was accepted"
[ "$(cat "$report2")" = "$(printf 'unknown\t%s' "$work_dir/guarded/errors.jsonl")" ] \
  || fail "the report holds '$(cat "$report2")' rather than an unknown suite"
pass "a refused write with no suite name is recorded as unknown"

suite_passed
