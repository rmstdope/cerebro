#!/usr/bin/env bash
#
# Proves a consumer can declare ITS OWN verification procedure, and that the verifier reads it
# before it ever prepares a launch (ah-38qc).
#
# agents/verifier.md must stay generic - it ships to every consumer of this submodule, the same
# way agents/reviewer.md and skills/implement-bead/SKILL.md do (tests/launch-targets.sh already
# proves that for launch commands and ports). A consumer whose verification has a procedure of its
# own - which shell to prefer, how a fixture is chosen and proved, what a script looks like -
# declares it under a new, generic key, `verification_skill', exactly the way it already declares
# `fixtures_doc'. NOTHING here may name the consumer that first needed this (atlantis, or its
# skill's own name) except as data a throwaway consumer's OWN fixture feeds in - never as prose a
# role reads.
#
# No framework: plain bash, exit non-zero on the first failed assertion. Run from the submodule
# root:
#
#     bash tests/verification-skill.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# ---------------------------------------------------------------------------
# 1. The verifier is told to read the key, before it ever prepares a launch.
# ---------------------------------------------------------------------------
grep -q 'verification_skill' "$repo_root/agents/verifier.md" \
  || fail "verifier.md: nothing tells the role to read the key, so no consumer's skill is ever loaded"
pass "the verifier reads verification_skill before it prepares"

# ---------------------------------------------------------------------------
# 2. The key survives to the end of the line, and its absence is SAID, not silent - this is what
#    turns absence into "the step is skipped" rather than "the file is broken".
#
# This pins the CONTRACT the prose in agents/verifier.md now depends on, so a later change to
# project-conf's lookup cannot silently break it - project-conf itself needs no change here, since
# its generic key/value lookup already does this (see README.md and scripts/project-conf).
# ---------------------------------------------------------------------------
consumer="$(consumer_new repo --link consumer-root project-conf)"
project_conf="$consumer/.claude/cerebro/scripts/project-conf"
mkdir -p "$consumer/.cerebro"

# A made-up consumer skill name, deliberately not this project's own - a name that matched this
# repository's would make assertion 3 below (the role file stays generic) ambiguous to read.
printf 'verification_skill  some-project-skill\n' > "$consumer/.cerebro/project.conf"
out="$("$project_conf" verification_skill 2>/dev/null)"
[[ "$out" == "some-project-skill" ]] \
  || fail "verification_skill: expected 'some-project-skill', got '$out'"
pass "the declared value survives to the end of the line"

bare="$(consumer_new bare --link consumer-root project-conf)"
mkdir -p "$bare/.cerebro"
: > "$bare/.cerebro/project.conf"

out="$("$bare/.claude/cerebro/scripts/project-conf" verification_skill 2>"$work_dir/err")" || true
[[ -z "$out" ]] || fail "no verification_skill: expected no value on stdout, got '$out'"
grep -q 'verification_skill unset' "$work_dir/err" \
  || fail "no verification_skill: the absence must be SAID, not silent - that is what makes the step skippable"
pass "no verification_skill is reported as unset, which is what makes the step skippable"

# ---------------------------------------------------------------------------
# 3. The role file stays generic. Green from the start - this is a REGRESSION GUARD for the
#    navigator's standing rule (agents/verifier.md ships to every consumer of this submodule), not
#    a driver. Do not "fix" it later by deleting it because it never fails.
# ---------------------------------------------------------------------------
grep -qi 'atlantis' "$repo_root/agents/verifier.md" \
  && fail "verifier.md names a consumer project; the whole point of the key is that it does not"
pass "the verifier names no consumer project"

suite_passed
