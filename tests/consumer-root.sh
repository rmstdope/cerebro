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

# --- how this checkout is mounted, from the one script that knows (cb-akc) ---
set +e
"$consumer/.claude/cerebro/scripts/consumer-root" --self-mounted; status=$?
set -e
[[ $status -eq 1 ]] || fail "--self-mounted on a real consumer: expected 1, got $status"
pass "--self-mounted is 1 for a consumer whose mount is not its own checkout"
mount_out="$("$consumer/.claude/cerebro/scripts/consumer-root" --mount)"
[[ "$mount_out" == ".claude/cerebro" ]] || fail "--mount at the standard mount: got $mount_out"
pass "--mount names .claude/cerebro at the standard mount"

# --- a linked worktree of it: plain answers the worktree, --shared answers the main checkout ---
worktree="$consumer/.cerebro/worktrees/wt"
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

# --- cerebro mounted somewhere other than .claude/cerebro (ah-ohc2) ---
#
# A consumer that vendors cerebro as a submodule at `vendor/cerebro` gets no answer at all from the
# path arithmetic above: three levels up is the consumer, but `<consumer>/.claude/cerebro` does not
# resolve back to this checkout. `git rev-parse --show-superproject-working-tree` is purpose-built
# for exactly this question and answers regardless of the mount's depth or name.
#
# A REAL submodule, not a copied directory: the probe answers for a submodule and nothing else, so
# an arbitrarily-placed non-submodule copy stays unsupported (see the header of scripts/consumer-root).
cerebro_src="$work_dir/cerebro-src"
mkdir -p "$cerebro_src/scripts"
cp "$repo_root/scripts/consumer-root" "$cerebro_src/scripts/consumer-root"
cp "$repo_root/scripts/roster" "$cerebro_src/scripts/roster"
git init -q "$cerebro_src"
git -C "$cerebro_src" -c user.name=test -c user.email=test@example.com add -A
git -C "$cerebro_src" -c user.name=test -c user.email=test@example.com commit -q -m "cerebro"

alt="$work_dir/alt"
git init -q "$alt"
git -C "$alt" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
git -C "$alt" -c user.name=test -c user.email=test@example.com \
  -c protocol.file.allow=always submodule add -q "$cerebro_src" vendor/cerebro

alt_root="$(cd "$alt" && pwd -P)"
alt_out="$("$alt/vendor/cerebro/scripts/consumer-root")"
[[ "$alt_out" == "$alt_root" ]] || fail "alternative mount: expected $alt_root, got $alt_out"
pass "a submodule mounted at vendor/cerebro resolves its consumer"

alt_shared="$("$alt/vendor/cerebro/scripts/consumer-root" --shared)"
[[ "$alt_shared" == "$alt_root" ]] || fail "alternative mount --shared: expected $alt_root, got $alt_shared"
pass "--shared answers from an alternative mount too"

alt_mount="$("$alt/vendor/cerebro/scripts/consumer-root" --mount)"
[[ "$alt_mount" == "vendor/cerebro" ]] || fail "--mount at vendor/cerebro: got $alt_mount"
pass "--mount names the physical relative path for a submodule vendored elsewhere"

# A plain COPY at the standard mount, inside a consumer that is itself a submodule of something
# else. The superproject probe would answer with the GRANDPARENT here - it reports the superproject
# of whatever repository this checkout belongs to, and a copied mount belongs to the consumer's own
# repo - so the validated arithmetic has to come first (Copilot, PR #84).
grandparent="$work_dir/grandparent"
git init -q "$grandparent"
git -C "$grandparent" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
nested_src="$work_dir/nested-src"
mkdir -p "$nested_src"
git init -q "$nested_src"
git -C "$nested_src" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
git -C "$grandparent" -c user.name=test -c user.email=test@example.com \
  -c protocol.file.allow=always submodule add -q "$nested_src" child
nested="$grandparent/child"
mkdir -p "$nested/.claude/cerebro/scripts"
cp "$repo_root/scripts/consumer-root" "$nested/.claude/cerebro/scripts/consumer-root"
nested_out="$("$nested/.claude/cerebro/scripts/consumer-root")"
[[ "$nested_out" == "$(cd "$nested" && pwd -P)" ]] \
  || fail "a copied mount in a nested consumer: expected $nested, got $nested_out"
pass "a plain copy at the standard mount resolves the consumer, not its grandparent"

# --- the standard mount still resolves with no git on PATH ---
#
# The bare `consumer-root` uses no external command today, and tests/launchers.sh runs a launcher
# with a PATH of `dirname` and `bash` alone. The superproject probe must be tried and its failure
# swallowed, never made mandatory.
bare_path_dir="$work_dir/bare-path"
mkdir -p "$bare_path_dir"
ln -s "$(command -v dirname)" "$bare_path_dir/dirname"
ln -s "$(command -v bash)" "$bare_path_dir/bash"
bare_out="$(PATH="$bare_path_dir" "$(command -v bash)" "$consumer/.claude/cerebro/scripts/consumer-root")"
[[ "$bare_out" == "$(cd "$consumer" && pwd -P)" ]] \
  || fail "narrowed PATH: expected $consumer, got $bare_out"
pass "the standard mount resolves with PATH narrowed to dirname and bash - git stayed optional"

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

# --- cerebro as its own consumer: .claude/cerebro is a symlink back to the checkout (cb-i3l.1) ---
#
# This repository is a harness for other repositories, and its own fleet has to run somewhere. The
# mount is a committed symlink `.claude/cerebro -> ..`, which makes the path every script already
# assumes literally exist. The path arithmetic above cannot see it: `pwd -P` resolves the link, so
# the script appears to live at <cerebro>/scripts and three levels up is nobody's consumer. A
# submodule of the repository inside itself would have satisfied the arithmetic, but
# `git submodule update --init --recursive` on a repository containing itself has no fixed point.
self_consumer="$work_dir/self"
mkdir -p "$self_consumer/scripts" "$self_consumer/.claude"
git init -q "$self_consumer"
cp "$repo_root/scripts/consumer-root" "$self_consumer/scripts/consumer-root"
chmod +x "$self_consumer/scripts/consumer-root"
ln -s ".." "$self_consumer/.claude/cerebro"
git -C "$self_consumer" -c user.name=test -c user.email=test@example.com add -A
git -C "$self_consumer" -c user.name=test -c user.email=test@example.com commit -q -m "self-consumer"

self_root="$(cd "$self_consumer" && pwd -P)"
self_out="$("$self_consumer/.claude/cerebro/scripts/consumer-root")"
[[ "$self_out" == "$self_root" ]] || fail "self-consumer: expected $self_root, got $self_out"
pass "cerebro mounted in itself by symlink resolves its own checkout"

self_shared="$("$self_consumer/.claude/cerebro/scripts/consumer-root" --shared)"
[[ "$self_shared" == "$self_root" ]] \
  || fail "self-consumer --shared: expected $self_root, got $self_shared"
pass "--shared from a self-consumer's main checkout prints that checkout"

"$self_consumer/.claude/cerebro/scripts/consumer-root" --self-mounted \
  || fail "--self-mounted on cerebro mounted in itself: expected 0"
pass "--self-mounted is 0 for cerebro mounted in itself"
self_mount="$("$self_consumer/.claude/cerebro/scripts/consumer-root" --mount)"
[[ "$self_mount" == ".claude/cerebro" ]] || fail "--mount on the self-mount: got $self_mount"
pass "--mount on the self-mount names .claude/cerebro, like every other consumer"
# With no git on PATH: the answer is builtins only, which is what lets roster ask it.
PATH="$bare_path_dir" "$(command -v bash)" "$self_consumer/.claude/cerebro/scripts/consumer-root" --self-mounted \
  || fail "--self-mounted under a narrowed PATH: expected 0"
pass "--self-mounted answers with PATH narrowed to dirname and bash"

# A worktree of it carries the same committed symlink, which resolves to the WORKTREE - so an
# implementer building there reads its own branch's skills, not the main checkout's.
self_wt="$self_consumer/.cerebro/worktrees/wt"
git -C "$self_consumer" worktree add -q "$self_wt" -b self-wt-branch

self_wt_out="$("$self_wt/.claude/cerebro/scripts/consumer-root")"
[[ "$self_wt_out" == "$(cd "$self_wt" && pwd -P)" ]] \
  || fail "self-consumer worktree: expected $self_wt, got $self_wt_out"
pass "plain, from a self-consumer's worktree, prints the worktree"

self_wt_shared="$("$self_wt/.claude/cerebro/scripts/consumer-root" --shared)"
[[ "$self_wt_shared" == "$self_root" ]] \
  || fail "self-consumer worktree --shared: expected $self_root, got $self_wt_shared"
pass "--shared, from a self-consumer's worktree, prints the main checkout"

echo "all consumer-root tests passed"
