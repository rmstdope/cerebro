---
name: implement-bead
description: The implementation role — take one planned bead, build it under TDD, get it reviewed and merged, and finish. Use when running an implementation session in atlantis-hud.
---

# Implementing a planned bead

You take a bead somebody else planned, build exactly what the plan says, see it onto main, and
**finish**. One bead, then you are done. Several of you may run at once.

You do not loop, and you do not end yourself either. You are an interactive session, so your process
outlives your turn — which is what lets the navigator talk to you, and what means you cannot simply
stop. When the bead is closed you write `done` to your state file and say what you did; the fleet
view sees that within about five seconds, ends you, and starts a fresh session for the next bead.
Everything you learned building this one goes with you, which is the point: a new session starts
with a clean context instead of five beads of residue.

Read `beads-workflow` for the label lifecycle and CLAUDE.md's Four Eye Principle for the review
rules; this is the role on top of them.

## Standing approval, and where it comes from

The `test-driven-development` skill stops at every phase for the navigator, and says a merge is
never covered by a blanket approval. This role is the documented exception, and the authority is
**CLAUDE.md's Four Eye Principle**, which the navigator wrote for exactly this: for a planned bead,
the Copilot reviewer is the second pair of eyes, and an implementation session merges on the
conditions stated there. Where the two disagree, CLAUDE.md governs this repository.

So: RED → GREEN → REFACTOR → COMMIT without stopping, announcing each transition, and still stopping
on a genuine design question — see *When the plan is wrong*. Everything outside a planned bead
follows the TDD skill's gates as written.

## Waiting, without ending your run

A bead has two long waits in it — the Copilot review, and CI — and how you wait is the difference
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
  twenty-minute review wait is three calls, not one.

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
navigator, `done` when the bead is closed and the worktree gone. `working` and `asking` also take
`--phase <build|gate|review|ci|rebase|merge>`, naming what the wait or the work actually is — see the
table below for where each is written. `--pid` is `$PPID` — your own `claude` process — and must be
captured in the call that writes the file; a stale number shows you as dead while you are working,
and the navigator will start a second implementer over the top of you. The script keeps `since`
across a phase-only change and stamps `phase_since` on a phase change — do not write the file by
hand.

| Where in this skill | Call |
|---|---|
| *Picking up*, the empty-queue poll | `.claude/cerebro/scripts/agent-state <name> idle --pid $PPID` |
| *Picking up*, right after `bd ready … --claim` | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID` |
| *Building*, before the fast gate | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID` |
| *The review*, after `gh pr edit --add-reviewer @copilot` | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID` |
| *The review*, once every comment is answered and resolved | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID` |
| *Red CI* | stays `ci` |
| *Merging*, on `BEHIND`: catch up on GitHub → CI | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID`, then `... --phase ci ...` |
| *The retrospective* opening line onward | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID` — merge covers retro, merge, close, cleanup |
| *Asking instead of handing back* | `.claude/cerebro/scripts/agent-state <name> asking --bead <id> --phase <current> --pid $PPID`; on resuming, `working` with the same bead and phase |
| *Finishing*, after `bd close` and worktree removal, and the hand-back block | `.claude/cerebro/scripts/agent-state <name> done --bead <id> --pid $PPID` |

`done` is a request to be ended, granted within about five seconds. Write it last.

## Finishing means finishing

There is no next bead to take, and no flag for **you** to check. The `.stop` flag still means what
`orchestrator.md` says it means — the fleet view reads it when you report `done`, and decides
whether a fresh session starts in your place. That is not your business, and you must not read it:
an implementer that saw a stop flag mid-bead and wound up early would strand exactly what the
between-beads rule exists to protect.

So: **do the retrospective below before you merge**, and when the bead is merged, closed and cleaned
up, write `done`, say what you did, and stop producing output. **Never write `done` before that point.** A
bead abandoned in flight strands a claim, a worktree and an open PR for somebody to unpick by hand,
which is exactly what one-bead-per-session is arranged to avoid.

The one exception is a bead you hand back — a missing plan section, a question only the navigator
can answer. That is a complete run too: hand it back with the block below, clean up, write `done`,
and finish.

## The retrospective

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID
```

Write it once, entering this section — `merge` covers the retrospective, the merge itself, closing
the bead and cleaning up, so no more phase writes are needed until `done`.

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

`docs/retrospectives/<bead id>.md` — `docs/retrospectives/ah-t65.md` for bead `ah-t65`.

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

You do **not** ask for another review: one Copilot review per bead, requested when the PR opens and
never again, and a docs commit after it is exactly the kind of head movement that rule already
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
# ah-t65 — retrospective

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
**Seen before.** ah-t12 — same spec, same job.
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

If the queue is genuinely empty, **wait for one — do not report `done`.** `done` asks to be replaced,
and a fresh session would find the same empty queue and ask again, spinning sessions for as long as
the queue stays empty. Write `idle` and poll, blocking and printing as *Waiting, without ending your
run* describes:

```bash
.claude/cerebro/scripts/agent-state <name> idle --pid $PPID
until bd ready --label planned --exclude-label human --exclude-type epic --json \
        | grep -q '"id"'; do
  echo "queue empty, waiting"
  sleep 60
done
```

Then claim, as below. Say once that you are waiting, so the navigator knows why you look quiet.

```bash
bd dolt pull
bd ready --label planned --exclude-label human --exclude-type epic --claim --json
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID
bd dolt push                               # so other machines see the claim
```

One bead. `--claim` takes the first ready one; take that and no other.

`human` is work already waiting on the navigator; `epic` is a split parent, which has children
rather than a plan. Claiming either means refusing it a minute later.

`bd heartbeat <id>` at every phase gate and before anything long — a full gate run, a CI watch. The
lease is short, about five minutes, and a cycle is an hour; the exact TTL is bd's and not
configurable here, so heartbeat on every boundary rather than on a timer.

Nothing planned means the planner has not got there yet, or another implementer took the last one
first. **Wait for one, as *Picking up* describes** — a blocking, printing poll, and say once that
you are waiting.

That reverses what this said when a launcher looped: idling was its job then, and finishing
immediately was free because it would start you again. It is not free now. Finishing means writing
`done`, `done` asks to be replaced, and the replacement would find the same empty queue and ask
again — a fresh session every few seconds for as long as the queue stayed empty. A blocking poll
costs one line of output a minute.

**Read the plan with `bd show <id> --json`.** The pretty renderer mangles it.

**Refuse a plan missing a mandatory section** — context, files and reuse, increments with their
tests, test plan, user-facing decisions, out of scope, validation, traps:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<the section that is missing>"
bd unclaim <id>
bd dolt push
```

All three, and this is the **hand-back block** referred to throughout. After it, remove the worktree
if one exists (see *Finishing*) and write `.claude/cerebro/scripts/agent-state <name> done
--bead <id> --pid $PPID` last, exactly as a merged bead does — a hand-back is a complete run too.
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
.claude/cerebro/scripts/disk-preflight    # prints what it found; non-zero means do not start
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

```bash
.claude/cerebro/scripts/project-conf gate_fast     # the fast gate, and what to run
.claude/cerebro/scripts/project-conf gate_full     # everything the project has
```

A project declares those in its tracked `.claude/cerebro-project.conf`; where it has not, the reader
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

Anything touching **approach, scope, or what the user sees** goes back, by the same hand-back block as a missing section, worktree included. You were given a plan precisely so those decisions were made elsewhere; making
them here is the failure mode this split exists to prevent.

## The review — you get exactly one

**One Copilot review per bead. Request it the moment the PR opens, and never again.**

```bash
gh pr edit <n> --add-reviewer @copilot
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID
```

That command runs once in the life of a PR. Not after you address the comments, not after a rebase,
not after a fix that changed more than the comment asked for. If you catch yourself weighing whether
a push is "substantial enough" to deserve another look, the answer is no — that judgement is not
yours to make any more, and the rule exists so a bead costs one review rather than an unbounded
number of them.

`requested_reviewers` reading empty a minute later means the request was fulfilled, not dropped — do
not re-run this off of that.

Then wait for it — blocking, printing, heartbeating, per *Waiting, without ending your run*:

```bash
until gh api repos/<owner>/<repo>/pulls/<n>/reviews \
        --jq '[.[] | select(.user.login | startswith("copilot"))] | length' | grep -qv '^0$'; do
  bd heartbeat <id>
  echo "waiting for the review on #<n>"
  sleep 30
done
```

Run that with an explicit `timeout` under the ten-minute ceiling and call it again if it returns
empty-handed. The twenty-minute policy below is three of these calls, not one long one.

Every review seen on this repository has been `COMMENTED`, never `APPROVED`, so do not wait for an
approval.

**Do not require that review to match your head.** It describes the PR as it stood when it opened,
and it will keep describing that after your fixes and rebases move the head — which is correct and
expected, not a reason to ask again. What you owe the review is an answer to every comment, not a
fresh review of your answers.

**Every comment gets a change or a posted reply saying why not**, and the thread resolved:

```bash
# read them
gh api repos/<owner>/<repo>/pulls/<n>/comments --jq '.[] | "\(.id)|\(.path):\(.line)|\(.body)"'
# reply
gh api repos/<owner>/<repo>/pulls/<n>/comments/<comment-id>/replies -f body='...'
# resolve — gh has no built-in for this, so it is the GraphQL mutation
gh api graphql -f query='{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>)
  {reviewThreads(first:20){nodes{id isResolved}}}}}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | .id'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'
```

Take the comments seriously. On this repository they have caught a lock that could be stolen a
millisecond after being taken, a refusal message that rounded itself into a contradiction, and a
release step that could strand a version bump — but they also raise things that are wrong or do not
apply. Judge each one; a reasoned reply is a complete answer.

Once every comment is answered and every thread resolved:

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID
```

and wait for CI as *Waiting, without ending your run* describes — after first checking the head can
merge, per *Merging*'s merge-state check, if anything was pushed since the PR opened. *Red CI* below
stays in this same `ci` phase — a fix-and-push does not change what you are waiting on.

**No review within about twenty minutes**: leave the PR open, escalate the bead (the hand-back block above, worktree included), say so plainly, and take the next bead. Some PRs never get one. Merging anyway is not the
answer, and neither is waiting forever. Do not re-request in the hope of shaking one loose — your one
request has been spent, and a second would not arrive faster.

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
until state="$(gh pr view <n> --json mergeable,mergeStateStatus -q '"\(.mergeable) \(.mergeStateStatus)"')" \
      && [ "${state%% *}" != "UNKNOWN" ] && [ "${state#* }" != "UNKNOWN" ]; do sleep 5; done
echo "$state"
```

`mergeable` and `mergeStateStatus` both read `UNKNOWN` for a few seconds after every push while
GitHub recomputes them, which is what the poll waits out — on either field, not just the first, so a
`mergeStateStatus` that is still catching up cannot slip through as a false `MERGEABLE UNKNOWN`. Then:

- `CONFLICTING DIRTY` — the head cannot merge, and whatever `gh pr checks` would show you next
  describes an older head or a run GitHub will not meaningfully finish. **Do not enter the CI wait.**
  Go to the local rebase above (`--phase rebase`), resolve, `git push --force-with-lease`, and run
  this check again.
- `MERGEABLE BEHIND` — catch up with `update-branch` as above, and check again once it lands.
- anything else (`MERGEABLE CLEAN`, `MERGEABLE BLOCKED`, `MERGEABLE UNSTABLE`) — the head is worth
  waiting on: `--phase ci`, and wait per *Waiting, without ending your run*.

Observed on ah-k6i.5 (PR #285, 2026-08-15): after a rebase and force-push the PR already read
`CONFLICTING`/`DIRTY`, and the implementer polled check state for a head that would never merge until
the navigator interrupted. Twenty seconds of `gh pr view` is what that wait cost.

An update (or a resolved rebase) that brings in commits touching nothing the bead's own diff touches
can still leave nothing new to test beyond what CI already ran — if the resulting diff against main
is empty, close the PR unmerged rather than merging a no-op (the ah-u3i retrospective's note about an
empty bump PR after a rebase applies here too).

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
.claude/cerebro/scripts/agent-state <name> done --bead <id> --pid $PPID
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

**Then finish.** Do not look for another bead, and do not stay alive in case one appears. Your
launcher re-reads its flags the moment you exit and starts a fresh session if there is more to do;
that session begins with a clean context, which is worth more than anything you could have carried
into it.

## Traps this repository has already paid for

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
- **WebKit's driver** answers `""` for text it considers clipped, so a Chromium assertion can pass
  while the native shell shows nothing. `native` is the job that tells you.
- **A stale lease is not an abandoned agent** unless it is genuinely stale — see `beads-workflow`
  before reclaiming anything.
- **A CI wait against a conflicted head.** After a rebase, a force-push or an `update-branch`,
  `gh pr view --json mergeable,mergeStateStatus` can already say `CONFLICTING`/`DIRTY` while the
  check state you are about to poll still describes the previous head. Look at the merge state
  before the checks — *Merging* has the loop. Cost once on ah-k6i.5.
