# Running the agent workflow

Work on this repository is split between two kinds of agent session. This is the human's guide to
running them: what to start, what you will be asked, where to look when something wants you, and
what it costs.

The agents' own instructions live in `.claude/skills/plan-bead/`, `.claude/skills/implement-bead/`
and `.claude/skills/beads-workflow/`. You do not need to read those to operate this.

## The idea

A **planner** turns rough beads into plans. A **builder** builds them. They are separate sessions
because they need different things from you: planning needs your judgement on anything a player will
see, and building needs nothing at all if the plan is good.

The handover is one label. A bead is *planned* or it is not.

```
  unplanned  ──►  planner claims  ──►  planned  ──►  builder claims  ──►  merged, closed
                        │                                   │
                        └──────── needs you ◄───────────────┘
```

## Starting a planner

One session, in its own terminal:

```
claude --model fable        # or opus; the skill will tell you if it is on something else
/plan-bead
```

It takes the next unplanned bead that is not blocked, researches it, and writes a plan into the
bead. Then the next one, and the next.

**It will interrupt you**, and this is the part worth your attention. Anything a player sees —
layout, wording, what a control is called, what happens on a click — is yours to decide, not the
agent's. It will propose, usually with a self-contained HTML mockup you can open in a browser, and
wait for you to choose. Architecture, file layout, test shape and ordering it decides by itself.

If you walk away mid-question, it parks that bead and moves to one with no user-facing surface, so
the queue keeps filling. It will not guess on your behalf.

## Starting builders

**You** start builders — one session each, from the Emacs fleet view (`s`) or a terminal. What runs
alongside them is an **orchestrator**: one interactive session, in its own terminal, that watches the
fleet, reports on it, and stops builders for you. It cannot start one, because starting one means
starting a session and it has no way to do that.

```
claude --agent orchestrator --name Cerebro --permission-mode auto
```

The orchestrator is always called **Cerebro** — it finds the mutants and points them at the work.

It starts nothing on its own, and it cannot start an implementer for you at all — starting one means
starting a session, which only you can do: press `s` on that name in the Emacs fleet view, or run
`.claude/cerebro/scripts/run-implementer <name>` in a terminal. Cerebro sweeps away any worktrees left behind by a
previous run, greets you, tells you what the queue looks like, and waits. Then you talk to it in
whatever words you like:

```
how are they doing?
what is waiting on me?
take Storm down
```

There is no flag that puts a running implementer to work, and there used to be. **A running
implementer is a working one**: it claims the next planned bead as soon as it comes up. If you want
another builder, start another session.

Implementers are named after X-Men — Cyclops, Storm, Wolverine, Rogue, and on down the roster — so
that a fleet of them can be talked about without anyone counting session hashes.

Each implementer takes a planned bead, creates its own git worktree, works through the plan
test-first, opens a PR, answers the Copilot review, waits for CI, merges and cleans up. Then it
reports itself `done` and **that session ends**: a fresh one starts in its place for the next bead.
They run on Sonnet, each with its own context, and the fleet keeps replacing them until told to
stop.

The replacement is the point. One bead fills a session with a plan, a diff, a review and three CI
runs, and nothing can clear that from the inside — so instead of clearing it, the session is thrown
away and a clean one takes the next bead.

They are interactive sessions, so you can watch one work and type to it. If it hits a question only
you can answer it will ask, and show as `asking` in the fleet view. Answer it and it carries on. If
you are away, it is told to give up after fifteen minutes and hands the bead to your queue instead —
so a fleet left alone overnight drains the queue rather than sitting blocked on you.

**Two or three is a sensible number on one machine.** More is not faster: the browser test suites
take a machine-wide lock and run one at a time, and every merge makes every other open PR stale, so
each of them pays for a rebase and a fresh CI run. The orchestrator will say so if you ask for more,
once, and then do as it is told.

### What "take one down" means

It means *finish*, not *stop now*. The orchestrator writes a stop flag; it is read at the one moment
the implementer reports itself done — bead merged, closed, worktree gone — and no fresh session
starts in its place. So a builder that has just claimed something will be a while yet. That is
deliberate: killing one mid-bead leaves a claimed bead, a worktree and an open PR for you to unpick
by hand.

The implementer never reads the flag itself, and cannot end itself either. It says it is done; the
supervisor decides whether a replacement starts.

If you genuinely want one gone this second, say so and the orchestrator will stop it — and then you
have that cleanup to do.

Changed your mind before it noticed? Deleting the flag cancels the instruction:

```bash
rm .claude/implementers/<name>.stop
```

### What the builders learned

An implementer that hit something unexpected writes it up before it merges, as
`docs/retrospectives/<bead id>.md`, riding in on that bead's own PR. Only surprises go in — a bead
that went to plan leaves no file — so everything in that directory cost somebody time:

```bash
ls docs/retrospectives/
```

Each file says what happened, why if the agent established it, what it cost, and the specific change
that would prevent it. Agents record; they do not act on these — changing the rules, the skills or
CI is yours. Read the *Seen before* line: a finding on its third bead is one the fleet keeps paying
for.

They are committed, so they survive the machine and the session that wrote them. That is why they
live under `docs/` rather than beside the state files in `.claude/implementers/`, which is gitignored
as live state.

### Leftover worktrees

Builders work in `.claude/worktrees/<bead>` and remove the tree when they finish. One that crashes,
or whose bead somebody else merged, leaves it behind — and a stray tree holding `main` makes the next
agent's `git checkout main` fail for no visible reason.

Cerebro sweeps them: once when it starts, then every ten minutes. You can run the same sweep yourself
at any time:

```bash
.claude/cerebro/scripts/prune-worktrees.sh --dry-run   # say what would go
.claude/cerebro/scripts/prune-worktrees.sh             # actually go
```

It only removes a worktree when **nothing can be lost from it**: the tree is clean, the work is
already on main, and nothing has touched it for half an hour. Anything else it keeps and tells you
why. Note that it asks GitHub whether the branch's PR merged, rather than looking for its commits on
main — with `--squash` merges the commits are never there, so the naive check would keep every
worktree for ever.

### When a builder gets slow or vague

An implementer's context grows with every bead it finishes, and nothing can clear it from the inside.
It is told to re-read plans rather than recall them, and to tell you when it starts to feel the
weight. When it does — or when its reports get woolly — take it down and start a fresh one. That is
the cure, and it is why the fleet is yours to manage rather than automatic.

## Your queue

Everything waiting on you, from every agent and every terminal, in one place:

```bash
bd human list
```

Beads arrive there for four reasons: a plan turned out to be wrong in a way the builder must not
decide; a plan was missing something; the Copilot review never came; or CI stayed red after three
attempts. The bead says which in its notes.

To put one back into circulation after you have answered:

```bash
bd update <id> --add-label planned --remove-label human    # back to the builders
bd update <id> --remove-label human                        # back to the planner
```

## Watching without interfering

```bash
bd ready --label planned      # what builders can pick up
bd list --status in_progress  # who is on what
bd human list                 # waiting on you
gh pr list                    # what is in flight
git worktree list             # which agent is in which directory
```

The one thing not to do is work in `.claude/worktrees/` yourself — those belong to running agents,
and checking out a branch there moves an agent off its own work.

## What it costs

Honest numbers from building this repository's own harness:

- **A bead is an hour or more**, most of it CI. The code is usually the short part.
- **Expect a rebase on nearly every merge.** With several agents, a PR that sat through one review
  round has usually been overtaken, and the rules require a rebase plus a fresh CI cycle before it
  can merge. That is deliberate: a green run on a stale tree is evidence about a tree that will never
  exist.
- **Copilot reviews about four PRs in five**, sometimes minutes late, and never marks one approved.
  When it does not review, the builder leaves the PR open and tells you rather than merging.
- **One review per bead**, requested when the PR opens and never again. Fixes and rebases move the
  head past what the reviewer read, and that is accepted rather than chased: what a review is owed is
  an answer to every comment, not a re-read of the answers. So the review you see on a merged PR
  describes the PR as it opened, which is worth knowing when you read one later.
- **Nothing merges unreviewed and nothing merges red.** The `main` ruleset enforces the second on the
  server; the first is the agents following the rule.

## When something goes wrong

**An agent died and its bead is stuck.** A crashed session leaves its bead claimed and invisible.
After about fifteen minutes of silence:

```bash
bd reclaim --id <bead> --older-than 10m
git worktree remove --force .claude/worktrees/<bead>
git worktree prune
```

Only ever by `--id`. Without it, that command reaps every stale claim on the machine, including from
an agent that is merely busy.

**Two agents want the same ports.** Each builder picks a block of three (4173, 4183, 4193, …) and
checks it is free first. A collision fails loudly rather than testing the wrong bundle, but it stalls
both — give them different blocks.

**The disk fills.** The Rust build tree is shared by every worktree and still grows:

```bash
pnpm exec tsx scripts/diskPreflight.ts     # what is free, and whether it is enough
rm -rf target/debug/incremental            # the cheap few gigabytes back
```

**A bead keeps coming back to you.** That usually means the plan is wrong rather than the builder is:
send it to the planner (`--remove-label human`, leave `planned` off) rather than to another builder.

## What agents never decide

- Anything a player sees. That is the whole reason the planner talks to you.
- Whether to take a bead off another agent, beyond the narrow crashed-agent case above.
- Anything outside a planned bead — a change to these rules, to the workflow, or to CI.
- Whether to merge something red, stale, or unreviewed.
