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

## Launchers

Each agent is started by a script of its own, run from the consumer repository root:

```bash
.claude/cerebro/scripts/run-planner              # Xavier, on Fable at high effort
.claude/cerebro/scripts/run-orchestrator         # Cerebro, on Fable at medium effort
.claude/cerebro/scripts/run-user-feedback        # Moira
.claude/cerebro/scripts/run-psylocke             # Psylocke, the verifier
.claude/cerebro/scripts/run-bishop               # Bishop, the architect, one sweep per session
.claude/cerebro/scripts/run-implementer Cyclops  # one implementer, named from a closed roster
.claude/cerebro/scripts/run-implementer --roster # the thirteen names, one per line
```

All of them start **one interactive `claude` session** and nothing else — no loop, no flags, no
files. That last point is a reversal worth knowing if you have used an older version: the
implementer launcher used to run `claude --print` in a loop, one process per bead, for as long as a
`.go` flag was set. That bought "one bead per session" for free and cost the ability to talk to an
implementer at all.

Now an implementer is interactive, so it can be answered — and because an interactive session never
exits, the loop moved to something that can end one. The Emacs fleet view polls each implementer's
state file, and when one reports `done` it ends that session and starts a fresh one, unless
`.claude/agents-state/<name>.stop` says not to. **The `.go` flag is retired**, along with the loop
that read it: a running implementer is a working one.

`scripts/prune-worktrees.sh` is the worktree sweep, run by Cerebro on a timer and by you whenever
you like (`--dry-run` first).

## Sync Script (Skills and Agents)

Claude code customization discovery expects direct entries under:

- `.claude/skills/<skill-name>/SKILL.md`
- `.claude/agents/*.md`

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
- Scans `.claude/cerebro/agents/*.md` and creates/updates symlinks in `.claude/agents/`.
- Removes the old aggregate symlink `.claude/skills/cerebro` if present.

Run it whenever:

- You add or remove skills or agents in this repository.
- You update the submodule to a newer commit.

### Optional: Run Sync Automatically On Submodule Pointer Changes

This repository ships git hooks in `githooks/` that run the sync script automatically after merge/pull and checkout when the `.claude/cerebro` gitlink changes.

Enable once per clone, from anywhere inside the consumer repository:

```bash
.claude/cerebro/githooks/install.sh
```

What it configures:

- `core.hooksPath=.claude/cerebro/githooks`
- `post-merge` hook: syncs when `.claude/cerebro` changed between `ORIG_HEAD` and `HEAD`.
- `post-checkout` hook: syncs when `.claude/cerebro` changed between old and new refs, and only on a branch checkout.

Both hooks are silent when the gitlink did not move.

**`core.hooksPath` is repository-wide**: it replaces `.git/hooks` rather than adding to it, so any hooks
already there stop running. The installer refuses to overwrite a `core.hooksPath` that points somewhere
else, and warns if `.git/hooks` holds non-sample hooks — in either case, merge them by hand instead.

The script uses fixed locations relative to itself and does not support source/destination override variables.