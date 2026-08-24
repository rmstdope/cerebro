#!/usr/bin/env bash
#
# Proves `scripts/ci-needed' answers "can these changed paths affect the gate" the way a predicate
# must: the exit status is the whole answer, and a mistake can never read as "skip".
#
# The list it encodes is a decision - which paths no suite opens - and decisions are advisories
# (scripts/lint check 12), not tests. What is under test here is the bash the script is: its exit
# codes, its fail-safe on an empty diff, and that it names the path that reached the gate.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/ci-needed.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

cd "$repo_root"

script="$repo_root/scripts/ci-needed"
[[ -f "$script" ]] || fail "scripts/ci-needed does not exist"
[[ -x "$script" ]] || fail "scripts/ci-needed is not executable"

# One call per case. `set +e' around it because exit 1 is an answer here, not a failure.
out=""
status=0
run() {
  set +e
  out="$(printf '%s' "$1" | bash "$script" 2>&1)"
  status=$?
  set -e
}

# --- an argument is a usage error, never an answer ---
set +e
out="$(bash "$script" foo 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "an argument: expected exit 2, got $status
$out"
grep -q '^usage: ' <<<"$out" || fail "an argument: no usage line
$out"
pass "an argument is a usage error, not an answer"

# --- fail-safe: no paths at all means run everything ---
run ""
[[ $status -eq 0 ]] || fail "empty input: expected exit 0, got $status
$out"
grep -q 'no paths given' <<<"$out" || fail "empty input: does not say why
$out"
pass "an empty diff is a broken diff, so everything runs"

run $'\n\n'
[[ $status -eq 0 ]] || fail "blank lines only: expected exit 0, got $status
$out"
grep -q 'no paths given' <<<"$out" || fail "blank lines only: does not say why
$out"
pass "blank lines are not paths"

# --- the skip list ---
run $'docs/retrospectives/cb-ypx.md\n'
[[ $status -eq 1 ]] || fail "a retrospective: expected exit 1, got $status
$out"
grep -q 'none of 1 paths' <<<"$out" || fail "a retrospective: does not count the paths
$out"
pass "a retrospective under docs/ is skippable"

run $'docs/ui/cb-ypx-a.html\nREADME.md\nLICENSE\nmodels.conf.example\n'
[[ $status -eq 1 ]] || fail "the whole skip list: expected exit 1, got $status
$out"
grep -q 'none of 4 paths' <<<"$out" || fail "the whole skip list: does not count the paths
$out"
pass "the whole skip list together is skippable"

run $'docs/a b.md\n'
[[ $status -eq 1 ]] || fail "a path with a space: expected exit 1, got $status
$out"
grep -q 'none of 1 paths' <<<"$out" || fail "a path with a space: counted as more than one path
$out"
pass "a path with a space in it is one path"

# --- the gated side ---
run $'docs/agent-workflow.md\n'
[[ $status -eq 0 ]] || fail "docs/agent-workflow.md: expected exit 0, got $status
$out"
grep -q 'ci-needed: docs/agent-workflow.md' <<<"$out" \
  || fail "docs/agent-workflow.md: does not name the path that reached the gate
$out"
pass "the one docs file a suite reads still runs the gate"

run $'docs/x.md\nemacs/cerebro.el\n'
[[ $status -eq 0 ]] || fail "mixed paths: expected exit 0, got $status
$out"
grep -q 'ci-needed: emacs/cerebro.el' <<<"$out" \
  || fail "mixed paths: does not name emacs/cerebro.el
$out"
pass "a docs change beside a code change runs the gate, and the code path is named"

run $'docs/x.md\ntests/launchers.sh\n'
[[ $status -eq 0 ]] || fail "a suite beside a docs change: expected exit 0, got $status
$out"
grep -q 'ci-needed: tests/launchers.sh' <<<"$out" \
  || fail "a suite beside a docs change: does not name tests/launchers.sh
$out"
pass "a changed suite beside a docs change runs the gate"

# --- the skip list matches paths, not prefixes ---
for p in docs-notes/x.md README.md.orig emacs/README.md; do
  run "$p"$'\n'
  [[ $status -eq 0 ]] || fail "$p: expected exit 0 (not on the skip list), got $status
$out"
done
pass "docs-notes/, README.md.orig and emacs/README.md are not on the skip list"

# --- everything the gate can see is gated ---
for p in .github/workflows/ci.yml scripts/ci-needed tests/gate agents/planner.md \
         skills/plan-bead/SKILL.md templates/consumer-CLAUDE.md CLAUDE.md \
         .cerebro/roster.conf .claude/settings.json hooks/question-state.settings.json \
         githooks/install.sh; do
  run "$p"$'\n'
  [[ $status -eq 0 ]] || fail "$p: expected exit 0, got $status
$out"
  grep -q "ci-needed: $p" <<<"$out" || fail "$p: does not name the path that reached the gate
$out"
done
pass "every path a suite or the gate can see runs the gate"

echo "all ci-needed assertions passed"
