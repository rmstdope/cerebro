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
mkdir -p "$cerebro_dir/scripts" "$cerebro_dir/skills/demo" "$cerebro_dir/agents" \
         "$cerebro_dir/hooks/copilot"
# The two hook schemas, side by side, exactly as the mount ships them: Claude Code's settings file
# directly under hooks/, and the provider's own file one level down. Only the latter is ever linked.
echo '{}' > "$cerebro_dir/hooks/copilot/cerebro-question-state.json"
echo '# not a hook' > "$cerebro_dir/hooks/copilot/README.md"
echo '{}' > "$cerebro_dir/hooks/question-state.settings.json"
cp "$repo_root/scripts/sync-symlinks.sh" "$cerebro_dir/scripts/sync-symlinks.sh"
chmod +x "$cerebro_dir/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$cerebro_dir/scripts/consumer-root"
cp "$repo_root/scripts/root-hints.sh" "$cerebro_dir/scripts/root-hints.sh"
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

# --- the provider hook file is linked into .github/hooks (cb-d59.5) -----------------------------
#
# Copilot has no `--settings': it discovers hooks from .github/hooks/*.json IN THE REPOSITORY. So
# the sync links the mount's hooks/copilot/ there, in every consumer whatever agent_cli says - the
# same rule the layouts above follow. `agent-cli --hooks' is where the two paths are written down.
hook_link="$consumer/.github/hooks/cerebro-question-state.json"
[[ -L "$hook_link" ]] || fail "expected $hook_link to be a symlink"
hook_target="$(readlink "$hook_link")"
[[ "$hook_target" == "../../.claude/cerebro/hooks/copilot/cerebro-question-state.json" ]] \
  || fail "expected hook link '../../.claude/cerebro/hooks/copilot/cerebro-question-state.json', got '$hook_target'"
[[ -e "$hook_link" ]] || fail "the hook link does not resolve"
pass "the copilot question-state hook is linked into .github/hooks"

grep -qF "Synced 1 hook link(s) from $cerebro_dir/hooks/copilot to $consumer/.github/hooks" <<<"$first_out" \
  || fail "expected the hook link to be named in the same Synced shape, got: $first_out"
pass "the hook link is named in the same Synced shape as the others"

# --- Claude Code's settings file must never land in .github/hooks -------------------------------
#
# Copilot loads EVERY .json there, and the two schemas are different files and different shapes -
# one would be loaded as a broken hook. That is the whole reason the source is hooks/copilot/ and
# not hooks/, and this is what keeps it true if someone later widens the row.
entries=("$consumer/.github/hooks"/*)
[[ "${#entries[@]}" -eq 1 ]] \
  || fail ".github/hooks should hold exactly the one hook link, got: ${entries[*]}"
for e in "${entries[@]}"; do
  [[ "$(readlink "$e")" == *question-state.settings.json ]] \
    && fail "Claude Code's settings file was linked into .github/hooks: $e"
done
pass "the claude settings file is not linked into the copilot hook directory"

[[ ! -e "$consumer/.github/hooks/README.md" && ! -L "$consumer/.github/hooks/README.md" ]] \
  || fail "a non-json file beside the hook was linked into .github/hooks"
pass "a non-json file beside the hook is not linked"

# --- the tracked-directory line, and its silence -------------------------------------------------
#
# launch-preflight syncs before every single session, so this line is printed only when a link
# outside .claude/ was created or repointed in that run - otherwise it would scroll past above the
# first prompt of every agent, for ever.
grep -qF ".github/ is tracked - commit these links so every clone has them without running this script." <<<"$first_out" \
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
grep -q "is tracked" <<<"$out" \
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
grep -qF ".github/ is tracked" <<<"$out" \
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
grep -qF "Removed stale skill link: $consumer/.claude/skills/gone" <<<"$out" \
  || fail "expected the sync to name the removed skill link, got: $out"
grep -qF "Removed stale agent link: $consumer/.claude/agents/gone.md" <<<"$out" \
  || fail "expected the sync to name the removed agent link, got: $out"
[[ -L "$consumer/.claude/skills/mine" ]] \
  || fail "a dangling link that does not point into the mount was removed; it is not this script's"
grep -q "mine" <<<"$out" \
  && fail "the sync talked about a link that is not its own, got: $out"
pass "a link into the mount whose source is gone is removed, out loud; a consumer's own is not"

out="$("$cerebro_dir/scripts/sync-symlinks.sh" 2>&1)"
grep -q "Removed stale" <<<"$out" \
  && fail "a second sync still removes stale links, got: $out"
pass "a second sync says nothing about it"
# --- a sync that changes nothing does not rewrite the links it finds ----------------------------
#
# `ln -sfn' removes and recreates, so an unconditional write gave every link in the consumer a new
# inode on every launch - and launch-preflight syncs before every session. The script already asks
# `link_would_change' before writing; this pins that the answer is acted on.
#
# `ls -i' reports the LINK's own inode: `ls' does not follow a symlink without -L.
inode_of() { ls -i "$1" | awk '{print $1}'; }

"$cerebro_dir/scripts/sync-symlinks.sh" >/dev/null
before_skill="$(inode_of "$skill_link")"
before_agent="$(inode_of "$agent_link")"
before_hook="$(inode_of "$hook_link")"
"$cerebro_dir/scripts/sync-symlinks.sh" >/dev/null
[[ "$(inode_of "$skill_link")" == "$before_skill" ]] \
  || fail "a second sync rewrote the skill link"
[[ "$(inode_of "$agent_link")" == "$before_agent" ]] \
  || fail "a second sync rewrote the agent link"
[[ "$(inode_of "$hook_link")" == "$before_hook" ]] \
  || fail "a second sync rewrote the hook link"
pass "a sync that changes nothing does not rewrite the links"

# --- the guard: run from somewhere that is not a consumer repo's .claude/cerebro ---
outside="$work_dir/x/cerebro/scripts"
mkdir -p "$outside" "$work_dir/.claude"   # a sibling .claude that must NOT be mistaken for a consumer's
cp "$repo_root/scripts/sync-symlinks.sh" "$outside/sync-symlinks.sh"
chmod +x "$outside/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$outside/consumer-root"
cp "$repo_root/scripts/root-hints.sh" "$outside/root-hints.sh"
cp "$repo_root/scripts/agent-cli" "$outside/agent-cli"
chmod +x "$outside/agent-cli" "$outside/consumer-root"

set +e
out="$("$outside/sync-symlinks.sh" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]] || fail "expected the guard to reject a non-consumer layout, exited 0"
grep -q "must run from a consumer repo" <<<"$out" \
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
mkdir -p "$self_consumer/scripts" "$self_consumer/skills/demo" "$self_consumer/agents" \
         "$self_consumer/.claude" "$self_consumer/hooks/copilot"
echo '{}' > "$self_consumer/hooks/copilot/cerebro-question-state.json"
cp "$repo_root/scripts/sync-symlinks.sh" "$self_consumer/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root" "$self_consumer/scripts/consumer-root"
cp "$repo_root/scripts/root-hints.sh" "$self_consumer/scripts/root-hints.sh"
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

self_hook_link="$self_consumer/.github/hooks/cerebro-question-state.json"
[[ "$(readlink "$self_hook_link")" == "../../.claude/cerebro/hooks/copilot/cerebro-question-state.json" ]] \
  || fail "self-consumer hook link: expected '../../.claude/cerebro/hooks/copilot/cerebro-question-state.json', got '$(readlink "$self_hook_link")'"
[[ -e "$self_hook_link" ]] || fail "the self-consumer hook link does not resolve"
pass "a self-consumer links the hook through the mount too"

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
cp "$repo_root/scripts/root-hints.sh" "$own_cerebro/scripts/root-hints.sh"
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
grep -q "\.dir-locals\.el" <<<"$out" \
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
cp "$repo_root/scripts/root-hints.sh" "$foreign_cerebro/scripts/root-hints.sh"
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
cp "$repo_root/scripts/root-hints.sh" "$old_cerebro/scripts/root-hints.sh"
cp "$repo_root/scripts/agent-cli" "$old_cerebro/scripts/agent-cli"
chmod +x "$old_cerebro/scripts/agent-cli" "$old_cerebro/scripts/sync-symlinks.sh" "$old_cerebro/scripts/consumer-root"

"$old_cerebro/scripts/sync-symlinks.sh" >/dev/null

[[ ! -e "$old_sub/.dir-locals.el" ]] || fail "wrote a .dir-locals.el at a consumer root"
pass "a submodule with no templates/ syncs the rest and writes no .dir-locals.el"

# The same fixture ships no hooks/<provider>/ either, which is every consumer on an older submodule.
# This script runs from launch-preflight before every session, so that must sync the rest and say
# nothing rather than refuse - unlike a mount missing skills/ or agents/, which is broken.
[[ -L "$old_sub/.claude/agents/demo.md" ]] || [[ ! -e "$old_cerebro/agents/demo.md" ]] \
  || fail "the rest of the sync did not run"
[[ ! -d "$old_sub/.github/hooks" ]] || [[ -z "$(ls -A "$old_sub/.github/hooks")" ]] \
  || fail "a mount with no hooks/copilot still wrote something into .github/hooks"
out="$("$old_cerebro/scripts/sync-symlinks.sh" 2>&1)"
grep -q "hook" <<<"$out" \
  && fail "a mount with no hooks/copilot talked about hooks, got: $out"
pass "a mount that ships no provider hooks syncs the rest, silently"

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
cp "$repo_root/scripts/root-hints.sh" "$mig_cerebro/scripts/root-hints.sh"
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
grep -qF "Removed stale .dir-locals.el link (templates/consumer-dir-locals.el is gone)" <<<"$out" \
  || fail "expected the sync to say it removed the stale link, got: $out"
pass "a retired .dir-locals.el link is removed, out loud"

out="$("$mig_cerebro/scripts/sync-symlinks.sh" 2>&1)"
grep -q "\.dir-locals\.el" <<<"$out" \
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
cp "$repo_root/scripts/root-hints.sh" "$mir_cerebro/scripts/root-hints.sh"
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

grep -qF "Mirrored 1 project agent link(s) from $mirror/.claude/agents to $mirror/.github/agents" <<<"$out" \
  || fail "expected the mirror to name what it linked (agents), got: $out"
grep -qF "Mirrored 1 project skill link(s) from $mirror/.claude/skills to $mirror/.github/skills" <<<"$out" \
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
grep -qF "Removed stale agent link: $own_agent_link (its source is gone)" <<<"$out" \
  || fail "expected the sync to name the removed mirrored link, got: $out"
pass "a mirrored link whose source the project deleted is removed, out loud"

[[ -L "$mirror/.github/agents/mine.agent.md" ]] \
  || fail "a dangling link in the copilot layout that points elsewhere was removed; it is not this script's"
grep -q "mine" <<<"$out" \
  && fail "the sync talked about a link that is not its own, got: $out"
pass "a link in the copilot layout that points somewhere else is left alone"

# --- the hook sweep: a link whose source is gone, and a link that is not this script's ----------
rm "$cerebro_dir/hooks/copilot/cerebro-question-state.json"
ln -s "../../elsewhere/mine.json" "$consumer/.github/hooks/mine.json"
out="$("$cerebro_dir/scripts/sync-symlinks.sh" 2>&1)"
[[ ! -L "$hook_link" ]] || fail "a hook link whose source is gone from the mount survived the sync"
grep -qF "Removed stale hook link: $hook_link (its source is gone from the mount)" <<<"$out" \
  || fail "expected the sync to name the removed hook link, got: $out"
pass "a hook link whose source is gone from the mount is removed, out loud"

[[ -L "$consumer/.github/hooks/mine.json" ]] \
  || fail "a dangling hook link pointing elsewhere was removed; it is not this script's"
grep -q "mine" <<<"$out" \
  && fail "the sync talked about a hook link that is not its own, got: $out"
pass "a hook link pointing somewhere else is left alone"

# --- many links in one destination directory: the sweep still picks the right one ----------------
#
# The stale sweep reads a whole directory's links at once, so a directory holding several is where
# a path-to-target misalignment would show: one link's target read against another's path would
# either spare a stale link or remove a live one, and a directory of two could hide both.
many="$work_dir/many"
mkdir -p "$many/.claude"
git init -q "$many"
many_cerebro="$many/.claude/cerebro"
mkdir -p "$many_cerebro/scripts" "$many_cerebro/agents" \
         "$many_cerebro/skills/alpha" "$many_cerebro/skills/beta" "$many_cerebro/skills/gamma"
cp "$repo_root/scripts/sync-symlinks.sh" "$many_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/consumer-root"    "$many_cerebro/scripts/consumer-root"
cp "$repo_root/scripts/root-hints.sh" "$many_cerebro/scripts/root-hints.sh"
cp "$repo_root/scripts/agent-cli"        "$many_cerebro/scripts/agent-cli"
chmod +x "$many_cerebro/scripts/agent-cli" "$many_cerebro/scripts/sync-symlinks.sh" \
         "$many_cerebro/scripts/consumer-root"
for sk in alpha beta gamma; do echo "# $sk" > "$many_cerebro/skills/$sk/SKILL.md"; done
echo "# Demo agent" > "$many_cerebro/agents/demo.md"

"$many_cerebro/scripts/sync-symlinks.sh" >/dev/null

# Two links of the consumer's own, interleaved with this script's: one that resolves and one that
# does not. Neither points into the mount, so neither is this script's to touch.
mkdir -p "$many/elsewhere/theirs"
ln -s "../../elsewhere/theirs" "$many/.claude/skills/theirs"
ln -s "../../elsewhere/gone"   "$many/.claude/skills/theirs-gone"

rm -rf "$many_cerebro/skills/beta"
out="$("$many_cerebro/scripts/sync-symlinks.sh" 2>&1)"

[[ ! -L "$many/.claude/skills/beta" ]] || fail "many: the link for the removed skill beta survived"
grep -qF "Removed stale skill link: $many/.claude/skills/beta" <<<"$out" \
  || fail "many: expected the sync to name the removed beta link, got: $out"
for sk in alpha gamma; do
  [[ "$(readlink "$many/.claude/skills/$sk")" == "../cerebro/skills/$sk" ]] \
    || fail "many: $sk's link was disturbed: $(readlink "$many/.claude/skills/$sk")"
done
[[ "$(readlink "$many/.claude/skills/theirs")" == "../../elsewhere/theirs" ]] \
  || fail "many: the consumer's own resolving link was disturbed"
[[ "$(readlink "$many/.claude/skills/theirs-gone")" == "../../elsewhere/gone" ]] \
  || fail "many: the consumer's own dangling link was removed; it is not this script's"
grep -q "theirs" <<<"$out" \
  && fail "many: the sync talked about a link that is not its own, got: $out"
pass "a directory of several links sweeps only the stale cerebro one"

# --- a link target with a space in it survives the sync ------------------------------------------
#
# The directory's links are read in one go, with `read -r' and no IFS splitting, so a target that
# is not a bare word comes back whole. Split on IFS it would arrive as two words, the link would
# read as pointing somewhere it does not, and this script would take a decision about a link that
# is not its own.
ln -s "../../a dir/x" "$many/.claude/agents/spaced.md"
out="$("$many_cerebro/scripts/sync-symlinks.sh" 2>&1)"
[[ "$(readlink "$many/.claude/agents/spaced.md")" == "../../a dir/x" ]] \
  || fail "spaced: the link was disturbed: $(readlink "$many/.claude/agents/spaced.md")"
grep -qF "Synced 1 agent link(s)" <<<"$out" \
  || fail "spaced: expected the sync to still report its own agent link, got: $out"
pass "a link target with a space in it survives the sync"

# --- the launch path's hints replace both consumer-root forks (cb-ue0) ---------------------------
#
# `launch-preflight' runs this script on every session start, and it forked `consumer-root' twice -
# once for the root and once for the mount - after `launch' had already resolved both. With
# `consumer-root' stubbed to fail, a link written here can only have come from the hints.
hint_consumer="$work_dir/hinted"
hint_cerebro="$hint_consumer/.claude/cerebro"
mkdir -p "$hint_cerebro/scripts" "$hint_cerebro/skills/demo" "$hint_cerebro/agents" \
         "$hint_cerebro/hooks/copilot"
git init -q "$hint_consumer"
echo '# Demo skill' > "$hint_cerebro/skills/demo/SKILL.md"
echo '# Demo agent' > "$hint_cerebro/agents/demo.md"
cp "$repo_root/scripts/sync-symlinks.sh" "$hint_cerebro/scripts/sync-symlinks.sh"
cp "$repo_root/scripts/agent-cli" "$hint_cerebro/scripts/agent-cli"
cp "$repo_root/scripts/root-hints.sh" "$hint_cerebro/scripts/root-hints.sh"
cat > "$hint_cerebro/scripts/consumer-root" <<'STUB'
#!/usr/bin/env bash
echo "consumer-root: the suite says this must not be forked" >&2
exit 1
STUB
chmod +x "$hint_cerebro/scripts/sync-symlinks.sh" "$hint_cerebro/scripts/agent-cli" \
         "$hint_cerebro/scripts/consumer-root"

CEREBRO_CONSUMER_ROOT="$(cd "$hint_consumer" && pwd -P)" \
CEREBRO_CONSUMER_SHARED_ROOT="$(cd "$hint_consumer" && pwd -P)" \
CEREBRO_CONSUMER_MOUNT=".claude/cerebro" \
  "$hint_cerebro/scripts/sync-symlinks.sh" >/dev/null
[[ "$(readlink "$hint_consumer/.claude/skills/demo")" == "../cerebro/skills/demo" ]] \
  || fail "hinted sync: expected ../cerebro/skills/demo, got $(readlink "$hint_consumer/.claude/skills/demo")"
pass "validated hints replace both consumer-root forks, and the link is spelled from the hinted mount"

# --- and a foreign hint is refused rather than followed into another tree ------------------------
set +e
out="$(CEREBRO_CONSUMER_ROOT="$(cd "$consumer" && pwd -P)" \
       CEREBRO_CONSUMER_SHARED_ROOT="$(cd "$consumer" && pwd -P)" \
       CEREBRO_CONSUMER_MOUNT=".claude/cerebro" \
       "$hint_cerebro/scripts/sync-symlinks.sh" 2>&1)"
status=$?
set -e
[[ $status -eq 1 ]] || fail "foreign hint: expected the refusal (exit 1), got $status: $out"
grep -q "must run from a consumer repo" <<<"$out" \
  || fail "foreign hint: expected the refusal line, got: $out"
pass "a hint describing another checkout is refused, not followed into that tree"

suite_passed
