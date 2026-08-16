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

## Starting a planner — there are two of them

**Xavier and Beast both hold the planner role** (`scripts/roster --role planner`). One planner keeps
about two implementers fed; a wider fleet outruns a single planning session, which is what the second
one is for. Run one or both — nothing breaks with only Xavier up, the buffer simply refills at half
the rate, and Cerebro will say so on its sweep.

What they divide, and how:

- **Candidates**, by the `planning` label. A planner takes the label before it researches anything
  and pushes it at once, so the other sees the bead as spoken for. There is no lease and nothing to
  reclaim: if a planning session dies, the label is all it leaves, and any planner can pick that bead
  up next pass.
- **Abandoned labels**, at the top of every pass. The `planning` label is not a claim and has no
  lease, so nothing reclaims it: a planning session that is killed mid-bead leaves its candidate
  labelled, and a labelled bead is excluded from every candidate query — lost rather than pending.
  Each planner now frees, on every pass and every wake-up, any `planning` label that no live planner
  names in its own state file, and says which it freed. Three beads sat stranded for a day before
  this existed. You can see them yourself in the fleet view: **Being planned** with both planner rows
  idle is the shape of it.
- **The buffer**, by counting `planned` beads only — what an idle implementer could actually claim.
  Both planners may therefore fill at the same time, which is what a second planner is *for*; the
  overshoot is at most one bead each. Counting `planning` too was tried and starved the queue: two
  held candidates were enough to make a small fleet's target look met, and both planners slept over
  a queue of two.
- **The triage pass belongs to Xavier alone** — the first planner on the roster. It is the one part
  of the role that is not divisible, because what a session remembers asking lives in its own context
  and nowhere on the bead: two triaging planners means being walked through the same P4 backlog
  twice. Beast says so in a line when it starts and goes straight to the buffer.

**Two planners is two sessions asking you questions.** That is the cost, and it is the thing to watch
before adding the second: if Xavier's row spends most of its time on `asking` rather than `working`,
the queue is bounded by your answers, and a second planner adds a second row waiting on you rather
than more plans. If he is mostly `working`, the second one buys you throughput directly.

One session, in its own terminal:

```
claude --model opus         # the skill will tell you if it is on something else
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

The fleet view's State column names the **phase** an implementer is actually in — `build`, `gate`
(the fast local checks — lint, typecheck, unit, cargo fmt/clippy; no machine-wide lock any more),
`review`, `ci`, `rebase` (catching a `BEHIND` branch up on GitHub, or resolving a real conflict
locally), `merge` — rather than one undifferentiated `working` for however long the bead takes. The
Bead/Phase column shows both timers side by side, time on the bead and time in the current phase, so
three implementers all sitting in `review` says Copilot is slow and one stuck in `ci` for an hour
says something is stuck.

**This is not implementer-only any more.** Since `ah-2n3.2` the interactive agents write the
same state file and show the same way: a planner's row says `triage` or `plan`, Psylocke's says
`prepare` or `verify`, Moira's and Cerebro's say `sweep` (Cerebro's also `release`), Forge's says
`daily` or `weekly` — and any one of them can show `?`, bold, when it is the one waiting on you
rather than an implementer. Answer it the same way. A session started by hand outside the fleet view
still shows `up` with no phase, since it has never written a file.

**Two or three is a sensible number on one machine.** More is not faster: every merge makes every
other open PR stale, so each of them pays for a `BEHIND` catch-up and a fresh CI run — and CI is
where the browser suites actually run now, in parallel jobs implementers no longer serialize behind
locally. The orchestrator will say so if you ask for more, once, and then do as it is told.

### What "take one down" means

It means *finish*, not *stop now* — for a builder mid-bead. The orchestrator writes a stop flag; for
one that has claimed something it is read when the implementer reports itself done — bead merged,
closed, worktree gone — and no fresh session starts in its place. So a builder that has just claimed
something will be a while yet. That is deliberate: killing one mid-bead leaves a claimed bead, a
worktree and an open PR for you to unpick by hand. An **idle** builder — between beads, nothing
claimed — is the one exception: it stops at once, since there is nothing in flight to finish, so
there is nothing to strand by ending it now.

The implementer never reads the flag itself, and cannot end itself either. It says it is done; the
supervisor decides whether a replacement starts.

If you genuinely want one gone this second, say so and the orchestrator will stop it — and then you
have that cleanup to do.

Changed your mind before it noticed? Deleting the flag cancels the instruction:

```bash
rm .cerebro/state/<name>.stop
```

— or just press `s`; a stale flag is cleared on start.

### What the builders learned

An implementer that hit something unexpected writes it up before it merges, as
`docs/retrospectives/<bead id>.md`, riding in on that bead's own PR. Only surprises go in — a bead
that went to plan leaves no file — so everything in that directory cost somebody time:

```bash
ls docs/retrospectives/ 2>/dev/null || echo "nothing recorded yet"
```

Each file says what happened, why if the agent established it, what it cost, and the specific change
that would prevent it. Agents record; they do not act on these — changing the rules, the skills or
CI is yours. Read the *Seen before* line: a finding on its third bead is one the fleet keeps paying
for.

They are committed, so they survive the machine and the session that wrote them. That is why they
live under `docs/` rather than beside the state files in `.cerebro/state/`, which is gitignored
as live state.

### Leftover worktrees

Builders work in `.cerebro/worktrees/<bead>` and remove the tree when they finish. One that crashes,
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

## Starting a verifier

Every step so far — plan, build, review, merge — is an agent judging its own work. Nothing checks
that the merged result actually does what it was supposed to, until **Psylocke**:

```bash
.claude/cerebro/scripts/run-psylocke
```

One interactive session, like the planner and the orchestrator, and for the same reason: she has to
put a running application in front of you and wait for your verdict, which a `--print` session cannot
do. She walks beads closed since her last pass, works out on her own which ones touched anything a
player could see — a change to `.claude/`, `docs/`, or CI is marked and skipped without ever bothering
you — and for the rest, prepares everything she can before she asks for your time: what the bead
claimed, which shell to launch (web or desktop), which fixture report to load, and what you should
look for.

**She only ever asks when she is ready to hand you something to run.** Say yes and she briefs you,
launches the app and waits for one of three verdicts:

- **Passed.** The bead is marked verified and that is the end of it.
- **Passed, with a follow-up.** It works; something small about it is worth a look later. She files
  that as an ordinary new bead — unranked, for the planner to triage with you next time round — and
  still marks the original passed.
- **Failed.** She reopens the bead **at P0**, records what you saw, and asks one more thing: was the
  *plan* wrong, or was the *build* wrong? A build failure goes straight back to the implementers as
  ordinary rework against the same design. A plan failure goes to the planner first, who reads what
  you saw and revises the existing design rather than starting from nothing.

If you are not free when she asks, the bead simply waits — nothing is blocked, and she offers it again
next pass rather than escalating it to your queue.

**A bead she cannot verify does not block anything.** An unverified bead never stops a release; when
the orchestrator cuts one, it names whatever has not yet had a person look at it and leaves the
decision to you. Verification is information, not a gate.

**What it costs**: a verification is a few minutes of your time per bead, on top of whatever it took
you to build one in the first place — starting the app, loading the report she names, and telling her
what you saw. It runs on a ten-minute cycle like the other passive sessions, so it will sit quietly
between beads rather than pestering you.

She verifies in her own worktree, `.cerebro/worktrees/psylocke`, reset to `origin/main` immediately
before every use — never the shared checkout, and never a build started before she fetched. She tells
you the sha she is about to build before she ever asks you to look at anything, and if a port she
needs is already serving something, she refuses to reuse it rather than risk verifying against a
build that is not the one that merged. When a verification is later found to have judged the wrong
build, she writes a retrospective of her own, the same way an implementer does.

## Starting the architect

Nobody else in the fleet reads the *shape* of the code. A planner plans one bead, an implementer builds
one bead, Copilot reviews that one diff, Psylocke checks that one merged bead does what it claimed —
and across fifty merges nobody asks whether the codebase got harder to change along the way.
**Forge** is that reader:

```bash
.claude/cerebro/scripts/run-forge
```

Unlike every other interactive session here, Forge does **one sweep and stops** — it works out for
itself whether this is a daily sweep (what merged since its last one) or a weekly one (the whole
codebase), reads accordingly, and then ends its own turn once it has reported. There is no loop to
end and no flag to set: when it says the sweep is finished, end the session with `k` in the fleet
view, same as any other agent you are done with.

Start it whenever you want a read — each morning is a reasonable habit, or any time you want to know
whether recent work left something worth revisiting. It costs you nothing until triage: what it finds
becomes an ordinary `Refactoring:`-titled bead at P4, unranked, for the planners to bring to you like
anything else in the backlog. Forge never fixes anything itself, and it only files a finding that
names a cost already being paid today — a defect fixed twice in the same place, a change that had to
touch several files, a retrospective that names a structural reason something cost time — never a bare
principle or a "could be cleaner."

Its watermark (the last commit it read, and the date of its last weekly sweep) lives in bd memory
rather than in the checkout, so it survives a lost or replaced machine: `bd recall bishop-watermark`
shows you where it last left off, and losing a checkout loses nothing.

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

The one thing not to do is work in `.cerebro/worktrees/` yourself — those belong to running agents,
and checking out a branch there moves an agent off its own work.

## What it costs

Honest numbers from building this repository's own harness:

- **A bead is an hour or more**, most of it CI. The code is usually the short part.
- **Expect a `BEHIND` branch on nearly every merge.** With several agents, a PR that sat through one
  review round has usually been overtaken, and the rules require catching it up (on GitHub, not
  locally — see *Starting builders* above) plus a fresh CI cycle before it can merge. That is
  deliberate: a green run on a stale tree is evidence about a tree that will never exist.
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
git worktree remove --force .cerebro/worktrees/<bead>
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
