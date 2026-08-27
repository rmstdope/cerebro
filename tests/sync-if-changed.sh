#!/usr/bin/env bash
#
# Proves githooks/sync-if-changed.sh finds its own mount point instead of assuming
# `.claude/cerebro', and says something when it cannot find the sync script rather than
# exiting zero in silence (ah-qled.9). Silently no-opping is how this class of breakage
# stayed invisible: a consumer mounting cerebro anywhere else got no symlink sync and no
# word about it.
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion.
# Run from the submodule root:
#
#     bash tests/sync-if-changed.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

hook="$repo_root/githooks/sync-if-changed.sh"

# A throwaway consumer with cerebro mounted somewhere that is NOT .claude/cerebro.
consumer="$work_dir/repo"
mount="vendor/cerebro"
mkdir -p "$consumer/$mount/githooks" "$consumer/$mount/scripts"
git -C "$consumer" init -q
git -C "$consumer" config user.email t@example.com
git -C "$consumer" config user.name Test

cp "$hook" "$consumer/$mount/githooks/sync-if-changed.sh"
cat > "$consumer/$mount/scripts/sync-symlinks.sh" <<'INNER'
#!/usr/bin/env bash
echo "sync-symlinks ran"
INNER
chmod +x "$consumer/$mount/scripts/sync-symlinks.sh"

git -C "$consumer" add -A
git -C "$consumer" commit -qm one

# --- the mount point comes from where the hook itself lives ---
out="$(cd "$consumer" && bash "$mount/githooks/sync-if-changed.sh" 2>&1)"
grep -q "sync-symlinks ran" <<<"$out" \
  || fail "the hook did not find its sync script at $mount (said: $out)"
pass "the hook syncs from a mount that is not .claude/cerebro"

# --- an unfindable sync script is reported, not swallowed ---
rm "$consumer/$mount/scripts/sync-symlinks.sh"
out="$(cd "$consumer" && bash "$mount/githooks/sync-if-changed.sh" 2>&1)" \
  || fail "the hook should not fail the checkout it runs in"
grep -qi "sync-symlinks" <<<"$out" \
  || fail "a missing sync script said nothing at all (said: $out)"
pass "a missing sync script is reported rather than silently skipped"

suite_passed
