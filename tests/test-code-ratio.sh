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
expect() { # <what> <want> <got>
  [[ "$3" == "$2" ]] || fail "$1: want
$2
got
$3"
}

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
lines "src/a:b.sh" 'one'                                  # 1: a colon is no separator
lines src/fixtures/f.sh 'f1' 'f2' 'f3' 'f4' 'f5'          # 5, test: test_code_paths wins
# Only a #[cfg(test)] module is test, wherever it sits; the attribute on anything else is not.
lines src/lib.rs \
  '#[cfg(test)] use crate::x;' \
  'fn a() {}' \
  '' \
  '#[cfg(test)]' \
  'mod mid {' \
  '    fn t() {}' \
  '}' \
  'fn b() {}' \
  '#[cfg(test)]' \
  'fn helper() {}' \
  '#[cfg(test)]' \
  '#[allow(dead_code)]' \
  'mod tests {' \
  '    #[test] fn t() {}' \
  '}'                                                   # 5 production, 9 test
lines tests/big.sh 1 2 3 4 5 6 7 8 9 10                   # 10
lines tests/small.sh 1 2                                  # 2
lines docs/readme.md 1 2 3 4 5 6 7 8 9                    # in neither: not counted
lines src/untracked.sh 1 2 3 4 5 6 7 8 9                  # never committed: not counted
printf 'bin\0ary\0\n\nmore\n' > "$consumer/src/blob.bin" # binary: not counted
printf '\0\0\0\n' > "$consumer/tests/blob.bin"
track src/a.sh "src/with space.sh" "src/a:b.sh" src/fixtures/f.sh src/lib.rs tests/big.sh \
  tests/small.sh docs/readme.md src/blob.bin tests/blob.bin

counted=$'production 11\ntest 26\nratio 2.36'
expect "the count" "$counted" "$(run 2>/dev/null)"
pass "non-blank lines of committed text; test paths win; only a Rust #[cfg(test)] module is test"

# A personal git config must not change the count: line numbers, columns, colour and a pattern
# dialect all rewrite what `git grep' prints or matches.
out="$(cd "$consumer" && GIT_CONFIG_COUNT=4 \
  GIT_CONFIG_KEY_0=grep.lineNumber GIT_CONFIG_VALUE_0=true \
  GIT_CONFIG_KEY_1=grep.column GIT_CONFIG_VALUE_1=true \
  GIT_CONFIG_KEY_2=color.ui GIT_CONFIG_VALUE_2=always \
  GIT_CONFIG_KEY_3=grep.patternType GIT_CONFIG_VALUE_3=fixed \
  "$ratio" 2>/dev/null)"
expect "under a personal git config" "$counted" "$out"
pass "the count is the same under grep.lineNumber, grep.column, color.ui and grep.patternType"

# --- the largest test files -----------------------------------------------------------------------

top3="$counted"$'\ntop 10 tests/big.sh\ntop 9 src/lib.rs\ntop 5 src/fixtures/f.sh'
expect "--top 3" "$top3" "$(run --top 3 2>/dev/null)"
expect "--top 03" "$top3" "$(run --top 03 2>/dev/null)"
pass "--top <n> names the n largest test files, largest first; a leading zero is still decimal"

status=0
run --top x >/dev/null 2>&1 || status=$?
[[ $status -eq 2 ]] || fail "--top x: want usage exit 2, got $status"
pass "--top takes a number"

# --- a revision ----------------------------------------------------------------------------------

lines tests/later.sh 1 2 3
track tests/later.sh
git_q -C "$consumer" update-ref refs/remotes/origin/main HEAD~1
expect "--rev HEAD~1" "$counted" "$(run --rev HEAD~1 2>/dev/null)"
expect "--rev origin/main" "$counted" "$(run --rev origin/main 2>/dev/null)"
later=$'production 11\ntest 29\nratio 2.64'
expect "HEAD after a commit" "$later" "$(run 2>/dev/null)"
pass "it counts HEAD by default and any revision under --rev, never the working tree"

for bad in no-such-rev HEAD:src; do
  status=0
  run --rev "$bad" >/dev/null 2>&1 || status=$?
  [[ $status -eq 2 ]] || fail "--rev $bad: want exit 2, got $status"
done
pass "an unknown revision, or a path inside one, is exit 2"

# --- no production code ---------------------------------------------------------------------------

conf 'production_code_paths ^nothing/' 'test_code_paths ^tests/'
expect "no production code" $'production 0\ntest 15\nratio -' "$(run 2>/dev/null)"
pass "with no production code the ratio is '-', not a division by zero"

# --- the same from a subdirectory -----------------------------------------------------------------

conf 'production_code_paths ^src/' 'test_code_paths ^(tests/|src/fixtures/)'
expect "from src/" "$later" "$(cd "$consumer/src" && "$ratio" 2>/dev/null)"
pass "it counts the whole consumer from any directory in it"

suite_passed
