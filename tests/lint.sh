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
grep -q 'rule bead-id' <<<"$out" \
  || fail "plan check: the advisory does not name the rule that fired
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

# A plan may not tell an implementer to write the provenance file's name into prose an agent
# reads: check 1 forbids exactly that on the tree, and a plan that specifies it costs a rewrite
# plus a gate cycle.
# The path is composed rather than written: rule `docs-in-suites' reads this suite, and a literal
# one here would fire the tree lint on the file that tests it.
d='docs/'
cat > "$plan_dir/decisions-in-skill.md" <<PLAN
### \`skills/plan-bead/SKILL.md\`
Replace the paragraph with:
> The provenance goes in ${d}decisions.md, which the lint names when it fires.
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/decisions-in-skill.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, the provenance file named in a skill: expected exit 1, got $status
$out"
grep -q 'rule decisions-ref' <<<"$out" \
  || fail "plan check, the provenance file named in a skill: rule decisions-ref did not fire
$out"
grep -q 'decisions-in-skill.md:3' <<<"$out" \
  || fail "plan check, the provenance file named in a skill: the hit does not name line 3
$out"
pass "the plan check fires on the provenance file named in a skill"

# A suite that opens a file under docs/ is what stops scripts/ci-needed letting CI skip the
# suites on a docs-only pull request. A plan that specifies one costs a red CI job, not a red
# gate. Both paths here are composed, for the reason above.
cat > "$plan_dir/docs-in-suite.md" <<PLAN
### \`tests/lint.sh\`
Add the case:
\`\`\`bash
grep -q x "$fixture/${d}retrospectives/why.md"
\`\`\`
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/docs-in-suite.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, a docs/ path in a suite: expected exit 1, got $status
$out"
grep -q 'rule docs-in-suites' <<<"$out" \
  || fail "plan check, a docs/ path in a suite: rule docs-in-suites did not fire
$out"

cat > "$plan_dir/docs-in-exempt-suite.md" <<PLAN
### \`tests/ci-needed.sh\`
Add the case:
\`\`\`bash
grep -q x "$fixture/${d}retrospectives/why.md"
\`\`\`
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/docs-in-exempt-suite.md" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "plan check, a docs/ path in the exempt suite: expected exit 0, got $status
$out"
pass "the plan check fires on a docs/ path quoted into a suite, and honours the exempt suite"

# The audience word, spelled by concatenation for the same reason scripts/lint spells it that
# way: this suite is one of the trees the rule reads.
n="play""er"
cat > "$plan_dir/audience-word.md" <<PLAN
### \`scripts/roster\`
Add the comment:
\`\`\`bash
# the ${n} sees this
\`\`\`
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/audience-word.md" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "plan check, the audience word in a script: expected exit 1, got $status
$out"
grep -q 'rule audience-noun' <<<"$out" \
  || fail "plan check, the audience word in a script: rule audience-noun did not fire
$out"

# scripts/lint is exempt from every rule in both walks: it spells every pattern it forbids.
cat > "$plan_dir/audience-word-in-lint.md" <<PLAN
### \`scripts/lint\`
Add the comment:
\`\`\`bash
# the ${n} sees this
\`\`\`
PLAN
set +e
out="$(bash "$lint" --plan "$plan_dir/audience-word-in-lint.md" 2>&1)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "plan check, the audience word in scripts/lint: expected exit 0, got $status
$out"
pass "the plan check fires on the audience word in a script and leaves scripts/lint alone"

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

# The retired worktree path in a script: a tree-mode rule that never had a case of its own, and
# the one that proves a rule reaching outside agent prose still names the file it found.
printf '\nx=.claude/worktrees/y\n' >> "$fixture/scripts/roster"
set +e
out="$(bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a planted retired worktree path: expected exit 1, got $status
$out"
grep -q 'retired worktree path' <<<"$out" \
  || fail "lint with a planted retired worktree path: the advisory did not fire
$out"
grep -q 'scripts/roster' <<<"$out" \
  || fail "lint with a planted retired worktree path: the advisory does not name scripts/roster
$out"
pass "a retired worktree path in a script fires the rule naming the file"

# --- a grep or an awk that fails is an advisory naming the rule, never an `ok' ------------------
#
# A rule whose grep exits 2 - a bad pattern, an exempt pattern read as an option - used to report
# itself clean, because `|| true' cannot tell a no-match from a grep that never ran (cb-u5e). The
# failure is simulated with a shim first on PATH: the real tool, unless the arguments carry the
# marker in $LINT_BREAK_GREP, in which case it prints a message and exits 2 the way grep does. A
# real bad pattern is not used because the platforms disagree about awk (gawk is fatal on a bad
# dynamic regex, BSD awk is not), and the class under test is the exit status, not the regex.
shim_dir="$work_dir/shim"
mkdir -p "$shim_dir"
real_grep="$(command -v grep)"
real_awk="$(command -v awk)"
cat > "$shim_dir/grep" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ -n "\${LINT_BREAK_GREP:-}" && "\$a" == *"\$LINT_BREAK_GREP"* ]]; then
    echo "grep: simulated failure for the suite" >&2
    exit 2
  fi
done
exec "$real_grep" "\$@"
SHIM
cat > "$shim_dir/awk" <<SHIM
#!/usr/bin/env bash
if [[ -n "\${LINT_BREAK_AWK:-}" ]]; then
  echo "awk: simulated failure for the suite" >&2
  exit 2
fi
exec "$real_awk" "\$@"
SHIM
chmod +x "$shim_dir/grep" "$shim_dir/awk"

# The marker is `)?scripts/work-beads': it occurs in the work-beads-status row's hit pattern and
# nowhere else a grep argument can come from. NOT the bare `work-beads' - the shim compares every
# argument, and the file list is arguments too, so a marker that is also a path would break every
# rule that reads that file.
set +e
out="$(LINT_BREAK_GREP=')?scripts/work-beads' PATH="$shim_dir:$PATH" bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a failing grep: expected exit 1, got $status
$out"
grep -q 'ADVISORY: rule work-beads-status could not be checked - its hit grep exited 2' <<<"$out" \
  || fail "lint with a failing grep: no advisory names the rule and the step
$out"
if grep -q 'ok - rule work-beads-status: clean' <<<"$out"; then
  fail "lint with a failing grep: the rule still reported itself clean
$out"
fi
grep -q -e 'ok - rule bead-id: clean' -e 'ADVISORY: ' <<<"$out" \
  || fail "lint with a failing grep: the other rules stopped reporting
$out"
tail -n1 <<<"$out" | grep -q '^lint: 1 rule(s) could not be run - fix scripts/lint' \
  || fail "lint with a failing grep: the verdict does not say the lint is broken
$out"
pass "a grep that fails is an advisory naming the rule and the step, and the verdict says so"

# A path grep that fails is reported at its own step, not folded into the hit grep's. The marker
# `^scripts/' is the whole path pattern of the `mount-round-trip' row and a substring of
# `retired-worktrees'' - so two rules fail at their path grep, and the assertion is on the first.
set +e
out="$(LINT_BREAK_GREP='^scripts/' PATH="$shim_dir:$PATH" bash "$lint" "$fixture" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "lint with a failing path grep: expected exit 1, got $status
$out"
grep -q 'ADVISORY: rule mount-round-trip could not be checked - its path grep exited 2' <<<"$out" \
  || fail "lint with a failing path grep: the path step is not read
$out"
pass "a failing path grep is reported at its own step"

echo "all lint assertions passed"
