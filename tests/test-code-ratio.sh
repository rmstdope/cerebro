#!/usr/bin/env bash
#
# Proves `scripts/test-code-ratio`: the one count of production against test code Sage (qa) reports
# every pass and warns on past 1:2 (cb-nm58).
#
#     bash tests/test-code-ratio.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

consumer="$(consumer_new ratio --link project-conf consumer-root test-code-ratio)"
ratio="$consumer/.cerebro/cerebro/scripts/test-code-ratio"

run() { (cd "$consumer" && "$ratio" "$@"); }
conf() { printf '%s\n' "$@" > "$consumer/.cerebro/project.conf"; }
lines() { mkdir -p "$(dirname "$consumer/$1")"; printf '%s\n' "${@:2}" > "$consumer/$1"; }
track() { git_q -C "$consumer" add -f -- "$@"; git_q -C "$consumer" commit -q -m fixture; }

# --- refuses rather than guesses ------------------------------------------------------------------

for missing in production_code_paths test_code_paths; do
  if [[ "$missing" == production_code_paths ]]; then conf 'test_code_paths ^tests/'
  else conf 'production_code_paths ^src/'; fi
  status=0
  out="$(run 2>"$work_dir/err")" || status=$?
  [[ $status -eq 3 ]] || fail "absent $missing: want exit 3, got $status"
  [[ -z "$out" ]] || fail "absent $missing: stdout must be empty, got: $out"
  grep -q "$missing" "$work_dir/err" || fail "absent $missing: stderr must name it: $(cat "$work_dir/err")"
done
pass "an absent key is exit 3, named on stderr, nothing on stdout"

# --- the count ------------------------------------------------------------------------------------

conf 'production_code_paths ^src/' 'test_code_paths ^(tests/|src/fixtures/)'

lines src/a.sh 'one' '' 'two' '   ' 'three'             # 3 non-blank
lines "src/with space.sh" 'one' 'two'                     # 2
lines src/fixtures/f.sh 'f1' 'f2' 'f3' 'f4' 'f5'          # 5, test: test_code_paths wins
lines src/lib.rs 'fn a() {}' 'fn b() {}' '' \
  '#[cfg(test)]' 'mod tests {' '    #[test] fn t() {}' '}'   # 2 production, 4 test
lines tests/big.sh 1 2 3 4 5 6 7 8 9 10                   # 10
lines tests/small.sh 1 2                                  # 2
lines docs/readme.md 1 2 3 4 5 6 7 8 9                    # in neither: not counted
lines src/untracked.sh 1 2 3 4 5 6 7 8 9                  # never committed: not counted
printf 'bin\0ary\0\n\nmore\n' > "$consumer/src/blob.bin" # binary: not counted
printf '\0\0\0\n' > "$consumer/tests/blob.bin"
track src/a.sh "src/with space.sh" src/fixtures/f.sh src/lib.rs tests/big.sh tests/small.sh \
  docs/readme.md src/blob.bin tests/blob.bin

out="$(run 2>/dev/null)"
want=$'production 7\ntest 21\nratio 3.00'
[[ "$out" == "$want" ]] || fail "the count: want
$want
got
$out"
pass "non-blank lines of committed text; test paths win; a Rust #[cfg(test)] tail is test"

# --- the largest test files -----------------------------------------------------------------------

out="$(run --top 3 2>/dev/null)"
want=$'production 7\ntest 21\nratio 3.00\ntop 10 tests/big.sh\ntop 5 src/fixtures/f.sh\ntop 4 src/lib.rs'
[[ "$out" == "$want" ]] || fail "--top 3: want
$want
got
$out"
pass "--top <n> names the n largest test files, largest first, a Rust tail counted as its file"

status=0
run --top x >/dev/null 2>&1 || status=$?
[[ $status -eq 2 ]] || fail "--top x: want usage exit 2, got $status"
pass "--top takes a number"

# --- a revision ----------------------------------------------------------------------------------

lines tests/later.sh 1 2 3
track tests/later.sh
out="$(run --rev HEAD~1 2>/dev/null)"
[[ "$out" == $'production 7\ntest 21\nratio 3.00' ]] || fail "--rev HEAD~1: got
$out"
out="$(run 2>/dev/null)"
[[ "$out" == $'production 7\ntest 24\nratio 3.43' ]] || fail "HEAD after a commit: got
$out"
pass "it counts HEAD by default and any revision under --rev, never the working tree"

status=0
run --rev no-such-rev >/dev/null 2>&1 || status=$?
[[ $status -eq 2 ]] || fail "--rev no-such-rev: want exit 2, got $status"
pass "an unknown revision is exit 2"

# --- no production code ---------------------------------------------------------------------------

conf 'production_code_paths ^nothing/' 'test_code_paths ^tests/'
out="$(run 2>/dev/null)"
[[ "$out" == $'production 0\ntest 15\nratio -' ]] || fail "no production code: got
$out"
pass "with no production code the ratio is '-', not a division by zero"

# --- the same from a subdirectory -----------------------------------------------------------------

conf 'production_code_paths ^src/' 'test_code_paths ^(tests/|src/fixtures/)'
out="$(cd "$consumer/src" && "$ratio" 2>/dev/null)"
[[ "$out" == $'production 7\ntest 24\nratio 3.43' ]] || fail "from src/: got
$out"
pass "it counts the whole consumer from any directory in it"

suite_passed
