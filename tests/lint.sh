#!/usr/bin/env bash
#
# Proves `scripts/lint' behaves: it reports, it refuses a root that is not a directory, and it
# fires on a planted violation naming the file it found.
#
# The lint itself guards DECISIONS - prose and configuration this project has chosen - and those
# are advisories rather than tests (cb-194). What is under test here is the bash `scripts/lint'
# is: the exit codes and the report, which is code this repository ships.
#
# It does not assert that this repository's prose is clean: an advisory is a decision to update
# `scripts/lint', never a red suite (cb-ypx) - which is also what lets CI skip the suites on a
# docs-only pull request.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/lint.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

lint="$repo_root/scripts/lint"
[[ -f "$lint" ]] || fail "scripts/lint does not exist"

# --- every check runs and reports itself, whichever way it went ---
#
# Not "exit 0": whether this tree's prose is clean today is not what the lint is for.
set +e
out="$(bash "$lint" 2>&1)"
status=$?
set -e
[[ $status -eq 0 || $status -eq 1 ]] \
  || fail "lint on this repository: expected exit 0 or 1, got $status
$out"
reported="$(grep -c -e '^ok - ' -e '^ADVISORY: ' <<<"$out" || true)"
[[ "$reported" -ge 10 ]] \
  || fail "lint on this repository: expected at least ten checks to report, got $reported
$out"
tail -n1 <<<"$out" | grep -q -e '^lint: clean$' -e '^lint: advisories above are not failures' \
  || fail "lint on this repository: the last line is neither verdict
$out"
pass "the lint runs on this repository and reports every check"

# --- a root that is not a directory is a usage error, not a wall of advisories ---
set +e
out="$(bash "$lint" /nonexistent-root-for-cb-194 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "lint /nonexistent: expected exit 2, got $status
$out"
pass "a root that is not a directory exits 2"

# --- a planted violation fires, exits 1, and names the file it was found in ---
#
# The fixture is a copy of the linted inputs rather than this tree, so the violation can be
# planted without touching the repository. It needs a git work tree with one commit and its own
# .gitignore: one check queries `git ls-files' and `git check-ignore'.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
fixture="$work_dir/repo"
mkdir -p "$fixture"
cp -R agents skills docs emacs templates tests scripts CLAUDE.md README.md .github .gitignore "$fixture/"
git init -q "$fixture"
git -C "$fixture" add -A >/dev/null 2>&1
git -C "$fixture" -c user.name=test -c user.email=test@example.com commit -q -m init

# The unmodified copy is the baseline the planted violation is measured against, not a claim
# that it is clean.
baseline="$(bash "$lint" "$fixture" 2>&1 || true)"

printf '\nA citation a consumer cannot resolve (ah-zzz9).\n' >> "$fixture/agents/planner.md"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a planted bead id: expected exit 1, got $status
$out"
grep -F 'agents/planner.md' <<<"$out" | grep -qF 'ah-zzz9' \
  || fail "lint with a planted bead id: no advisory line names agents/planner.md and ah-zzz9
$out"
if grep -F 'agents/planner.md' <<<"$baseline" | grep -qF 'ah-zzz9'; then
  fail "the planted id was already reported before planting - the fixture is not a baseline
$baseline"
fi
pass "a planted violation fires an advisory, exits 1 and names the file"

echo "all lint assertions passed"
