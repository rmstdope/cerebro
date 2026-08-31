#!/usr/bin/env bash
#
# Proves `scripts/marker-readers' answers "is every reader of the session marker a subscriber" -
# the check the third repeat of one defect earned.
#
# One sentence identifies every session the fleet starts, and it is parsed in several languages.
# `tests/lib/session-args.cases' closed the drift between readers THAT OPT IN, but it is a test
# fixture, so it is silent about a reader that never subscribes - which is exactly what cb-akt was:
# `scripts/fleet-cost' invented an anchored SQL `LIKE', dropped every row carrying anything before
# the marker, and reported a zero that reads as a fleet that has never run rather than as a failure.
# This check makes that red on the day the reader is written.
#
# The fixtures are self-consumers with `emacs/' and `tests/' copied in beside what
# `copy_cerebro_into' brings, then broken a copy at a time. Everything fabricated lives under
# `$work_dir'; `$repo_root' is only ever read.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/marker-readers.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/marker-readers"
[[ -f "$script" ]] || fail "scripts/marker-readers does not exist"
[[ -x "$script" ]] || fail "scripts/marker-readers is not executable"

# A fresh, whole self-consumer. `copy_cerebro_into' brings `scripts/', `agents/', `skills/' and
# `hooks/' only - deliberately not `emacs/', which no other bash suite reads - so this check's other
# three scanned directories (`emacs', `tests', `githooks' and, since cb-vyp.1, `fleet-view') are
# copied here, or every fixture reports a table full of `stale:' rows.
new_fixture() {
  local fix="$work_dir/$(fixture_name markers)" d
  copy_cerebro_into "$fix"
  for d in emacs tests githooks fleet-view; do
    [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$fix/"
  done
  git init -q "$fix"
  git_q -C "$fix" add -A
  git_q -C "$fix" commit -q -m init
  echo "$fix"
}

# One call per case, streams kept apart: stdout carries the findings, stderr the usage refusal.
out=""
status=0
run() {
  set +e
  out="$("$@" 2>"$work_dir/err")"
  status=$?
  set -e
}

# --- this repository has no unsubscribed marker readers ------------------------------------------
#
# The case the bead exists for, and the counterpart of tests/tracked-links.sh's "this repository's
# own tracked links are whole". The script resolves its own root, so the suite's shell needs no cd.

run "$script"
[[ $status -eq 0 ]] || fail "this repository's marker readers must all be subscribers, got $status: $out"
[[ -z "$out" ]] || fail "this repository's marker readers must all be subscribers, got: $out"
pass "this repository has no unsubscribed marker readers"

# --- an argument is a usage error, and prints no findings -----------------------------------------

run "$script" --all
[[ $status -eq 2 ]] || fail "an argument must exit 2, got $status"
[[ -z "$out" ]] || fail "a usage error must print no findings, got: $out"
grep -qF "usage: marker-readers" "$work_dir/err" \
  || fail "expected the usage line on stderr, got: $(cat "$work_dir/err")"
pass "an argument is a usage error, and prints no findings"

# --- a file spelling the marker with no declared row is reported ----------------------------------
#
# Exactly cb-akt: a fourth reader written without subscribing. Untracked on purpose - the scan is
# `--cached --others --exclude-standard', because tracked files alone would give a green gate to an
# implementer who wrote a new reader and ran the gate before `git add', which is precisely the
# moment this check is meant to fire.

fix="$(new_fixture)"
cat >"$fix/scripts/fake-reader" <<'READER'
#!/usr/bin/env bash
# A reader that invented its own spelling of "cerebro fleet rooted at" and told nobody.
grep -c "cerebro fleet rooted at" "$1"
READER
run "$fix/scripts/marker-readers"
[[ $status -eq 1 ]] || fail "an unsubscribed reader must exit 1, got $status (output: $out)"
grep -qF "unsubscribed: scripts/fake-reader (spells the session marker and is not a declared reader)" <<<"$out" \
  || fail "expected the unsubscribed finding, got: $out"
pass "a file spelling the marker with no declared row is reported"

# --- a file under fleet-view/ spelling the marker with no declared row is reported ----------------
#
# The same finding as scripts/fake-reader above, proven under the directory cb-vyp.1 added to the
# scan set - a scan-set edit that missed a directory would leave this fixture green.

fix="$(new_fixture)"
mkdir -p "$fix/fleet-view/src"
cat >"$fix/fleet-view/src/fake_reader.rs" <<'READER'
// A reader that invented its own spelling of "cerebro fleet rooted at" and told nobody.
pub fn spells_it(s: &str) -> bool {
    s.contains("cerebro fleet rooted at")
}
READER
run "$fix/scripts/marker-readers"
[[ $status -eq 1 ]] || fail "an unsubscribed reader under fleet-view/ must exit 1, got $status (output: $out)"
grep -qF "unsubscribed: fleet-view/src/fake_reader.rs (spells the session marker and is not a declared reader)" <<<"$out" \
  || fail "expected the unsubscribed finding, got: $out"
pass "a file under fleet-view/ spelling the marker with no declared row is reported"

# --- a declared row whose file no longer spells it is reported ------------------------------------
#
# The inverse cost, and the one tracked-links also pays: a declaration that has quietly stopped
# describing anything is a row nobody will think to remove, and it makes the table read as covering
# more than it does.

fix="$(new_fixture)"
grep -v "$(cd "$repo_root" && source scripts/session-marker.sh && cerebro_marker_infix)" \
  "$fix/scripts/fleet-cost" >"$fix/scripts/fleet-cost.stripped"
mv "$fix/scripts/fleet-cost.stripped" "$fix/scripts/fleet-cost"
run "$fix/scripts/marker-readers"
[[ $status -eq 1 ]] || fail "a stale row must exit 1, got $status (output: $out)"
grep -qF "stale: scripts/fleet-cost (declared a session-marker reader and no longer spells it)" <<<"$out" \
  || fail "expected the stale finding, got: $out"
pass "a declared row whose file no longer spells it is reported"

# --- a declared row whose suite does not run the case table is reported ---------------------------
#
# The subscription is the point of the row: a reader pinned to a suite that has stopped running
# tests/lib/session-args.cases is a reader nothing holds to the other copies' spelling.

fix="$(new_fixture)"
grep -v "session-args.cases" "$fix/tests/agent-alive.sh" >"$fix/tests/agent-alive.stripped"
mv "$fix/tests/agent-alive.stripped" "$fix/tests/agent-alive.sh"
run "$fix/scripts/marker-readers"
[[ $status -eq 1 ]] || fail "an unpinned row must exit 1, got $status (output: $out)"
grep -qF "unpinned: scripts/agent-alive -> tests/agent-alive.sh (its declared suite does not run tests/lib/session-args.cases)" <<<"$out" \
  || fail "expected the unpinned finding, got: $out"
pass "a declared row whose suite does not run the case table is reported"

suite_passed
