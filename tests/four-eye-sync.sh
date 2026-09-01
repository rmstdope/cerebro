#!/usr/bin/env bash
#
# Proves `scripts/four-eye-sync' answers "do this repository's copies of the merge-review rule
# agree". The rule is written once, in `templates/four-eye-principle.md'; the two documents that
# carry it - the root `CLAUDE.md' and `templates/consumer-CLAUDE.md' - wrap their copy in
# `<!-- four-eye:begin -->' / `<!-- four-eye:end -->' markers, and this is what makes a drifted
# copy a red gate rather than a silent divergence. The two had already drifted when cb-m7u was
# filed: the root's closing sentence was never in the template.
#
# Fixtures are not consumers - `copy_cerebro_into' brings `scripts/' but neither `templates/' nor
# `CLAUDE.md', so the suite writes those itself. Everything it fabricates lives under `$work_dir';
# `$repo_root' is only ever read.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/four-eye-sync.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/four-eye-sync"
[[ -f "$script" ]] || fail "scripts/four-eye-sync does not exist"
[[ -x "$script" ]] || fail "scripts/four-eye-sync is not executable"

# A fixture: the scripts (so `four-eye-sync' itself), plus the two carriers and the canonical
# fragment written here - `copy_cerebro_into' brings neither `templates/' nor `CLAUDE.md'.
# `fixture_name' rather than a counter, because this is called as `fix="$(new_fixture)"' and a
# counter incremented in that subshell would never survive it.
BLOCK='Nothing merges unreviewed and nothing merges red.

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself**, and it counts when every check is green.'

new_fixture() {
  local fix="$work_dir/$(fixture_name foureye)"
  copy_cerebro_into "$fix"
  mkdir -p "$fix/templates"
  printf '%s\n' "$BLOCK" >"$fix/templates/four-eye-principle.md"
  local carrier
  for carrier in "$fix/CLAUDE.md" "$fix/templates/consumer-CLAUDE.md"; do
    {
      printf '## Four Eye Principle\n\n*A preamble this carrier owns.*\n\n'
      printf '<!-- four-eye:begin -->\n\n%s\n\n<!-- four-eye:end -->\n\n' "$BLOCK"
      printf 'A closing paragraph this carrier owns.\n'
    } >"$carrier"
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
grep -qF "usage: four-eye-sync" "$work_dir/err" \
  || fail "expected the usage line on stderr, got: $(cat "$work_dir/err")"
pass "an argument is a usage error, and prints no findings"

# --- a missing canonical block is the only finding ------------------------------------------------
#
# Reporting the carriers too would bury the one real fault under two `drifted:' lines.

fix="$(new_fixture)"
rm "$fix/templates/four-eye-principle.md"
run "$fix/scripts/four-eye-sync"
[[ $status -eq 1 ]] || fail "a missing canonical block must exit 1, got $status (output: $out)"
[[ "$out" == "missing: templates/four-eye-principle.md (the canonical block)" ]] \
  || fail "expected exactly the missing: line, got: $out"
pass "a missing canonical block is the only finding"

# --- carriers that agree are silent, and one that does not is reported ----------------------------

fix="$(new_fixture)"
run "$fix/scripts/four-eye-sync"
[[ $status -eq 0 ]] || fail "agreeing carriers must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "agreeing carriers must print nothing, got: $out"
pass "carriers that carry the block verbatim are silent"

fix="$(new_fixture)"
perl -0pi -e 's/Nothing merges unreviewed/Nothing merges unread/' "$fix/templates/consumer-CLAUDE.md"
run "$fix/scripts/four-eye-sync"
[[ $status -eq 1 ]] || fail "a drifted carrier must exit 1, got $status (output: $out)"
[[ "$out" == "drifted: templates/consumer-CLAUDE.md (block differs from templates/four-eye-principle.md)" ]] \
  || fail "expected exactly the drifted: line, got: $out"
pass "a carrier whose block has drifted is reported"

# --- the blank lines the markers need are not drift -----------------------------------------------
#
# CommonMark ends an HTML block at a blank line, so `<!-- four-eye:begin -->' must be followed by
# one or the paragraph is swallowed into the comment. The normalisation that makes those blanks
# safe is pinned here so a later simplification cannot quietly remove it.

fix="$(new_fixture)"
perl -0pi -e 's/<!-- four-eye:begin -->\n/<!-- four-eye:begin -->\n\n\n/' "$fix/CLAUDE.md"
perl -0pi -e 's/\n<!-- four-eye:end -->/\n\n\n<!-- four-eye:end -->/' "$fix/CLAUDE.md"
run "$fix/scripts/four-eye-sync"
[[ $status -eq 0 ]] || fail "extra blank lines beside the markers must exit 0, got $status: $out"
[[ -z "$out" ]] || fail "extra blank lines beside the markers must print nothing, got: $out"
pass "blank lines beside the markers are not drift"

# --- every malformed marker pair is one `unmarked:' line ------------------------------------------
#
# A carrier with no usable pair is not drift: there is no block to compare, and saying `drifted:'
# would send a reader to diff two things one of which does not exist.

for shape in no-begin no-end end-first two-begins; do
  fix="$(new_fixture)"
  case "$shape" in
    no-begin)   perl -0pi -e 's/<!-- four-eye:begin -->\n\n//' "$fix/CLAUDE.md" ;;
    no-end)     perl -0pi -e 's/\n<!-- four-eye:end -->//' "$fix/CLAUDE.md" ;;
    end-first)  perl -0pi -e 's/<!-- four-eye:begin -->/<!-- four-eye:end -->/; s/\n<!-- four-eye:end -->\n\nA closing/\n<!-- four-eye:begin -->\n\nA closing/' "$fix/CLAUDE.md" ;;
    two-begins) perl -0pi -e 's/<!-- four-eye:begin -->/<!-- four-eye:begin -->\n\n<!-- four-eye:begin -->/' "$fix/CLAUDE.md" ;;
  esac
  run "$fix/scripts/four-eye-sync"
  [[ $status -eq 1 ]] || fail "$shape must exit 1, got $status (output: $out)"
  [[ "$out" == "unmarked: CLAUDE.md (no four-eye:begin/end pair)" ]] \
    || fail "expected exactly the unmarked: line for $shape, got: $out"
done
pass "a carrier with no usable marker pair is reported"

# --- a carrier that is not there says so ----------------------------------------------------------
#
# Not `unmarked:': that would send a reader to grep a file that is gone.

fix="$(new_fixture)"
rm "$fix/CLAUDE.md"
run "$fix/scripts/four-eye-sync"
[[ $status -eq 1 ]] || fail "a missing carrier must exit 1, got $status (output: $out)"
[[ "$out" == "missing: CLAUDE.md (carrier file not found)" ]] \
  || fail "expected exactly the missing carrier line, got: $out"
pass "a carrier file that is not there is named as missing, not as unmarked"

# --- the real repository --------------------------------------------------------------------------
#
# The case the bead exists for. The script resolves its own root, so the suite's shell needs no
# `cd'.

run "$script"
[[ $status -eq 0 ]] || fail "this repository's Four Eye copies must agree, got $status: $out"
[[ -z "$out" ]] || fail "this repository's Four Eye copies must agree, got: $out"
pass "this repository's own Four Eye copies agree"

suite_passed
