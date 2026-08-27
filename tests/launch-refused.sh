#!/usr/bin/env bash
#
# Proves scripts/launch-refused says a launcher's refusal in the one place the navigator is told to
# look (cb-ccl). On 2026-08-26 `launch-preflight` refused every start for about a day with a precise
# line on stderr, and nothing anywhere kept it: vterm had not drawn the line by the time the exit
# sentinel read the buffer, so `errors.jsonl` held nothing about launch at all. The launcher writing
# its own refusal needs no pty, no timer and no fleet view.
#
# Every assertion runs against a fabricated consumer under `mktemp -d` - never the checkout this is
# run from, whose own .cerebro/state/errors.jsonl the fleet view is reading while this runs.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/launch-refused.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# The script is run from a consumer's own copy, so `consumer-root --shared` resolves to the fixture
# and the line lands in the fixture's state directory.
refused_in() {
  local consumer="$1"; shift
  bash "$consumer/.claude/cerebro/scripts/launch-refused" "$@"
}

errors_of() { echo "$1/.cerebro/state/errors.jsonl"; }

# --- it prints the refusal and exits 0 ------------------------------------------------------------
#
# Exit 0 always: the CALLER exits 2. A refusal that failed because its log could not be written
# would replace a precise message with a mystery, which is the defect this script exists to fix.
c="$(consumer_with_submodule refusal .claude/cerebro)"
msg="the checkout is 4 commits behind origin/main and has uncommitted changes"
set +e
out="$(refused_in "$c" Storm "$msg" 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "refusal: expected exit 0, got $status"
[[ "$out" == "cerebro: $msg" ]] || fail "refusal: expected 'cerebro: $msg' on stderr, got: $out"
pass "a refusal is printed to stderr and the script exits 0"

# --- it appends one errors.jsonl line, in the view's own shape ------------------------------------
log="$(errors_of "$c")"
[[ -f "$log" ]] || fail "line: expected $log to exist"
[[ "$(wc -l < "$log" | tr -d ' ')" == "1" ]] || fail "line: expected exactly one line, got: $(cat "$log")"
[[ "$(jq -r .event "$log")" == "error" ]] || fail "line: expected event=error, got: $(cat "$log")"
[[ "$(jq -r .context "$log")" == "launch Storm" ]] || fail "line: expected context='launch Storm', got: $(cat "$log")"
[[ "$(jq -r .message "$log")" == "$msg" ]] || fail "line: expected the bare message with no cerebro: prefix, got: $(cat "$log")"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$(jq -r .ts "$log")" \
  || fail "line: expected the view's own UTC ts format, got: $(jq -r .ts "$log")"
pass "the refusal is appended to errors.jsonl as one error line"

# --- a second refusal appends rather than replacing -----------------------------------------------
#
# An agent refused 34 times running is the incident this comes from; each attempt is its own line.
refused_in "$c" Rogue "claude is not on PATH" 2>/dev/null
[[ "$(wc -l < "$log" | tr -d ' ')" == "2" ]] || fail "append: expected two lines, got: $(cat "$log")"
[[ "$(tail -n1 "$log" | jq -r .context)" == "launch Rogue" ]] \
  || fail "append: expected the second line to name Rogue, got: $(tail -n1 "$log")"
pass "a second refusal appends a second line"

# --- with no jq it still prints, still exits 0, and writes nothing ---------------------------------
#
# tests/launchers.sh proves the launchers run on a narrowed PATH. This is the refusal path's half of
# that guarantee: a tool it cannot find must cost the log line and nothing else.
c2="$(consumer_with_submodule nojq .claude/cerebro)"
stub_dir="$(mktemp -d)"
cleanup_add "$stub_dir"
cat > "$stub_dir/jq" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
chmod +x "$stub_dir/jq"
set +e
out="$(PATH="$stub_dir:$PATH" refused_in "$c2" Storm "no jq here" 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "nojq: expected exit 0, got $status"
[[ "$out" == "cerebro: no jq here" ]] || fail "nojq: expected the refusal on stderr, got: $out"
[[ ! -f "$(errors_of "$c2")" ]] || fail "nojq: expected no log line, got: $(cat "$(errors_of "$c2")")"
pass "with no jq the refusal is still printed and nothing is written"

# --- outside a consumer it prints and writes nothing ----------------------------------------------
#
# The launchers run from a standalone clone in the tests, where there is no root to write to.
set +e
out="$(bash "$repo_root/scripts/launch-refused" Storm "nowhere to write this" 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "rootless: expected exit 0, got $status"
[[ "$out" == "cerebro: nowhere to write this" ]] || fail "rootless: expected the refusal on stderr, got: $out"
pass "with no consumer root the refusal is still printed"

# --- usage ----------------------------------------------------------------------------------------
set +e
out="$(bash "$repo_root/scripts/launch-refused" Storm 2>&1 >/dev/null)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "usage: expected exit 2, got $status"
grep -q "usage: launch-refused" <<<"$out" || fail "usage: expected a usage line, got: $out"
pass "a call with no message is a usage error"
suite_passed
