---
name: implement-bead
description: The implementation role — take one planned bead, build it under TDD, get it reviewed and merged, and finish. Use when running an implementation session.
---

# Implementing a planned bead

You take a bead somebody else planned, build exactly what the plan says, see it onto main, and
**finish**. One bead, then you are done. Several of you may run at once.

You do not loop, and you do not end yourself either. You are an interactive session, so your process
outlives your turn — which is what lets the navigator talk to you, and what means you cannot simply
stop. When the bead is closed you write `waiting` to your state file and say what you did; the fleet
view ends you half a minute later and starts a fresh session under your name when there is another
planned bead.
Everything you learned building this one goes with you, which is the point: a new session starts
with a clean context instead of five beads of residue.

Read `beads-workflow` for the label lifecycle and the consumer's root `CLAUDE.md` — its Four Eye
Principle — for the review
rules; this is the role on top of them.

## Standing approval, and where it comes from

The `test-driven-development` skill stops at every phase for the navigator, and says a merge is
never covered by a blanket approval. This role is the documented exception, and the authority is
**the consumer's root `CLAUDE.md` and its Four Eye Principle**, which the navigator wrote for
exactly this: for a planned bead,
a review sub-agent you spawn for yourself is the second pair of eyes, and an implementation session
merges on the
conditions stated there. Where the two disagree, the consumer's root `CLAUDE.md` governs — it is
the project's own document, not cerebro's, and `templates/consumer-CLAUDE.md` is where a project
without one starts.

So: RED → GREEN → REFACTOR → COMMIT without stopping, announcing each transition, and still stopping
on a genuine design question — see *When the plan is wrong*. Everything outside a planned bead
follows the TDD skill's gates as written.

## Waiting, without ending your run

A bead has one long wait in it — CI — and how you wait is the difference
between finishing a bead and abandoning one. An implementer once armed a `Monitor` against a
review, said "I'll wait now for the monitor's event", and ended its turn. The review landed two
minutes later: two comments unanswered, the bead claimed, the PR open, and nothing to wake it.

**Wait by blocking inside a tool call. Never by ending your turn.**

```bash
until <the condition>; do bd heartbeat <id>; sleep 30; done
```

Three things about that line, each of which has cost something here:

- **The heartbeat is inside the loop, not around it.** A lease is about five minutes and a CI run is
  ten, so a heartbeat before and after leaves the middle uncovered and the claim reads as abandoned.
- **It must print as it goes.** The harness kills a run whose stream has stalled for 600 seconds,
  and it has done so here. A silent loop is indistinguishable from a hang.
- **Keep each call well under ten minutes.** A `Bash` call times out — 600000ms at the most,
  120000ms by default — so pass an explicit `timeout` and, for a longer wait, call again. A
  twenty-minute CI wait is three calls, not one.

`Monitor` and `Bash` with `run_in_background` both promise to re-invoke you later. Do not rely on
either here. Your process survives the end of a turn now, so this is no longer the guaranteed
disaster it was when it ran under `--print` — but nothing wakes you. A turn ended against a review
sits until the navigator happens to look and type something, with the bead claimed, the PR open and
the lease going stale the whole time. Block, and stay in the run.

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how you are seen and how you are replaced. Rewrite
it at every transition, in the same `Bash` call as the thing it describes — through
`scripts/agent-state`, never by hand:

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID
```

`idle` before you claim, `working` the moment you do, `asking` if you put a question to the
navigator, `waiting` when the bead is closed and the worktree gone — or when there was nothing to
claim. `working` and `asking` also take
`--phase <build|gate|review|ci|rebase|merge>`, naming what the wait or the work actually is — see the
table below for where each is written. `--pid` is `$PPID` — your own `claude` process — and must be
captured in the call that writes the file; a stale number shows you as dead while you are working,
and the navigator will start a second implementer over the top of you. The script keeps `since`
across a phase-only change and stamps `phase_since` on a phase change — do not write the file by
hand.

| Where in this skill | Call |
|---|---|
| *Picking up*, nothing to claim | `.claude/cerebro/scripts/end-pass <name> --pid $PPID` |
| *Picking up*, right after `bd ready … --claim` | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID` |
| *Building*, before the fast gate | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID` |
| *The review*, before spawning the review sub-agent | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID` |
| *The review*, once every finding is answered | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID` |
| *Red CI* | stays `ci` |
| *Merging*, on `BEHIND`: catch up on GitHub → CI | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID`, then `... --phase ci ...` |
| *The retrospective* opening line onward | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID` — merge covers retro, merge, close, cleanup |
| *Asking instead of handing back* | `.claude/cerebro/scripts/agent-state <name> asking --bead <id> --phase <current> --pid $PPID`; on resuming, `working` with the same bead and phase |
| *Finishing*, after `bd close` and worktree removal, and the hand-back block | `.claude/cerebro/scripts/end-pass <name> --pid $PPID` |

`waiting` is a request to be ended, granted within about half a minute. Run `end-pass` last. There
is no wake to ask for: the view starts an implementer on a planned bead, not on a clock.

## Finishing means finishing

There is no next bead to take, and no flag for **you** to check. The `.stop` flag still means what
`orchestrator.md` says it means — the fleet view reads it when you report `waiting`, and decides
whether a fresh session starts in your place. That is not your business, and you must not read it:
an implementer that saw a stop flag mid-bead and wound up early would strand exactly what the
between-beads rule exists to protect.

So: **do the retrospective below before you merge**, and when the bead is merged, closed and cleaned
up, write `waiting`, say what you did, and stop producing output. **Never write `waiting` before that point.** A
bead abandoned in flight strands a claim, a worktree and an open PR for somebody to unpick by hand,
which is exactly what one-bead-per-session is arranged to avoid.

The one exception is a bead you hand back — a missing plan section, a question only the navigator
can answer. That is a complete run too: hand it back with the block below, clean up, write `waiting`,
and finish.

## The retrospective

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID
```

Write it once, entering this section — `merge` covers the retrospective, the merge itself, closing
the bead and cleaning up, so no more phase writes are needed until `waiting`.

**When the review is answered and CI is green, before you merge**, look back over the run and ask
one question: *did anything happen that I did not expect?*

This is not optional. You are the only one who saw the run, your context is about to be thrown away
by design, and whatever cost you an hour will cost the next session an hour too unless it is
written down.

**Why before the merge, when the run is not quite over.** It is a tracked file, and nothing reaches
main here unreviewed or un-green — so it travels in the bead's own PR, and once that PR is merged
there is no branch left to put it on. The last stretch of the run is the merge itself, which is the
one part a retrospective written here cannot cover; if something goes wrong there, the next session
will hit it too and record it then.

### What is worth recording

Something that **would need attention so it does not happen again**. Concretely: a step that failed
for a reason the plan or these instructions did not prepare you for; a check that passed locally and
failed in CI; a tool that behaved differently from how it is documented here; a rule you found
yourself unable to follow as written; time lost to something that reads as avoidable in hindsight.

**Not** worth recording, and actively harmful if you do: the bead going normally, a test failing
during RED, a review comment you answered, anything already written in these instructions. A
directory with a file per bead is one nobody reads, and then a real finding sits in it unseen.

If nothing qualifies — which is the common case for a bead that went to plan — **write no file at
all** and say so in your closing message: *"retrospective: nothing to record."* That is a complete
retrospective, and it is how the navigator can tell you did one. A directory that only ever gains a
file when something went wrong is one worth opening.

### Where it goes

`docs/retrospectives/<bead id>.md` — the bead's own id as the file name, and nothing else.

**One retrospective per file, and one file per bead.** Never append to another bead's file and never
rewrite one: they are the record of runs that are over. If your bead produced two findings, both go
in your own file, as two sections of the one retrospective.

It lives under `docs/` rather than beside your state file because it is knowledge rather than live
state — `.cerebro/state/` is gitignored, so a retrospective there would never leave the
machine that wrote it.

**Committing it costs a CI cycle, and that is the intended trade.** Adding the file moves the head
past the green run:

```bash
mkdir -p docs/retrospectives          # the first finding in a fresh checkout creates it
git add docs/retrospectives/<bead id>.md
git commit -m "docs(<bead id>): retrospective — <the one-line symptom>"
git push
# then wait for CI again, per *Waiting, without ending your run*, and merge on green
```

You do **not** obtain another review: one review per bead, obtained before the merge and never
again, and a docs commit after it is exactly the kind of head movement that rule already
accepts. This is also why the bar is high — most runs add nothing and merge straight away, so the
cycle is paid only when something was genuinely learned.

### The format

**Create `docs/retrospectives/README.md` with this exact content if it does not exist**, so the
format is documented where the files are rather than only here. `mkdir -p docs/retrospectives`
first: yours may be the first finding this checkout has ever had, and `>` into a directory that is
not there fails.

```markdown
# Retrospectives

One file per bead, `<bead id>.md`, written by the implementer that built it — but only when
something went unexpectedly. A bead that went to plan leaves no file, so everything in here is
something that cost somebody time.

Each file is one retrospective and is never edited afterwards: it is the record of a run that is
over. A later bead that hits the same thing writes its own file and names this one under
**Seen before**, which is how a recurring problem becomes visible as a count rather than a feeling.

## Format

    # <bead id> — retrospective

    - **Implementer:** <name>
    - **Date:** <YYYY-MM-DD>
    - **PR:** #<n>

    ## <one line: the symptom, not the cause>

    **What happened.** What you observed, concretely, with the command or step that produced it.
    **Why.** The cause if you established one; "not established" if you did not. Do not guess.
    **Cost.** What it took: wall-clock, CI cycles, a bead handed back, a rebase.
    **Prevent by.** The specific change that would stop it — a file and section, a step to add, a
    check to run earlier. "Be careful" is not a prevention.
    **Seen before.** Other bead ids whose file describes the same thing, or "none found".

Two findings in one run are two `##` sections in that bead's one file.
```

### Writing it

**Grep the directory before you write**, so *Seen before* is real rather than decorative — a
finding on its third sighting is the strongest evidence the fleet produces that something needs
fixing rather than tolerating:

```bash
grep -rl "<a word from your symptom>" docs/retrospectives/ 2>/dev/null || echo "nothing like it yet"
```

A complete example:

```markdown
# <bead-id> — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-14
- **PR:** #231

## The browser suite passed locally and failed in CI

**What happened.** The project's browser suite was green on this machine three times. The same commit failed
twice in CI on `smoke (web, 2, 2)`, both times on a timeout in the map-drag spec.
**Why.** Not established. The CI runner is slower and the spec waits on a fixed 500ms, but I did not
prove that is the cause.
**Cost.** Two CI cycles and a rebase, about 50 minutes.
**Prevent by.** The plan's *Validation* section should name which suite covers a map interaction, so
it is run in CI-like conditions before the PR opens rather than after.
**Seen before.** <an earlier bead id> — same spec, same job.
```

Two rules for the writing itself. **Be specific enough to act on**: name the file, the command, the
job, the section. A future reader has none of your context and cannot ask you. And **do not fix it
here** — recording is your job; changing the rules, the skill or CI is outside a planned bead and
belongs to the navigator, who reads these precisely so they can decide.

### Asking instead of handing back

You are interactive, so the navigator can answer you. For a question that genuinely blocks the bead
you may ask rather than hand back — write `asking` to your state file first, with the bead still in
`bead` and the current phase passed again, then ask plainly and wait.

Nobody waits for ever. You do not enforce the timeout and cannot see it: if it expires, a line
starting `[cerebro]` arrives in your session telling you to give up. Treat it as the navigator
speaking — stop waiting, hand the bead back exactly as below, and finish.

Prefer handing back outright when the answer plainly needs somebody awake, or when the bead can wait
for the planner rather than the navigator. Asking is the faster path only when somebody is there.

## Picking up

**This is your first turn's work.** Nothing gates it: a running implementer is a working one, and
there is no flag to wait for. (There was a `.go` flag once; it is gone.)

If the queue is empty, **end the pass** — do not poll. Write `waiting`, say "queue empty, ending
the pass" in one line, and stop producing output. The fleet view ends this session and starts a
fresh one under your name the moment a planned bead exists; a session that sits polling is a session
the view cannot tell from one that has hung.

```bash
.claude/cerebro/scripts/end-pass <name> --pid $PPID
```

```bash
bd dolt pull
bd ready --label planned --exclude-label human --exclude-label verdict:stale \
        --exclude-type epic --claim --json
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID
bd dolt push                               # so other machines see the claim
```

One bead. `--claim` takes the first ready one; take that and no other.

`human` is work already waiting on the navigator; `epic` is a split parent, which has children
rather than a plan. Claiming either means refusing it a minute later.

`verdict:stale` is the third, and it is the one that looks most like ordinary work: an open,
`planned`, P0 bead exactly like a reopened one, except that the fleet view has found main has moved
past the commit its verdict was formed against. **Building against a stale verdict is the no-op this
label exists to prevent**: on the day this was filed, one such bead asked for something a sibling
had already shipped two merges later, and another for wording a bead in flight was already carrying
when the verdict was written. The bead is waiting for Psylocke to look again, not for you; she either clears the label,
and it comes back to this queue unchanged, or she records a fresh verdict against current main, and
then it is worth building.

`bd heartbeat <id>` at every phase gate and before anything long — a full gate run, a CI watch. The
lease is short, about five minutes, and a cycle is an hour; the exact TTL is bd's and not
configurable here, so heartbeat on every boundary rather than on a timer.

Nothing planned means the planner has not got there yet, or another implementer took the last one
first — the view may have started you for a bead a peer claimed a moment ago. End the pass as
*Picking up* describes; the view brings you back when there is one.

**Read the plan with `bd show <id> --json`.** The pretty renderer mangles it.

**Refuse a plan missing a mandatory section** — context, files and reuse, increments with their
tests, test plan, user-facing decisions, out of scope, validation, traps:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<the section that is missing>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd unclaim <id>
bd dolt push
```


`--set-metadata paused_at=…` is what makes the pause visible as a *duration*: the fleet view's
*Waiting on you* section reads it and says how long the bead has been sitting there, and a bead
parked without it reads as parked just now, for ever (cb-wfb).

All three, and this is the **hand-back block** referred to throughout.

**One variation, and it is about where the bead goes next.** A bead carrying `verification:failed`
that you are handing back because there is **nothing left to implement** — you read the failure
notes and the surface the navigator asked for is already there, or another bead carries it — drops
the `human`:

```bash
bd update <id> --remove-label planned --append-notes "<why there is nothing to build>"
bd unclaim <id>
bd dolt push
```

`verification:failed` on an **open** bead, with neither `planned` nor `plan:revise`, is what puts it
on Psylocke's second-look list (`scripts/second-look-beads`) — her ordinary work list is built from
closed beads and would never show it. So a failed verification with nothing left to build wants that
second look, not the navigator's queue; adding `human` parks it in front of a person who has nothing
to decide. It has happened, and the bead had to be moved back by hand. (That list once matched
`verdict:stale` only, and a bead handed back this way reached no role at all for eleven hours —
which is why the query now lives in a script with a test under it rather than in prose.)

**Never add `plan:revise` in either case.** Whether the plan was wrong is the navigator's answer to
Psylocke's question, asked at the verdict, and it is not an implementer's to assert — the label is
hers alone to set, and it is what sends the bead to a planner. After it, remove the worktree
if one exists (see *Finishing*) and run `.claude/cerebro/scripts/end-pass <name> --pid $PPID`
last, exactly as a merged bead does — a hand-back is a complete run too.
`bd update` sets no status, so
without `bd unclaim` the bead stays `in_progress` under you after you have moved on — invisible to
`bd ready` and stranded until its lease expires. Without the push, no other machine learns it was
released. If a worktree exists by then, remove it too (see *Finishing*).

### A reopened bead

You can pick one of these up exactly like any other planned bead — it is open, `planned` and P0, and
`bd ready` does not tell you it has a history. Recognise it from `bd show <id> --json`: a
`verification:failed` label, notes beginning "Verification failed", and a closed-then-reopened
history.

What changes is not the process, only what you read first. Before the plan, read what actually
shipped and what the navigator saw fail:

```bash
git log origin/main --grep "(<id>):" -F --oneline    # the original PR(s)
```

and the failure itself, in the bead's notes. The plan (amended in place by a planner, per `plan-bead`)
is what you build from as always; the failure notes tell you what "done" now has to mean. **Your
scope is making the plan's promise true — the gap the navigator found — not rebuilding the bead from
nothing.** Where the failure is testable at all, let your first failing test reproduce what they
saw; that is the increment that matters most.

On merge, close it exactly as usual — it keeps `verification:failed` through the close, and that is
by design: it is what puts the bead back on Psylocke's list for a second look. The parent-close walk
in *Finishing* needs nothing different either; Psylocke already reopened the parent chain when she
reopened this bead, so closing the last open child closes it again the same way it always does.

## Workspace

Check there is room before starting — a build that runs out of disk fails inside the linker with a
message that reads like a code fault:

```bash
.claude/cerebro/scripts/disk-preflight --workload <workload from the plan>
                                      # prints what it found; non-zero means do not start
```

Never check out `main` — another agent usually holds it. `scripts/prepare-worktree` is the one
script that makes a tree: it fetches `origin/main`, branches, and — the step five retrospectives
paid for one at a time before this script existed — initialises the `.claude/cerebro` submodule and
runs the project's declared `install` inside the new tree, so the first `agent-state` write and the
first gate run both find what they need instead of failing for a reason that has nothing to
do with the bead:

```bash
<repo>/.claude/cerebro/scripts/prepare-worktree --path <repo>/.cerebro/worktrees/<id> --branch <id>-short-description
cd <repo>/.cerebro/worktrees/<id>
```

It prints the tree's path and its short sha on stdout; it does not `cd` for you, so the second line
above is still yours to run. Pass `--prewarm` here only if you already know this bead will run the
suites that need the project's prewarmed build — the gate instructions below say when that first
fails without it.

Worktrees must stay under `.cerebro/worktrees/`; the script refuses anything else, naming why. `bd`
and most build tools find their configuration by walking up, so a worktree outside the repository
silently gets its own empty bead database and its own multi-gigabyte build directory.

### A bead whose diff is inside `.claude/cerebro`

**It needs no special tree, and no worktree of the submodule at all.** Run `prepare-worktree`
exactly as above — it already initialises the submodule inside the new tree — and do the work in
`<tree>/.claude/cerebro`.

**That checkout is yours alone.** Every consumer worktree gets its own private submodule git dir, so
branching there moves nobody else's HEAD. Check it rather than believe it:

```bash
cat <tree>/.claude/cerebro/.git    # gitdir: …/.git/worktrees/<id>/modules/.claude/cerebro
cat <repo>/.claude/cerebro/.git    # gitdir: …/.git/modules/.claude/cerebro
```

**It arrives detached at the pinned sha**, because `prepare-worktree` ends with
`submodule update --init --recursive`, which checks out the commit the consumer pins rather than a
branch. So the first two commands are its own fetch and branch — branching from the pinned sha
instead is how a cerebro PR arrives based on a commit behind cerebro's main:

```bash
git -C <tree>/.claude/cerebro fetch origin
git -C <tree>/.claude/cerebro checkout -b <id>-short-description origin/main
```

**Never `git -C .claude/cerebro worktree add`.** It makes a tree registered in the submodule and not
in the consumer — and for a long time nothing enumerated the submodule's list, so trees made that way
sat on disk with their merged branches checked out and the janitor never saw one. It walks both
lists now, but that is cleanup for a category this route no longer creates. Given a relative path it also lands the tree
*inside* the submodule, which four retrospectives paid for one at a time.

**Do not clone cerebro to a sibling directory either.** The harness classifier refuses it outright —
a dead end with no diagnosis.

`bd` still works from here, because the tree is inside the consumer: that is why the location matters
more than the mechanism, and why a clone in `~/repos/` is the wrong shape even where it is allowed.

**It is two PRs.** Commit and push in `<tree>/.claude/cerebro` and open the PR against the cerebro
repository; once it merges, bump the pointer with a `chore: bump cerebro` commit from the same
consumer tree.

**Check `pwd` before any git command.** A shell keeps its directory between commands, so one `cd`
into another agent's worktree to look at something leaves every later command there — and a
`git checkout -b` then moves that agent off its own branch.

**Give each session its own block of ports** so two agents never test each other's bundle, and
**check before claiming one**. The project declares where the blocks start and how far apart they
are; nothing here knows the numbers:

```bash
base="$(.claude/cerebro/scripts/project-conf port_base)"          # where this project's blocks start
size="$(.claude/cerebro/scripts/project-conf port_block_size 10)" # blocks are this far apart
mine=$((base + size))                                             # the next block up; try base + 2*size, ... otherwise
lsof -i :$mine -i :$((mine + 1)) -i :$((mine + 2))   # silence means the block is free
export "$(.claude/cerebro/scripts/project-conf port_env)=$mine"   # the variable the project's suites read
export CI=1                          # so a dying server from your own last run is never reused
```

A project that declares no `port_base` has no port-sharing problem to solve — skip this and carry on.

There is no registry, so the check is the whole mechanism. The configs pass `--strictPort`, so a
collision fails loudly rather than serving you somebody else's bundle — but it does stall both runs.

## Building

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID
```

Write it once, before you run the fast gate for the first time — `gate` is still the word for
this step even though there is no machine-wide lock behind it any more.

Follow the plan's increments in order, each opening with its named failing test. **Run the fast gate
before opening the PR.** The command is the project's, not this skill's — ask for it, and run exactly
what it names:

Immediately before that gate, classify the actual changed paths:

```bash
git diff --name-only -z origin/main...HEAD |
  xargs -0 .claude/cerebro/scripts/build-workload --classify
```

If a planned `non-rust` workload classifies as `rust` or classification fails, rerun the preflight
with `--workload rust` and use the normal private-target gate. Otherwise use the plan's shared-target
fast gate; keep every existing gate leg.

```bash
.claude/cerebro/scripts/project-conf gate_fast     # the fast gate, and what to run
.claude/cerebro/scripts/project-conf gate_full     # everything the project has
```

A project declares those in its tracked `.cerebro/project.conf`; where it has not, the reader
may detect one and will say on stderr that it did — read that line, because a gate the harness chose
is not one the project vouched for. If neither answers, you should never have been started: the
launch preflight refuses an implementer with no fast gate.

**The distinction between the two is the project's to make, and it is worth respecting.** The fast
gate is deliberately *not* everything: it is what the project judged worth paying for on every
change, and CI is what actually gates the merge. The full gate is the rest, and it is yours to run by
choice when you suspect a regression in a surface the fast gate skips — expect it to be slower, and
possibly serialized behind a lock. A fresh worktree carries nothing the project declared as its
`prewarm` build, so a suite that needs one fails on a missing artefact rather than on anything you
wrote — pass `--prewarm` when you prepared the tree, or run
`.claude/cerebro/scripts/project-conf prewarm` and run what it names, now.

A project may also have a suite in neither gate — one needing a runner this machine has not got, run
in CI only when the diff touches the paths it covers (`.claude/cerebro/scripts/app-paths` is where
this fleet's application paths are declared). With no local browser or platform run by default, a red
job of that kind in CI is the *first* sign of that class of regression rather than a surprise — read
it as the gate doing its job, not as something that slipped past a check that used to catch it
locally.

## When the plan is wrong

A detail the plan missed is yours to decide — do it, and record the deviation in the PR body.

**A helper the plan cites for what it decides is read before it is built on.** A predicate, a
filter, a query named as the test for something is a claim about what that symbol accepts, and a
plan can be confidently wrong about it — a planner once cited one three times as the test for a
thing it accepted the opposite of. Open it and read its body before the first increment that
depends on it. If it does not accept what the plan says and the plan's intent is unambiguous, use
what does and record the deviation in the PR body; if the intent is not, that is the plan being
wrong about approach, and it goes back. The same care applies to your own PR body: a sentence there
about what a helper or a label does is read by the reviewer and the navigator with the trust a
plan gets, so run or read the thing before writing the sentence.

Anything touching **approach, scope, or what the user sees** goes back, by the same hand-back block as a missing section, worktree included. You were given a plan precisely so those decisions were made elsewhere; making
them here is the failure mode this split exists to prevent.

## The review — you get exactly one

**One review per bead, and you obtain it yourself.** No review is requested from GitHub, and none is
waited for. The second pair of eyes is a `reviewer` sub-agent you spawn once, when the gate is green
and the PR is open, and the standing approval you merge on rests on it — read the consumer's root
`CLAUDE.md` and its *Four Eye Principle* if you want the authority, because it is there and nowhere
else.

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID
.claude/cerebro/scripts/model-for --role reviewer
```

`model-for` prints one tab-separated line — `<matched-key>\t<model>\t<effort>` — or **nothing at
all** when `.cerebro/models.conf` says nothing about the `reviewer` role, in which case the
sub-agent runs on the CLI's own default. Say out loud in the session which key matched and which
model you are about to review on, the way `scripts/launch` does, so a review on an unexpected model
is traceable to the file nobody remembers editing.

This is one round. Not after you address the findings, not after a rebase, not after a fix that
changed more than the finding asked for. If you catch yourself weighing whether a push is
"substantial enough" to deserve another look, the answer is no — the rule exists so a bead costs one
review rather than an unbounded number of them.

### Getting the review

Spawn a sub-agent of type **`reviewer`**, on the model resolved above. Both layouts ship a
discoverable `reviewer` agent, so this works on either CLI.

Give it three things, and only these three:

- the diff — `gh pr diff <n>`,
- the bead's plan — `bd show <id> --json`,
- `.claude/cerebro/agents/reviewer.md`, to read as its checklist.

**Do not give it your reasoning.** Summarising your own approach into the prompt is the one thing
that would make this a second reading of the same mind rather than a second pair of eyes.

`agents/reviewer.md` has a section saying which of it applies when it is loaded this way rather than
as Cypher's own session — the sub-agent reads that for itself, and you do not need to repeat it into
the prompt.

The spawn is synchronous: wait for it inside the tool call, exactly as *Waiting, without ending your
run* says, and heartbeat the bead across it.

### Posting it

**In full, as a PR comment, before the merge**, and appended to the bead's notes — so a later
session reads the review without going to GitHub for it. The numbered list is the sub-agent's
findings, most important first, each naming the file and the case; when it found none, the list is
replaced by the italic line and nothing else:

```markdown
**Review** — this pull request was reviewed before merge under the Four Eye Principle, by an agent
given the diff and the bead's plan, and not the implementer's reasoning.

1. <finding, naming the file and the case>
```

```markdown
*No findings.*
```

```bash
gh pr comment <n> --body-file <the review>
bd update <id> --append-notes "$(cat <the review>)"
bd dolt push
```

### Answering it, and going on

**Every finding gets a change or a posted reply saying why not.** Judge each one: the reviews on
this repository have caught a lock that could be stolen a millisecond after being taken, a refusal
message that rounded itself into a contradiction, and a release step that could strand a version
bump — and they also raise things that are wrong or do not apply. A reasoned reply is a complete
answer.

A finding about **approach, scope or what the audience sees** is a hand-back, by the hand-back block
above, worktree included — those decisions were made elsewhere on purpose.

Once every finding is answered:

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID
```

and wait for CI as *Waiting, without ending your run* describes — after first checking the head can
merge, per *Merging*'s merge-state check, if anything was pushed since the PR opened. *Red CI* below
stays in this same `ci` phase — a fix-and-push does not change what you are waiting on.

**If the sub-agent cannot be spawned, or returns nothing usable**: leave the PR open, escalate by
the hand-back block, worktree included, and end the pass. No retry — this is the only escalation
route the review has, and a second attempt at a spawn that failed is not a second pair of eyes.

A review a person or a bot leaves on the PR anyway is read and answered like any other comment. It
is welcome; it is not what the approval rests on, and it does not replace the round above.

## Red CI

Three fix attempts. Diagnose, fix, push — and read the failure before believing it: a wall of
identical connection errors is infrastructure, not a defect.

A suspected flake gets the job re-run instead, capped at two re-runs, and only after you have
reproduced it locally once — reproducing locally means running that one suite directly, by whatever
command the project runs it with, for the specific spec: the full gate, or the project's own suite
for the surface in question, rather than everything. Without that cap, "it was a flake" is an unbounded loop that ends with a
genuinely broken timing test merged.

On exhaustion, leave the PR open, escalate, move on.

## Merging

Expect `BEHIND` on most merges: with several agents, a PR that sat through one review round has
usually been overtaken. **Catch the branch up on GitHub, and wait for CI again — no local re-gate.**
It costs a full CI cycle each time and that is the accepted price — a green run on a stale tree is
evidence about a tree that will never exist, and two agents changing the same function compatibly is
exactly what this catches.

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID
gh api -X PUT "repos/<owner>/<repo>/pulls/<n>/update-branch"
until [ "$(gh pr view <n> --json mergeStateStatus -q .mergeStateStatus)" != "BEHIND" ]; do
  sleep 10
done
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID
# wait for CI on the new head
```

`update-branch` merges main into the branch server-side rather than rebasing — fine here because
every PR is squash-merged, so the branch's own history never reaches main. It returns 202 and the
merge commit appears a moment later, hence the poll before waiting on CI. **No local gate runs in
this path**: CI on the new head is the re-gate, the same as it is on a fresh push.

A **422** from `update-branch` means a real conflict, not a routine BEHIND — fall back to resolving it
locally:

```bash
git fetch origin main && git rebase origin/main   # resolve conflicts
git push --force-with-lease
# back to --phase ci, and wait for CI
```

**Before waiting on CI after any push that could have raced main** — an `update-branch`, a rebase and
force-push, a fix pushed onto a head that sat through a review — check that the head can merge at all:

```bash
want="$(git ls-remote --heads origin "$(git rev-parse --abbrev-ref HEAD)" | cut -f1)"
until state="$(gh pr view <n> --json mergeable,mergeStateStatus,headRefOid \
                 -q '"\(.mergeable) \(.mergeStateStatus) \(.headRefOid)"')" \
      && [ "${state##* }" = "$want" ] \
      && [ "${state%% *}" != "UNKNOWN" ] && [ "$(echo "$state" | cut -d' ' -f2)" != "UNKNOWN" ]; do
  sleep 5
done
state="${state% *}"      # drop the sha again: the bullets below read the two words
echo "$state"
```

`mergeable` and `mergeStateStatus` both read `UNKNOWN` for a few seconds after every push while
GitHub recomputes them — and while it does, GitHub can also serve the **previous head's** concrete
verdict instead, so a `CONFLICTING DIRTY` read straight after a clean rebase and force-push may be
about a head that no longer exists. That is why the poll compares `headRefOid` with the branch tip
you just pushed and treats a mismatch exactly as `UNKNOWN`: a verdict about another head is not a
verdict yet. It waits on both fields, not just the first, so a `mergeStateStatus` still catching up
cannot slip through as a false `MERGEABLE UNKNOWN`. Then:

- `CONFLICTING DIRTY` — the head cannot merge, and whatever `gh pr checks` would show you next
  describes an older head or a run GitHub will not meaningfully finish. **Do not enter the CI wait.**
  Go to the local rebase above (`--phase rebase`), resolve, `git push --force-with-lease`, and run
  this check again.
- `MERGEABLE BEHIND` — catch up with `update-branch` as above, and check again once it lands.
- anything else (`MERGEABLE CLEAN`, `MERGEABLE BLOCKED`, `MERGEABLE UNSTABLE`) — the head is worth
  waiting on: `--phase ci`, and wait per *Waiting, without ending your run*.

Observed here on 2026-08-15: after a rebase and force-push the PR already read
`CONFLICTING`/`DIRTY`, and the implementer polled check state for a head that would never merge until
the navigator interrupted. Twenty seconds of `gh pr view` is what that wait cost. And twice since, on
consecutive days, the opposite: a `CONFLICTING DIRTY` served for the *old* head for twenty seconds to
a minute after a clean force-push, which read literally would have sent a rebased branch into a
second, no-op rebase and a second CI cycle. The `headRefOid` comparison is what tells those two cases
apart.

An update (or a resolved rebase) that brings in commits touching nothing the bead's own diff touches
can still leave nothing new to test beyond what CI already ran — if the resulting diff against main
is empty, close the PR unmerged rather than merging a no-op — a retrospective here recorded exactly
that, an empty bump PR after a rebase.

```bash
gh pr merge <n> --squash --delete-branch
```

**Never `--auto`.** On this repository the ruleset requires checks but no review, so auto-merge fires
on green checks alone: it does not wait for the reviewer and it races any fix you push afterwards.
PR #142 merged that way four minutes before its review arrived, and the fixes that review prompted
had to ship as a second PR.

`--delete-branch` often aborts with `'main' is already used by worktree` — the merge has already
happened by then. Check `git ls-remote --heads origin <branch>` and delete it explicitly if it
survived.

## Finishing, then going again

```bash
bd close <id> --reason "Delivered in PR #NN"
git -C <repo> worktree remove --force .cerebro/worktrees/<id>
git -C <repo> worktree prune
bd dolt push
.claude/cerebro/scripts/end-pass <name> --pid $PPID
```

`--force`, because `worktree remove` refuses a tree holding untracked files and would otherwise abort
at the very end of a session — leaving the worktree, its branch and its build artifacts behind. The
two commands are separate rather than chained for the same reason: a failure in the first should not
skip the second.

**Do this on every exit, not only this one.** A bead handed back, a review that never came, a CI
budget spent — each of those leaves a worktree too, and nothing else cleans them up.

### Close the parent too, when you were the last child

A bead you closed may be a child of an epic, and the epic is nothing but its children: once the last
one is closed there is no work left under it, but nothing closes it on its own. Two epics sat open
here with 2/2 children closed for exactly that reason. So this belongs with the `bd close` above and
**before** the `bd dolt push` that ends the block — a parent closed after the push is a close no
other machine sees:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'            # includes closed children by default
bd close <parent> --reason "All children closed; last was <id>, delivered in PR #NN"
```

An empty first line means there is no parent and you are done. `bd show --json` returns an array, so
index it as one — but guard the shape as `plan-bead` and `user-feedback` already do, because
indexing the wrong one fails with `Cannot index array with string "parent"` and reads like a missing
parent rather than a broken command.

Close the parent only when **every** child reads `closed`, and then repeat the lookup on *its*
parent — a child of a child leaves two levels to settle, and each is the same three commands. If the
walk runs after you have already pushed, push again; it costs nothing and the alternative is a
family that looks half-closed everywhere but here.

Two things this is not:

- **Not `bd epic close-eligible`.** That sweeps every eligible epic in the database, including
  families no session of yours ever touched. Walk up from your own bead, the way `bd reclaim --id`
  names one bead rather than reaping every stale lease.
- **Not a judgement about whether the epic is finished.** All children closed is the whole test. An
  epic that still has work left in it has that work as an open child, or it has a scope the navigator
  changed — and a scope change is theirs, not yours. If the children are all closed but the parent
  plainly is not done, leave it open, `--append-notes` why, and say so on the way out.

Say what you merged and anything the navigator should know — a deviation, a trap the plan missed, a
bead you handed back.

**Then finish.** Do not look for another bead, and do not stay alive in case one appears. The fleet
view ends this session and starts a fresh one under your name when there is a planned bead to take;
that session begins with a clean context, which is worth more than anything you could have carried
into it.

## Traps this fleet has already paid for

- **One suite's build clobbering another's.** Where two of a project's suites build the same
  artefact differently, running them in the wrong order fails the second one for a reason that is
  not a defect — which is why a project's full gate orders them as it does. Run the gate; do not
  "fix" what the previous suite left behind.
- **A leftover preview server.** Without `CI=1`, a browser runner reuses an existing server —
  including your own dying one from the previous run — and tests the bundle it is serving. That
  produced a "65 passed" and a "40 passed" run of a 138-test suite before anyone noticed.
- **`--` forwarded into a test runner.** A package-manager script passes `--` through, and a runner
  that reads what follows as a positional filter then matches no spec at all, after building and
  serving — which looks exactly like a hang rather than a mistake.
- **A stale lease is not an abandoned agent** unless it is genuinely stale — see `beads-workflow`
  before reclaiming anything.
- **A merge verdict about the wrong head.** After a rebase, a force-push or an `update-branch`,
  `gh pr view --json mergeable,mergeStateStatus` describes whichever head GitHub last finished
  computing — which may be the previous one. Read one way that is a `CONFLICTING`/`DIRTY` while the
  check state you are about to poll still describes an older head; read the other it is a stale
  `CONFLICTING` after a clean push that sends you into a needless second rebase. Look at the merge
  state before the checks, and only believe it once `headRefOid` is the tip you pushed — *Merging*
  has the loop. Cost a wasted check-state poll here once, and a near-miss on a wasted CI cycle
  twice.
- **An accessible name is a shared namespace.** A browser suite selects on the names controls
  expose, so a new control whose name contains — or is contained by — one an existing spec relies on
  makes that spec match two elements and fail, in a file with nothing to do with your change. Before
  you push, grep the suite for the words of every name you add. A project may keep a ratchet that
  holds existing selectors exact; that catches a loose selector, never a new name colliding with an
  exact one, so it passes while the suite goes red.

Read `<consumer>/.cerebro/traps.md` if it exists — the traps this project has already paid
for. It is a list of facts, not rules: if the bead touches one, say so and say what to do about it.
Absent is an ordinary state, not an error — a project with no traps file has paid for nothing yet,
which is where every project starts.
