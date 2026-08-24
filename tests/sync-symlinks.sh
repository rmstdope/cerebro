#!/usr/bin/env bash
#
# Proves sync-symlinks.sh writes RELATIVE links (so the same link is correct in the main
# checkout, in every worktree and on every machine — ah-cuc) and refuses to run anywhere that
# is not a consumer repo's .claude/cerebro (a standalone clone of this repository would
# otherwise climb three directories from scripts/ and land on the user's own ~/.claude,
# linking skills into their global config).
#
# No framework: plain bash, set -euo pipefail, exit non-zero on the first failed assertion. Run
# from the submodule root:
#
#     bash tests/sync-symlinks.sh

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
mkdir -p "$consumer/.claude"
git init -q "$consumer"

cerebro_dir="$consumer/.claude/cerebro"
mkdir -p "$cerebro_dir/scripts" "$cerebro_dir/skills/demo" "$cerebro_dir/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$cerebro_dir/scripts/sync-symlinks.sh"
chmod +x "$cerebro_dir/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$cerebro_dir/scripts/consumer-root"
chmod +x "$cerebro_dir/scripts/consumer-root"
cat > "$cerebro_dir/skills/demo/SKILL.md" <<'EOF'
# Demo skill
EOF
cat > "$cerebro_dir/agents/demo.md" <<'EOF'
# Demo agent
EOF

"$cerebro_dir/scripts/sync-symlinks.sh"

skill_link="$consumer/.claude/skills/demo"
agent_link="$consumer/.claude/agents/demo.md"

[[ -L "$skill_link" ]] || fail "expected $skill_link to be a symlink"
skill_target="$(readlink "$skill_link")"
[[ "$skill_target" == "../cerebro/skills/demo" ]] \
  || fail "expected skill link target '../cerebro/skills/demo', got '$skill_target'"
pass "skill link is relative: ../cerebro/skills/demo"

[[ -L "$agent_link" ]] || fail "expected $agent_link to be a symlink"
agent_target="$(readlink "$agent_link")"
[[ "$agent_target" == "../cerebro/agents/demo.md" ]] \
  || fail "expected agent link target '../cerebro/agents/demo.md', got '$agent_target'"
pass "agent link is relative: ../cerebro/agents/demo.md"

[[ -e "$skill_link/SKILL.md" ]] || fail "relative skill link does not resolve to SKILL.md"
[[ -e "$agent_link" ]] || fail "relative agent link does not resolve"
pass "relative links resolve correctly"

# --- running again leaves both links unchanged and still exits 0 ---
"$cerebro_dir/scripts/sync-symlinks.sh"
[[ "$(readlink "$skill_link")" == "../cerebro/skills/demo" ]] \
  || fail "second run changed the skill link target"
[[ "$(readlink "$agent_link")" == "../cerebro/agents/demo.md" ]] \
  || fail "second run changed the agent link target"
pass "a second run is idempotent"

# --- the guard: run from somewhere that is not a consumer repo's .claude/cerebro ---
outside="$work_dir/x/cerebro/scripts"
mkdir -p "$outside" "$work_dir/.claude"   # a sibling .claude that must NOT be mistaken for a consumer's
cp "$repo_root/scripts/sync-symlinks.sh" "$outside/sync-symlinks.sh"
chmod +x "$outside/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$outside/consumer-root"
chmod +x "$outside/consumer-root"

set +e
out="$("$outside/sync-symlinks.sh" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "expected the guard to reject a non-consumer layout, exited 0"
echo "$out" | grep -q "must run from a consumer repo" \
  || fail "expected the guard's message to name the requirement, got: $out"
[[ ! -d "$work_dir/.claude/skills" ]] \
  || fail "the guard must exit before creating any target directory"
pass "refuses to run outside a consumer repo's .claude/cerebro, before touching anything"

# --- cerebro as its own consumer: the links still read ../cerebro/... (cb-i3l.1) ---
#
# Here the source root is the consumer root, not a directory below .claude, so stripping
# $CLAUDE_ROOT off the front of it strips nothing and the old arithmetic produced an ABSOLUTE path
# with a "../" glued to the front of it. The mount is the answer: `.claude/cerebro` is a symlink
# back to the checkout, so a link through it is correct and reads exactly like every consumer's.
self_consumer="$work_dir/self"
mkdir -p "$self_consumer/scripts" "$self_consumer/skills/demo" "$self_consumer/agents" "$self_consumer/.claude"
cp "$repo_root/scripts/sync-symlinks.sh" "$self_consumer/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$self_consumer/scripts/consumer-root"
chmod +x "$self_consumer/scripts/sync-symlinks.sh" "$self_consumer/scripts/consumer-root"
ln -s ".." "$self_consumer/.claude/cerebro"
cat > "$self_consumer/skills/demo/SKILL.md" <<'EOF'
# Demo skill
EOF
cat > "$self_consumer/agents/demo.md" <<'EOF'
# Demo agent
EOF

"$self_consumer/.claude/cerebro/scripts/sync-symlinks.sh" >/dev/null

self_skill_link="$self_consumer/.claude/skills/demo"
self_agent_link="$self_consumer/.claude/agents/demo.md"
[[ "$(readlink "$self_skill_link")" == "../cerebro/skills/demo" ]] \
  || fail "self-consumer skill link: expected '../cerebro/skills/demo', got '$(readlink "$self_skill_link")'"
[[ "$(readlink "$self_agent_link")" == "../cerebro/agents/demo.md" ]] \
  || fail "self-consumer agent link: expected '../cerebro/agents/demo.md', got '$(readlink "$self_agent_link")'"
pass "a self-consumer's links read ../cerebro/... like every other consumer's"

[[ -e "$self_skill_link/SKILL.md" ]] || fail "self-consumer skill link does not resolve to SKILL.md"
[[ -e "$self_agent_link" ]] || fail "self-consumer agent link does not resolve"
pass "a self-consumer's links resolve through the mount"

echo "all sync-symlinks tests passed"
