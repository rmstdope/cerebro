# Cerebro

Cerebro runs a fleet of AI coding agents on your repository. You file work as beads and rank it;
the fleet plans each bead, builds it test-first in its own worktree, reviews and merges the pull
request, and brings what merged back to you to verify. It ships as a git submodule mounted at
`.cerebro/cerebro`: agent definitions, skills and scripts for Claude Code or GitHub Copilot CLI, and
a terminal fleet view that shows the agents and the board and starts, ends and nudges their
sessions. You are the navigator. You never make a technical decision: architecture, files, tests
and approach are the agents' to decide. You make every decision about what people will see and
about what gets built in which order: you rank the work, agree each user experience before it is
built, and verify it once it has merged.

## Prerequisites

The fleet is bash and Rust on top of programs it does not ship. Have these on `PATH`:

- **One agent CLI** — every agent is a session of it. Either `claude`
  ([Claude Code](https://claude.com/claude-code)) or `copilot`
  ([GitHub Copilot CLI](https://github.com/github/copilot-cli)); each agent's tool is named in
  `agents.conf`. What a fleet on Copilot gets and does not is
  [docs/providers/copilot.md](docs/providers/copilot.md).
- `bd` — the bead board every role reads and writes ([beads](https://github.com/steveyegge/beads)),
  with a Dolt remote so every machine and session sees one board.
- `gh` — pull requests, reviews, and the issue inbox.
- `git` and `jq` — every script.
- **Rust and Cargo**, for the fleet view (`.cerebro/cerebro/scripts/cerebro-tui`, below). Optional:
  the launchers work without it.

## Setting up a new project

Five steps, in this order, and an optional sixth. Each says what it is for, what to run from the root of your
repository, and how to tell it worked.

### 1. Add cerebro as a submodule at `.cerebro/cerebro`

`.cerebro/cerebro` is the one path every script and the fleet view assume. It sits beside the
project's declarations, so a fleet that runs Copilot alone needs no `.claude/` of its own.

A repository that mounted cerebro at the old `.claude/cerebro` moves it once; every launch refuses
until it has:

```bash
git mv .claude/cerebro .cerebro/cerebro
.cerebro/cerebro/scripts/sync-symlinks.sh
git commit -m "Move cerebro to .cerebro/cerebro"
```

```bash
git submodule add https://github.com/rmstdope/cerebro.git .cerebro/cerebro
git submodule update --init --recursive
```

Check: `.cerebro/cerebro/scripts/consumer-root` prints your repository's absolute path.

### 2. Run the installer

```bash
.cerebro/cerebro/scripts/install
```

It asks a handful of questions about the project, each with a default taken from the tree, and
writes the answers to `.cerebro/project.conf`, where every other setting is listed, explained and
commented out. Then it asks about the fleet — how many agents of each role, and which the fleet
view starts on its own — and writes `.cerebro/roster.conf`. Next it asks which agent CLI and
models the agents run on, and writes `.cerebro/agents.conf`, shared with every clone or kept
personal as you answer; the runtime directories under `.cerebro/` are ignored either way. Last it
makes the bead board, proposing a prefix for bead ids, with the repository's `origin` as the Dolt
remote every machine and session shares.

Check: it exits 0. If it does not, it has named what is missing; fix that and run it again.

### 3. Give the fleet its instructions

The fleet reads one instruction file at your root, `CLAUDE.md`. Claude Code loads it, and Copilot
loads the same file as its custom instructions when no `AGENTS.md` sits beside it
([docs/providers/copilot.md](docs/providers/copilot.md)). Copy the template there, or merge its
sections into the file you have, and edit it until it describes your project. `## Work tracking`
is read by its exact name.

```bash
cp .cerebro/cerebro/templates/consumer-instructions.md CLAUDE.md
```

Check: `grep -c '^## Work tracking' CLAUDE.md` prints `1`.

### 4. Commit and push

Everything so far is tracked, so every clone runs the same fleet: the submodule, the links the
installer wrote under `.claude/` and `.github/`, the declarations under `.cerebro/`, `CLAUDE.md`,
`.gitignore` and `.beads/`. The board goes to its own remote.

```bash
git add -A && git commit -m "Mount cerebro" && git push
bd dolt push
```

Check: `git status` reports a clean tree, and `bd dolt push` says there is nothing left to push.

### 5. Start the fleet

Open the fleet view, from anywhere inside the repository:

```bash
.cerebro/cerebro/scripts/cerebro-tui
```

The rows the roster marks `autostart` start as it opens, `standby` rows wait for their trigger,
and `s` on any row starts that agent now. Work is tracked on the board: every bead is created
unranked and ranked with you; `ux` agrees its experience; a producer plans and builds it.

Check: a started row turns green a few seconds later, when the session writes its state file.
[docs/agent-workflow.md](docs/agent-workflow.md) is what to read next: it is the operating guide
for everything after this point.

### 6. Define the project in more detail (optional)

With the fleet up, type `/project-definition` into the orchestrator's or the architect's session.
It interviews you about the project — what the software is, where it runs, what it is built with,
what using it is like — refines the declarations and the instruction file from the answers, and
files the opening epics on the board, ranked with you, so the fleet has work to start on. Today
the skill still expects a blank repository and writes its own declarations; until it is reworked to
build on the installer's, answer its questions the same way you answered the installer.

## The fleet view

It shows the fleet rows and six work queues (Claimed, Planned unclaimed, Being
planned, Unplanned, Waiting on you, Merged unverified) in two separately bordered, independently
scrolling widgets stacked one above the other - Fleet on top, Work below - refreshing the fleet
every five seconds and the board every thirty. `Tab` moves focus between them, and `F1`/`F2`/`F3`
jump straight to the Fleet, Work and Session panes from any focus; the
focused widget has a bright-blue thick-line border and `↑`/`↓`/`PgUp`/`PgDn` scroll only it. `g`
refreshes both panes, and `q`, `Esc` or `Ctrl-C` quits.

**What it may do is whether it holds the checkout's lease, not a property of the program.** The
window that holds it operates the fleet: it hosts sessions, starts them on their triggers, ends a
pass, runs the sweeps and prunes worktrees. A second window open on the same checkout draws all of
that and acts on none of it, and says so in its header. Building it needs Rust and Cargo (see Prerequisites); the first
run in a fresh checkout compiles the workspace, so give it a minute before deciding it has hung.

## Launchers

Each agent is started by a script of its own, run from the consumer repository root:

```bash
.cerebro/cerebro/scripts/launch <Name>            # any agent, by name - the one way to start one
.cerebro/cerebro/scripts/roster                   # the fleet: name, role, kind - one line per agent
.cerebro/cerebro/scripts/roster --implementers    # the producer names, one per line
.cerebro/cerebro/scripts/cerebro-tui              # the fleet view (needs cargo)
```

Every agent starts the same way, by its own name: `launch Xavier`, `launch Cyclops`, `launch Forge`.
There are no per-role launcher scripts - the roster is the one place the fleet is declared, and
`launch` is the one place a session is started. A session started this way runs in that terminal,
outside the fleet view; `.cerebro/cerebro/scripts/launch-preflight ux Xavier; echo $?` printing
`0` and nothing else says one could start.

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

`scripts/prune-worktrees.sh` is the worktree sweep, run by Cerebro every two hours and by you whenever
you like (`--dry-run` first).

To take a newer cerebro: `git submodule update --remote --merge .cerebro/cerebro`, then start
something — every launch re-syncs the links.

## What the fleet cost

A Copilot session prints its AI-credit cost as it ends — `Session: 264.44 AIC used` — and is then
gone, and the number with it. `scripts/fleet-cost` asks afterwards, and answers per **bead and
agent** rather than only per session:

```bash
.cerebro/cerebro/scripts/fleet-cost --by-bead --since 7d      # what each agent cost on each bead
.cerebro/cerebro/scripts/fleet-cost --by-bead --phase         # the same, split by phase as well
.cerebro/cerebro/scripts/fleet-cost --by-agent --since 30d    # what each agent spent
.cerebro/cerebro/scripts/fleet-cost --bead cb-d89             # one bead, split by agent and phase
```

```
AGENT      SESSIONS  BEADS   ON BEAD   NO BEAD       AIC  UNPRICED
Cyclops           8      7    4892.7     432.3    5325.1         1
Xavier           10      7    2019.4     557.7    2577.2        18
Cerebro           6      0       0.0    1686.5    1686.5        14

40 sessions, 11730.6 AIC in all.
```

`--since` takes a span (`90m`, `24h`, `7d`; the default is `7d`) or an ISO-8601 UTC timestamp.
`--agent <Name>` narrows `--by-bead`, and `--json` gives the same answer for a script. A window with
nothing in it is exit 0 and a sentence — nothing ran is an answer. `SHARE` is share **of that
bead** — each bead's rows sum to 100%, so the column answers who spent this bead's money.

**Nothing is captured while a session runs**, and no writer is added to any path: both halves of the
join are already on disk. `~/.copilot/session-store.db` has the per-request cost; turn 0 of every
session carries the marker sentence naming the agent and the root; and `.cerebro/state/transitions.jsonl`
says which bead that agent held at the time. Each request is attributed to whichever bead was
current when it was made, so a session that worked on none, one or several is reported honestly.

Two columns are worth understanding before you trust a total:

- **`no bead`** is about a third of the fleet's spend, and is not a rounding error. An orchestrator
  holds no bead by design, and every pass spends before it claims anything. It gets a row of its own
  rather than being tidied away, which is what makes the rows add up to the true total.
- **`UNPRICED`** counts requests the store records no cost for — a couple of per cent, and every
  request on some models. They are excluded from the sums, and the count is **per row**, so an
  agent whose whole contribution to a bead was unpriced reads `0.0` beside a number there rather
  than looking free.

It needs `sqlite3` and `jq` on `PATH`, and a project running on Copilot — cost is recorded per
machine, and a Claude-only fleet is told so and gets nothing rather than a
misleading zero. It refuses out loud, on stderr with nothing on stdout, whenever it cannot answer:
a number that means "the query broke" is worse than no number. If the window reaches further back
than either record goes, it says on stderr what it could actually see, and stdout stays parseable.

The companion is `scripts/fleet-history`, which turns the same transition log into durations — how
long a bead was held, how long anyone waited at `asking`. Both are covered at greater depth in
[docs/agent-workflow.md](docs/agent-workflow.md).

## Skills

`produce-bead` is the producer procedure; `beads-workflow` is the shared substrate roles read.

## Sync Script (Skills and Agents)

You do not normally run this by hand: every launcher runs it before starting a session, so a bumped
agent or skill is linked the first time something is started (ah-cuc).

What it does:

- Asks `scripts/consumer-root` for the consumer repository root (the enclosing working tree) and exits with an error if this checkout is not mounted at `<consumer>/.cerebro/cerebro`.
- Creates `../../.claude/skills/` and `../../.claude/agents/` if they do not exist.
- Scans `.cerebro/cerebro/skills/*` for folders that contain `SKILL.md`.
- Creates/updates symlinks in `.claude/skills/` (for example `.claude/skills/produce-bead -> ../../.cerebro/cerebro/skills/produce-bead`), relative rather than absolute, so the same link is correct in the main checkout, in every worktree and on every machine.
- Scans `.cerebro/cerebro/agents/*.md` and creates/updates symlinks in `.claude/agents/`.
- Removes the old aggregate symlink `.claude/skills/cerebro` if present.
- Removes a `.dir-locals.el` link at the consumer root left by a sync from before the fleet view had its own command; a `.dir-locals.el` the project wrote itself is never touched.

Run it whenever:

- You add or remove skills or agents in this repository.
- You update the submodule to a newer commit.

### Optional: Run Sync Automatically On Submodule Pointer Changes

This repository ships git hooks in `githooks/` that run the sync script automatically after merge/pull and checkout when the `.cerebro/cerebro` gitlink changes.

Enable once per clone, from anywhere inside the consumer repository:

```bash
.cerebro/cerebro/githooks/install.sh
```

What it configures:

- `core.hooksPath=.cerebro/cerebro/githooks`
- `post-merge` hook: syncs when `.cerebro/cerebro` changed between `ORIG_HEAD` and `HEAD`.
- `post-checkout` hook: syncs when `.cerebro/cerebro` changed between old and new refs, and only on a branch checkout.

Both hooks are silent when the gitlink did not move.

**`core.hooksPath` is repository-wide**: it replaces `.git/hooks` rather than adding to it, so any hooks
already there stop running. The installer refuses to overwrite a `core.hooksPath` that points somewhere
else, and warns if `.git/hooks` holds non-sample hooks — in either case, merge them by hand instead.
`githooks/` is optional and refused where `core.hooksPath` is already taken (whenever another tool —
beads, husky, lefthook — already owns it) — that is fine, since every launcher syncs the links itself before starting a session
regardless of whether the hooks are installed.

The script uses fixed locations relative to itself and does not support source/destination override variables.
