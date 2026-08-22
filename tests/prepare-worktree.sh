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

# The submodule, narrowed to what a fixture consumer actually needs. `cp -R "$repo_root"` dragged in
# whatever happened to be present at the time - a local `.cerebro/`, the `.git`, byte-compiled
# elisp, editor droppings - so the fixture was neither hermetic nor cheap (ah-qled.11). `emacs/` is
# deliberately absent: no bash suite reads it, and it is the largest thing in the tree.
copy_cerebro_into() {
  local dest="$1" d
  mkdir -p "$dest"
  for d in scripts agents skills hooks; do
    [ -d "$repo_root/$d" ] && cp -R "$repo_root/$d" "$dest/"
  done
}

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
  copy_cerebro_into "$consumer/.claude/cerebro"
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


# --- a dry run creates nothing ---------------------------------------------------------------------
#
# ah-1rls: `dry_run` used to be consulted only around the install and prewarm commands, so a
# --dry-run created a real branch and a real worktree - the opposite of what its header promises.
c="$(make_consumer dryfresh main)"
before_trees="$(git -C "$c" worktree list)"
run_prepare "$c" --path .cerebro/worktrees/ah-4 --branch ah-4-work --dry-run >/dev/null 2>&1 \
  || fail "dry-fresh: a dry run exited non-zero"
[[ ! -e "$c/.cerebro/worktrees/ah-4" ]] || fail "dry-fresh: --dry-run created a worktree"
[[ -z "$(git -C "$c" branch --list ah-4-work)" ]] || fail "dry-fresh: --dry-run created a branch"
[[ "$(git -C "$c" worktree list)" == "$before_trees" ]] || fail "dry-fresh: the worktree list moved"
pass "a dry run creates neither a worktree nor a branch"

# --- a dry run destroys nothing --------------------------------------------------------------------
#
# The reuse path `reset --hard`s and `clean -fd`s, and the tree it exists for is the verifier's. A
# dry run against it must leave an untracked scratch file and HEAD exactly where they were.
c="$(make_consumer dryreuse main)"
run_prepare "$c" --path .cerebro/worktrees/psylocke >/dev/null 2>&1 \
  || fail "dry-reuse: the real run that sets the fixture up failed"
scratch="$c/.cerebro/worktrees/psylocke/scratch.txt"
echo "work in progress" > "$scratch"
git_q -C "$c/.cerebro/worktrees/psylocke" commit -q --allow-empty -m "local work"
head_before="$(git -C "$c/.cerebro/worktrees/psylocke" rev-parse HEAD)"
run_prepare "$c" --path .cerebro/worktrees/psylocke --dry-run >/dev/null 2>&1 \
  || fail "dry-reuse: a dry run exited non-zero"
[[ -f "$scratch" ]] || fail "dry-reuse: --dry-run cleaned away an untracked file"
[[ "$(cat "$scratch")" == "work in progress" ]] || fail "dry-reuse: the untracked file was rewritten"
[[ "$(git -C "$c/.cerebro/worktrees/psylocke" rev-parse HEAD)" == "$head_before" ]] \
  || fail "dry-reuse: --dry-run moved HEAD"
pass "a dry run leaves an existing detached tree untouched"

# --- the stdout contract survives a dry run --------------------------------------------------------
#
# Callers parse one line: the path and a short sha. Under --dry-run the tree may not exist, so the
# sha comes from the ref instead - see the comment beside the rev-parse.
c="$(make_consumer drycontract main)"
out="$(run_prepare "$c" --path .cerebro/worktrees/ah-5 --branch ah-5-work --dry-run 2>/dev/null)"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "dry-contract: stdout was not exactly one line"
[[ "${out%% *}" == *"/.cerebro/worktrees/ah-5" ]] || fail "dry-contract: the path is wrong ($out)"
[[ "${out##* }" == "$(git -C "$c" rev-parse --short origin/main)" ]] \
  || fail "dry-contract: the sha is not origin/main's"
pass "a dry run still prints the path and the ref's sha on stdout"

# --- what it would run goes to stderr --------------------------------------------------------------
err="$(run_prepare "$c" --path .cerebro/worktrees/ah-6 --branch ah-6-work --dry-run 2>&1 >/dev/null)"
grep -q "would " <<<"$err" || fail "dry-narrate: nothing was narrated on stderr"
grep -q "worktree add" <<<"$err" || fail "dry-narrate: the worktree add was not printed"
pass "a dry run narrates the commands it would have run, on stderr"

# --- the refusals still fire under a dry run -------------------------------------------------------
#
# They are reads, and reporting them is most of a dry run's value. A dry run that agrees with
# everything is worse than one that mutates, because it looks fine.
c="$(make_consumer dryrefuse main)"
if run_prepare "$c" --path /tmp/elsewhere --dry-run >/dev/null 2>&1; then
  fail "dry-refuse: a path outside .cerebro/worktrees/ was accepted"
fi
run_prepare "$c" --path .cerebro/worktrees/ah-7 --branch ah-7-work >/dev/null 2>&1 \
  || fail "dry-refuse: the real run that sets the fixture up failed"
if run_prepare "$c" --path .cerebro/worktrees/ah-7 --branch ah-7-again --dry-run >/dev/null 2>&1; then
  fail "dry-refuse: an existing path with --branch was accepted"
fi
if run_prepare "$c" --path .cerebro/worktrees/ah-7 --dry-run >/dev/null 2>&1; then
  fail "dry-refuse: a tree on a branch was accepted for reset"
fi
pass "every refusal still fires under --dry-run"

echo "all prepare-worktree tests passed"
