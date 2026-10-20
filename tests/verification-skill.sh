#!/usr/bin/env bash
#
# Proves the `verification_skill' key a consumer declares to name ITS OWN verification procedure
# reaches the end of project-conf's lookup, and that its absence is reported rather than silent
# (ah-38qc). The verifier reads the key; that the role does so, and stays generic, is kept by
# reading CLAUDE.md, never by grepping the role's prose (cb-ozf5).
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
# The key survives to the end of the line, and its absence is SAID, not silent - this is what
# turns absence into "the step is skipped" rather than "the file is broken".
#
# This pins the contract the verifier depends on, so a later change to project-conf's lookup
# cannot silently break it - project-conf itself needs no change here, since
# its generic key/value lookup already does this (see README.md and scripts/project-conf).
# ---------------------------------------------------------------------------
consumer="$(consumer_new repo --link consumer-root project-conf)"
project_conf="$consumer/.cerebro/cerebro/scripts/project-conf"
mkdir -p "$consumer/.cerebro"

# A made-up consumer skill name, deliberately not any real project's own.
printf 'verification_skill  some-project-skill\n' > "$consumer/.cerebro/project.conf"
out="$("$project_conf" verification_skill 2>/dev/null)"
[[ "$out" == "some-project-skill" ]] \
  || fail "verification_skill: expected 'some-project-skill', got '$out'"
pass "the declared value survives to the end of the line"

bare="$(consumer_new bare --link consumer-root project-conf)"
mkdir -p "$bare/.cerebro"
: > "$bare/.cerebro/project.conf"

out="$("$bare/.cerebro/cerebro/scripts/project-conf" verification_skill 2>"$work_dir/err")" || true
[[ -z "$out" ]] || fail "no verification_skill: expected no value on stdout, got '$out'"
grep -q 'verification_skill unset' "$work_dir/err" \
  || fail "no verification_skill: the absence must be SAID, not silent - that is what makes the step skippable"
pass "no verification_skill is reported as unset, which is what makes the step skippable"

suite_passed
