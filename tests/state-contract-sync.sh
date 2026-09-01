#!/usr/bin/env bash
#
# Proves `scripts/state-contract-sync' answers "do this repository's copies of the state-file
# contract agree". The contract - how to call `scripts/agent-state', what the four state words
# mean, what `--pid $PPID' is, the question sandwich, the hook behind `asking' - is written once,
# in `templates/state-file-contract.md'; the seven role documents that carry it wrap their copy in
# `<!-- state-contract:begin -->' / `<!-- state-contract:end -->' markers, and this is what makes a
# drifted copy a red gate rather than a silent divergence. It had already drifted when cb-mqa was
# filed: one sentence was corrected in `implementer.md' and re-corrected across five more files
# three days later, and `verifier.md' still told Psylocke to write `idle' at the end of a pass
# directly under the bullet forbidding it.
#
# Fixtures are not consumers - `copy_cerebro_into' brings `scripts/', `agents/' and `skills/', so
# the suite overwrites the carriers it needs and writes the canonical file itself. Everything it
# fabricates lives under `$work_dir'; `$repo_root' is only ever read.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/state-contract-sync.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/state-contract-sync"
[[ -f "$script" ]] || fail "scripts/state-contract-sync does not exist"
[[ -x "$script" ]] || fail "scripts/state-contract-sync is not executable"

BLOCK='Write it at every transition, through `scripts/agent-state` and never by hand.

There are four state words and no others: `idle`, `working`, `asking`, `waiting`.'

# The carrier list is the script'"'"'s own decision, so the fixture spells it out here: a carrier added
# to `scripts/state-contract-sync' without a row here fails loudly rather than passing silently.
CARRIERS=(
  agents/architect.md
  agents/orchestrator.md
  agents/reviewer.md
  agents/user-feedback.md
  agents/verifier.md
  skills/implement-bead/SKILL.md
  skills/plan-bead/SKILL.md
)

new_fixture() {
  local fix="$work_dir/$(fixture_name statecontract)"
  copy_cerebro_into "$fix"
  mkdir -p "$fix/templates"
  printf '%s\n' "$BLOCK" >"$fix/templates/state-file-contract.md"
  local carrier
  for carrier in "${CARRIERS[@]}"; do
    mkdir -p "$fix/$(dirname "$carrier")"
    {
      printf '# %s\n\n*A preamble this carrier owns.*\n\n' "$carrier"
      printf '<!-- state-contract:begin -->\n\n%s\n\n<!-- state-contract:end -->\n\n' "$BLOCK"
      printf 'The table this carrier owns.\n'
    } >"$fix/$carrier"
  done
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

# --- the usage refusal ---------------------------------------------------------------------------

run "$script" --whole
[[ $status -eq 2 ]] || fail "an argument must exit 2, got $status"
[[ -z "$out" ]] || fail "a usage error must print no findings, got: $out"
grep -qF "usage: state-contract-sync" "$work_dir/err" \
  || fail "expected the usage line on stderr, got: $(cat "$work_dir/err")"
pass "an argument is a usage error, and prints no findings"

# --- carriers that agree are silent ---------------------------------------------------------------

fix="$(new_fixture)"
run "$fix/scripts/state-contract-sync"
[[ $status -eq 0 ]] || fail "agreeing carriers must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "agreeing carriers must print nothing, got: $out"
pass "carriers that carry the block verbatim are silent"

# --- one drifted carrier is one finding -----------------------------------------------------------

fix="$(new_fixture)"
perl -0pi -e 's/There are four state words/There are five state words/' "$fix/agents/verifier.md"
run "$fix/scripts/state-contract-sync"
[[ $status -eq 1 ]] || fail "a drifted carrier must exit 1, got $status (output: $out)"
[[ "$out" == "drifted: agents/verifier.md (block differs from templates/state-file-contract.md)" ]] \
  || fail "expected exactly the drifted: line, got: $out"
pass "a carrier whose block has drifted is reported"

# --- one unmarked carrier is one finding ----------------------------------------------------------

fix="$(new_fixture)"
perl -0pi -e 's/\n<!-- state-contract:end -->//' "$fix/skills/plan-bead/SKILL.md"
run "$fix/scripts/state-contract-sync"
[[ $status -eq 1 ]] || fail "an unmarked carrier must exit 1, got $status (output: $out)"
[[ "$out" == "unmarked: skills/plan-bead/SKILL.md (no state-contract:begin/end pair)" ]] \
  || fail "expected exactly the unmarked: line, got: $out"
pass "a carrier with no usable marker pair is reported"

# --- a carrier that is not there says so ----------------------------------------------------------

fix="$(new_fixture)"
rm "$fix/agents/orchestrator.md"
run "$fix/scripts/state-contract-sync"
[[ $status -eq 1 ]] || fail "a missing carrier must exit 1, got $status (output: $out)"
[[ "$out" == "missing: agents/orchestrator.md (carrier file not found)" ]] \
  || fail "expected exactly the missing carrier line, got: $out"
pass "a carrier file that is not there is named as missing, not as unmarked"

# --- a missing canonical block is the only finding ------------------------------------------------

fix="$(new_fixture)"
rm "$fix/templates/state-file-contract.md"
run "$fix/scripts/state-contract-sync"
[[ $status -eq 1 ]] || fail "a missing canonical block must exit 1, got $status (output: $out)"
[[ "$out" == "missing: templates/state-file-contract.md (the canonical block)" ]] \
  || fail "expected exactly the missing: line, got: $out"
pass "a missing canonical block is the only finding"

# --- the real repository --------------------------------------------------------------------------
#
# The case the bead exists for, and the one a fixture cannot make. The script resolves its own root,
# so the suite's shell needs no `cd'.

run "$script"
[[ $status -eq 0 ]] || fail "this repository's state-file contract copies must agree, got $status: $out"
[[ -z "$out" ]] || fail "this repository's state-file contract copies must agree, got: $out"
pass "this repository's own state-file contract copies agree"

suite_passed
