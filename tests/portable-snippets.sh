#!/usr/bin/env bash
#
# Proves `scripts/portable-snippets' answers "do this repository's skills and agents contain a
# shell snippet that only word-splits under bash". An alternate-value expansion in a snippet an
# agent pastes into its tool shell means two different things on two machines: bash splits an
# unquoted one into several arguments and zsh does not. Two implementers paid for it at the same
# line of the same file (cb-i1w 2026-09-02, cb-hz4 2026-09-03), which is when this repository says
# a class of defect earns a check.
#
# Silence and exit 0 is the whole clean answer, and an argument is a usage error that prints no
# findings at all, so a mistake can never read as "portable".
#
# The fixtures are plain git repositories under `$work_dir' - the script sources nothing and reads
# only `git ls-files', so no consumer shape is needed. `$repo_root' is only ever read.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the repository root:
#
#     bash tests/portable-snippets.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/portable-snippets"
[[ -f "$script" ]] || fail "scripts/portable-snippets does not exist"
[[ -x "$script" ]] || fail "scripts/portable-snippets is not executable"

# The construct under test, built rather than written literally, so this suite's own prose does not
# have to carry it and a reader cannot mistake the fixture text for advice.
bad='${provider'":+--provider \"\$provider\"}"

# A fixture is a git repository holding a copy of the script and two ordinary Markdown files.
new_fixture() {
  local fix="$work_dir/$(fixture_name snippets)"
  mkdir -p "$fix/scripts" "$fix/skills/thing" "$fix/agents" "$fix/docs"
  cp "$script" "$fix/scripts/portable-snippets"
  chmod +x "$fix/scripts/portable-snippets"
  printf '# thing\n\nRun this:\n\n```bash\nmodel-for --role reviewer\n```\n' \
    >"$fix/skills/thing/SKILL.md"
  printf '# implementer\n\nOrdinary prose.\n' >"$fix/agents/implementer.md"
  git init -q "$fix"
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

# --- a portable checkout is silent ---------------------------------------------------------------

fix="$(new_fixture)"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 0 ]] || fail "a portable fixture must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "a portable fixture must print nothing, got: $out"
pass "a fixture with no alternate-value expansion produces no findings and exits 0"

# --- one under skills/ is a finding, with its path and line --------------------------------------

fix="$(new_fixture)"
printf 'model-for %s --role reviewer\n' "$bad" >>"$fix/skills/thing/SKILL.md"
line="$(wc -l <"$fix/skills/thing/SKILL.md" | tr -d ' ')"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 1 ]] || fail "an unportable snippet must exit 1, got $status (output: $out)"
grep -q "^unportable: skills/thing/SKILL.md:$line " <<<"$out" \
  || fail "expected a finding for skills/thing/SKILL.md:$line, got: $out"
pass "an alternate-value expansion under skills/ is reported with its path and line"

# --- one under agents/ is a finding too ----------------------------------------------------------

fix="$(new_fixture)"
printf 'launch %s\n' "$bad" >>"$fix/agents/implementer.md"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 1 ]] || fail "an unportable agent file must exit 1, got $status (output: $out)"
grep -q "^unportable: agents/implementer.md:" <<<"$out" \
  || fail "expected a finding for agents/implementer.md, got: $out"
pass "one under agents/ is reported too"

# --- outside the scan set it is not a finding ----------------------------------------------------
#
# This is what pins the pathspec. Widening it would make this suite read `docs/', which is on
# `scripts/ci-needed''s skip list, and a suite that starts reading one of those makes a green pull
# request that should have been red.

fix="$(new_fixture)"
printf 'model-for %s\n' "$bad" >>"$fix/docs/note.md"
printf 'model-for %s\n' "$bad" >>"$fix/scripts/example"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 0 ]] || fail "an occurrence outside the scan set must exit 0, got $status: $out"
[[ -z "$out" ]] || fail "an occurrence outside the scan set must print nothing, got: $out"
pass "an occurrence outside skills/ and agents/ is not a finding"

# --- a file written but not yet git-added is scanned ----------------------------------------------
#
# The moment this check exists for: the implementer writes the snippet and runs the gate before
# `git add'. That is what `--others --exclude-standard' buys, and why the enumeration is
# `git ls-files' rather than `grep -r'.

fix="$(new_fixture)"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
mkdir -p "$fix/skills/fresh"
printf 'model-for %s\n' "$bad" >"$fix/skills/fresh/SKILL.md"
run "$fix/scripts/portable-snippets"
[[ $status -eq 1 ]] || fail "an unstaged new skill must exit 1, got $status (output: $out)"
grep -q "^unportable: skills/fresh/SKILL.md:" <<<"$out" \
  || fail "expected a finding for the unstaged skill, got: $out"
pass "a new skill written but not yet git-added is scanned"

# --- the default-value form is deliberately not matched -------------------------------------------

fix="$(new_fixture)"
printf 'timeout "${BD_TIMEOUT%s30}" bd list\n' ':-' >>"$fix/skills/thing/SKILL.md"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 0 ]] || fail "a default-value expansion must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "a default-value expansion must print nothing, got: $out"
pass "a quoted default-value expansion is not a finding"

# --- the scan does not stop at the first occurrence ------------------------------------------------

fix="$(new_fixture)"
printf 'model-for %s\nsomething else\nlaunch %s\n' "$bad" "$bad" >>"$fix/skills/thing/SKILL.md"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 1 ]] || fail "two occurrences must exit 1, got $status (output: $out)"
[[ "$(grep -c '^unportable: ' <<<"$out")" -eq 2 ]] \
  || fail "expected two findings, got: $out"
pass "two occurrences in one file are two findings"

# --- a positional parameter is the same class ------------------------------------------------------

fix="$(new_fixture)"
printf 'launch %s\n' '${1'":+--name \"\$1\"}" >>"$fix/skills/thing/SKILL.md"
git_q -C "$fix" add -A
git_q -C "$fix" commit -q -m init
run "$fix/scripts/portable-snippets"
[[ $status -eq 1 ]] || fail "a positional-parameter expansion must exit 1, got $status: $out"
grep -q "^unportable: skills/thing/SKILL.md:" <<<"$out" \
  || fail "expected a finding for the positional parameter, got: $out"
pass "an alternate-value expansion on a positional parameter is a finding too"

# --- an argument is a usage error, and prints no findings -----------------------------------------

run "$script" --all
[[ $status -eq 2 ]] || fail "an argument must exit 2, got $status (output: $out)"
[[ -z "$out" ]] || fail "a usage refusal must print no findings, got: $out"
grep -q "usage: portable-snippets" "$work_dir/err" \
  || fail "a usage refusal must name itself on stderr, got: $(cat "$work_dir/err")"
pass "an argument is a usage error, and prints no findings"

# --- this repository answers clean ------------------------------------------------------------------

run "$repo_root/scripts/portable-snippets"
[[ $status -eq 0 ]] || fail "this repository must exit 0, got $status (output: $out)"
[[ -z "$out" ]] || fail "this repository must print no findings, got: $out"
pass "this repository's own skills and agents are portable"

suite_passed
