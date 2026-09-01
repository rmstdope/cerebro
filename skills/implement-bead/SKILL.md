---
name: implement-bead
description: The implementation role — take one planned bead, build it under TDD, get it reviewed and merged, and finish. Use when running an implementation session.
---

# Implementing a planned bead

You take a bead somebody else planned, build exactly what the plan says, see it onto main, and
**finish**. One bead, then you are done. Several of you may run at once.

You do not loop, and you do not end yourself either. You are an interactive session, so your process
outlives your turn — which is what lets the navigator talk to you, and what means you cannot simply
stop. When the bead is closed you run `end-pass` (see *Ending a pass*) and say what you did; the
fleet view ends you half a minute later and starts a fresh session under your name when there is
another planned bead. Everything you learned building this one goes with you, which is the point: a
new session starts with a clean context instead of five beads of residue.

Read `beads-workflow` for the label lifecycle and the consumer's root `CLAUDE.md` — its Four Eye
Principle — for the review
rules; this is the role on top of them.

## Standing approval, and where it comes from

Merging is not normally something a blanket approval covers. This role is the documented exception,
and the authority is **the consumer's root `CLAUDE.md` and its Four Eye Principle**, which the
navigator wrote for exactly this: for a planned bead, a review sub-agent you spawn for yourself is
the second pair of eyes, and an implementation session merges on the conditions stated there.
`templates/consumer-CLAUDE.md` is where a project without one starts, and where anything in this
skill disagrees with the project's own document, the project's governs.

So: RED → GREEN → REFACTOR → COMMIT without stopping, announcing each transition, and still stopping
on a genuine design question — see *When the plan is wrong*. The approval covers a planned bead and
nothing else: work outside one stops for the navigator at each phase, like any other change.

## Waiting, without ending your run

A bead has one long wait in it — CI — and how you wait is the difference between finishing a bead
and abandoning one. An implementer once armed a `Monitor` against a review, said "I'll wait now
for the monitor's event", and ended its turn. The review landed two minutes later: two comments
unanswered, the bead claimed, the PR open, and nothing to wake it.

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
disaster it was when it ran under `--print` — but nothing wakes you. A turn ended against a CI run
sits until the navigator happens to look and type something, with the bead claimed, the PR open and
the lease going stale the whole time. Block, and stay in the run.

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how you are seen and how you are replaced.

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID
```

<!-- state-contract:begin -->

Write it at every transition, in the same `Bash` call as the thing it describes, through
`.claude/cerebro/scripts/agent-state` — never by hand, and never with a state word of your own
invention. There are four, and no others: `idle`, `working`, `asking`, `waiting`.

- `working` covers everything you are actually doing.
- `asking` says you are blocked on the navigator and nothing is moving until they answer.
- `idle` says a live session with nothing in hand, waiting to be spoken to.
- `waiting` says *this pass is over and my turn has ended*. The fleet view ends the session about
  half a minute later, keeps its buffer as the record of the pass, and starts a fresh one on your
  role's own trigger.

The table below is where you find which of them you write, and when. Work done under the wrong one
is invisible or misleading: a session shown with nothing in flight is one the navigator may `k`, and
one shown as `asking` is one they think is blocked on them.

`working` and `asking` also take `--phase`, naming what the work or the wait actually is; the words
your role uses are in that same table. The script keeps `since` across a phase-only change and
stamps `phase_since` on one — which is another reason never to write the file by hand.

`--pid` is `$PPID` — your own session's process, whichever agent CLI it runs on — and it must be
captured in the call that writes the file. A stale number shows you as dead while you are working,
and the navigator will start a second session over the top of you.

**Every question to the navigator is three actions, not one.** Write `asking`, ask, and then — as
the very first thing you do with the answer, before any `bd`, `git` or reply — write `working`
again. If you find yourself typing `bd` or `git` straight after an answer, you have skipped the
third: stop, write the state, then carry on. That is the most common way this goes wrong, because
the answer feels like the end of the exchange while the file still says you are blocked.

**There is a hook behind that, and it does not excuse you.** `hooks/question-state.settings.json`
and `scripts/agent-asking`, which `scripts/launch` gives every session, flip the file to `asking`
for the lifetime of a question tool call and back again on the answer or a cancellation. Keep
writing the states anyway: the hook knows about the question tool and nothing else, so a question
put in prose, a wait on a port or a "say when" is invisible to it, and it cannot tell `idle` from
`working`. Two writes that agree cost nothing; a missing one costs the navigator an hour of not
knowing you were waiting.

**You cannot see your own state file**, so read it rather than trusting your memory of it — once at
the start of a pass and once before you end it. If it does not describe what you are doing at that
moment, fix it with `agent-state` before anything else, and say so in one line ("my state file still
said `asking`; corrected").

<!-- state-contract:end -->

| Where in this skill | Call |
|---|---|
| *Picking up*, nothing to claim | `.claude/cerebro/scripts/end-pass <name> --pid $PPID` |
| *Picking up*, right after `bd ready … --claim` | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID` |
| *Building*, before the fast gate | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID` |
| *The review loop*, before spawning the review sub-agent | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID` |
| *The review loop*, once every finding is answered | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID` |
| *Red CI*, after each fix-and-push | back to `--phase review` for the new head, then `--phase ci` again |
| *The retrospective* opening line onward | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID` |
| *The retrospective*, if you committed one | back to `--phase review` for the new head, then `--phase ci`, then `--phase merge` again |
| *Merging*, on `BEHIND`: catch up on GitHub → CI | `.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID`, then `... --phase ci ...` |
| *Asking instead of handing back* | `.claude/cerebro/scripts/agent-state <name> asking --bead <id> --phase <current> --pid $PPID`; on resuming, `working` with the same bead and phase |
| *Finishing, then going again*, after `bd close` and worktree removal, and the hand-back block | `.claude/cerebro/scripts/end-pass <name> --pid $PPID` |

`waiting` is a request to be ended, granted within about half a minute. Run `end-pass` last. There
is no wake to ask for: the view starts an implementer on a planned bead, not on a clock.

## Ending a pass

There is no next bead to take, and no flag for **you** to check. The `.stop` flag still means what
`orchestrator.md` says it means — the fleet view reads it when you report `waiting`, and decides
whether a fresh session starts in your place. That is not your business, and you must not read it:
an implementer that saw a stop flag mid-bead and wound up early would strand exactly what
one-bead-per-session is arranged to protect.

**A pass is ended in one place**, and `waiting` is what it writes for you:

```bash
.claude/cerebro/scripts/end-pass <name> --pid $PPID
```

Run it last — after the bead is merged and closed, the retrospective below is written and the
worktree is gone — then say what you did and stop producing output. **Never end a pass before that
point.** A bead abandoned in flight strands a claim, a worktree and an open PR for somebody to
unpick by hand.

The one exception is a bead you hand back — a missing plan section, a question only the navigator
can answer. That is a complete run too: hand it back with the block in *Picking up*, clean up, and
end the pass exactly the same way.

## Picking up

**This is your first turn's work.** Nothing gates it: a running implementer is a working one, and
there is no flag to wait for.

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

**Nothing to claim? End the pass — do not poll.** The planner has not got there yet, or another
implementer took the last one first; the view may have started you for a bead a peer claimed a
moment ago. Say "queue empty, ending the pass" in one line, run `end-pass` as *Ending a pass*
describes, and stop producing output. The view starts a fresh session under your name the moment a
planned bead exists, and a session that sits polling is one it cannot tell from a session that has
hung.

**Read the plan with `bd show <id> --json`.** The pretty renderer mangles it.

**Refuse a plan missing a mandatory section** — context, files and reuse, increments with their
tests, test plan, user-facing decisions, out of scope, validation, traps:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<the section that is missing>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd unclaim <id>
bd dolt push
```


All three, and this is the **hand-back block** referred to throughout. `beads-workflow` carries why
each command matters; the short of it is that `paused_at` is what makes the pause visible as a
*duration* rather than as parked-just-now-for-ever (cb-wfb), and that `bd unclaim` is what stops the
bead sitting `in_progress` under an agent that has walked away.

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
hers alone to set, and it is what sends the bead to a planner. After either block, remove the
worktree if one exists (see *Finishing, then going again*) and run `end-pass` last, exactly as a
merged bead does — a hand-back is a complete run too.

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
in *Finishing, then going again* needs nothing different either; Psylocke already reopened the parent chain when she
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
**check before claiming one**. A project that declares no `port_base` has no port-sharing problem to
solve — skip the rest of this section. Otherwise the project declares where the blocks start and how
far apart they are; nothing here knows the numbers:

```bash
base="$(.claude/cerebro/scripts/project-conf port_base)"          # where this project's blocks start
size="$(.claude/cerebro/scripts/project-conf port_block_size 10)" # blocks are this far apart
mine=$((base + size))                                             # the next block up; try base + 2*size, ... otherwise
lsof -i :$mine -i :$((mine + 1)) -i :$((mine + 2))   # silence means the block is free
export "$(.claude/cerebro/scripts/project-conf port_env)=$mine"   # the variable the project's suites read
export CI=1                          # so a dying server from your own last run is never reused
```

There is no registry, so the check is the whole mechanism. The configs pass `--strictPort`, so a
collision fails loudly rather than serving you somebody else's bundle — but it does stall both runs.

## Building

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID
```

Write it once, before you run the fast gate for the first time — `gate` is still the word for
this step even though there is no machine-wide lock behind it any more.

Follow the plan's increments in order, each opening with its named failing test.

**Before you open the PR: classify what you actually changed, then run the fast gate.** Classify
first, because the answer decides which gate you run:

```bash
git diff --name-only -z origin/main...HEAD |
  xargs -0 .claude/cerebro/scripts/build-workload --classify
```

If a planned `non-rust` workload classifies as `rust`, or classification fails, rerun the preflight
with `--workload rust` and use the normal private-target gate. Otherwise use the plan's shared-target
fast gate; keep every existing gate leg. The command itself is the project's, not this skill's — ask
for it, and run exactly what it names:

```bash
.claude/cerebro/scripts/project-conf gate_fast     # the fast gate, and what to run
.claude/cerebro/scripts/project-conf gate_full     # everything the project has
```

A project declares those in its tracked `.cerebro/project.conf`; where it has not, the reader
may detect one and will say on stderr that it did — read that line, because a gate the harness chose
is not one the project vouched for. If neither answers, you should never have been started: the
launch preflight refuses an implementer with no fast gate.

### A changed shared-root declaration is gated in a clone

`project-conf` and `model-for` deliberately read `.cerebro/project.conf` and
`.cerebro/models.conf` from the shared checkout. When the diff changes either file, a read from
this worktree still sees main; a failure or old value there is not evidence that the branch is
wrong. Finish and commit the increments first, then follow the plan's exact clone, submodule,
install or prewarm, and fast-gate commands. Run the gate in that throwaway clone of the
committed branch, where the enclosing and shared roots are one tree. Do not dirty main to make
a worktree check pass, and do not report a worktree shared-root read as validation of the
branch. Run any direct reader check the plan labels post-merge only after the merge.

`.cerebro/roster.conf` does not require this escape hatch: `roster` reads the enclosing
worktree. Use the clone path only when the changed declaration is actually read through
`consumer-root --shared`.

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

**A current-source claim the plan relies on is checked before its increment begins.** This includes
a quoted `Currently:` region, the old side of a proposed diff, a line-number or body claim, and
replacement prose whose factual wording describes current behavior. Open the referenced region in
the current worktree before writing the first failing test that depends on it; compare it with
merged source, not a sibling bead's design. If the source still supports the claim, proceed with
the planned increment. If `main` already supplies its outcome, do not recreate the code or duplicate
its tests: skip that overtaken increment and name the current evidence in the PR body, then continue
with the remaining increments. If the source moved or changed in place but the intent remains
unambiguous, use the current location or shape and record the deviation in the PR body, as with the
helper rule above.
If the change affects or obscures approach, scope, or audience-visible intent, use the existing
hand-back block rather than inferring a replacement design.

Anything touching **approach, scope, or what the user sees** goes back, by the same hand-back block as a missing section, worktree included. You were given a plan precisely so those decisions were made elsewhere; making
them here is the failure mode this split exists to prevent.

### Asking instead of handing back

You are interactive, so the navigator can answer you. For a question that genuinely blocks the bead
you may ask rather than hand back — write `asking` to your state file first, with the bead still in
`bead` and the current phase passed again, then ask plainly and wait.

Nobody waits for ever. You do not enforce the timeout and cannot see it: the fleet view holds the
clock (`cerebro-answer-timeout`, fifteen minutes by default), and when it expires a line starting
`[cerebro]` arrives in your session telling you to give up. Treat it as the navigator speaking —
stop waiting, hand the bead back by the hand-back block in *Picking up*, and end the pass.

So a question worth asking is one somebody could answer inside that quarter of an hour. Prefer
handing back outright when the answer plainly needs somebody awake, or when the bead can wait for
the planner rather than the navigator: handing back is always available and always correct, and
asking is only the faster path when somebody is there.

## The review loop

**Review the exact head being merged, and obtain it yourself.** No review is requested from GitHub,
and none is waited for. The second pair of eyes is a `reviewer` sub-agent you spawn synchronously
when the gate is green and the PR is open, and the standing approval you merge on rests on the
consumer's root `CLAUDE.md` and its *Four Eye Principle*, because the rule is there and nowhere
else. Everything below is how you satisfy it.

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID
provider="$(.claude/cerebro/scripts/agent-cli)" || provider=""
.claude/cerebro/scripts/model-for ${provider:+--provider "$provider"} --role reviewer
```

**Pass the provider**, exactly as `scripts/launch` does: a consumer declaring `agent_cli copilot`
may carry a `reviewer@copilot` row, and asking without it silently matches the plain key instead —
one file with two answers, which is the defect `model-for` exists to prevent.

`model-for` prints one tab-separated line — `<matched-key>\t<model>\t<effort>` — or **nothing at
all** when no key matched, in which case the sub-agent runs on the CLI's own default. Two things its
header is explicit about and this text will not repeat wrongly: a `default` or `default@<provider>`
row matches too, so a miss means *no key matched* rather than *nothing about `reviewer`*; and
`<model>` may be the literal `-`, which is a real answer meaning **pass no model at all** — spawn on
the CLI's default, never on a model named `-`. Say out loud in the session which key matched and
which model you are about to review on, the way `scripts/launch` does, so a review on an unexpected
model is traceable to the file nobody remembers editing.

Before each invocation, read and retain `reviewed_head` from
`gh pr view <n> --json headRefOid`. Give the reviewer the diff, bead plan, and reviewer checklist,
never your reasoning. A tool failure, empty response, or response lacking both findings and an
explicit no-findings verdict is unusable; retry that head up to three attempts, heartbeating between
attempts, then use the hand-back path and record the failed attempts. For a usable response, post
the complete review with its `reviewed_head` in the heading and answer every finding. Re-read
`headRefOid` after answers: any difference requires a fresh review, with the counter reset. Every
later push or server-side head change (finding or CI fixes, retrospective, rebase, or update-branch)
also returns here; do not decide whether a change is substantial enough.

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
**Review (`reviewed_head`: `<sha>`)** — this pull request was reviewed before merge under the Four Eye Principle, by an agent
given the diff and the bead's plan, and not the implementer's reasoning.

1. <finding, naming the file and the case>
```

```markdown
*No findings.*
```

Write what the sub-agent returned to a file first — `/tmp/review-<id>.md`, say — so the same bytes
go to both places and neither is a paraphrase:

```bash
gh pr comment <n> --body-file /tmp/review-<id>.md
bd update <id> --append-notes "$(cat /tmp/review-<id>.md)"
bd dolt push
```

### Answering it, and going on

**Every finding gets a change or a posted reply saying why not.** The findings arrive in your
session rather than as review threads, so there is nothing to reply *to* and nothing to resolve: a
reply is a second PR comment under the review, naming the finding by its number and saying why it is
not being changed.

```bash
gh pr comment <n> --body 'Finding 3 — not changing this, because ...'
```

One comment answering several findings is fine; what the standing approval asks is that no finding
is left with neither a change nor an answer. Judge each one: the reviews on
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
returns every fix-and-push through the review loop; only after that review is complete does it return
to `ci` and wait for checks on the reviewed head.

**If three attempts for one head are unusable**: leave the PR open, record the attempts in the
bead's notes, hand it back by the hand-back block in *Picking up*, worktree included, and end the
pass.

A review a person or a bot leaves on the PR anyway is read and answered like any other comment. It
is welcome; it is not what the approval rests on, and it does not replace the round above.

## Red CI

**Three fix attempts, and two bare re-runs, for the whole bead.** They are two budgets, not one
each per failure: a fix that pushes a new commit spends a fix attempt, a job re-run of the same head
spends a re-run, and neither refills. Diagnose, fix, push — and read the failure before believing
it: a wall of identical connection errors is infrastructure, not a defect.

A re-run is for a suspected flake, and only after you have reproduced it locally once — that means
running the one suite directly, by whatever command the project runs it with, for the specific spec,
rather than everything. Without the cap, "it was a flake" is an unbounded loop that ends with a
genuinely broken timing test merged.

Every fix changes the head, so it returns through the review loop before CI, exactly as *The review
loop* says — which makes this budget the only thing bounding how many review rounds one red bead
costs. **It is deliberately scoped differently from the review budget**, which is three attempts
*per head* and resets on every new head: a review retried is a supplier that failed, while a fix
retried is this bead failing, and the second is what has to be bounded for the bead as a whole. On
exhaustion of either budget here, leave the PR open, hand the bead back by the hand-back block in
*Picking up*, and end the pass.

## The retrospective

```bash
.claude/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID
```

Write it entering this section. `merge` covers the retrospective, the merge itself, closing the bead
and cleaning up — so if you write no file, which is the common case, there is no further phase write
until the pass ends. Committing one changes the head, which sends you back through `review` and `ci`
and then to `merge` again, exactly as any other head change does.

**When the review is answered and CI is green, before you merge**, look back over the run and ask
one question: *did anything happen that I did not expect?*

This is not optional. You are the only one who saw the run, your context is about to be thrown away
by design, and whatever cost you an hour will cost the next session an hour too unless it is
written down.

**Before the merge, because it is a tracked file**: it travels in the bead's own PR, and once that
PR is merged there is no branch left to put it on. The merge itself is the one stretch a
retrospective written here cannot cover; if something goes wrong there, the next session hits it too
and records it then.

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

**Committing it costs a review round and a CI cycle, and that is the intended trade** — which is
also why the bar for writing one is high. Adding the file moves the head past the green run:

```bash
mkdir -p docs/retrospectives          # the first finding in a fresh checkout creates it
[ -f docs/retrospectives/README.md ] || \
  cp .claude/cerebro/templates/retrospectives-README.md docs/retrospectives/README.md
git add docs/retrospectives/          # the README too, on the run that creates it
git commit -m "docs(<bead id>): retrospective — <the one-line symptom>"
git push
# then wait for CI again, per *Waiting, without ending your run*, and merge on green
```

**Stage the directory, not just your own file.** The `cp` above writes the README into your
worktree, and a worktree is removed at the end of the pass: a copy that is never staged is a copy nobody ever sees,
and the next bead finds the directory undocumented again.

The commit changes the head, so it returns through the review loop and then CI before the merge, as
every head change does. A bead with no retrospective adds no round at all.

### The format

The template the block above copies in — `templates/retrospectives-README.md`, in this mount — is
the format, documented where the files are rather than only here.

Five fields, and the README has them in full: **What happened** (concretely, with the command that
produced it), **Why** (or "not established" — do not guess), **Cost**, **Prevent by** (a file and a
section, a step, a check — "be careful" is not a prevention), **Seen before** (other bead ids, or
"none found").

### Writing it

**Grep the directory before you write**, so *Seen before* is real rather than decorative — a
finding on its third sighting is the strongest evidence the fleet produces that something needs
fixing rather than tolerating:

```bash
grep -rl "<a word from your symptom>" docs/retrospectives/ 2>/dev/null || echo "nothing like it yet"
```

A complete example, indented here so its own headings stay out of this skill's outline:

    # <bead-id> — retrospective

    - **Implementer:** Cyclops
    - **Date:** 2026-08-14
    - **PR:** #231

    ## The browser suite passed locally and failed in CI

    **What happened.** The project's browser suite was green on this machine three times. The same
    commit failed twice in CI on `smoke (web, 2, 2)`, both times on a timeout in the map-drag spec.
    **Why.** Not established. The CI runner is slower and the spec waits on a fixed 500ms, but I did
    not prove that is the cause.
    **Cost.** Two CI cycles and a rebase, about 50 minutes.
    **Prevent by.** The plan's *Validation* section should name which suite covers a map
    interaction, so it is run in CI-like conditions before the PR opens rather than after.
    **Seen before.** <an earlier bead id> — same spec, same job.

Two rules for the writing itself. **Be specific enough to act on**: name the file, the command, the
job, the section. A future reader has none of your context and cannot ask you. And **do not fix it
here** — recording is your job; changing the rules, the skill or CI is outside a planned bead and
belongs to the navigator, who reads these precisely so they can decide.

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

Immediately before merging, require all three facts together: the PR's current `headRefOid` equals
the most recently reviewed head, mergeability is not behind or conflicting, and required checks for
that head are green. If the SHA differs, return to the review loop; if mergeability or checks differ,
follow the existing rebase and CI paths.

```bash
gh pr merge <n> --squash --delete-branch
```

**Never `--auto`.** On this repository the ruleset requires checks but no review, so auto-merge fires
on green checks alone: it races any fix you push afterwards, and it would merge a PR whose review
you had not yet obtained. PR #142 merged that way four minutes before its review arrived, back when
the review came from GitHub — the supplier has changed, the race has not.

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

**Do this on every exit, not only this one.** A bead handed back, a review sub-agent that returned
nothing usable, a CI
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

An empty first line means there is no parent and you are done. Close the parent only when **every**
child reads `closed`, then repeat the lookup on *its* parent — a child of a child leaves two levels
to settle. If the walk runs after you have already pushed, push again; it costs nothing.

`beads-workflow` has the rest of this walk — why the `if type=="array"` guard is there, and why it
is not `bd epic close-eligible`. The one part that is yours to judge: all children closed is the
whole test, and a parent that plainly is not done anyway is left open with `--append-notes` saying
why, because changing an epic's scope is the navigator's.

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
- **A merge verdict about the wrong head.** `gh pr view --json mergeable,mergeStateStatus` can
  describe the head before your push. Never believe it until `headRefOid` is the tip you pushed —
  *Merging* has the loop and what it cost.
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
