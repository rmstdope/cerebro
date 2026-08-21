#!/usr/bin/env bash
#
# Proves scripts/default-branch answers with the branch this consumer's fleet should read from,
# instead of the `main` that used to be hardcoded fifteen times across five scripts (ah-qled.3).
#
# Three answers, in this order, because CONFIGURED MUST BEAT DETECTED: a consumer that has both a
# `main` and does its work on `develop` is exactly the case `origin/HEAD` gets wrong.
#
#   1. the `default_branch` key in <consumer>/.claude/cerebro-project.conf
#   2. `git symbolic-ref --short refs/remotes/origin/HEAD`, minus its `origin/` prefix
#   3. `main`
#
# And a fourth thing that is not an answer but a constraint: WITH GIT UNAVAILABLE IT MUST STILL
# PRINT `main` AND EXIT 0. `launch` runs `launch-preflight` before it ever reaches `claude`, and
# tests/launchers.sh runs that path with a PATH of only `dirname` and `bash`; a resolver that fails
# hard there takes every launcher with it.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/default-branch.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

pass() {
  echo "ok - $1"
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

git_q() { git -c user.name=test -c user.email=test@example.com "$@"; }

# make_consumer <name> <branch>  ->  echoes the consumer path.
#
# A real clone of a real origin, so `refs/remotes/origin/HEAD` is set the way `git clone` sets it -
# which is the only way the detection step can be tested at all. The branch is a parameter because
# a fixture that only ever builds `main` agrees with the bug and proves nothing.
make_consumer() {
  local name="$1" branch="$2"
  local origin="$work_dir/$name-origin.git" consumer="$work_dir/$name" seed="$work_dir/$name-seed"

  git init -q --bare -b "$branch" "$origin"
  git init -q -b "$branch" "$seed"
  git_q -C "$seed" commit -q --allow-empty -m init
  git_q -C "$seed" push -q "$origin" "$branch"
  git clone -q "$origin" "$consumer"

  mkdir -p "$consumer/.claude/cerebro/scripts"
  local s
  for s in consumer-root project-conf default-branch; do
    ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
  done
  printf '%s\n' "$consumer"
}

resolve() { "$1/.claude/cerebro/scripts/default-branch" 2>/dev/null; }

# --- the configured key wins over a resolvable origin/HEAD ---
#
# THE precedence assertion: this consumer's origin/HEAD really does say `main`, and the answer must
# still be `develop`.
c="$(make_consumer configured main)"
echo "default_branch develop" > "$c/.claude/cerebro-project.conf"
out="$(resolve "$c")"
[[ "$out" == "develop" ]] || fail "configured: expected 'develop', got '$out'"
pass "the default_branch key beats a resolvable origin/HEAD"

# --- with no key, origin/HEAD is used ---
c="$(make_consumer detected trunk)"
out="$(resolve "$c")"
[[ "$out" == "trunk" ]] || fail "detected: expected 'trunk', got '$out'"
pass "origin/HEAD is used when no key is set"

# --- the origin/ prefix is stripped, never printed ---
[[ "$out" != origin/* ]] || fail "detected: the origin/ prefix survived: '$out'"
pass "the origin/ prefix is stripped"

# --- an unset origin/HEAD falls through quietly to main ---
#
# ORDINARY, not exceptional: `git clone` sets origin/HEAD, but a remote added with `git remote add`
# has none until somebody runs `git remote set-head`.
c="$(make_consumer unset trunk)"
git -C "$c" symbolic-ref --delete refs/remotes/origin/HEAD
out="$(resolve "$c")"
[[ "$out" == "main" ]] || fail "unset origin/HEAD: expected 'main', got '$out'"
pass "an unset origin/HEAD falls through to main"

# --- a standalone clone, with no consumer at all, still answers ---
standalone="$work_dir/standalone"
mkdir -p "$standalone/scripts"
for s in consumer-root project-conf default-branch; do
  ln -s "$repo_root/scripts/$s" "$standalone/scripts/$s"
done
set +e
out="$("$standalone/scripts/default-branch" 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "standalone: expected exit 0, got $status"
[[ "$out" == "main" ]] || fail "standalone: expected 'main', got '$out'"
pass "a standalone clone answers main rather than failing"

# --- git unavailable: main, exit 0 ---
#
# The constraint tests/launchers.sh:412-422 imposes. Asserted with the same narrowed PATH it uses.
c="$(make_consumer nogit trunk)"
narrow="$work_dir/bare-path"
mkdir -p "$narrow"
ln -s "$(command -v dirname)" "$narrow/dirname"
ln -s "$(command -v bash)" "$narrow/bash"
set +e
out="$(PATH="$narrow" "$(command -v bash)" "$c/.claude/cerebro/scripts/default-branch" 2>/dev/null)"
status=$?
set -e
[[ $status -eq 0 ]] || fail "no git: expected exit 0, got $status"
[[ "$out" == "main" ]] || fail "no git: expected 'main', got '$out'"
pass "with git unavailable it prints main and exits 0"

echo "all default-branch tests passed"
