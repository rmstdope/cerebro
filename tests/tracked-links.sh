#!/usr/bin/env bash
#
# Proves `scripts/tracked-links' answers "are this repository's tracked links whole" - both
# directions. A tracked symlink under `.claude/' or `.github/' that no longer resolves is a
# `dangling:' finding; a skill, agent or provider hook the mount ships that no layout has a tracked
# link for is a `missing:' one. Silence and exit 0 is the whole clean answer, and an argument is a
# usage error that prints no findings at all, so a mistake can never read as "whole".
#
# The defect it exists for shipped: cb-7v2 (d7a76fa, #151) removed `skills/release-notes/' without
# removing `.claude/skills/release-notes', and the dangling link sat on main through three merges
# with a green gate on every PR.
#
# The fixtures are self-consumers built by the real `sync-symlinks.sh', then broken a copy at a
# time, so what the suite calls whole is what the sync actually produces rather than a hand-written
# guess. Everything it fabricates lives under `$work_dir'; `$repo_root' is only ever read.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/tracked-links.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/tracked-links"
[[ -f "$script" ]] || fail "scripts/tracked-links does not exist"
[[ -x "$script" ]] || fail "scripts/tracked-links is not executable"

# A fresh, whole self-consumer: cerebro copied in, `.claude/cerebro' pointing back at it the way
# this repository's own committed symlink does, the real sync run over it, and the result committed
# so every link is tracked. `fixture_name' rather than a counter, because this is called as
# `fix="$(new_fixture)"' and a counter incremented in that subshell would never survive it.
new_fixture() {
  local fix="$work_dir/$(fixture_name selfrepo)"
  copy_cerebro_into "$fix"
  mkdir -p "$fix/.claude"
  ln -s ".." "$fix/.claude/cerebro"
  "$fix/.claude/cerebro/scripts/sync-symlinks.sh" >/dev/null
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

# --- a whole checkout is silent ------------------------------------------------------------------

fix="$(new_fixture)"
run "$fix/scripts/tracked-links"
[[ $status -eq 0 ]] || fail "a whole self-consumer must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "a whole self-consumer must print nothing, got: $out"
pass "a whole self-consumer produces no findings and exits 0"

# --- a dangling tracked link is a finding --------------------------------------------------------
#
# Exactly d7a76fa: the skill goes, the link stays tracked, and nothing else changes.

fix="$(new_fixture)"
rm -rf "$fix/skills/beads-workflow"
git_q -C "$fix" commit -q -am "drop a skill"
run "$fix/scripts/tracked-links"
[[ $status -eq 1 ]] || fail "a dangling tracked link must exit 1, got $status (output: $out)"
grep -qF "dangling: .claude/skills/beads-workflow -> ../cerebro/skills/beads-workflow" <<<"$out" \
  || fail "expected the .claude/ link reported, got: $out"
pass "a tracked link whose source is gone is reported, and the exit status is 1"

grep -qF "dangling: .github/skills/beads-workflow -> ../../.claude/cerebro/skills/beads-workflow" <<<"$out" \
  || fail "expected the .github/ link reported too, got: $out"
pass "both layouts report it, not just .claude/"

# --- an untracked dangling link is not a finding -------------------------------------------------
#
# Tracked is the subject: the defect is what a clone gets.

fix="$(new_fixture)"
ln -s ../cerebro/skills/nothing "$fix/.claude/skills/nothing"
run "$fix/scripts/tracked-links"
[[ $status -eq 0 ]] || fail "an untracked dangling link must not be a finding, got $status: $out"
[[ -z "$out" ]] || fail "an untracked dangling link must print nothing, got: $out"
pass "an untracked dangling link is not a finding"

# --- a shipped source with no tracked link is a finding ------------------------------------------

fix="$(new_fixture)"
git_q -C "$fix" rm -q --cached .github/skills/plan-bead >/dev/null
rm "$fix/.github/skills/plan-bead"
git_q -C "$fix" commit -q -m "untrack a skill link"
run "$fix/scripts/tracked-links"
[[ $status -eq 1 ]] || fail "a skill with no tracked link must exit 1, got $status (output: $out)"
grep -qF "missing: .github/skills/plan-bead (skills/plan-bead is shipped and has no tracked link)" <<<"$out" \
  || fail "expected the missing skill link reported, got: $out"
pass "a skill with no tracked link in a layout is reported"

fix="$(new_fixture)"
git_q -C "$fix" rm -q --cached .claude/agents/verifier.md >/dev/null
rm "$fix/.claude/agents/verifier.md"
git_q -C "$fix" commit -q -m "untrack an agent link"
run "$fix/scripts/tracked-links"
[[ $status -eq 1 ]] || fail "an agent with no tracked link must exit 1, got $status (output: $out)"
grep -qF "missing: .claude/agents/verifier.md (agents/verifier.md is shipped and has no tracked link)" <<<"$out" \
  || fail "expected the missing agent link reported, got: $out"
pass "an agent with no tracked link in a layout is reported"

fix="$(new_fixture)"
git_q -C "$fix" rm -q --cached .github/hooks/cerebro-question-state.json >/dev/null
rm "$fix/.github/hooks/cerebro-question-state.json"
git_q -C "$fix" commit -q -m "untrack a hook link"
run "$fix/scripts/tracked-links"
[[ $status -eq 1 ]] || fail "a hook with no tracked link must exit 1, got $status (output: $out)"
grep -qF "missing: .github/hooks/cerebro-question-state.json (hooks/copilot/cerebro-question-state.json is shipped and has no tracked link)" <<<"$out" \
  || fail "expected the missing hook link reported, got: $out"
pass "a provider hook with no tracked link is reported"

# --- the real repository, and the usage refusal --------------------------------------------------
#
# The case the bead exists for: this would have been red on main for three merges after d7a76fa.
# The script resolves its own root, so the suite's shell needs no `cd'.

run "$script"
[[ $status -eq 0 ]] || fail "this repository's tracked links must be whole, got $status: $out"
[[ -z "$out" ]] || fail "this repository's tracked links must be whole, got: $out"
pass "this repository's own tracked links are whole"

run "$script" --whole
[[ $status -eq 2 ]] || fail "an argument must exit 2, got $status"
[[ -z "$out" ]] || fail "a usage error must print no findings, got: $out"
grep -qF "usage: tracked-links" "$work_dir/err" \
  || fail "expected the usage line on stderr, got: $(cat "$work_dir/err")"
pass "an argument is a usage error, and prints no findings"

suite_passed
