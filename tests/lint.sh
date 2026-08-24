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

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

cd "$repo_root"

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
fixture="$work_dir/repo"
mkdir -p "$fixture"
cp -R agents skills docs emacs templates tests scripts CLAUDE.md README.md .github .gitignore "$fixture/"
git init -q "$fixture"
git -C "$fixture" add -A >/dev/null 2>&1
git_q -C "$fixture" commit -q -m init

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

# --- the same check reads this repository's own board, not only the one it grew up in ---
#
# cerebro's beads are `cb-'; the check was written against `ah-' alone, so a plan for cerebro
# could ship its own ids into agent prose and be reported clean.
printf '\nA citation a consumer cannot resolve (cb-zzz8).\n' >> "$fixture/agents/planner.md"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a planted cb- id: expected exit 1, got $status
$out"
grep -F 'agents/planner.md' <<<"$out" | grep -qF 'cb-zzz8' \
  || fail "lint with a planted cb- id: no advisory line names agents/planner.md and cb-zzz8
$out"
pass "a planted cb- id fires the same advisory as an ah- id"

# --- a work-beads call that names no status ------------------------------------------------------
#
# A work-beads call with no --status in an agent file would exit 2 at run time (cb-45f); the lint
# says so on the gate instead.
printf '\n```bash\n.claude/cerebro/scripts/work-beads | jq -r ".[].id"\n```\n' >> "$fixture/agents/verifier.md"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a planted bare work-beads call: expected exit 1, got $status
$out"
grep -q 'names no --status' <<<"$out" \
  || fail "lint with a planted bare work-beads call: the advisory did not fire
$out"
grep -q 'agents/verifier.md' <<<"$out" \
  || fail "lint with a planted bare work-beads call: the advisory does not name agents/verifier.md
$out"
pass "a work-beads call that names no --status fires an advisory naming the file"

# --- the plan check ------------------------------------------------------------------------------
#
# A plan may cite beads in its Context; what it may not do is quote one into a block or a
# blockquote destined for a file an agent reads. One plan, one assertion each.
plan_dir="$work_dir/plans"
mkdir -p "$plan_dir"

cat > "$plan_dir/bad-fence.md" <<'PLAN'
## Context
This stands on ah-tjaz and cb-194, which is fine here.
## Files to change, and what to reuse
### `agents/verifier.md`
Replace the paragraph with:
```
The stale list is open, which is why the arm was dead code (ah-e0kf).
```
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/bad-fence.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, id in a fence under agents/: expected exit 1, got $status
$out"
grep -q 'bad-fence.md:7' <<<"$out" || fail "plan check, id in a fence under agents/: the hit does not name line 7
$out"
grep -q 'quotes a bead id into prose an agent reads' <<<"$out" \
  || fail "plan check: the advisory text is missing
$out"
pass "the plan check fires on a bead id in a fenced block destined for agents/"

cat > "$plan_dir/bad-quote.md" <<'PLAN'
### `agents/orchestrator.md:324-328`
Replace the paragraph with:
> One place worktrees live (cb-k6r).
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/bad-quote.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, id in a blockquote: expected exit 1, got $status
$out"
pass "the plan check fires on a bead id in a blockquote destined for agents/"

cat > "$plan_dir/context-only.md" <<'PLAN'
## Context
Filed after ah-kjfm and ah-e0kf; see the retrospectives for the cost.
### `agents/verifier.md`
Replace the paragraph with:
> The stale list is open; see the retrospectives for the cost.
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/context-only.md" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "plan check, ids in Context only: expected exit 0, got $status
$out"
grep -q 'plan clean' <<<"$out" || fail "plan check, clean plan: no 'plan clean' line
$out"
pass "the plan check lets a plan cite beads in its prose"

cat > "$plan_dir/script-block.md" <<'PLAN'
### `scripts/work-beads`
Add after the loop:
```bash
# No default (ah-tjaz, ah-e0kf): the status was on no line anyone read.
```
### `agents/verifier.md:124`
Add `--status closed` after `work-beads`.
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/script-block.md" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "plan check, id in a block under scripts/: expected exit 0, got $status
$out"
pass "the plan check ignores a block destined for a script"

cat > "$plan_dir/consumer-role.md" <<'PLAN'
### `.claude/agents/archivist.md`
```
The archivist's rule comes from cb-zzz9, this project's own board.
```
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/consumer-role.md" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "plan check, a consumer's own role file: expected exit 0, got $status
$out"
pass "the plan check leaves a consumer's own .claude/agents/ file alone"

cat > "$plan_dir/mounted.md" <<'PLAN'
### `.claude/cerebro/skills/plan-bead/SKILL.md`
```
Run it before you ship (cb-zzz9).
```
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/mounted.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, a skill named through the mount: expected exit 1, got $status
$out"
pass "the plan check sees a skill named through the consumer's mount"

cat > "$plan_dir/child-id.md" <<'PLAN'
### `skills/plan-bead/SKILL.md`
```
The rename shim was removed once a release had carried it (ah-qled.5.1).
```
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/child-id.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, a child bead id: expected exit 1, got $status
$out"
pass "the plan check sees a child bead id with dotted suffixes"

# The documented invocation passes a relative path from wherever the planner is sitting, while the
# checks run from the repository root: a plan re-opened there is no plan at all, and reports clean.
set +e
out="$(cd "$plan_dir" && bash "$lint" --plan bad-fence.md 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, a relative plan path: expected exit 1, got $status
$out"
pass "the plan check reads a plan named relative to the caller's directory"

set +e
out="$(bash "$lint" --plan "$plan_dir/absent.md" 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "plan check, missing file: expected exit 2, got $status
$out"
set +e
out="$(bash "$lint" --plan 2>&1)"
status=$?
set -e
[[ $status -eq 2 ]] || fail "plan check, no file: expected exit 2, got $status
$out"
pass "the plan check is a usage error without a readable plan"

# A round trip through the mount spelled anywhere but consumer-root is the five-copies drift
# cb-akc removed coming back.
printf '\nx="$(cd "$here/.claude/cerebro" 2>/dev/null && pwd -P)"\n' >> "$fixture/scripts/roster"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a planted mount round trip: expected exit 1, got $status
$out"
grep -q 'scripts/roster' <<<"$out" \
  || fail "lint with a planted mount round trip: the advisory does not name scripts/roster
$out"
pass "a mount round trip outside consumer-root fires an advisory naming the file"

echo "all lint assertions passed"
