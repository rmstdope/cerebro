#!/usr/bin/env bash
#
# Proves scripts/prepare-worktree makes a tree on the branch the consumer actually uses, rather than
# on the `origin/main` it used to hardcode (ah-qled.3). This was the LOUD failure of the three: two
# unguarded `git fetch origin main` under `set -euo pipefail`, so on a `trunk` consumer worktree
# creation aborted outright and no bead could be started at all.
#
# `pnpm` is stubbed: a fabricated consumer has no lockfile, and this script's install step is not
# what is under test here.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run from
# the submodule root:
#
#     bash tests/prepare-worktree.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok - $1"; }

work_dir="$(mktemp -d)"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir" "$stub_dir"' EXIT

cat > "$stub_dir/pnpm" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_dir/pnpm"

git_q() { git -c user.name=test -c user.email=test@example.com "$@"; }

# make_consumer <name> <branch>  ->  echoes the consumer path. A real clone of a real origin, so
# refs/remotes/origin/HEAD is set the way `git clone` sets it.
make_consumer() {
  local name="$1" branch="$2"
  local origin="$work_dir/$name-origin.git" consumer="$work_dir/$name" seed="$work_dir/$name-seed"

  git init -q --bare -b "$branch" "$origin"
  git init -q -b "$branch" "$seed"
  echo one > "$seed/file.txt"
  git_q -C "$seed" add file.txt
  git_q -C "$seed" commit -q -m init
  git_q -C "$seed" push -q "$origin" "$branch"

  git clone -q "$origin" "$consumer"
  mkdir -p "$consumer/.claude"
  cp -R "$repo_root" "$consumer/.claude/cerebro"
  rm -rf "$consumer/.claude/cerebro/.git"
  printf '%s\n' "$consumer"
}

# The relative --path form, deliberately: on macOS `mktemp -d` hands back a /var path while
# consumer-root resolves it to /private/var, so an absolute path built from $work_dir would be
# refused for a reason that has nothing to do with this bead.
run_prepare() {
  local consumer="$1"; shift
  PATH="$stub_dir:$PATH" bash "$consumer/.claude/cerebro/scripts/prepare-worktree" "$@"
}

# --- a trunk consumer gets its worktree ------------------------------------------------------------
c="$(make_consumer trunk trunk)"
run_prepare "$c" --path .cerebro/worktrees/ah-1 --branch ah-1-work >/dev/null \
  || fail "trunk: prepare-worktree failed on a consumer whose branch is trunk"
[[ -d "$c/.cerebro/worktrees/ah-1" ]] || fail "trunk: no worktree was created"
[[ "$(git -C "$c/.cerebro/worktrees/ah-1" rev-parse --abbrev-ref HEAD)" == "ah-1-work" ]] \
  || fail "trunk: the worktree is not on the requested branch"
[[ "$(git -C "$c/.cerebro/worktrees/ah-1" rev-parse HEAD)" == "$(git -C "$c" rev-parse origin/trunk)" ]] \
  || fail "trunk: the worktree was not branched from origin/trunk"
pass "a worktree is created from the consumer's own default branch"

# --- a main consumer is unchanged ------------------------------------------------------------------
#
# The consumer we actually have. The acceptance for it is that NOTHING moves.
c="$(make_consumer plain main)"
run_prepare "$c" --path .cerebro/worktrees/ah-2 --branch ah-2-work >/dev/null \
  || fail "main: prepare-worktree failed on an ordinary main consumer"
[[ "$(git -C "$c/.cerebro/worktrees/ah-2" rev-parse HEAD)" == "$(git -C "$c" rev-parse origin/main)" ]] \
  || fail "main: the worktree was not branched from origin/main"
pass "a main consumer behaves exactly as before"

# --- an explicit --from still wins -----------------------------------------------------------------
#
# The resolver supplies the DEFAULT for --from, and must not override a caller that named a ref.
c="$(make_consumer explicit trunk)"
# `other` must DIVERGE from origin/trunk, or the assertion cannot fail: straight after the clone
# every ref points at the same `init` commit, so a worktree made from either lands on it and the
# case would pass whether --from was honoured or ignored.
git_q -C "$c" branch other
git_q -C "$c" commit -q --allow-empty -m "on other"
git_q -C "$c" branch -f other HEAD
git_q -C "$c" reset -q --hard HEAD~1
run_prepare "$c" --path .cerebro/worktrees/ah-3 --branch ah-3-work --from other >/dev/null \
  || fail "explicit: prepare-worktree failed with an explicit --from"
[[ "$(git -C "$c/.cerebro/worktrees/ah-3" rev-parse HEAD)" == "$(git -C "$c" rev-parse other)" ]] \
  || fail "explicit: --from was ignored"
[[ "$(git -C "$c/.cerebro/worktrees/ah-3" rev-parse HEAD)" != "$(git -C "$c" rev-parse origin/trunk)" ]] \
  || fail "explicit: the worktree is at origin/trunk, so --from proved nothing"
pass "an explicit --from still wins over the resolved branch"

echo "all prepare-worktree tests passed"
