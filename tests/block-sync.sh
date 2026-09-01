#!/usr/bin/env bash
#
# Proves `scripts/block-sync.sh' answers "does every carrier's marked copy of a canonical block
# match the canonical file". The mechanism arrived with cb-m7u for the Four Eye Principle and is
# now shared with `scripts/state-contract-sync' (cb-mqa), so the marker parse, the comparison and
# the finding text live once, in a sourced library, and each predicate keeps only its own header,
# carrier list and exit codes.
#
# The library is SOURCED, never executed: `cerebro_block_sync' returns rather than exits, and the
# suite needs both its stdout and its return value. Each case sources the copy inside its own
# fixture, so what is proved is the shipped file rather than a copy written here.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/block-sync.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

lib="$repo_root/scripts/block-sync.sh"
[[ -f "$lib" ]] || fail "scripts/block-sync.sh does not exist"

BLOCK='The canonical paragraph, which every carrier must hold verbatim.

A second paragraph, so the block is more than one line.'

# A fixture: the scripts (so `block-sync.sh' itself), a canonical file and two carriers. The marker
# word is a parameter, which is the whole reason the library exists rather than a second copy of
# `four-eye-sync'.
new_fixture() {
  local marker="${1:-demo}"
  local fix="$work_dir/$(fixture_name blocksync)"
  copy_cerebro_into "$fix"
  mkdir -p "$fix/templates"
  printf '%s\n' "$BLOCK" >"$fix/templates/canonical.md"
  local carrier
  for carrier in one two; do
    {
      printf '# %s\n\n*A preamble this carrier owns.*\n\n' "$carrier"
      printf '<!-- %s:begin -->\n\n%s\n\n<!-- %s:end -->\n\n' "$marker" "$BLOCK" "$marker"
      printf 'A closing paragraph this carrier owns.\n'
    } >"$fix/$carrier.md"
  done
  echo "$fix"
}

# `cerebro_block_sync' returns; the subshell keeps its `set' state and any stray `exit' out of the
# suite, and the paths are relative to the fixture, so the subshell cds there first.
out=""
status=0
run_lib() {                       # run_lib <fixture> <marker> <canonical> <carrier>...
  local fix="$1"; shift
  set +e
  out="$(cd "$fix" && source "$fix/scripts/block-sync.sh" && cerebro_block_sync "$@" 2>"$work_dir/err")"
  status=$?
  set -e
}

# --- carriers that agree are silent ---------------------------------------------------------------

fix="$(new_fixture)"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 0 ]] || fail "agreeing carriers must return 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "agreeing carriers must print nothing, got: $out"
pass "carriers that carry the block verbatim are silent"

# --- a drifted carrier is reported ----------------------------------------------------------------

fix="$(new_fixture)"
perl -0pi -e 's/The canonical paragraph/The canonical sentence/' "$fix/two.md"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 1 ]] || fail "a drifted carrier must return 1, got $status (output: $out)"
[[ "$out" == "drifted: two.md (block differs from templates/canonical.md)" ]] \
  || fail "expected exactly the drifted: line, got: $out"
pass "a carrier whose block has drifted is reported"

# --- the blank lines the markers need are not drift -----------------------------------------------
#
# CommonMark ends an HTML block at a blank line, so a marker followed straight by prose swallows
# that prose into the comment. The normalisation that makes those blanks safe is pinned here so a
# later simplification cannot quietly remove it.

fix="$(new_fixture)"
perl -0pi -e 's/<!-- demo:begin -->\n/<!-- demo:begin -->\n\n\n/' "$fix/one.md"
perl -0pi -e 's/\n<!-- demo:end -->/\n\n\n<!-- demo:end -->/' "$fix/one.md"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 0 ]] || fail "extra blank lines beside the markers must return 0, got $status: $out"
[[ -z "$out" ]] || fail "extra blank lines beside the markers must print nothing, got: $out"
pass "blank lines beside the markers are not drift"

# ... and a line that only looks blank is drift, deliberately: the comparison is otherwise
# byte-exact, and an invisible difference the checker forgives is one no reader can see either.

fix="$(new_fixture)"
perl -0pi -e 's/\n\n<!-- demo:end -->/\n \n<!-- demo:end -->/' "$fix/one.md"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 1 ]] || fail "a whitespace-only line must be drift, got $status: $out"
[[ "$out" == "drifted: one.md (block differs from templates/canonical.md)" ]] \
  || fail "expected exactly the drifted: line, got: $out"
pass "a line of spaces beside a marker is drift, not a blank line"

# --- every malformed marker pair is one `unmarked:' line ------------------------------------------

for shape in no-begin no-end end-first two-begins; do
  fix="$(new_fixture)"
  case "$shape" in
    no-begin)   perl -0pi -e 's/<!-- demo:begin -->\n\n//' "$fix/one.md" ;;
    no-end)     perl -0pi -e 's/\n<!-- demo:end -->//' "$fix/one.md" ;;
    end-first)  perl -0pi -e 's/<!-- demo:begin -->/<!-- demo:end -->/; s/\n<!-- demo:end -->\n\nA closing/\n<!-- demo:begin -->\n\nA closing/' "$fix/one.md" ;;
    two-begins) perl -0pi -e 's/<!-- demo:begin -->/<!-- demo:begin -->\n\n<!-- demo:begin -->/' "$fix/one.md" ;;
  esac
  run_lib "$fix" demo templates/canonical.md one.md two.md
  [[ $status -eq 1 ]] || fail "$shape must return 1, got $status (output: $out)"
  [[ "$out" == "unmarked: one.md (no demo:begin/end pair)" ]] \
    || fail "expected exactly the unmarked: line for $shape, got: $out"
done
pass "a carrier with no usable marker pair is reported"

# --- a carrier that is not there says so ----------------------------------------------------------
#
# Not `unmarked:': a carrier that is gone has no markers to have lost, and saying it does sends a
# reader to grep a file that is not there.

fix="$(new_fixture)"
rm "$fix/one.md"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 1 ]] || fail "a missing carrier must return 1, got $status (output: $out)"
[[ "$out" == "missing: one.md (carrier file not found)" ]] \
  || fail "expected exactly the missing carrier line, got: $out"
pass "a carrier file that is not there is named as missing, not as unmarked"

# --- a missing canonical block is the only finding ------------------------------------------------
#
# Reporting the carriers too would bury the one real fault under two `drifted:' lines.

fix="$(new_fixture)"
rm "$fix/templates/canonical.md"
run_lib "$fix" demo templates/canonical.md one.md two.md
[[ $status -eq 1 ]] || fail "a missing canonical block must return 1, got $status (output: $out)"
[[ "$out" == "missing: templates/canonical.md (the canonical block)" ]] \
  || fail "expected exactly the missing: line, got: $out"
pass "a missing canonical block is the only finding"

# --- the marker word is a parameter ---------------------------------------------------------------
#
# The whole reason this is a library rather than a second copy of `four-eye-sync'.

fix="$(new_fixture zzz)"
run_lib "$fix" zzz templates/canonical.md one.md two.md
[[ $status -eq 0 ]] || fail "another marker word must return 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "another marker word must print nothing, got: $out"

perl -0pi -e 's/<!-- zzz:end -->//' "$fix/two.md"
run_lib "$fix" zzz templates/canonical.md one.md two.md
[[ $status -eq 1 ]] || fail "a broken zzz pair must return 1, got $status (output: $out)"
[[ "$out" == "unmarked: two.md (no zzz:begin/end pair)" ]] \
  || fail "expected the marker word in the finding, got: $out"
pass "the marker word is a parameter, in the parse and in the finding"

suite_passed
