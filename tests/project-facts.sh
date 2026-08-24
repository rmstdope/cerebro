#!/usr/bin/env bash
#
# Proves this repository declares its OWN facts, the way every consumer must (cb-i3l.2). Cerebro is
# a harness for other repositories and is now also a consumer of itself (cb-i3l.1), so the file
# every other consumer writes — .claude/cerebro-project.conf — has to exist here too, and say what
# is true here rather than what was true in the repository these agents were extracted from.
#
# Two things are asserted, and they are different in kind:
#
#   * the facts resolve — project-conf answers, and app-paths can classify a change;
#   * the gate does not drift from CI. What an implementer runs before it opens a pull request and
#     what the pull request is then judged by must be the same three commands, or the fleet merges
#     on a gate nobody else runs.
#
# The gate is NEVER executed here: it runs every tests/*.sh, which includes this file.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/project-facts.sh

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

conf=".claude/cerebro-project.conf"
project_conf() { ".claude/cerebro/scripts/project-conf" "$@" 2>/dev/null; }

# --- the file exists, and is TRACKED ---
#
# .claude/* is ignored here; a fact every clone needs that lives in an ignored file vanishes on a
# fresh clone and takes the whole declaration with it, which is the trap project-conf's own header
# warns about.
[[ -f "$conf" ]] || fail "$conf does not exist - this repository declares no facts of its own"
git ls-files --error-unmatch "$conf" >/dev/null 2>&1 \
  || fail "$conf is not tracked by git - an ignored copy vanishes on a fresh clone"
pass "this repository declares its own facts, in a tracked file"

# --- the facts that have one right answer here ---
[[ "$(project_conf project_name)" == "Cerebro" ]] \
  || fail "project_name: got '$(project_conf project_name)'"
[[ "$(project_conf default_branch)" == "main" ]] \
  || fail "default_branch: got '$(project_conf default_branch)'"
pass "project_name and default_branch answer for this repository"

# The audience of a release note here is whoever runs a fleet: this repository ships a harness
# rather than an application, and `navigator' is what every agent document already calls them.
[[ "$(project_conf audience_noun)" == "navigator" ]] \
  || fail "audience_noun: got '$(project_conf audience_noun)'"
pass "the audience is the navigator, which is who reads what this repository ships"

# --- app_paths, which app-paths REFUSES to guess at ---
#
# The classification is inverted here compared to every other consumer, and that is the point:
# `scripts/' is the fleet talking to itself in a project that USES cerebro, and is the product in
# the project that IS cerebro.
[[ -n "$(project_conf app_paths)" ]] || fail "app_paths is not declared - app-paths exits 3"
classify() { ".claude/cerebro/scripts/app-paths" --classify "$@" 2>/dev/null; }
for p in scripts/launch emacs/cerebro.el agents/planner.md skills/plan-bead/SKILL.md \
         hooks/question-state.settings.json githooks/post-merge templates/consumer-CLAUDE.md; do
  [[ "$(classify "$p")" == "application" ]] || fail "$p should classify as application"
done
pass "what a consumer runs classifies as application: scripts, emacs, agents, skills, hooks, templates"

for p in docs/agent-workflow.md tests/project-facts.sh .github/workflows/ci.yml CLAUDE.md; do
  [[ "$(classify "$p")" == "invisible" ]] || fail "$p should classify as invisible"
done
pass "what only this repository reads classifies as invisible: docs, tests, CI, CLAUDE.md"

# --- the gate, and its agreement with CI ---
gate_fast="$(project_conf gate_fast)"
gate_full="$(project_conf gate_full)"
[[ -n "$gate_fast" ]] || fail "gate_fast is not declared - an implementer here could not launch"
[[ -n "$gate_full" ]] || fail "gate_full is not declared"

runner="tests/gate"
[[ -x "$runner" ]] || fail "$runner does not exist or is not executable"
[[ "$gate_fast" == *"$runner"* ]] || fail "gate_fast does not name $runner: '$gate_fast'"
[[ "$gate_full" == *"$runner"* ]] || fail "gate_full does not name $runner: '$gate_full'"
pass "both gates name one runner, so there is one definition of green"

# The runner must never be picked up by the `tests/*.sh' loop it runs: the gate would then run the
# gate, once per suite, forever.
[[ "$runner" != *.sh ]] || fail "$runner ends in .sh, so the gate would run itself recursively"
pass "the runner is not itself a suite, so the gate cannot recurse"

ci=".github/workflows/ci.yml"
byte_compile="emacs --batch -L emacs -f batch-byte-compile emacs/cerebro.el"
ert="emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit"
for cmd in "$byte_compile" "$ert"; do
  grep -qF "$cmd" "$ci" || fail "CI no longer runs: $cmd"
  grep -qF "$cmd" "$runner" || fail "$runner does not run what CI runs: $cmd"
done
grep -qF 'tests/*.sh' "$ci" || fail "CI no longer runs every tests/*.sh"
grep -qF 'tests/*.sh' "$runner" || fail "$runner does not run every tests/*.sh"
pass "the gate runs exactly what CI runs: byte-compile, ERT, every tests/*.sh"

# --- the absences are deliberate ---
#
# A key left out by accident and a key left out on purpose read identically to project-conf, which
# returns the default either way. The difference has to be written down, or the next person adds
# `install' to a repository that installs nothing and wonders why it never ran.
for key in install prewarm disk_floor_gb retro_dir release_cmd launch_targets; do
  [[ -z "$(project_conf "$key")" ]] || continue
  grep -q "$key" "$conf" || fail "$key is absent from $conf without a word saying why"
done
pass "every key this repository deliberately leaves out says so in the file"

# --- the harness's own machine state is ignored, wholesale (cb-i3l.5) ---
#
# `.cerebro/' is where the fleet keeps what belongs to this machine and this moment: an agent's
# state file, its stop flag, its worktrees, and the personal models.conf. None of it is ever part
# of the project. The first session started in this repository writes one, and an unignored
# `.cerebro/' turns every `git status' into noise - or gets a state file committed, which then
# describes somebody else's machine to everybody who clones.
#
# Ignored WHOLESALE, never partially: nothing tracked lives there, so a negation would only invite
# one to.
for p in .cerebro/state/Xavier.state.json .cerebro/state/Cyclops.stop \
         .cerebro/worktrees/cb-1/file.txt .cerebro/models.conf; do
  git check-ignore -q "$p" || fail "$p is not ignored - the fleet's machine state would be committable"
done
pass "every path the fleet writes under .cerebro/ is ignored"

[[ -z "$(git ls-files .cerebro)" ]] \
  || fail "something under .cerebro/ is tracked: $(git ls-files .cerebro)"
pass "nothing under .cerebro/ is tracked, which is why the ignore can be wholesale"

echo "all project-facts tests passed"
