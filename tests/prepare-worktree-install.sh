#!/usr/bin/env bash
#
# Proves scripts/prepare-worktree works in a consumer that is not atlantis-hud (ah-qled.2,
# cerebro#58 §1).
#
# The defect this pins: the script ran `pnpm install --frozen-lockfile` unconditionally, so under
# `set -euo pipefail` it exited non-zero in any project without pnpm - BEFORE printing the path and
# sha its callers parse, which is the one thing every caller uses it for. What runs now is what the
# project declared through `project-conf`, and nothing when it declared nothing.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/prepare-worktree-install.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

# --- a throwaway consumer with an origin, since prepare-worktree fetches origin/main ---
origin="$work_dir/origin.git"
git init -q --bare -b main "$origin"
consumer="$work_dir/repo"
git init -q -b main "$consumer"
git -C "$consumer" remote add origin "$origin"
mkdir -p "$consumer/.claude/cerebro/scripts" "$consumer/.cerebro/worktrees"
echo hello > "$consumer/README.md"
git -C "$consumer" add README.md
git -C "$consumer" -c user.name=test -c user.email=test@example.com commit -q -m init
git -C "$consumer" push -q origin main
for s in consumer-root project-conf default-branch prepare-worktree; do
  ln -s "$repo_root/scripts/$s" "$consumer/.claude/cerebro/scripts/$s"
done
prepare="$consumer/.claude/cerebro/scripts/prepare-worktree"
conf="$consumer/.cerebro/project.conf"

# The path-and-sha line is the contract every caller parses.
assert_contract() {
  local out="$1" expected_path="$2" what="$3"
  local path sha
  read -r path sha <<<"$out"
  [[ "$path" == "$expected_path" ]] || fail "$what: expected path '$expected_path', got '$path'"
  [[ "$sha" =~ ^[0-9a-f]{7,}$ ]] || fail "$what: expected a short sha, got '$sha'"
}

# --- THE BEAD: no lockfile, no `install' key - the tree is still prepared ---
tree="$consumer/.cerebro/worktrees/bare"
set +e
out="$("$prepare" --path .cerebro/worktrees/bare --branch bare-branch 2>"$work_dir/err")"
status=$?
set -e
[[ $status -eq 0 ]] || fail "no install configured: expected exit 0, got $status: $(cat "$work_dir/err")"
assert_contract "$out" "$tree" "no install configured"
grep -qi "install" "$work_dir/err" || fail "no install configured: expected a line saying nothing was installed"
pass "a consumer with no lockfile and no install key gets its tree"

# --- a configured `install' is what runs, and it really runs ---
cat > "$conf" <<CONF
install  touch installed.marker
CONF
out="$("$prepare" --path .cerebro/worktrees/one --branch one-branch 2>/dev/null)"
assert_contract "$out" "$consumer/.cerebro/worktrees/one" "configured install"
[[ -f "$consumer/.cerebro/worktrees/one/installed.marker" ]] \
  || fail "configured install: expected the declared command to have run in the tree"
pass "a configured install runs, expanded into a command and its arguments"

# --- --dry-run prints the command, runs it not, and STILL prints path and sha ---
out="$("$prepare" --path .cerebro/worktrees/dry --branch dry-branch --dry-run 2>"$work_dir/err")"
assert_contract "$out" "$consumer/.cerebro/worktrees/dry" "--dry-run"
grep -q "touch installed.marker" "$work_dir/err" \
  || fail "--dry-run: expected the install command named, got: $(cat "$work_dir/err")"
[[ ! -f "$consumer/.cerebro/worktrees/dry/installed.marker" ]] \
  || fail "--dry-run: the install command must not have run"
pass "--dry-run prints the commands, runs none of them, and still prints path and sha"

# --- with no key set, project-conf's own lockfile detection is what shows up ---
rm "$conf"
touch "$consumer/pnpm-lock.yaml"
"$prepare" --path .cerebro/worktrees/det --branch det-branch --dry-run >/dev/null 2>"$work_dir/err"
grep -q "pnpm install --frozen-lockfile" "$work_dir/err" \
  || fail "detection: expected the detected install named, got: $(cat "$work_dir/err")"
pass "with no install key the lockfile detection from project-conf is what would run"

# --- prewarm is NEVER inferred: a lockfile is not a reason to prewarm anything ---
"$prepare" --path .cerebro/worktrees/nopre --branch nopre-branch --prewarm --dry-run \
  >/dev/null 2>"$work_dir/err"
grep -qi "prewarm" "$work_dir/err" || fail "--prewarm unconfigured: expected one line saying so"
grep -q "build:wasm" "$work_dir/err" && fail "--prewarm unconfigured: nothing may be inferred"
pass "prewarm is never inferred, and --prewarm with nothing configured says one line"

# --- --prewarm with nothing configured is a no-op, not an error ---
cat > "$conf" <<CONF
install  touch installed.marker
CONF
set +e
"$prepare" --path .cerebro/worktrees/nopre2 --branch nopre2-branch --prewarm >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 0 ]] || fail "--prewarm unconfigured: expected exit 0, got $status"
pass "--prewarm with nothing configured exits 0"

# --- a configured prewarm runs, after the install ---
cat > "$conf" <<CONF
install  touch installed.marker
prewarm  touch prewarmed.marker
CONF
"$prepare" --path .cerebro/worktrees/pre --branch pre-branch --prewarm >/dev/null 2>&1
[[ -f "$consumer/.cerebro/worktrees/pre/prewarmed.marker" ]] \
  || fail "configured prewarm: expected the declared command to have run"
pass "a configured prewarm runs when asked for"

# --- prewarm only happens when asked for ---
"$prepare" --path .cerebro/worktrees/unasked --branch unasked-branch >/dev/null 2>&1
[[ ! -f "$consumer/.cerebro/worktrees/unasked/prewarmed.marker" ]] \
  || fail "prewarm without the flag: expected no prewarm"
pass "prewarm runs only when asked for"

# --- the old spelling still works, identically ---
"$prepare" --path .cerebro/worktrees/old --branch old-branch --with-wasm >/dev/null 2>&1
[[ -f "$consumer/.cerebro/worktrees/old/prewarmed.marker" ]] \
  || fail "--with-wasm: the old spelling must behave as --prewarm"
pass "--with-wasm still works as an alias for --prewarm"

# --- unchanged: a path outside .cerebro/worktrees/ is refused, exit 2 ---
set +e
"$prepare" --path elsewhere/tree --branch nope >/dev/null 2>"$work_dir/err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "path refusal: expected exit 2, got $status"
grep -q "worktrees" "$work_dir/err" || fail "path refusal: expected the reason named"
pass "a path outside .cerebro/worktrees/ is still refused with exit 2"

# --- unchanged: an existing tree is not reused for a new branch ---
set +e
"$prepare" --path .cerebro/worktrees/one --branch one-again >/dev/null 2>"$work_dir/err"
status=$?
set -e
[[ $status -eq 2 ]] || fail "reuse refusal: expected exit 2, got $status"
pass "an existing tree is still refused for a new branch"

# --- the atlantis vocabulary is gone from the prose every consumer's agents read ---
# `--with-wasm` was cerebro's own interface speaking one repository's language, and
# `@atlantis/browser-core` is a package that exists in exactly one repository on earth; the prose
# here is read by every consumer's agents, so one left behind teaches the old vocabulary for ever.
# The workspace-member map in agents/architect.md is a different coupling and ah-qled.6's to remove.
if grep -rn -- "--with-wasm\|@atlantis/browser-core" "$repo_root/skills" "$repo_root/agents" 2>/dev/null; then
  fail "atlantis vocabulary: skills/ and agents/ must name neither --with-wasm nor @atlantis/browser-core"
fi
pass "no --with-wasm or @atlantis/browser-core left in skills/ or agents/"

echo "all prepare-worktree assertions passed"
