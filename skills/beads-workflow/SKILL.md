---
name: beads-workflow
description: How planned work is tracked in this repository with beads (bd) — picking up work, writing a good bead, modelling dependencies, branch/commit conventions, and the GitHub bug-report bridge. Use whenever work is selected, created, updated, or closed.
---

# Beads workflow

Planned work lives in **beads** (`bd`), not in GitHub issues. GitHub issues are the inbox for
external requests and bug reports only.

Bead IDs look like `<prefix>-t65` — the project's prefix and a short suffix. Partial IDs work:
`bd show t65` finds the whole id.

## Daily loop

```bash
bd dolt pull                   # other machines' claims arrive only here
bd ready                       # what can be worked on now (no open blockers)
bd show <id> --json            # scope, acceptance criteria, validation, the plan in `design`
bd update <id> --claim         # before any code is read — see "Claiming" below
bd dolt push                   # publish the claim now, not at session end
git fetch origin main          # bd dolt pull moves beads, not git refs
git checkout -b <id>-short-description origin/main
# ... test-driven-development skill: RED → GREEN → REFACTOR → COMMIT ...
# ... bd heartbeat <id> at every phase gate, and before any long wait ...
gh pr create ...               # then the review round: the Four Eye Principle in the consumer's root CLAUDE.md
gh pr merge <n> --squash --delete-branch    # only once reviewed at head, green, and not behind
bd close <id> --reason "Delivered in PR #NN"
# ... then close the parent if that was its last open child - see "Dependencies and breakdown" ...
bd dolt push                   # back the bead database up to the remote
```

Two ways to pick work, and they are different mechanisms rather than two spellings of one. Reading
`bd ready` and then claiming by id is the one to use when a human or an agent is *choosing* — it
allows `bd show` first. `bd ready --claim` takes the **first** match itself, which is what the agent
roles below want, since they take whatever is next rather than choosing:

```bash
bd ready --label planned --exclude-label human --exclude-type epic --claim --json          # builder
```

`human` is already waiting on the navigator, and re-claiming it just re-asks a question nobody is
there to answer. `epic` is a split parent: it has children rather than a plan.

**Claiming belongs to the implementer, and to nobody else.** A claim says *this is being built
right now*, which is why it takes the bead off `bd ready` and holds a lease that has to be
heartbeated. No other role runs `bd update --claim`, `bd ready --claim` or `bd unclaim` — not the
planner, not user feedback, not the orchestrator, not a session the navigator is driving by hand.
A claim from any of them is indistinguishable from a build in flight: it hides a ready bead from the
fleet, and when that session ends it strands a lease nobody can account for.

**The planner does not use `bd ready` either.** It may plan a bead whose dependencies are still
unbuilt — often those are the ones most worth having planned — and `bd ready` hides exactly those. It
picks from `bd list ... --sort priority`, and marks its candidate with a **`planning:<its own
name>`** label rather than claiming it: enough to keep a second planning session off the same bead,
while leaving it
`open`, unassigned and free of any lease. `plan-bead` carries the commands.

The claim is atomic, and a failure means somebody else won the race: take the next bead rather than
retrying.

`bd blocked` shows what is waiting and on what. `bd list` shows everything.

## The lifecycle a bead moves through

Work is split between a **planning** session, which turns an unplanned bead into a specified one and
owns every decision the user can see, and one or more **implementation** sessions, which build what
the plan says. One label carries the handover, and `bd ready --claim` is an atomic compare-and-swap,
so neither role can double-book a bead. Only the implementation session ever claims: the planner
holds nothing but a label.

| State | How it looks | Who moves it, and how |
|---|---|---|
| unplanned | open, no `planned` | — |
| being planned | open, `planning:<planner>`, unassigned | planner: add the label, then plan it |
| planned | open, `planned`, unassigned | planner: write the plan, swap its own `planning:` for `planned` |
| being implemented | in_progress, implementer holds the lease | the builder pickup above |
| needs the user | open, unassigned, `human`, **`planned` removed** | either role, on anything it must not decide |
| parked on a UI answer | open, unassigned, `needs-ui-decision` **and** `human` | planner, when the user is away |

A **split family is owned by one planner**, marked `planner:<name>` on the parent rather than on any
child: the children share one design, so a second planner taking one of them writes half a family
that disagrees with the other half. It is not a hold and not a claim — it says who plans this family,
survives that planner restarting between beads, and is ignored once the name leaves the roster.

A hold is read as **the word `planning`, or the word and a `:` and the holder's name** — never as a
bare prefix, so an unrelated label that merely starts with those letters is not mistaken for somebody
holding the bead, and `planner:` is not caught by it either.

The plan lives in the bead's `design` field (`bd update <id> --design-file plan.md`). Read it with
`bd show <id> --json`: the pretty renderer reflows Markdown and mangles tables.

**Escalating takes three commands, and all of them matter:**

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<what stopped it>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd unclaim <id>          # clears the assignee and returns the status to open
bd dolt push             # or no other machine learns it was released
```


`--set-metadata paused_at=…` is what makes the pause visible as a *duration*: the fleet view's
*Waiting on you* section reads it and says how long the bead has been sitting there, and a bead
parked without it reads as parked just now, for ever (cb-wfb).

Removing `planned` stops `bd ready --label planned` handing the bead straight back to the next
implementer, which would hit the same wall and escalate again. `bd unclaim` is the half that is easy
to forget and worse to skip: `bd update` sets no status, so without it the bead stays `in_progress`
assigned to an agent that has walked away — invisible to `bd ready`, and stranded until its lease
runs out. That is the exact condition the reclaim rule below exists to repair, manufactured
deliberately every time an implementer escalates.

**One exception, and `implement-bead` is where it is written in full:** a bead already carrying
`verification:failed`, handed back because there is nothing left to implement, is **closed** rather
than escalated — a closed bead still carrying `verification:failed` is what the verifier's work list
is built from, and left open it reaches no role at all. Nothing here ever adds `plan:revise`; only
the verifier sets that.

**A planner escalating has no claim to release**, so it runs the first and third commands and
`--remove-label planning:<its own name>` in place of the second. `bd unclaim` on a bead you never claimed is not
harmless bookkeeping — it is a claim you should not have had in the first place.

A bead parked on a UI answer carries **both** `needs-ui-decision` and `human`, for the same reason:
`bd human list` lists the `human` label and nothing else, so a bead with only the first sits in
nobody's queue at all. With both, `bd human list` is the user's one queue across every agent and
every terminal.

## Claiming, and not colliding

Several agents work this backlog at once, so a claim is the only thing keeping two of them off the
same bead. The second rule below is the one that is easy to forget and expensive to skip.

**If you are implementing: claim before you explore, not before you branch.** Claiming — by id when
you chose the bead, or as part of `bd ready --claim` when you are taking whatever is next — comes
ahead of reading code or asking the navigator anything. Reading the bead itself with `bd show` is not
exploring: it is how you decide whether to take it, and it costs seconds. Everything after that waits
for the claim, because until it lands the bead is still on every other agent's `bd ready`. The claim
is atomic, so a failure means somebody else won the race: pick another bead rather than retrying.

**If you are not implementing, do not claim, and do not need to.** Creating, reading, ranking,
labelling, commenting and planning all work on an unclaimed bead. If you find yourself wanting a
claim to stop another session touching your bead, you want a label.

**Heartbeat while you work.** A claim carries a lease of about five minutes, and only
`bd heartbeat <id>` pushes it forward. A cycle here — RED, GREEN, REFACTOR, the local gate, CI —
runs an hour or more, so a claim that is never heartbeated is stale for almost all of the work it
covers. Send one at every phase gate and before anything long (a full smoke run, a CI watch).
Heartbeats write no Dolt commit and no history, so the cadence costs nothing.

**Never take a bead off another agent by yourself**, with one exception. `in_progress` with an
assignee is authoritative; `bd update --force` and reassigning over a live claim need the
navigator's approval. The exception exists only because agents now heartbeat: a crashed implementer
leaves its bead in_progress forever, invisible to `bd ready`, so

```bash
bd reclaim --id <bead> --older-than 10m        # one named bead, never a sweep
git worktree remove --force .cerebro/worktrees/<bead>
git worktree prune                             # separately: it must run even if the remove failed
```

**`--id`, always.** Without it `bd reclaim` reaps every stale lease this replica granted, so an agent
that merely missed a heartbeat during a long CI watch is robbed alongside the genuinely dead one.

**`--older-than` counts from lease expiry, not from the last heartbeat.** With a five-minute lease,
`10m` fires after about fifteen minutes of silence — a real death when every phase gate renews the
lease. That safety rests on agents heartbeating, which is an instruction and not something the tool
enforces.

**Only on the machine the claim was made.** A lease is enforceable only on the node that granted it,
and `bd reclaim` skips leases granted elsewhere. A crashed agent on another machine is the
navigator's to sort out.

The removal is not decoration, and `--force` is not either: `worktree remove` refuses a tree holding
untracked files, and `git worktree prune` only clears entries whose directory has already gone. Skip
either and the dead agent's branch and build artifacts stay behind.

They are separate lines rather than chained with `&&` on purpose. `worktree remove` fails whenever
the path is already gone or is not a worktree it recognises — exactly the half-cleaned states worth
pruning — and chaining would skip the prune in precisely those cases.

Anything wider — a sweep with no `--id`, a shorter window, a live claim — is the navigator's call.
See the Traps section for why this rule used to be absolute.

**Push the claim immediately.** Leases never leave the machine that granted them; only status and
assignee commit, and they travel only on `bd dolt push`/`bd dolt pull`. A claim that is not pushed is
invisible to an agent on another machine for as long as you hold it.

**Check your working directory before any `git` command.** The other agents are in
`.cerebro/worktrees/*`, and a shell's directory persists between commands — one `cd` into a worktree
to check something leaves every later command there. Branching from that shell checks a branch out
inside somebody else's live worktree, which is a collision the bead graph cannot prevent. This has
happened: a `cd .cerebro/worktrees/task` to see whether worktrees share the database was followed,
several commands later, by a `git checkout -b` that moved that agent off its own branch. Run
`pwd && git branch --show-current` before branching, or give `git -C /path/to/repo` the path
outright.

If `main` is checked out in another git worktree, `git checkout main` fails; use
`git checkout -b <branch> origin/main` instead.

## Branch, commit and PR conventions

- Branch: `<bead-id>-short-description`, e.g. `<bead-id>-render-the-summary-panel`
- Commit subject: `feat(<bead-id>): render the summary panel` (`fix(...)`, `docs(...)`, `chore(...)`)
- PR title: the same subject. PR body names the bead, and the originating GitHub issue if one exists.
- One bead per branch. Merge it before starting the next bead - except a bead escalated to the
  navigator, whose PR stays open by design, since the point is that it must not merge as it stands.

## Writing a good bead

A bead is executable when someone else could pick it up cold. Carry the same five things the
implementation plan asks of every work package:

| What | Where it goes |
|---|---|
| Summary and problem | `--description` (markdown; use `--body-file` for anything long) |
| Scope and out of scope | `--description` |
| Acceptance criteria | `--acceptance` |
| Validation (commands, manual checks) | `--description` |
| Inputs it depends on | dependency edges, not prose — see below |

```bash
bd create "Load several files at once" --type feature -p 4 --body-file scope.md \
  --acceptance "Selecting several files imports them in the order their headers give"
```

Types used here: `feature`, `bug`, `task`, `epic`.

**The title has to stand on its own.** It is what everyone sees in `bd list`, in a triage question
and in the release notes, usually without the description. So name the effect rather than the area,
say a bug's symptom rather than its suspected cause, keep internal module names out of it, and avoid
verbs that carry no information — *fix*, *improve*, *update*, *handle*. "Roads do not shrink with the
map when zooming out" needs nothing else; "One gate at a time, machine-wide" is from this backlog too.
The planner rewrites titles that do not meet this as part of planning (see `plan-bead`), so a title
here is a starting point rather than a last word — but a good one saves a triage question.

**Every bead is created at P4**, whoever creates it and however urgent it looks. `-p 4` is explicit
because bd's own default is P2, and a bead that arrives at P2 has been given a rank by whoever
happened to file it. The one exception is a child of a split parent, which takes the parent's
priority — see "Dependencies and breakdown" below.

P4 is not "unimportant" here — it is **unranked**, the floor a bead waits on until it is prioritised
deliberately. That prioritisation is a step of its own: Cerebro walks the P4 beads with the
navigator, recommends a priority for each from what the bead says, and applies what the navigator
chooses (see `agents/orchestrator.md`, *Ranking the backlog*). Ranking is the navigator's call, and a bead filed at P1 by its author has
taken that call from them.

So set the priority you think it deserves nowhere but in the bead's text — say in the description why
it matters and what it is holding up. That is the argument the ranking is made from, and it survives
being read weeks later, which a number does not.

A priority already agreed with the navigator is theirs and stays: `bd update <id> --priority=<n>`
after they have said so, never before.

Do not restate a dependency in the description — model it, so `bd ready` stays truthful.

## Dependencies and breakdown

```bash
bd dep add <blocked-bead> <blocker-bead>            # blocked-bead is blocked by blocker-bead
bd dep add <a> <b> --type relates-to                # related, but not blocking
bd create "Sub-task title" --parent <bead-id> -p <parent's priority>  # hierarchical child
```

**A child carries its parent's priority, and keeps it.** It is the one bead that is not created at P4,
because a split parent has usually been ranked already and an epic is one piece of work built in
several passes — ranked once, as a family. bd does not copy the priority for you, so pass it
explicitly; if the parent is itself still P4 the children are P4 with it, and the whole family is
ranked in one question at the next triage.

The navigator is asked about the parent only. A child whose priority has drifted out of step with its
parent — higher or lower — is put back to the parent's: Cerebro reconciles the tree on every
triage pass, and a child that outranks its own parent jumps the queue ahead of work the navigator put
first.

Beads has real parent links and dependency edges, so the old `Sub-issue (NN):` title prefix is gone.
When a bead turns out to be larger than one increment, split it into children and wire the order with
`bd dep add`; do not grow the parent.

**Whoever closes the last child closes the parent.** A parent is nothing but its children, and
nothing closes it on its own — two epics sat open here at 2/2 children closed. So every `bd close`
is followed by a walk upwards, one level at a time until there is no parent left:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'        # closed children are included by default
bd close <parent> --reason "All children closed; last was <id>"
bd dolt push                                            # the parent's close travels like any other
```

An empty first line means there is no parent above and the walk stops. The `if type=="array"` guard
is the same one `plan-bead` documents: `bd show --json` returns an array, and indexing the wrong
shape fails with `Cannot index array with string "parent"` — which reads like a bead with no parent
rather than a broken command, and would quietly stop every walk.

Every child `closed` is the whole test, and it is not `bd epic close-eligible`: that sweeps every
eligible epic in the database, including families this session never touched, in the same way
`bd reclaim` without `--id` reaps leases that were never yours. Walk up from your own bead.

## GitHub bug-report bridge

```bash
GITHUB_TOKEN=$(gh auth token) bd github pull <issue-number>   # import as a bead, keeps gh-<n> ref
GITHUB_TOKEN=$(gh auth token) bd github status                # verify configuration
```

`bd github pull` generates a long legacy-style ID. When the bead is going to be worked on rather than
just recorded, prefer creating it with a rewritten scope and a back-reference:

```bash
bd create "Title" --type bug --external-ref gh-<n> -p 4 --body-file body.md
```

P4 here too, however urgent the report reads. A reporter's sense of urgency is evidence for the
ranking, not the ranking itself — put it in the description and let the navigator weigh it.

`bd github pull` sets its own priority from the issue, so a bead imported that way is worth checking
and correcting to P4 unless the navigator has already ranked it.

Then comment on the GitHub issue naming the bead and close it. Nothing is pushed from beads to
GitHub automatically; the sync is pull-only and manual.

## Storage, and what is committed

- `.beads/embeddeddolt/` — the Dolt database. Local, git-ignored, the source of truth.
- `.beads/issues.jsonl` — a readable export, **committed**, so the backlog is browsable in the repo.
  It is a snapshot taken when somebody happens to push main, not a mirror, and it lags — often by
  several beads. That is deliberate: see the export gate below for why no branch may carry it, and
  `bd dolt push` for where bead state actually travels. Refresh it by hand from main
  (`bd export -o .beads/issues.jsonl`) when a readable diff is wanted; never read it as truth.
- `.beads/config.yaml`, `.beads/hooks/` — committed configuration and the git hook shims
  (`core.hooksPath` points at them).
- The Dolt remote is the repo's own GitHub origin, under `refs/dolt/data`. `bd dolt push` backs it
  up; `bd dolt pull` retrieves it on another machine.

Never commit a GitHub token to `.beads/config.yaml` — pass it as `GITHUB_TOKEN` per command.

## The export gate

`scripts/beadsExportGate.ts` runs from `.beads/hooks/pre-push`, below the `BEADS INTEGRATION`
markers where `bd hooks install` leaves it alone. **On main only**: it exports the database and
compares the result with the committed `.beads/issues.jsonl`. Equal, and the push goes through
silently. Different, and it commits the fresh export alone as
`chore(beads): refresh the issues export` and stops the push:

```
beads: .beads/issues.jsonl was out of date and has been committed as "chore(beads): refresh the issues export".
beads: nothing was pushed - run the push again to send it along.
```

Push again and it goes. A pre-push hook cannot amend the commits being pushed, so the refresh is a
commit of its own — nothing is rewritten and `--force` is never needed. Expect this on main, once,
after beads changed.

**A feature branch never carries the export**, and this is the point rather than an optimisation.
The file is a snapshot of the whole database — which every agent on this machine shares — not of the
branch holding it. Two branches pushed minutes apart each carried a complete backlog from a
different instant, so whichever merged last reverted every close, claim, label and plan recorded in
between; because each side had rewritten a different subset of the one-line-per-bead file, git
usually did not even call it a conflict. Bead state travels by `bd dolt push`, not by the export.

The gate stands aside rather than blocking a push when it cannot do its job: no `bd` on `PATH`, no
`.beads` directory, no installed `node_modules`, a detached HEAD, or a `bd export` that fails.

## Traps

**The auto-export was stale, which is why it is off.** Auto-export is throttled to once a minute,
and the pre-commit hook was seen writing a snapshot that still held a bead deleted minutes earlier.
`export.auto` is `false` here and the refresh happens at push time instead — see the export gate
above. If you ever export by hand, check what actually landed rather than trusting the
acknowledgement:

```bash
git show HEAD:.beads/issues.jsonl | wc -l      # against `bd list` — the counts must agree
```

**`bd config set` accepts unknown keys silently.** A mistyped or invented key prints
`Set <key> = <value>` and does nothing, so config probing reads as success while changing nothing.
Confirm the effect, not the acknowledgement. Writing config also rewrites `.beads/config.yaml` — it
has rewritten a commented-out default and dropped the file's trailing newline — so read the diff
before committing it.

**A stale lease used to mean nothing at all, and now means a little.** `bd update --force` describes itself as
being for "abandoned claims — crashed agent, expired lease", and `bd reclaim` is built to clear the
assignee of any in_progress bead whose lease expired and set it back to open. Both are written for a
deployment where workers heartbeat; nothing in this repository did until recently, so every live
claim matched the description of a dead one. This is what had agents starting on each other's work.

Heartbeating is what changed it. Now that every phase gate renews a five-minute lease, silence
means something again — which is why the one narrow reclaim above is allowed, and why it is worded
as narrowly as it is. Outside that window, still read a stale lease as "nobody heartbeated" and ask
the navigator.

```
◐ bd-xde · Remove the deprecated theme    [P2 · IN_PROGRESS]
Lease: expires in 1 min (heartbeat 3 mins ago)      # an agent actively working, ten minutes in
```

`claim.ttl` is not part of the documented config surface — `bd config get claim.ttl` answers "not
set", and per the trap below that is also what an invented key answers — so lengthening the TTL is
not a lever. Heartbeat instead.

**`owner` comes from `git config user.email`** at creation time and has no override.  `--actor`
sets `created_by` only, `--assignee` is a separate field, and no config key changes it. The
committed export therefore carries the repo's committer address; that is the same identity every
commit already carries here, so it is expected rather than a leak.

## Checklist before ending a session

- [ ] Bead claimed or closed to match reality
- [ ] Nothing left `in_progress` that you are not actually working on — `bd unclaim <id>` releases it
- [ ] `bd dolt push`

The JSONL export is not on this list on purpose — the export gate takes it at push time.
