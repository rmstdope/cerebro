#!/usr/bin/env bash
#
# Proves `scripts/ci-changed' answers "which paths did the one commit under test change" for the
# CI `changes' job (cb-5eny): the paths on stdout when the event is a pull request, or a push that
# added exactly one commit; nothing at all otherwise, which `scripts/ci-needed' answers with
# `run=true'. So ci-changed can never cause a skip by itself - only a real path list can.
#
# Every fixture is a throwaway git repository under $work_dir. Run from the repository root:
#
#     bash tests/ci-changed.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

script="$repo_root/scripts/ci-changed"
needed="$repo_root/scripts/ci-needed"
[[ -f "$script" ]] || fail "scripts/ci-changed does not exist"
[[ -x "$script" ]] || fail "scripts/ci-changed is not executable"

repo="$work_dir/repo"
mkdir -p "$repo"
git_q -C "$repo" init -q
commit() {          # commit <message> <path>... : writes each path, commits, nothing on stdout
  local msg="$1" p
  shift
  for p in "$@"; do
    mkdir -p "$repo/$(dirname "$p")"
    printf '%s\n' "$msg" >>"$repo/$p"
  done
  git_q -C "$repo" add -A
  git_q -C "$repo" commit -q -m "$msg"
}
sha() { git -C "$repo" rev-parse "$1"; }

out=""
err=""
status=0
run() {             # run <arg>... : runs ci-changed inside $repo, streams captured apart
  set +e
  out="$(cd "$repo" && bash "$script" "$@" 2>"$work_dir/err")"
  status=$?
  set -e
  err="$(cat "$work_dir/err")"
}
expect_paths() {    # expect_paths <case> <expected stdout>
  [[ $status -eq 0 ]] || fail "$1: expected exit 0, got $status
$err"
  [[ "$out" == "$2" ]] || fail "$1: stdout is not exactly the changed paths
expected:
$2
got:
$out"
}
expect_nothing() {  # expect_nothing <case> <regex the reason on stderr must match>
  [[ $status -eq 0 ]] || fail "$1: expected exit 0, got $status
$err"
  [[ -z "$out" ]] || fail "$1: printed paths when it should print nothing
$out"
  grep -Eq "$2" <<<"$err" || fail "$1: stderr does not say why ($2)
$err"
}

# --- a root commit has no first parent: nothing ---
commit "root" README.md
run push ""
expect_nothing "a root commit" 'ci-changed: '
pass "a commit with no first parent prints nothing"

# --- usage errors print nothing at all, and exit 2 ---
for args in "" "push" "push a b"; do
  # shellcheck disable=SC2086  # the word split is the point: zero, one and three arguments
  run $args
  [[ $status -eq 2 ]] || fail "arguments '$args': expected exit 2, got $status"
  [[ -z "$out" ]] || fail "arguments '$args': printed on stdout
$out"
  grep -q '^usage: ' <<<"$err" || fail "arguments '$args': no usage line
$err"
done
pass "anything but two arguments is a usage error, and prints nothing"

commit "one" docs/a.md
commit "two" docs/b.md "docs/with space.md" scripts/x

# --- pull_request: HEAD^1..HEAD, as the job always did ---
run pull_request ""
expect_paths "pull_request" $'docs/b.md\ndocs/with space.md\nscripts/x'
pass "a pull request prints the paths of HEAD^1..HEAD, a path with a space as one line"

# --- push of exactly one commit ---
run push "$(sha HEAD^1)"
expect_paths "push of one commit" $'docs/b.md\ndocs/with space.md\nscripts/x'
pass "a push whose before is HEAD^1 prints that commit's paths"

# --- push of anything else: nothing ---
run push "$(sha HEAD~2)"
expect_nothing "push of two commits" 'more than one commit'
pass "a push of two commits prints nothing"

run push 0000000000000000000000000000000000000000
expect_nothing "push of a new branch" 'more than one commit'
pass "a push whose before is all zeros prints nothing"

run push ""
expect_nothing "push with no before" 'more than one commit'
pass "a push with an empty before prints nothing"

run workflow_dispatch ""
expect_nothing "workflow_dispatch" 'workflow_dispatch'
pass "any other event prints nothing"

# --- --no-renames: a rename out of a path lists the old path too ---
git_q -C "$repo" mv scripts/x docs/x
git_q -C "$repo" commit -q -m "move"
run push "$(sha HEAD^1)"
expect_paths "a rename" $'docs/x\nscripts/x'
pass "a rename lists both the old and the new path"

# --- end to end with ci-needed, as the workflow step pipes them ---
decide() {          # decide <event> <before> : the `decide' step's pipe, stdout only
  (cd "$repo" && bash "$script" "$1" "$2" 2>/dev/null | bash "$needed" 2>/dev/null)
}
commit "docs only" docs/c.md
[[ "$(decide push "$(sha HEAD^1)")" == "run=false" ]] \
  || fail "a docs-only push of one commit does not skip"
[[ "$(decide push "$(sha HEAD~2)")" == "run=true" ]] \
  || fail "a push of two commits, the older touching scripts/, does not run"
commit "code" scripts/y
[[ "$(decide push "$(sha HEAD^1)")" == "run=true" ]] \
  || fail "a push of one commit touching scripts/ does not run"
[[ "$(decide workflow_dispatch "")" == "run=true" ]] \
  || fail "workflow_dispatch does not run"
pass "piped into ci-needed: a docs-only push skips, anything else runs"

suite_passed
