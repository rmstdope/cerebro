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

# fail, pass, git_q, $work_dir and its cleanup trap - see tests/lib/consumer.sh.
source "$repo_root/tests/lib/consumer.sh"

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
mkdir -p "$cerebro_dir/templates"
cp "$repo_root/templates/consumer-dir-locals.el" "$cerebro_dir/templates/consumer-dir-locals.el"

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

# --- .dir-locals.el: installed at the consumer ROOT, not under .claude ---
#
# It is what gives every contributor `M-x cerebro' without editing their init. The link lives one
# level higher than the skill and agent links, so it carries its own relative arithmetic - from
# the consumer root rather than from $CLAUDE_ROOT/<sub>/.
dir_locals="$consumer/.dir-locals.el"
[[ -L "$dir_locals" ]] || fail "expected $dir_locals to be a symlink"
dir_locals_target="$(readlink "$dir_locals")"
[[ "$dir_locals_target" == ".claude/cerebro/templates/consumer-dir-locals.el" ]] \
  || fail "expected '.claude/cerebro/templates/consumer-dir-locals.el', got '$dir_locals_target'"
[[ -e "$dir_locals" ]] || fail "the .dir-locals.el link does not resolve"
pass ".dir-locals.el is linked from the consumer root and resolves"

# --- running again leaves both links unchanged and still exits 0 ---
"$cerebro_dir/scripts/sync-symlinks.sh"
[[ "$(readlink "$dir_locals")" == ".claude/cerebro/templates/consumer-dir-locals.el" ]] \
  || fail "second run changed the .dir-locals.el link target"
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
mkdir -p "$self_consumer/templates"
cp "$repo_root/templates/consumer-dir-locals.el" "$self_consumer/templates/consumer-dir-locals.el"

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

[[ "$(readlink "$self_consumer/.dir-locals.el")" == ".claude/cerebro/templates/consumer-dir-locals.el" ]] \
  || fail "self-consumer .dir-locals.el: got '$(readlink "$self_consumer/.dir-locals.el")'"
[[ -e "$self_consumer/.dir-locals.el" ]] || fail "self-consumer .dir-locals.el does not resolve"
pass "a self-consumer's .dir-locals.el links through the mount too"

# --- a consumer that already has its own .dir-locals.el keeps it, untouched ---
#
# Emacs reads exactly one per directory, so installing ours would silently replace whatever
# indent, compile-command or project settings the consumer had. The sync says so and moves on:
# this is the one file it cannot merge, and guessing is worse than a line on stderr.
own="$work_dir/own"
mkdir -p "$own/.claude"
git init -q "$own"
own_cerebro="$own/.claude/cerebro"
mkdir -p "$own_cerebro/scripts" "$own_cerebro/skills/demo" "$own_cerebro/agents" "$own_cerebro/templates"
cp "$repo_root/scripts/sync-symlinks.sh" "$own_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$own_cerebro/scripts/consumer-root"
chmod +x "$own_cerebro/scripts/sync-symlinks.sh" "$own_cerebro/scripts/consumer-root"
cp "$repo_root/templates/consumer-dir-locals.el" "$own_cerebro/templates/consumer-dir-locals.el"
echo "# Demo skill" > "$own_cerebro/skills/demo/SKILL.md"
echo "# Demo agent" > "$own_cerebro/agents/demo.md"
printf '((nil . ((indent-tabs-mode . nil))))\n' > "$own/.dir-locals.el"
before="$(cat "$own/.dir-locals.el")"

out="$("$own_cerebro/scripts/sync-symlinks.sh" 2>&1)"

[[ ! -L "$own/.dir-locals.el" ]] || fail "the consumer's own .dir-locals.el was replaced by a link"
[[ "$(cat "$own/.dir-locals.el")" == "$before" ]] \
  || fail "the consumer's own .dir-locals.el was modified"
echo "$out" | grep -q "\.dir-locals\.el" \
  || fail "expected the sync to say it left the consumer's .dir-locals.el alone, got: $out"
[[ -L "$own/.claude/skills/demo" ]] || fail "the skill links must still be written"
pass "a consumer's own .dir-locals.el is left alone, out loud, and the rest still syncs"

# --- a foreign symlink at that path is left alone too ---
#
# `-L' alone would say "ours, refresh it" about a link the consumer made to somewhere else.
foreign="$work_dir/foreign"
mkdir -p "$foreign/.claude" "$foreign/elsewhere"
git init -q "$foreign"
foreign_cerebro="$foreign/.claude/cerebro"
mkdir -p "$foreign_cerebro/scripts" "$foreign_cerebro/skills" "$foreign_cerebro/agents" "$foreign_cerebro/templates"
cp "$repo_root/scripts/sync-symlinks.sh" "$foreign_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$foreign_cerebro/scripts/consumer-root"
chmod +x "$foreign_cerebro/scripts/sync-symlinks.sh" "$foreign_cerebro/scripts/consumer-root"
cp "$repo_root/templates/consumer-dir-locals.el" "$foreign_cerebro/templates/consumer-dir-locals.el"
printf '((nil . ((indent-tabs-mode . nil))))\n' > "$foreign/elsewhere/dir-locals.el"
ln -s "elsewhere/dir-locals.el" "$foreign/.dir-locals.el"

"$foreign_cerebro/scripts/sync-symlinks.sh" >/dev/null 2>&1

[[ "$(readlink "$foreign/.dir-locals.el")" == "elsewhere/dir-locals.el" ]] \
  || fail "a .dir-locals.el symlink the consumer made was repointed at the template"
pass "a .dir-locals.el symlink pointing somewhere else is left alone"

# --- a submodule older than the template: nothing to link, and no failure ---
old_sub="$work_dir/old"
mkdir -p "$old_sub/.claude"
git init -q "$old_sub"
old_cerebro="$old_sub/.claude/cerebro"
mkdir -p "$old_cerebro/scripts" "$old_cerebro/skills" "$old_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$old_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$old_cerebro/scripts/consumer-root"
chmod +x "$old_cerebro/scripts/sync-symlinks.sh" "$old_cerebro/scripts/consumer-root"

"$old_cerebro/scripts/sync-symlinks.sh" >/dev/null

[[ ! -e "$old_sub/.dir-locals.el" ]] || fail "linked a template that is not in this submodule"
pass "a submodule with no templates/ syncs the rest and links no .dir-locals.el"

echo "all sync-symlinks tests passed"
