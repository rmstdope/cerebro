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
cp "$repo_root/scripts/agent-cli" "$cerebro_dir/scripts/agent-cli"
chmod +x "$cerebro_dir/scripts/agent-cli" "$cerebro_dir/scripts/consumer-root"
cat > "$cerebro_dir/skills/demo/SKILL.md" <<'EOF'
# Demo skill
EOF
cat > "$cerebro_dir/agents/demo.md" <<'EOF'
# Demo agent
EOF
first_out="$("$cerebro_dir/scripts/sync-symlinks.sh")"

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

# --- both layouts are written, whatever agent_cli says (cb-d59.4) --------------------------------
#
# Copilot reads .github/agents/<role>.agent.md and .github/skills/<name>; Claude Code reads
# .claude/. Every sync writes every layout in `agent-cli --layouts', in every consumer, so that
# switching provider is one line in .cerebro/project.conf and nothing else. The three assertions
# above are the regression proof that the .claude/ targets did not move.
copilot_agent_link="$consumer/.github/agents/demo.agent.md"
copilot_skill_link="$consumer/.github/skills/demo"

[[ -L "$copilot_agent_link" ]] || fail "expected $copilot_agent_link to be a symlink"
copilot_agent_target="$(readlink "$copilot_agent_link")"
[[ "$copilot_agent_target" == "../../.claude/cerebro/agents/demo.md" ]] \
  || fail "expected copilot agent link '../../.claude/cerebro/agents/demo.md', got '$copilot_agent_target'"
[[ -e "$copilot_agent_link" ]] || fail "the copilot agent link does not resolve"
pass "the copilot layout is written too, with the .agent.md suffix"

[[ -L "$copilot_skill_link" ]] || fail "expected $copilot_skill_link to be a symlink"
copilot_skill_target="$(readlink "$copilot_skill_link")"
[[ "$copilot_skill_target" == "../../.claude/cerebro/skills/demo" ]] \
  || fail "expected copilot skill link '../../.claude/cerebro/skills/demo', got '$copilot_skill_target'"
[[ -e "$copilot_skill_link/SKILL.md" ]] || fail "the copilot skill link does not resolve to SKILL.md"
pass "a skill keeps its directory name in the copilot layout"

# --- the tracked-directory line, and its silence -------------------------------------------------
#
# launch-preflight syncs before every single session, so this line is printed only when a link
# outside .claude/ was created or repointed in that run - otherwise it would scroll past above the
# first prompt of every agent, for ever.
echo "$first_out" | grep -qF ".github/ is tracked - commit these links so every clone has them without running this script." \
  || fail "expected the first sync to say .github/ is tracked, got: $first_out"
pass "a sync that creates a link outside .claude/ says the directory is tracked"

# --- the sync writes nothing outside .claude/ (cb-pq4) ---
#
# It used to install a `.dir-locals.el' at the consumer ROOT, the one file it could not merge -
# so a consumer that had its own got no fleet view at all. The fleet view has its own command
# now (scripts/cerebro), and the consumer root is the project's alone.
dir_locals="$consumer/.dir-locals.el"
[[ ! -e "$dir_locals" && ! -L "$dir_locals" ]] \
  || fail "the sync wrote $dir_locals: it must write nothing outside .claude/"
pass "the sync writes nothing at the consumer root"

# --- running again leaves the links unchanged and still exits 0 ---
out="$("$cerebro_dir/scripts/sync-symlinks.sh")"
echo "$out" | grep -q "is tracked" \
  && fail "a sync that changed nothing still talked about the tracked directory, got: $out"
pass "a sync that changes nothing says nothing about the tracked directory"
[[ "$(readlink "$skill_link")" == "../cerebro/skills/demo" ]] \
  || fail "second run changed the skill link target"
[[ "$(readlink "$agent_link")" == "../cerebro/agents/demo.md" ]] \
  || fail "second run changed the agent link target"
pass "a second run is idempotent"

# A link outside .claude/ that has been repointed is written again, so the line comes back.
ln -sfn "../../elsewhere/demo.md" "$copilot_agent_link"
out="$("$cerebro_dir/scripts/sync-symlinks.sh")"
[[ "$(readlink "$copilot_agent_link")" == "../../.claude/cerebro/agents/demo.md" ]] \
  || fail "the repointed copilot agent link was not written back"
echo "$out" | grep -qF ".github/ is tracked" \
  || fail "expected a repointed link outside .claude/ to say it again, got: $out"
pass "a repointed link outside .claude/ says it again"

# --- a link into the mount whose source is gone is removed; a consumer's own link is not ---
#
# After a submodule bump that removes a skill or an agent, the link this script wrote for it
# dangles. It is this script's link, so this script removes it - but ONLY a link that points
# into the mount: a consumer's own link to somewhere else is its own business, dangling or not.
ln -s "../cerebro/skills/gone" "$consumer/.claude/skills/gone"
ln -s "../cerebro/agents/gone.md" "$consumer/.claude/agents/gone.md"
ln -s "../../elsewhere/mine" "$consumer/.claude/skills/mine"

out="$("$cerebro_dir/scripts/sync-symlinks.sh" 2>&1)"

[[ ! -L "$consumer/.claude/skills/gone" ]] \
  || fail "a skill link into the mount with no source survived the sync"
[[ ! -L "$consumer/.claude/agents/gone.md" ]] \
  || fail "an agent link into the mount with no source survived the sync"
echo "$out" | grep -qF "Removed stale skill link: $consumer/.claude/skills/gone" \
  || fail "expected the sync to name the removed skill link, got: $out"
echo "$out" | grep -qF "Removed stale agent link: $consumer/.claude/agents/gone.md" \
  || fail "expected the sync to name the removed agent link, got: $out"
[[ -L "$consumer/.claude/skills/mine" ]] \
  || fail "a dangling link that does not point into the mount was removed; it is not this script's"
echo "$out" | grep -q "mine" \
  && fail "the sync talked about a link that is not its own, got: $out"
pass "a link into the mount whose source is gone is removed, out loud; a consumer's own is not"

out="$("$cerebro_dir/scripts/sync-symlinks.sh" 2>&1)"
echo "$out" | grep -q "Removed stale" \
  && fail "a second sync still removes stale links, got: $out"
pass "a second sync says nothing about it"

# --- the guard: run from somewhere that is not a consumer repo's .claude/cerebro ---
outside="$work_dir/x/cerebro/scripts"
mkdir -p "$outside" "$work_dir/.claude"   # a sibling .claude that must NOT be mistaken for a consumer's
cp "$repo_root/scripts/sync-symlinks.sh" "$outside/sync-symlinks.sh"
chmod +x "$outside/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$outside/consumer-root"
cp "$repo_root/scripts/agent-cli" "$outside/agent-cli"
chmod +x "$outside/agent-cli" "$outside/consumer-root"

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
cp "$repo_root/scripts/agent-cli" "$self_consumer/scripts/agent-cli"
chmod +x "$self_consumer/scripts/agent-cli" "$self_consumer/scripts/sync-symlinks.sh" "$self_consumer/scripts/consumer-root"
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

[[ ! -e "$self_consumer/.dir-locals.el" && ! -L "$self_consumer/.dir-locals.el" ]] \
  || fail "a self-consumer got a .dir-locals.el: the sync writes nothing outside .claude/"
pass "a self-consumer's root is left alone too"

# --- a consumer's own .dir-locals.el is not touched, and not mentioned ---
#
# It is the project's file and always was; what has gone is the sync having anything to say about
# it. Nothing is written, and nothing is printed - the "left it alone" lines went with the
# function that needed them.
own="$work_dir/own"
mkdir -p "$own/.claude"
git init -q "$own"
own_cerebro="$own/.claude/cerebro"
mkdir -p "$own_cerebro/scripts" "$own_cerebro/skills/demo" "$own_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$own_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$own_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/agent-cli" "$own_cerebro/scripts/agent-cli"
chmod +x "$own_cerebro/scripts/agent-cli" "$own_cerebro/scripts/sync-symlinks.sh" "$own_cerebro/scripts/consumer-root"
echo "# Demo skill" > "$own_cerebro/skills/demo/SKILL.md"
echo "# Demo agent" > "$own_cerebro/agents/demo.md"
printf '((nil . ((indent-tabs-mode . nil))))\n' > "$own/.dir-locals.el"
before="$(cat "$own/.dir-locals.el")"

out="$("$own_cerebro/scripts/sync-symlinks.sh" 2>&1)"

[[ ! -L "$own/.dir-locals.el" ]] || fail "the consumer's own .dir-locals.el was replaced by a link"
[[ "$(cat "$own/.dir-locals.el")" == "$before" ]] \
  || fail "the consumer's own .dir-locals.el was modified"
echo "$out" | grep -q "\.dir-locals\.el" \
  && fail "the sync mentioned the consumer's own .dir-locals.el, got: $out"
[[ -L "$own/.claude/skills/demo" ]] || fail "the skill links must still be written"
pass "a consumer's own .dir-locals.el is left alone, silently, and the rest still syncs"

# --- a foreign symlink at that path is left alone too ---
#
# `-L' alone would say "ours, refresh it" about a link the consumer made to somewhere else.
foreign="$work_dir/foreign"
mkdir -p "$foreign/.claude" "$foreign/elsewhere"
git init -q "$foreign"
foreign_cerebro="$foreign/.claude/cerebro"
mkdir -p "$foreign_cerebro/scripts" "$foreign_cerebro/skills" "$foreign_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$foreign_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$foreign_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/agent-cli" "$foreign_cerebro/scripts/agent-cli"
chmod +x "$foreign_cerebro/scripts/agent-cli" "$foreign_cerebro/scripts/sync-symlinks.sh" "$foreign_cerebro/scripts/consumer-root"
printf '((nil . ((indent-tabs-mode . nil))))\n' > "$foreign/elsewhere/dir-locals.el"
ln -s "elsewhere/dir-locals.el" "$foreign/.dir-locals.el"

"$foreign_cerebro/scripts/sync-symlinks.sh" >/dev/null 2>&1

[[ "$(readlink "$foreign/.dir-locals.el")" == "elsewhere/dir-locals.el" ]] \
  || fail "a .dir-locals.el symlink the consumer made was removed or repointed"
pass "a .dir-locals.el symlink pointing somewhere else is left alone"

# --- a submodule with no templates/ at all: nothing to do, and no failure ---
old_sub="$work_dir/old"
mkdir -p "$old_sub/.claude"
git init -q "$old_sub"
old_cerebro="$old_sub/.claude/cerebro"
mkdir -p "$old_cerebro/scripts" "$old_cerebro/skills" "$old_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$old_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$old_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/agent-cli" "$old_cerebro/scripts/agent-cli"
chmod +x "$old_cerebro/scripts/agent-cli" "$old_cerebro/scripts/sync-symlinks.sh" "$old_cerebro/scripts/consumer-root"

"$old_cerebro/scripts/sync-symlinks.sh" >/dev/null

[[ ! -e "$old_sub/.dir-locals.el" ]] || fail "wrote a .dir-locals.el at a consumer root"
pass "a submodule with no templates/ syncs the rest and writes no .dir-locals.el"

# --- migration: a link left by a sync from before the fleet view had its own command ---
#
# Every consumer that ever synced carries `.dir-locals.el -> .../templates/consumer-dir-locals.el'.
# The template is gone, so each of those is a dangling link Emacs complains about on every file
# opened. The sync removes exactly that one, out loud - and nothing else at the root.
migrating="$work_dir/migrating"
mkdir -p "$migrating/.claude"
git init -q "$migrating"
mig_cerebro="$migrating/.claude/cerebro"
mkdir -p "$mig_cerebro/scripts" "$mig_cerebro/skills/demo" "$mig_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$mig_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$mig_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/agent-cli" "$mig_cerebro/scripts/agent-cli"
chmod +x "$mig_cerebro/scripts/agent-cli" "$mig_cerebro/scripts/sync-symlinks.sh" "$mig_cerebro/scripts/consumer-root"
echo "# Demo skill" > "$mig_cerebro/skills/demo/SKILL.md"
echo "# Demo agent" > "$mig_cerebro/agents/demo.md"
# Dangling by construction: this fixture has no templates/, exactly like a consumer that has
# bumped the submodule past this change.
ln -s ".claude/cerebro/templates/consumer-dir-locals.el" "$migrating/.dir-locals.el"

out="$("$mig_cerebro/scripts/sync-symlinks.sh" 2>&1)"

[[ ! -e "$migrating/.dir-locals.el" && ! -L "$migrating/.dir-locals.el" ]] \
  || fail "the retired .dir-locals.el link survived the sync"
echo "$out" | grep -qF "Removed stale .dir-locals.el link (templates/consumer-dir-locals.el is gone)" \
  || fail "expected the sync to say it removed the stale link, got: $out"
pass "a retired .dir-locals.el link is removed, out loud"

out="$("$mig_cerebro/scripts/sync-symlinks.sh" 2>&1)"
echo "$out" | grep -q "\.dir-locals\.el" \
  && fail "a second sync still talks about .dir-locals.el, got: $out"
pass "a second sync says nothing about it"

# --- the mirror: a project's own agent and skill reach the other layout (cb-d59.4) --------------
#
# A consumer may declare a role cerebro does not ship and write .claude/agents/<role>.md itself.
# Copilot needs the same content at .github/agents/<role>.agent.md, so the sync mirrors the
# canonical layout's REAL files (never its symlinks, which are its own mount links) into every
# other layout. One way only: nothing is ever read out of .github/ and written into .claude/.
mirror="$work_dir/mirror"
mkdir -p "$mirror/.claude/agents" "$mirror/.claude/skills/own-skill" "$mirror/.github/agents"
git init -q "$mirror"
mir_cerebro="$mirror/.claude/cerebro"
mkdir -p "$mir_cerebro/scripts" "$mir_cerebro/skills/demo" "$mir_cerebro/agents"
cp "$repo_root/scripts/sync-symlinks.sh" "$mir_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$mir_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/agent-cli" "$mir_cerebro/scripts/agent-cli"
chmod +x "$mir_cerebro/scripts/agent-cli" "$mir_cerebro/scripts/sync-symlinks.sh" "$mir_cerebro/scripts/consumer-root"
echo "# Demo skill" > "$mir_cerebro/skills/demo/SKILL.md"
echo "# Demo agent" > "$mir_cerebro/agents/demo.md"
# The project's own, written before the sync ever runs.
echo "# A role only this project declares" > "$mirror/.claude/agents/own-role.md"
echo "# A skill only this project has" > "$mirror/.claude/skills/own-skill/SKILL.md"
# A link in the copilot layout pointing somewhere else entirely: not this script's, dangling or not.
ln -s "../../elsewhere/mine.md" "$mirror/.github/agents/mine.agent.md"

out="$("$mir_cerebro/scripts/sync-symlinks.sh" 2>&1)"

own_agent_link="$mirror/.github/agents/own-role.agent.md"
[[ -L "$own_agent_link" ]] || fail "expected the project's own agent to be mirrored to $own_agent_link"
[[ "$(readlink "$own_agent_link")" == "../../.claude/agents/own-role.md" ]] \
  || fail "mirrored agent link: expected '../../.claude/agents/own-role.md', got '$(readlink "$own_agent_link")'"
[[ -e "$own_agent_link" ]] || fail "the mirrored agent link does not resolve"
pass "a project's own agent file is mirrored into the copilot layout"

own_skill_link="$mirror/.github/skills/own-skill"
[[ -L "$own_skill_link" ]] || fail "expected the project's own skill to be mirrored to $own_skill_link"
[[ "$(readlink "$own_skill_link")" == "../../.claude/skills/own-skill" ]] \
  || fail "mirrored skill link: expected '../../.claude/skills/own-skill', got '$(readlink "$own_skill_link")'"
[[ -e "$own_skill_link/SKILL.md" ]] || fail "the mirrored skill link does not resolve to SKILL.md"
pass "a project's own skill directory is mirrored into the copilot layout"

echo "$out" | grep -qF "Mirrored 1 project agent link(s) from $mirror/.claude/agents to $mirror/.github/agents" \
  || fail "expected the mirror to name what it linked (agents), got: $out"
echo "$out" | grep -qF "Mirrored 1 project skill link(s) from $mirror/.claude/skills to $mirror/.github/skills" \
  || fail "expected the mirror to name what it linked (skills), got: $out"
pass "the mirror names what it linked"

# The mount pass has just written .claude/agents/demo.md -> ../cerebro/agents/demo.md. Mirroring
# that would put a link through a link over the mount link written moments earlier.
[[ "$(readlink "$mirror/.github/agents/demo.agent.md")" == "../../.claude/cerebro/agents/demo.md" ]] \
  || fail "the mount link in the copilot layout was overwritten by the mirror: '$(readlink "$mirror/.github/agents/demo.agent.md")'"
pass "the mirror does not copy this script's own mount links back"

[[ ! -e "$mirror/.claude/agents/own-role.agent.md" && ! -L "$mirror/.claude/agents/own-role.agent.md" ]] \
  || fail "the canonical layout was mirrored onto itself"
[[ ! -L "$mirror/.claude/skills/own-skill" ]] \
  || fail "the project's own skill directory was replaced by a link in the canonical layout"
pass "nothing is mirrored into the canonical layout itself"

# --- a mirrored link whose source is gone, and a link that is not this script's ------------------
rm "$mirror/.claude/agents/own-role.md"
out="$("$mir_cerebro/scripts/sync-symlinks.sh" 2>&1)"
[[ ! -L "$own_agent_link" ]] || fail "a mirrored link whose source the project deleted survived the sync"
echo "$out" | grep -qF "Removed stale agent link: $own_agent_link (its source is gone)" \
  || fail "expected the sync to name the removed mirrored link, got: $out"
pass "a mirrored link whose source the project deleted is removed, out loud"

[[ -L "$mirror/.github/agents/mine.agent.md" ]] \
  || fail "a dangling link in the copilot layout that points elsewhere was removed; it is not this script's"
echo "$out" | grep -q "mine" \
  && fail "the sync talked about a link that is not its own, got: $out"
pass "a link in the copilot layout that points somewhere else is left alone"

echo "all sync-symlinks tests passed"
