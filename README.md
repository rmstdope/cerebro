# Cerebro
An AI harness consisting of agents, skills and scripts. Preferably run within emacs

## Use As a Git Submodule

If you want to consume these skills from another repository, add this repository as a submodule under `.claude/cerebro`:

```bash
git submodule add https://github.com/rmstdope/cerebro.git .claude/cerebro
git submodule update --init --recursive
```

When pulling updates later:

```bash
git submodule update --remote --merge .claude/cerebro
```

## Sync Script (Skills and Agents)

Claude code customization discovery expects direct entries under:

- `.claude/skills/<skill-name>/SKILL.md`
- `.claude/agents/*.agent.md`

This repository ships a helper script that creates/updates symlinks for all of them.

Run from the consumer repository root:

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

What it does:

- Verifies `../../.claude/` exists (relative to the script location) to confirm the script is being run in a consumer repository root, and exits with an error if it is missing.
- Creates `../../.claude/skills/` and `../../.claude/agents/` if they do not exist.
- Scans `.claude/cerebro/skills/*` for folders that contain `SKILL.md`.
- Creates/updates symlinks in `.claude/skills/` (for example `.claude/skills/plan-bead -> .claude/cerebro/skills/plan-bead`).
- Scans `.claude/cerebro/agents/*.agent.md` and creates/updates symlinks in `.claude/agents/`.
- Scans `.claude/cerebro/instructions/*.instructions.md` and creates/updates symlinks in `.claude/instructions/`.
- Removes the old aggregate symlink `.claude/skills/cerebro` if present.

Run it whenever:

- You add or remove skills or agents in this repository.
- You update the submodule to a newer commit.

### Optional: Run Sync Automatically On Submodule Pointer Changes

This repository includes git hooks in `.githooks/` that run the sync script automatically after merge/pull and checkout when the `.claude/cerebro` gitlink changes.

Enable once per clone from the consumer repository root:

```bash
.githooks/install.sh
```

What it configures:

- `core.hooksPath=.githooks`
- `post-merge` hook: syncs when `.claude/cerebro` changed between `ORIG_HEAD` and `HEAD`.
- `post-checkout` hook: syncs when `.claude/cerebro` changed between old and new refs.

The script uses fixed locations relative to itself and does not support source/destination override variables.