#!/usr/bin/env bash
#
# Proves `scripts/pipefail-pipelines` reports pipeline readers that can exit before their writer
# drains, under `set -o pipefail`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/pipefail-pipelines"
[[ -f "$script" ]] || fail "scripts/pipefail-pipelines does not exist"
[[ -x "$script" ]] || fail "scripts/pipefail-pipelines is not executable"

quiet='grep -qF needle'
first_line='head -n 1'

new_fixture() {
  local fix="$work_dir/$(fixture_name pipefail)"
  mkdir -p "$fix/scripts" "$fix/tests"
  cp "$script" "$fix/scripts/pipefail-pipelines"
  chmod +x "$fix/scripts/pipefail-pipelines"
  git init -q "$fix"
  echo "$fix"
}

out=""
status=0
run() {
  set +e
  out="$("$@" 2>"$work_dir/err")"
  status=$?
  set -e
}

# --- a draining test source is silent -------------------------------------------------------------

fix="$(new_fixture)"
cat >"$fix/tests/safe.sh" <<'SAFE'
#!/usr/bin/env bash
printf '%s\n' one | grep -v two
SAFE
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/pipefail-pipelines"
[[ $status -eq 0 ]] || fail "a draining fixture must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "a draining fixture must print nothing, got: $out"
pass "a draining test source produces no findings"

# --- quiet grep is reported -----------------------------------------------------------------------

fix="$(new_fixture)"
printf 'printf "needle\\n" | %s\n' "$quiet" >"$fix/tests/quiet.sh"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/pipefail-pipelines"
[[ $status -eq 1 ]] || fail "a quiet grep pipeline must exit 1, got $status (output: $out)"
grep -q '^unsafe pipeline: tests/quiet.sh:1 .*grep' <<<"$out" \
  || fail "expected a quiet-grep finding with path and line, got: $out"
pass "a quiet grep pipeline is reported with its path and line"

# --- head is reported too -------------------------------------------------------------------------

fix="$(new_fixture)"
printf 'printf "one\\ntwo\\n" | %s\n' "$first_line" >"$fix/tests/head.sh"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/pipefail-pipelines"
[[ $status -eq 1 ]] || fail "a head pipeline must exit 1, got $status (output: $out)"
grep -q '^unsafe pipeline: tests/head.sh:1 .*head' <<<"$out" \
  || fail "expected a head finding with path and line, got: $out"
pass "a head pipeline is reported with its path and line"

# --- untracked source is scanned ------------------------------------------------------------------

fix="$(new_fixture)"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
printf 'printf "needle\\n" | %s\n' "$quiet" >"$fix/tests/fresh.sh"
run "$fix/scripts/pipefail-pipelines"
[[ $status -eq 1 ]] || fail "an untracked pipeline must exit 1, got $status (output: $out)"
grep -q '^unsafe pipeline: tests/fresh.sh:1 ' <<<"$out" \
  || fail "expected an untracked finding, got: $out"
pass "an untracked test source is scanned"

# --- an argument is a usage error -----------------------------------------------------------------

run "$script" --all
[[ $status -eq 2 ]] || fail "an argument must exit 2, got $status (output: $out)"
[[ -z "$out" ]] || fail "a usage refusal must print no findings, got: $out"
grep -q 'usage: pipefail-pipelines' "$work_dir/err" \
  || fail "a usage refusal must name itself, got: $(cat "$work_dir/err")"
pass "an argument is a usage error and prints no findings"

suite_passed
