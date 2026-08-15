#!/usr/bin/env bash
#
# Proves scripts/consumer-root answers the two roots every other script needs: the enclosing
# working tree (main checkout, or a bead worktree when this copy is the worktree's own submodule)
# and, with --shared, the main working tree every worktree of the repository shares (ah-e0w).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/consumer-root.sh

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

# --- a throwaway consumer repo: T/repo/.claude/cerebro is where the script actually lives ---
consumer="$work_dir/repo"
mkdir -p "$consumer/.claude/cerebro/scripts"
git init -q "$consumer"
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
ln -s "$repo_root/scripts/consumer-root" "$consumer/.claude/cerebro/scripts/consumer-root"

plain_out="$("$consumer/.claude/cerebro/scripts/consumer-root")"
[[ "$plain_out" == "$(cd "$consumer" && pwd -P)" ]] \
  || fail "plain: expected $consumer, got $plain_out"
pass "plain, from the main checkout, prints the consumer"

shared_out="$("$consumer/.claude/cerebro/scripts/consumer-root" --shared)"
[[ "$shared_out" == "$(cd "$consumer" && pwd -P)" ]] \
  || fail "--shared: expected $consumer, got $shared_out"
pass "--shared, from the main checkout, prints the same consumer"

# --- a linked worktree of it: plain answers the worktree, --shared answers the main checkout ---
worktree="$consumer/.claude/worktrees/wt"
git -C "$consumer" worktree add -q "$worktree" -b wt-branch
mkdir -p "$worktree/.claude/cerebro/scripts"
ln -s "$repo_root/scripts/consumer-root" "$worktree/.claude/cerebro/scripts/consumer-root"

wt_plain="$("$worktree/.claude/cerebro/scripts/consumer-root")"
[[ "$wt_plain" == "$(cd "$worktree" && pwd -P)" ]] \
  || fail "worktree plain: expected $worktree, got $wt_plain"
pass "plain, from a worktree's own submodule copy, prints the worktree"

wt_shared="$("$worktree/.claude/cerebro/scripts/consumer-root" --shared)"
[[ "$wt_shared" == "$(cd "$consumer" && pwd -P)" ]] \
  || fail "worktree --shared: expected $consumer, got $wt_shared"
pass "--shared, from a worktree's own submodule copy, prints the main checkout"

# --- standalone: cerebro checked out on its own, no consumer above it ---
standalone="$work_dir/x/cerebro/scripts"
mkdir -p "$standalone"
ln -s "$repo_root/scripts/consumer-root" "$standalone/consumer-root"

set +e
out="$("$standalone/consumer-root" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "standalone: expected a non-zero exit, got 0"
echo "$out" | grep -q "is not <consumer>/.claude/cerebro/scripts" \
  || fail "standalone: expected the guard's message, got: $out"
pass "refuses when there is no consumer above .claude/cerebro/scripts"

# --- a consumer layout that is not a git tree: plain still works, --shared refuses ---
plain_consumer="$work_dir/plain"
mkdir -p "$plain_consumer/.claude/cerebro/scripts"
ln -s "$repo_root/scripts/consumer-root" "$plain_consumer/.claude/cerebro/scripts/consumer-root"

plain_ng_out="$("$plain_consumer/.claude/cerebro/scripts/consumer-root")"
[[ "$plain_ng_out" == "$(cd "$plain_consumer" && pwd -P)" ]] \
  || fail "non-git plain: expected $plain_consumer, got $plain_ng_out"
pass "plain works even when the consumer is not a git working tree"

set +e
out="$("$plain_consumer/.claude/cerebro/scripts/consumer-root" --shared 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "non-git --shared: expected a non-zero exit, got 0"
echo "$out" | grep -q "is not inside a git working tree" \
  || fail "non-git --shared: expected the guard's message, got: $out"
pass "--shared refuses when the consumer is not inside a git working tree"

echo "all consumer-root tests passed"
