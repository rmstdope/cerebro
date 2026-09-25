---
name: beads-workflow
description: How planned work is tracked in this repository with beads (bd) — picking up work, writing a good bead, modelling dependencies, branch/commit conventions, and the GitHub bug-report bridge. Use whenever work is selected, created, updated, or closed.
---

# Beads workflow

Planned work lives in **beads** (`bd`); GitHub issues are the inbox for external requests and bug
reports only.

Bead IDs look like `<prefix>-t65`. Partial IDs work: `bd show t65` finds the whole id.

## Daily loop

```bash
bd dolt pull                   # other machines' claims arrive only here
bd show <id> --json            # scope, acceptance criteria, validation, the plan in `design`
# the fleet view has already claimed it for you (scripts/assign-bead)
bd heartbeat <id>              # at every phase gate, and before any long wait
# build in the worktree the fleet view prepared, and merge, by produce-bead
bd close <id> --reason "Delivered in PR #NN"
# then close the parent if that was its last open child - see "Dependencies and breakdown"
bd dolt push                   # back the bead database up to the remote
```

The fleet view gives each producer its bead through `scripts/assign-bead`, which claims it as
that agent before the session starts, choosing from:

```bash
.cerebro/cerebro/scripts/assignable-beads            # what a builder may be given
```

It offers only a ranked bead (P0 to P3) carrying `ux:agreed` or `ux:none`, and excludes `human`
(already waiting on the navigator), `epic` (a split parent, with children rather than a plan),
`verdict:stale` and `second-look` (the verifier's), and `bugfix` (the bugfixer's own queue,
`scripts/bugfix-candidates`, with the same rules).

**`bugfix` is a routing label, not decoration.** A bead carrying it is worked by the `bugfixer`
role directly and does not go through UX or the producer queue.

**Only the producer claims, and the fleet view does it on its behalf.** No other role runs
`bd update --claim`, `bd ready --claim` or `bd unclaim` — not the UX agent, user feedback, the
orchestrator, or a session the navigator drives by hand. Any other claim looks like a build in
flight, hides a ready bead and strands a lease when that session ends. Creating, reading, ranking,
labelling, commenting and planning all work unclaimed; if you want to stop another session touching
a bead, you want a label.

**The UX agent does not use `bd ready`**, which hides beads whose dependencies are unbuilt — often
the ones most worth designing first. The fleet view picks its bead from `scripts/stage-candidates`
and makes it the assignee without a claim; the UX agent clears the assignee when done.
`agree-experience` has the commands.

`bd blocked` shows what is waiting and on what. `bd list` shows everything.

## The lifecycle a bead moves through

Routing is fixed: no agent chooses who is next. Each role leaves a **label** (or a `bd set-state`
verification state) and the fleet view's candidate scripts read those labels to decide which role
is started and given the bead. The one table below is the whole route; every role reads it, and a
role that touches a label not in it is changing the pipeline for every consumer.

```
  filed (P4) ──► ranked ──► ux:agreed ──► claimed ──► closed ──► verification=passed
      │                        ▲             │                          │
   bugfix ─────────────────────┼──────► Bishop (bugfixer)               │
                               │                                        │
                    human / needs-ui-decision ◄──── parked ◄── reopened at P0 (failed)
```

| A bead that is… | looks like | is put there by | is taken by |
|---|---|---|---|
| **unranked** | open, priority 4 | whoever filed it: `write-bead` (Cerebro), Moira, Forge, Psylocke's follow-up | Cerebro ranks it with the navigator (`--priority`); no other role touches a P4 bead |
| **asked about, not ranked** | P4, `triage:declined` | Cerebro, when the navigator was away | nobody, until the navigator removes the label or Cerebro ranks it |
| **a bug** | `bugfix` (set at filing, never removed) | `write-bead` or Moira | Bishop, through `scripts/bugfix-candidates`; UX and producers never see it |
| **waiting for UX** | ranked, neither `ux:agreed` nor `ux:none`, unassigned | ranking | a `ux` agent, through `scripts/stage-candidates ux`; the fleet view assigns without claiming |
| **invisible by declaration** | `ux:none` | the navigator's *no* to "does it touch anything a person sees or presses?", asked by whoever files or first understands the bead: `write-bead`, Moira's triage, Cerebro's understand step; Forge on every refactoring. Never on a `bugfix` bead, whose route skips UX anyway | a producer, exactly as a UX-agreed bead. Removed only on the way back to UX: `producer-park … ux`, Cerebro's *Send it back to UX*, or `reopen-failed --fault plan`; a *yes* is recorded in the description as `A person sees this: yes`, so nobody asks again |
| **being designed** | open, assigned to a `ux` agent, not `in_progress` | `scripts/assign-bead` | that agent only; it clears the assignee when its pass ends, or the fleet view does when the session dies |
| **UX-agreed** | `ux:agreed`, unassigned | the `ux` agent (`agree-experience`) | a producer, through `scripts/assignable-beads`, claimed for it by the fleet view. An unclaimed bead that already has a `design` (with or without `planned`: every park removes the label, a crash does not) is a producer's returned plan and is resumed from that design |
| **being produced** | `in_progress`, assignee is the producer | `scripts/assign-bead` | that producer only. It writes `design`, adds `planned` while keeping its claim, builds, merges, closes |
| **waiting on the navigator** | open, unassigned, `human`, `planned` removed | any role escalating; `scripts/producer-park … scope` (`human` alone, never `needs-ui-decision`); a `ux` agent parking | nobody: `bd human list` and the fleet view's *Waiting on you*. Every candidate script excludes `human`. The fleet view's automatic unpause (blockers all closed) removes `human` alone; the navigator, or Cerebro's unpark, removes `human` and `pause:kept`; neither touches `needs-ui-decision` |
| **sent back to UX** | `needs-ui-decision`, no stage label, no `human`, a `## Sent back to the UX stage` note; `verification:failed` may still be on it | `scripts/producer-park … ux`, or Cerebro's *Send it back to UX* | a `ux` agent, as an ordinary UX candidate (`stage-candidates ux` admits a failed bead on the `needs-ui-decision`); it amends the record and re-adds `ux:agreed` |
| **parked on a UI question** | `needs-ui-decision` **and** `human`, no `ux:agreed` | a `ux` agent when nobody answered, or a second return of the same question | as *waiting on the navigator*; the unpark leaves `needs-ui-decision` on, which tells the next `ux` agent to resume from the notes, and that agent removes it when it records |
| **asked about and left parked** | as above, plus `pause:kept` | Cerebro alone | Cerebro alone; it stops the sweep asking twice |
| **merged, unverified** | closed, no `verification` state | the producer's `bd close` | Psylocke, through `scripts/work-beads`, a child of an epic included; the family is swept for the whole once every child is closed |
| **not worth a look** | `verification=not-needed` | Psylocke, from `scripts/app-paths --classify` | nobody; terminal |
| **verified** | `verification=passed`, `verified_at=<sha>` | Psylocke (`verifier-pass-epic-family` for a family) | nobody, unless main moves past it |
| **failed, and main moved on** | `verdict:stale` | the navigator's `x` on a verdict-sweep finding (`scripts/sweep-verdicts.sh` finds; the fleet view writes) | Psylocke re-verifies and removes it; every other candidate script excludes it |
| **failed, build at fault** | reopened, P0, `verification:failed`, `planned` kept | `scripts/reopen-failed --fault build` | a producer, as ordinary rework against the same design |
| **failed, plan at fault** | reopened, P0, `verification:failed`, `plan:revise`; `planned`, `ux:agreed` and `ux:none` removed | `scripts/reopen-failed --fault plan` | a `ux` agent, as an ordinary UX candidate; it amends the agreed experience in place, re-adds `ux:agreed` and removes `plan:revise` |
| **handed back, nothing to build** | `second-look`, `verification:failed`, no `planned`, no `human` | a producer's no-`human` hand-back (`produce-bead`, *Handing back*), and nothing else | Psylocke, through `scripts/second-look-beads`; every builder and UX queue excludes the label, and her verdict removes it |
| **a refactoring** | `refactoring`, title `Refactoring: …` | Forge | ranked and routed like any other bead; the label is Forge's own index |
| **an epic with children** | type `epic`, at least one child, each child carrying the parent's `external_ref`, and `bugfix` when the parent is a bug | `write-bead` filing a family; Cerebro splitting at ranking, which retypes the parent to `epic` first | nobody: `scripts/work-beads` skips it while it has a child. Whoever closes the last child closes it. A childless epic is retyped to `task` at ranking, since the builder queues exclude the epic type |

Three rules that the table depends on:

- **Only `assign-bead` claims, and only for a producer or bugfixer.** An assignee on an open bead
  means a `ux` agent holds it; `in_progress` means a builder does.
- **`human` is the one queue the navigator reads.** A bead parked for any reason carries it, or it
  waits for ever unseen. `needs-ui-decision` alone is not a queue.
- **P4 stops everything.** No candidate script ever offers an unranked bead, so a bead nobody ranks
  is a bead nobody works.

The plan lives in the bead's `design` field (`bd update <id> --design-file plan.md`). Read it with
`bd show <id> --json`: the pretty renderer mangles Markdown tables.

**Escalating takes three commands:**

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<what stopped it>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd unclaim <id>          # clears the assignee and returns the status to open
bd dolt push             # or no other machine learns it was released
```

- `paused_at` lets the fleet view's *Waiting on you* section show the pause as a duration; without
  it the bead reads as parked just now, for ever.
- The note is re-read by the orchestrator on every sweep to judge whether the pause still holds, so
  write what would **unblock** it — the question, the answer that settles it — not only what stopped you.
- Removing `planned` records that the producer must revisit its own build design before resuming.
- `bd unclaim` matters because `bd update` sets no status: without it the bead stays `in_progress`
  under an agent that has left.

**Exception (written in full in `produce-bead`, *Handing back*):** a bead carrying
`verification:failed`, handed back because nothing is left to implement, runs all three commands
but adds **no `human`** and no `paused_at`, and adds **`second-look`** instead: the one label that
says the verifier holds it, which `scripts/second-look-beads` matches and every builder and UX
queue excludes. Only the verifier ever adds `plan:revise`, and only her verdict removes
`second-look`.

**A UX agent escalating has no claim**, so it runs the first and third commands with
`--assignee ""` in place of the second — never `bd unclaim`.

`pause:kept` is the orchestrator's alone: *this pause was put to the user and they left it parked*,
so the next sweep does not ask again. It never suppresses unparking a bead whose blockers have all
closed, and needs no plumbing because such a bead always carries `human`. It goes when the
orchestrator unparks the bead or the user removes it to be asked again.

A bead parked on a UI answer carries **both** `needs-ui-decision` and `human`, because
`bd human list` lists only `human` — the user's one queue. The orchestrator's exception: when the
user sends a parked bead back to a UX agent to interview live, `human` comes off and
`needs-ui-decision` stays, telling that agent which question it holds.

## Claiming, and not colliding

**The claim is made before the session starts.** `scripts/assign-bead` claims the bead as the
producer or bugfixer and pushes, then the launcher hands the id over in the prompt; a session never
claims for itself, and a bead not `in_progress` for the named session is not its to work.

**Heartbeat while you work.** A claim's lease is about five minutes and only `bd heartbeat <id>`
renews it. Send one at every phase gate and before anything long (a full smoke run, a CI watch);
it writes no Dolt commit, so it costs nothing.

**Never take a bead off another agent.** `in_progress` with an assignee is authoritative;
`bd update --force` or reassigning over a live claim needs the navigator. The one exception is a
crashed producer's bead:

```bash
bd reclaim --id <bead> --older-than 10m        # one named bead, never a sweep
```

- **`--id`, always** — without it `bd reclaim` reaps every stale lease this replica granted,
  including an agent that merely missed a heartbeat.
- **`--older-than` counts from lease expiry**, so `10m` is about fifteen minutes of silence.
- **Only on the machine that granted the claim**; `bd reclaim` skips leases granted elsewhere.

Anything wider — no `--id`, a shorter window, a live claim — is the navigator's call. The fleet
view removes a dead agent's tree when nothing in it can be lost, and keeps it for a person otherwise.

**Every board write is pushed at once.** Leases never leave the machine that granted them; status
and assignee travel only on `bd dolt push`/`bd dolt pull`, which is why `assign-bead` pushes the
claim before the session exists.

**Check your working directory before any `git` command.** A shell's directory persists, so one
`cd` into another agent's worktree leaves later commands — a `git checkout -b` included — there.
Run `pwd && git branch --show-current` first, or use `git -C /path/to/repo`.

If `main` is checked out in another git worktree, `git checkout main` fails; use
`git checkout -b <branch> origin/main` instead.

## Branch, commit and PR conventions

- Branch: `<bead-id>-short-description`, e.g. `<bead-id>-render-the-summary-panel`
- Commit subject: `feat(<bead-id>): render the summary panel` (`fix(...)`, `docs(...)`, `chore(...)`)
- PR title: the same subject. PR body names the bead, and the originating GitHub issue if one exists.
- One bead per branch. Merge it before starting the next bead - except a bead escalated to the
  navigator, whose PR stays open by design, since the point is that it must not merge as it stands.

## Writing a good bead

A bead is executable when someone else could pick it up cold:

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

**The title stands on its own** — it is read in `bd list`, triage and release notes without the
description. Name the effect, not the area; a bug's symptom, not its suspected cause; no internal
module names; no *fix*, *improve*, *update* or *handle*. "Roads do not shrink with the map when
zooming out" needs nothing else. The UX agent restates a title that falls short in the product's
words (see `agree-experience`, *Opening the session*).

**Every bead is created at P4**, however urgent it looks: `-p 4` is explicit because bd defaults to
P2. The one exception is a child of a split parent — see "Dependencies and breakdown".

P4 means **unranked**. The orchestrator walks P4 beads with the navigator and applies the priority
they choose (see `agents/orchestrator.md`, *Ranking the backlog*); ranking is the navigator's call.
Argue priority in the description — why it matters, what it holds up — not in the number. A
priority agreed with the navigator stays: `bd update <id> --priority=<n>` only after they say so.

Do not restate a dependency in the description — model it, so `bd ready` stays truthful.

## Dependencies and breakdown

```bash
bd dep add <blocked-bead> <blocker-bead>            # blocked-bead is blocked by blocker-bead
bd dep add <a> <b> --type relates-to                # related, but not blocking
bd create "Sub-task title" --parent <bead-id> -p <parent's priority>  # hierarchical child
```

**A child takes its parent's priority, and keeps it.** bd does not copy it, so pass it explicitly;
a P4 parent means P4 children, ranked as one family. The navigator is asked about the parent only,
and the orchestrator puts a drifted child back to its parent's priority on every triage.

When a bead is larger than one increment, split it into children wired with `bd dep add`; do not
grow the parent.

**Whoever closes the last child closes the parent**, walking up one level at a time:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'        # closed children are included by default
bd close <parent> --reason "All children closed; last was <id>"
bd dolt push                                            # the parent's close travels like any other
```

An empty first line means no parent, and the walk stops. The `if type=="array"` guard is there
because `bd show --json` returns an array, and the wrong shape fails with
`Cannot index array with string "parent"` — which reads like no parent and silently stops the walk.

Every child `closed` is the whole test. Do not use `bd epic close-eligible`: it sweeps every
eligible epic, including families you never touched.

## GitHub bug-report bridge

```bash
GITHUB_TOKEN=$(gh auth token) bd github pull <issue-number>   # import as a bead, keeps gh-<n> ref
GITHUB_TOKEN=$(gh auth token) bd github status                # verify configuration
```

For a bead that will be worked on, prefer a rewritten scope with a back-reference over
`bd github pull`:

```bash
bd create "Title" --type bug --external-ref gh-<n> -p 4 --body-file body.md
```

P4 however urgent the report reads; put the reporter's urgency in the description. `bd github pull`
sets its own priority, so correct an imported bead to P4 unless the navigator has ranked it. Then
comment on the issue naming the bead and close it. The sync is pull-only and manual.

## Storage, and what is committed

- The Dolt database under `.beads/` is local, git-ignored and the source of truth.
- Bead state travels only by `bd dolt push` / `bd dolt pull` to the Dolt remote, never by git: never
  commit an export of the database on a branch.
- `.beads/config.yaml` and `.beads/hooks/` are committed (`core.hooksPath` points at the hooks).
- Where a project's own root `CLAUDE.md` *Work tracking* says otherwise, follow it.

Never commit a GitHub token to `.beads/config.yaml` — pass it as `GITHUB_TOKEN` per command.

## Traps

**`bd config set` accepts unknown keys silently**, printing `Set <key> = <value>` and changing
nothing — confirm the effect. It also rewrites `.beads/config.yaml`, so read that diff before
committing.

**A stale lease, outside the narrow reclaim above, means "nobody heartbeated", not "abandoned"** —
ask the navigator.

```
◐ bd-xde · Remove the deprecated theme    [P2 · IN_PROGRESS]
Lease: expires in 1 min (heartbeat 3 mins ago)      # an agent actively working, ten minutes in
```

`claim.ttl` is not a lever: it answers "not set", exactly as an invented key does. Heartbeat instead.

**`owner` comes from `git config user.email`** at creation and has no override: `--actor` sets
`created_by` only, and `--assignee` is a separate field.

## Checklist before ending a session

- [ ] Bead claimed or closed to match reality
- [ ] Nothing left `in_progress` that you are not actually working on — `bd unclaim <id>` releases it
- [ ] `bd dolt push`
