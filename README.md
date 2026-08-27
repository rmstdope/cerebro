# Cerebro
An AI harness consisting of agents, skills and scripts. Preferably run within emacs

![The Cerebro fleet](docs/cerebro-fleet.svg)

Six agent roles, one bead board, and the humans they answer to — the same picture lives in
[docs/agent-workflow.md](docs/agent-workflow.md), which is the operating guide behind it.

## Setting up a new project

Nine steps, in this order. Each says what it is for, what to run from the root of your
repository, and how to tell it worked.

### 1. Have the tools on PATH

The fleet is bash and Emacs Lisp on top of programs it does not ship:

- **One agent CLI** — every agent is a session of it. Either `claude`
  ([Claude Code](https://claude.com/claude-code)) or `copilot`
  ([GitHub Copilot CLI](https://github.com/github/copilot-cli)), declared once in step 4 as
  `agent_cli`; absent means `claude`. What a fleet on Copilot gets and does not is
  [docs/providers/copilot.md](docs/providers/copilot.md).
- `bd` — the bead board every role reads and writes ([beads](https://github.com/steveyegge/beads)),
  with a Dolt remote so every machine and session sees one board.
- `gh` — pull requests, reviews, and the issue inbox.
- `git` and `jq` — every script.
- Emacs 28 or later for the fleet view; `vterm` if you want sessions started from it with `s`.
  Without vterm you start sessions in a terminal and the view still shows them.

Check:

```bash
for t in bd gh git jq emacs; do command -v "$t" >/dev/null && echo "$t ok" || echo "$t MISSING"; done
if command -v claude >/dev/null || command -v copilot >/dev/null
then echo "agent CLI ok"; else echo "agent CLI MISSING"; fi
```

### 2. Add cerebro as a submodule at `.claude/cerebro`

`.claude/cerebro` is the one path every script and the fleet view assume.

```bash
git submodule add https://github.com/rmstdope/cerebro.git .claude/cerebro
git submodule update --init --recursive
```

Check: `.claude/cerebro/scripts/consumer-root` prints your repository's absolute path.

### 3. Link the skills and agents

Claude Code discovers `.claude/skills/<name>/SKILL.md` and `.claude/agents/<name>.md`; GitHub
Copilot discovers `.github/skills/<name>/` and `.github/agents/<name>.agent.md`, and its hooks from
`.github/hooks/`. The sync writes relative symlinks into **both** layouts in every project, whatever
`agent_cli` you declare — so switching CLI stays one line in step 4 and nothing else.

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

Check: it prints one `Synced N skill link(s) …` line and one `Synced N agent link(s) …` line. If a
`.dir-locals.el` link from an earlier sync is at your root, it also prints
`Removed stale .dir-locals.el link (templates/consumer-dir-locals.el is gone)`.

#### Or: let a session do steps 4 to 9

With the tools, the submodule and the links in place, run `claude` at the root of your repository
and type `/project-definition`. It interviews you about the project — what the software is, where it
runs, what it is built with, what using it is like — and then writes every declaration below,
initialises the board and files the first epics. The steps that follow are what it does, written out
for reading or for doing by hand.

### 4. Declare the project: `.cerebro/project.conf`

The one file every script reads a project fact from — `key value`, one per line, and everything
from a `#` on is a comment, so a value can never contain one. The minimum:

```
project_name   Ledger
default_branch main
audience_noun  user          # what the agents call the people who use your application
app_paths      ^src/         # a regex: which changed paths those people could see
gate_fast      make test     # what an implementer runs before it opens a pull request
gate_full      make test     # what a pull request is judged by
install        npm ci        # omit it when there is nothing to install
# agent_cli    copilot       # which CLI the sessions run on; absent means claude
```

An absent key is a default, with one exception: without `app_paths` the fleet refuses to classify a
change rather than guess, since a wrong guess either empties the release notes or sends you to
verify documentation.
A project with nothing a person can launch — a library, a build tool, a harness like this one —
adds `verification none`, and the verifier marks every merged bead as needing no look instead of
asking how to start an application that does not exist.
A project whose verification has a procedure of its own — which shell to prefer, how its fixtures
are chosen and proved, what shape a script should take for the person reading it — declares
`verification_skill <skill name>` instead, and the verifier loads that skill before it prepares
anything, following it wherever it is more specific than the verifier's own file.
This repository's own `.cerebro/project.conf` is a commented example, and
the header of `scripts/project-conf` states the format.

Check: `.claude/cerebro/scripts/project-conf project_name` prints the name, and
`.claude/cerebro/scripts/app-paths` prints your pattern.

### 5. Declare the fleet: `.cerebro/roster.conf` (optional)

Absent, you run the built-in fleet. To run your own names, or fewer of them, write `NAME  ROLE` per
line — the roles are the files in `.claude/cerebro/agents/`: `planner`, `implementer`,
`orchestrator`, `verifier`, `reviewer`, `user-feedback`, `architect`. Order is load-bearing:
implementers are taken in file order.

Check: `.claude/cerebro/scripts/roster` prints your fleet, one `name<TAB>role<TAB>kind` per line.

### 6. Traps and models (optional)

- `.cerebro/traps.md` — the facts this project has already paid for, read by planners and
  implementers before they start. Absent is where every project starts.
- `.cerebro/models.conf` — which model each agent runs on:
  `cp .claude/cerebro/models.conf.example .cerebro/models.conf` and uncomment a line. A key may name
  the CLI it is about — `planner@copilot gpt-5.5` applies only on Copilot, and beats a plain
  `planner` row there — which is how one file covers both; on a CLI other than Claude Code it is the
  **only** place models come from, the agent definitions declaring Claude Code's words. Commit it to
  share the fleet's models with every clone, or ignore it (step 8) to keep it personal.

Check: with a `models.conf` line uncommented, `launch` says `launch: models.conf (<key>) -> <model>`
on stderr as it starts a session.

### 7. Give the fleet its `CLAUDE.md`

Copy the template to your root `CLAUDE.md` — or merge its sections into the one you have — and edit
every section until it describes your project. Two headings are read by their exact name:
`## Four Eye Principle`, an implementer's standing permission to merge (delete it and nothing
merges), and `## Work tracking`.

```bash
cp .claude/cerebro/templates/consumer-CLAUDE.md CLAUDE.md
```

Check: `grep -c '^## Four Eye Principle' CLAUDE.md` prints `1`.

### 8. Ignore the runtime, track the declarations

`.cerebro/` holds two kinds of thing: what the fleet writes while it runs, and what the project
declares. Ignore the first and commit the second:

```gitignore
.cerebro/worktrees
.cerebro/state
.cerebro/scratch
```

`worktrees/` is where every implementer builds; `state/` holds the agents' state files and stop
flags; `scratch/` holds the planners' drafts and rejected mockup variants. Everything else in
`.cerebro/` is tracked — the declarations from steps 4 to 6, and `models.conf` if the fleet's
models are the project's to share (add `.cerebro/models.conf` here to keep it personal instead).
Then commit the submodule, the links, the declarations and `CLAUDE.md`.

Check: `git check-ignore -v .cerebro/state/x` names the `.cerebro/state` line, and
`git check-ignore .cerebro/project.conf` prints nothing.

### 9. Set up the board, and start the fleet

The board is beads: `bd init` in your repository, then a Dolt remote
(`bd dolt remote add origin <url>`) so every machine and session sees the same beads. Every bead is
created unranked and ranked with you; a planner turns it into a plan; an implementer builds it.

Then open the fleet view:

```bash
.claude/cerebro/scripts/cerebro
```

That opens it in a fresh Emacs — your own init is loaded, so the vterm the view needs for live
sessions is whatever your Emacs has; set `EMACS` to a binary that is not on your `PATH`
(`EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs`). Press `s` on a planner's row.

#### In your own Emacs

To have `M-x cerebro` in the Emacs you already work in, add to your init, with the path of your
checkout:

```elisp
(add-to-list 'load-path "/path/to/your/project/.claude/cerebro/emacs")
(autoload 'cerebro "cerebro" "List the Cerebro agent fleet." t)
```

A session can also be started from a terminal without the fleet view:

```bash
.claude/cerebro/scripts/launch Xavier
```

Check: `.claude/cerebro/scripts/launch-preflight planner Xavier; echo $?` prints `0` and nothing
else. In the fleet view the row turns green a few seconds after the session starts, when it writes
its state file. [docs/agent-workflow.md](docs/agent-workflow.md) is what to read next: it is the
operating guide for everything after this point.

## Launchers

Each agent is started by a script of its own, run from the consumer repository root:

```bash
.claude/cerebro/scripts/launch <Name>            # any agent, by name - the one way to start one
.claude/cerebro/scripts/roster                   # the fleet: name, role, kind - one line per agent
.claude/cerebro/scripts/roster --implementers    # the implementer names, one per line
```

Every agent starts the same way, by its own name: `launch Xavier`, `launch Cyclops`, `launch Forge`.
There are no per-role launcher scripts - the roster is the one place the fleet is declared, and
`launch` is the one place a session is started.

Every session starts with Remote Control on and is listed under its agent's name at
[claude.ai/code](https://claude.ai/code) and in the Claude app, so an agent can be read and steered
from another device. It needs a Pro/Max/Team login; where it cannot connect the session shows a
notification and runs on as a normal one, so nothing here depends on it.

Every launcher starts **one interactive `claude` session** and nothing else. Right before it
does, it runs `scripts/launch-preflight`: the checkout is brought current with the default
branch on origin, the skill and agent links are re-synced so a bumped submodule is usable the
moment something starts, and it refuses with one line naming what is wrong — `claude` missing
from `PATH`, a declaration left at a retired path, the submodule not carrying that role's agent
file — rather than the session going `up` for a moment and then silently `dead`.

`scripts/prune-worktrees.sh` is the worktree sweep, run by Cerebro on a timer and by you whenever
you like (`--dry-run` first).

To take a newer cerebro: `git submodule update --remote --merge .claude/cerebro`, then start
something — every launch re-syncs the links.

## Skills

`plan-bead` and `implement-bead` are the two roles' procedures; `beads-workflow` is the substrate
both read.

## Sync Script (Skills and Agents)

You do not normally run this by hand: every launcher runs it before starting a session, so a bumped
agent or skill is linked the first time something is started (ah-cuc).

What it does:

- Asks `scripts/consumer-root` for the consumer repository root (the enclosing working tree) and exits with an error if this checkout is not mounted at `<consumer>/.claude/cerebro`.
- Creates `../../.claude/skills/` and `../../.claude/agents/` if they do not exist.
- Scans `.claude/cerebro/skills/*` for folders that contain `SKILL.md`.
- Creates/updates symlinks in `.claude/skills/` (for example `.claude/skills/plan-bead -> ../cerebro/skills/plan-bead`), relative rather than absolute, so the same link is correct in the main checkout, in every worktree and on every machine.
- Scans `.claude/cerebro/agents/*.md` and creates/updates symlinks in `.claude/agents/`.
- Removes the old aggregate symlink `.claude/skills/cerebro` if present.
- Removes a `.dir-locals.el` link at the consumer root left by a sync from before the fleet view had its own command; a `.dir-locals.el` the project wrote itself is never touched.

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
`githooks/` is optional and refused where `core.hooksPath` is already taken (whenever another tool —
beads, husky, lefthook — already owns it) — that is fine, since every launcher syncs the links itself before starting a session
regardless of whether the hooks are installed.

The script uses fixed locations relative to itself and does not support source/destination override variables.
