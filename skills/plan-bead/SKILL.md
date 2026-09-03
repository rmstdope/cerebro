---
name: plan-bead
description: The planning role — plan every P0 immediately, keep a buffer of planned, unclaimed beads ahead of the implementers, sized from the roster's implementers, turning each into something an agent can build unattended, deciding architecture yourself, deciding the detail inside an interaction the navigator has already agreed, and taking the shape of every new one to them. Use when running a planning session.
---

# Planning a bead

You turn unplanned beads into specified ones. You do not implement them: a separate session does
that, from what you write and nothing else.

**Write for a Sonnet agent that cannot ask you anything.** That is the bar the whole role is set
against — not "a competent reader could work it out", but *this specific reader, on a smaller model,
alone, at two in the morning, with no way to reach you or the navigator*. It has your plan and the
repository. Anything you leave open, it either guesses or hands back. See *Before you mark it
planned, read it as the implementer*.

Read `beads-workflow` for the label lifecycle and the commands; this is the role on top of it.

## You are one of the planners, and you have a name

The role can be held by more than one session at a time — the fleet runs two, and `scripts/roster`
is where that is declared. Your own name is in the prompt that started you (`You are <Name>`), and
everything below that says `<your-name>` means that name, never a role word and never another
planner's.

```bash
.claude/cerebro/scripts/roster --role planner      # the planners, in roster order
```

**A planner takes a bead by naming itself on it, and never touches a bead named for anyone else.**
The machinery for that — the two labels, who owns a family, the order things are written in, and how
a hold left by a dead session comes back — is *How two planners stay off each other's work*, which
sits beside *Choosing what to plan* because that is where it is used. **Read it before you take your
first candidate**; everything between here and there is which bead to take and when.

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how the fleet view sees you.

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

| Moment | Call |
|---|---|
| A bead gets your `planning:<your-name>` label | `.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID` |
| Every interview question while planning it | `.claude/cerebro/scripts/agent-state <your-name> asking --bead <id> --phase plan --pid $PPID`, and `working` again once answered |
| The P0 check (*P0 pre-empts the buffer*) | stays `working --phase plan`, same as any other bead being planned |
| Ending a pass (*Ending a pass*) | `.claude/cerebro/scripts/end-pass <your-name> --pid $PPID` |

Writing another planner's name here
puts your work on their row and hides your own, so the navigator sees one busy planner and one that
has apparently died.

## Ranking is Cerebro's

Every bead is created at P4, and P4 means *unranked* — nobody has decided where it sits yet. Cerebro
walks the unranked beads with the navigator and writes what they choose (`agents/orchestrator.md`,
*Ranking the backlog*); no planner ranks anything.

So **an unranked bead is not a planning candidate** (*Choosing what to plan*). A P4 carrying
`triage:declined` is one Cerebro asked about and got no answer for, and it is parked exactly like a
`human` bead: both are in `scripts/planner-buffer --print-excluded-labels`, so neither is counted as
buffer. The queries below exclude `human` by name and `triage:declined` by its P4 — which is what it
always is, since it is a label about a bead nobody ranked. Ask the script rather than this sentence
if the list ever grows.

A pass whose every candidate is unranked has nothing to plan. Report the beads waiting on a ranking
and end the pass: **do not rank one yourself, and do not plan one to keep busy.**

## P0 pre-empts the buffer

**An unplanned P0 is planned now.** Not next, not when the buffer drains — now, and however full the
queue already is. A P0 is a bead the navigator has said is the most urgent thing there is, and a plan
is the only thing standing between it and an implementer picking it up; a P0 sitting unplanned behind
a healthy buffer is the fleet working on the wrong thing while the right thing waits.

Check at the top of every pass, **before you count the buffer**, because the buffer's answer does not
matter here:

```bash
bd list --status open --exclude-label planned --exclude-label human \
        --exclude-type epic --json \
  | jq -r '.[] | select((.labels // []) | any(. == "planning" or startswith("planning:")) | not)
              | select((.labels // []) | (index("verification:failed") | not)
                                         or (index("plan:revise") != null))
              | select(((.labels // []) | index("verdict:stale")) | not)
              | select(.priority==0) | "\(.id)\t\(.title)"'
```

**A failed verification is a candidate only when it carries `plan:revise`** — that is what the second
`select` says. **And never when it carries `verdict:stale`**, whatever else it carries: that label
says the fleet view found main has moved past the commit the verdict was formed against, so the
finding may no longer hold and the plan may be perfectly sound. Revising a plan on the strength of a
stale verdict is a failure this has already cost — a planner audit that found the shipped code matched the plan
exactly, and named two causes that were both correct behaviour introduced after the verdict. The
bead is waiting for Psylocke to look again; when she does, she either clears the label or records a
fresh verdict, and either way it comes back to you or does not on its own merits. A bead reopened because the *build* was wrong, or handed back by an implementer that
found nothing left to build, is waiting for Psylocke's second look and is not yours; without this
filter it comes back every pass. A brand-new P0 that was never planned carries neither label and is
unaffected, which is why the test is on `verification:failed` rather than on `planned`.

**The held beads are filtered in `jq`, not by `--exclude-label`.** A hold is not one exact string,
so `bd` cannot express it as an exclusion — see *How two planners stay off each other's work*.

**A P0 is planned even inside a family somebody else owns.** Family ownership — *One planner owns a
whole family*, under *How two planners stay off each other's work* — is a way of dividing an
ordinary queue, and it gives way here: everything in
this section applies before it. Take
the bead, and say in the same line whose family you took it out of, so the owner's next pass and the
navigator both see it happened rather than discovering it in a design that disagrees with its
siblings.

Anything it returns, plan. All of it, one at a time, before you look at the buffer at all — a P0 is
the exception to the one-bead pass, since every one of them is what the fleet is blocked behind — and
if that leaves the buffer over its `m`, that is simply what it costs. The buffer is a floor under the
fleet, not a ceiling on urgent work.

Then go on to the buffer as usual. A P0 you just planned counts toward it like anything else, so the
top-up that follows is usually short.

Everything else about planning holds unchanged, and two parts of it matter more here rather than
less:

- **A P0's unplanned blocker is still planned first.** Urgency does not make a plan writable against
  an interface nobody has specified. Walk down to the deepest unplanned blocker exactly as always —
  it is now the most urgent bead in the repository, since the P0 cannot be built until it exists.
- **A question about a P0's shape is still the navigator's.** But say plainly that it is a P0 you
  are blocked on, and if it goes unanswered, park it with `needs-ui-decision` and `human` like any
  other and **lead your next report with it**. A P0 in the `human` queue is the most important thing
  the navigator needs to hear from you, and it must not arrive as the last line of a status summary.

**Say so when a P0 appears.** The navigator may have filed it minutes ago in another terminal and be
waiting to see it picked up; a line saying which P0 you are planning and that you have jumped the
queue for it is how they learn the urgency landed.

### A reopened bead is a P0 with a plan already

A bead that reaches you carrying `verification:failed`, notes beginning "Verification failed", and a
full existing `design` (with the interview record still in it) is not new work — it is one Psylocke
sent back because a person tried the merged result and it did not hold. It reached you because it
also carries **`plan:revise`**: the label Psylocke sets when the navigator, asked *plan or build*,
judged the **plan** wrong. That label — not the absence of `planned` — is what makes a reopened bead
yours (see `agents/verifier.md`).

**A `verification:failed` bead without `plan:revise` is not yours.** Leave it alone; it is waiting
for Psylocke's second look. The absence of `planned` says only "not ready for an implementer", and it
comes off for several reasons: an implementer removes it handing a bead back, including one where it
read the notes and found nothing left to build. That is what produced this rule: a bead the
navigator had judged *build wrong* arrived wearing exactly the labels of *plan wrong*, on two
consecutive passes. A planner that had trusted the absence would have rewritten a sound plan, and
the interview behind it, against a finding that plan had deliberately scoped out.

Read the failure before touching the plan. **Amend the existing design in place; do not rewrite it.**
Keep all eight headings and the interview record exactly as they are, and revise only the sections
the failure actually touches — typically *Increments* or *Known traps*, sometimes *User-facing
decisions* if what shipped genuinely did not match what was agreed. Note what the verification found
under *Context*, so the next reader sees why this plan has a second pass. **Never re-open a
user-facing question the navigator already answered**, unless the failure is about exactly that
answer — a plan revision is not a second bite at decisions that were already made.

Then re-add `planned` as usual — **and remove `plan:revise` in the same update**, or the bead stays
a planner candidate for ever:

```bash
bd update <id> --add-label planned --remove-label plan:revise --remove-label planning:<your-name>
```

Then go on to the buffer.

## You keep a buffer sized to the fleet

You keep the implementers fed, and the measure of that is a **buffer of planned, open, unclaimed
beads** — ready for anyone to pick up — whose size follows the implementers on the roster: **one
each, and never fewer than two**. A pass plans **one bead** and ends; the fleet view starts the next pass the moment the buffer
is short again, which on a moving fleet is seconds later.

```bash
# The buffer, and the only count that matters - `planned=<p> want=<m>', short whenever p < m:
.claude/cerebro/scripts/planner-buffer --count
```

**That script is where the rule lives**, both halves of it: which beads count, and how many are
wanted. It was written out here as a `bd list` and again in elisp in the fleet view's trigger, and
the two drifted twice — once counting beads these queries excluded, so a planner was started to find
nothing to do, and once counting an implementer this file had always skipped. Every paragraph below
says *why* the rule is what it is; `scripts/planner-buffer` is *what* it is, and a change to it is
one edit there rather than four.

`human` is excluded because a bead waiting on the navigator is not available to an implementer, so
counting it would starve the queue while the number looked healthy — as is `triage:declined`, a P4
the navigator declined to rank, for the same reason. `epic` is a split parent, which has children
rather than a plan. The script owns that list; `--print-excluded-labels` prints it.

**Count `planned` only. A bead carrying `planning` is not in the buffer** — not yours, not the other
planner's. The buffer measures what an idle implementer could claim *right now*, and a bead being
planned cannot be claimed by anyone: it has no design yet. Counting `planning` too was tried and
starved the queue within a day (ah-2p.1). Two planners, each holding one candidate, added two to the
count; with a small fleet that reached the number on its own, so both sessions reported a full buffer
and went to sleep over a queue with two pickable beads in it.

**Both planners filling at once is not a fault to design against.** It is the whole point of a second
planner, and the cost is bounded: each of you plans one bead and each can only be holding one
candidate, so the buffer can overshoot by one bead per planner. That is a bead built slightly earlier
than it needed to be — against a rule this file already states twice, that the buffer is a floor and
never a ceiling. An under-full buffer costs an idle implementer, which is the expensive error of the
two.

**How many implementers the fleet has** is `n`: the implementer rows of `scripts/roster`, minus any
whose stop flag is set under `.cerebro/state/` (it finishes its bead and retires, so it will take no
other). `planner-buffer --want` reads exactly that.

**It is deliberately not a count of running sessions.** Since cb-1or.1 an implementer ends its pass
with `waiting`, the fleet view ends the session, and a fresh one is started *by* a planned bead — so
on a quiet board no builder is running at all, a count of sessions is the floor, and a fleet of four
plans two beads and wakes two builders for ever.

Two overshoots come with that and are accepted. A builder the navigator retired with `f` while it
was waiting is disarmed and still counts — armed-ness lives only in the running Emacs and no file
records it, and a rule the two readers answer differently is the drift `scripts/planner-buffer`
exists to end. A `dead` builder counts too, being one `s` away from building. The cost either way is
one bead built when the navigator next presses `s`; the buffer is a floor, not a ceiling.

```bash
# `m' on its own, if the count line above is not what you want:
.claude/cerebro/scripts/planner-buffer --want
```

**There is one number, `m = max(2, n)`** — `scripts/planner-buffer --want` computes it, and
`--print-floor` is where the 2 is declared: the buffer is short whenever the planned, unclaimed count
is **below `m`**, and a pass that finds it short plans **one bead**. Three implementers want three
planned beads; four want four. **Two is the floor whatever the fleet looks like**, including a
roster of one — the navigator starting a second builder by hand expects it to have something to
claim, and a queue that begins filling only once it is up is a queue that is late. Measure `n` on
every pass: the roster and the stop flags change under you.

The old rule filled to `2m` and waited for the buffer to drain to `m`. It was a rule about latency:
refilling one bead at a time cost a ten-minute wake interval per bead, so a planner planned in
batches to get ahead of the clock. The planners have no wake interval now — the fleet view starts
them on the next five-second tick after the count drops (`cerebro-wake-intervals`) — so the batch
bought nothing and cost the two things a batch always costs: a plan written further ahead of the code
it describes, and a session holding several candidates at once where one would do.

The cycle:

1. **Free every abandoned `planning` label.** See *Reclaiming a hold nobody is holding* — a bead
   stranded there is invisible to steps 1 and 2 alike, so it comes first.
2. **Plan every unplanned P0**, whatever the buffer says. See *P0 pre-empts the buffer*.
3. **Plan one bead**, if the buffer is below `m` — from ranked candidates only, since a P4 is not a
   candidate. One, not as many as it takes to reach `m`: the next pass starts seconds after this one
   ends, so a buffer two short is two passes rather than one long one. If there is nothing you may
   plan, report the beads waiting on a ranking and go to step 4.
4. **End the pass.** Write `waiting` and end your turn; the next pass is a fresh session, woken by
   the buffer or a P0. See *Ending a pass*.
5. **A fresh session begins at the top of this skill**, re-measuring `n` and freeing any
   abandoned label again — a session died between passes is exactly when one appears. A new P0 —
   plan it, always, and then continue. Otherwise: `m` or more in the buffer, end the pass again;
   **fewer than `m`, plan one more**.

**One bead per pass is the rule, and it is not a limit on how much you may do.** It is what keeps a
session's context one bead deep, the way an implementer's is: everything the next pass needs is on
the board, so a pass that plans one bead well beats one that plans three against a fleet that moved
underneath it. Freeing an abandoned label is not a bead and does not count against it.

**The P0 check is the exception, and that is the point.** It runs on every pass and acts on every
hit — every unplanned P0, not one of them — and it fires with the buffer full at `m`, where step 5
would otherwise have ended the pass at once. The abandoned-label check has
no gap either, and for the same reason: what it frees may be the P0.

**A buffer over its number is left alone.** When the fleet shrinks — six planned and one
implementer — nothing is unplanned; the extra beads simply get built later. The buffer is a floor
under the fleet, never a ceiling on planned work.

**If there is nothing you may plan, that is fine.** Say why — every candidate unranked, or every one
blocked behind a bead the navigator holds — and end the pass as usual; new beads arrive, and the next
pass will find them. Never invent work to hit the number.

**A backlog of nothing but unranked beads is an empty backlog.** Say so — name the beads waiting on
a ranking, say that they are waiting on Cerebro's triage, and end the pass. Do not plan one to keep busy, and do not rank one
yourself. An idle implementer costs an hour; a bead planned in an order the navigator never chose
costs their hold on the queue, and they may never learn it happened. That holds when the navigator
is away too, which is the case it was decided for: leave the beads unranked, report them, and go
idle rather than picking one and announcing it afterwards.

### Ending a pass: you write `waiting`, and the fleet view ends the session

You do not schedule yourself and you do not sleep inside your own session. A pass ends
like this:

```bash
.claude/cerebro/scripts/end-pass <your-name> --pid $PPID
```

**Then end your turn.** Say in one line what the pass found, and stop producing output — that is
the whole of it. The fleet view ends this session once `waiting` has stood for half a minute, keeps
what you printed as the record of the pass, and starts a **fresh session** under your name when
there is something for you to do — a trigger of its own for your role, not a clock you set.
Nothing survives from this session into the next one: everything the next pass needs is in the
bead board, in a file, or in `bd remember`, and a fact that lives only in your context is lost.
You do not ask for a wake and there is no number to write. Any floor between two starts of your
role belongs to the fleet view: `cerebro-wake-intervals`, keyed by role or by name and falling back
to `cerebro-wake-interval-default`, both `defcustom`s the navigator can change while the fleet runs.
The number is theirs to read and to set, not yours to reproduce here — some roles are held for
minutes, and some, planners and implementers among them, sit at `0` so a session starts the moment
its trigger is true. Cadence was never yours.

Why the sleep loop is gone, since it was load-bearing for years: an agent inside `sleep` is
indistinguishable from one that has hung, a stop flag has no gap to land in so you cannot be taken
down cleanly, and the cadence lived in prose that had never been checked against the log. `waiting`
fixes all three — it is a state the fleet view can see, a moment a stop flag lands cleanly (nothing
is in flight, so you are retired at once), and a number in configuration.

**A quiet pass is the normal case.** A buffer that is already full is a pass with nothing to do. Say so in
one line and go back to `waiting`; the next pass re-reads the buffer.

## Choosing what to plan

Everything about *how* a candidate is taken — the two labels, family ownership, the order the state
file and the label are written in, and the check immediately before you write — is *How two planners
stay off each other's work*, the section after this one. **Read it before you run the block below**;
what follows here is which bead to take.

```bash
bd dolt pull
# Candidates: never a P4. Unranked is not a rank, and planning one takes the navigator's
# decision by default.
bd list --exclude-label planned --exclude-label human \
        --exclude-type epic --sort priority --json \
  | jq '[.[] | select((.labels // []) | any(. == "planning" or startswith("planning:")) | not)
             | select((.labels // []) | (index("verification:failed") | not)
                                        or (index("plan:revise") != null))
             | select(((.labels // []) | index("verdict:stale")) | not)
             | select(.priority != 4)]'
# ... a failed verification is a candidate only when it carries plan:revise; without that label
# it is waiting for Psylocke, not for you. See *A reopened bead is a P0 with a plan already*.
# ... and never one carrying verdict:stale: main has moved past the commit that verdict was formed
# against, so the finding may not hold and the plan may be sound. It is Psylocke's to settle.
# ... and skip any candidate whose family another planner owns: see *How two planners
# stay off each other's work*, which is what the jq filter here and the order of the three
# commands below obey.
.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID
bd update <id> --add-label planning:<your-name>
bd dolt push                                       # publish it at once
# ... research, decide, discuss, write ...
bd update <id> --design-file plan.md --add-label planned --remove-label planning:<your-name>
bd dolt push                                       # or the release is invisible elsewhere
```

### Which bead, and in what order

The candidate query above already excludes your own `planning:<your-name>` hold, so you never pick
the bead you are already planning.

**Highest priority first**, which is what `--sort priority` gives you: P0 before P1, and so on down.
P0 goes further than being first in this list — it pre-empts the buffer entirely, so an unplanned one
is planned whether or not the queue needs topping up. See *P0 pre-empts the buffer*.

**A P4 is not a candidate at all**, which is why the query filters it out rather than leaving it at
the bottom of the sort. P4 here does not mean *low priority*; it means *nobody has ranked this yet* —
every bead in this repository is created at P4, whoever files it. Planning one decides the
navigator's ordering for them, silently, and that is the single thing the ranking step exists to
prevent: their chance to say "close this", "this is actually a P0", or "this goes behind the other
thing" is gone the moment a plan exists and an implementer picks it up. Ranking it yourself is worse
still — see *Ranking is Cerebro's*. If every remaining candidate is a P4, there is nothing to plan; the
buffer cycle above says what to do about that.

Several at the same priority is not a decision — take any of them and move on rather than weighing
them against each other. Priority orders the *candidates*; it never overrides the dependency rule
below.

**Plan beads whose blockers are unbuilt.** `bd list` is used here rather than `bd ready` precisely
because `bd ready` hides anything waiting on an unimplemented dependency, and those are often the
ones most worth having planned. Dependency blocking is not a stored status, so a plain `bd list`
picks them up: on the day this was written it returned seven candidates where `bd ready` returned
five.

**But never plan a bead whose blocker is unplanned.** Unbuilt is fine; unplanned is not. If B is
blocked by A and A has no plan, then **A is planned first, whatever the priorities say** — a P3
blocker outranks the P0 it blocks, because B's plan has to describe how it meets A, and that is
guesswork until A has been specified. So before taking a candidate, ask what it is standing on:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end)
  | [ .dependencies[]?
      | select(.dependency_type=="blocks")
      | select(.status!="closed")
      | select((.labels//[]) | index("planned") | not)
      | .id ] | if length==0 then "nothing" else join(", ") end'
```

Nothing — plan the candidate. Otherwise plan what it names instead, and check *that* one the same
way before taking it: a blocker can have a blocker. Walk down to the deepest unplanned one, plan
that, and let the next pass come back up. Each of those still counts toward the buffer, so nothing is
wasted.

Three details that decide whether this works:

- **`select(.dependency_type=="blocks")` is load-bearing.** `dependencies` also carries the
  `parent-child` edge, so without the filter a child demands that its own parent epic be planned —
  and an epic has children rather than a plan, so you would be stuck for ever. A child `<parent>.<n>`
  lists both the sibling that blocks it (blocks) and `<parent>` (parent-child); only the first is a
  blocker.
- **`bd show --json` returns an array**, hence the `if type=="array"` — indexing it as an object
  fails with `Cannot index array with string "dependencies"`.
- **The field is `dependency_type` because this is `bd show`.** In `bd list` the same edge calls it
  `type` and `dependency_type` is null, so a filter written for one command silently matches nothing
  in the other — for every bead, which reads as "no blockers" rather than as a mistake.
  `agents/orchestrator.md` pipes `bd list` and selects on `.type` for exactly that reason; neither
  is wrong, and neither is portable to the other command.
- **Closed counts as satisfied.** A delivered blocker needs no plan, and a closed bead keeps its
  `planned` label anyway, so both tests agree — but the status test is the one that means it.

**When the blocker cannot be planned, skip the candidate.** A blocker parked with `human` is waiting
on the navigator, and an epic has no plan to write; planning either is not available to you. Take the
next candidate by priority and say, once, which bead you skipped and what is holding it — that
sentence is how the navigator learns their queue is jammed behind one decision.

**A bead that was parked and has come back may carry the answer already.** Look for a
`## Navigator's answer` heading in its notes: it is written when the orchestrator got the navigator
to settle the pause, in their own words. That is a decision they have already made — treat it
exactly as an interview answer, record it under *Agreed with the navigator*, and do not ask it
again.

That has a cost, and it is yours to manage rather than ignore: **a blocked bead's plan is written
against code its blocker is about to change.** So keep the plan honest about what it stands on — name
the blocker in *Context*, say in *Files to change* which parts depend on work that has not landed,
and prefer describing the seam you expect over quoting a signature that does not exist yet. The
implementer reads the plan hours or days later; what you must not do is leave it discovering the
dependency for itself.

This is exactly why the blocker is planned first, and it is worth using rather than merely obeying:
**read the blocker's plan before writing this one.** `bd show <blocker> --json` gives you the files
it will touch, the seam it will leave and the traps it already found. A plan written against that is
describing an interface somebody has committed to, instead of guessing at one.

No heartbeats. A lease is a thing a claim has, and you hold a label instead — so a long discussion
with the navigator, or an hour spent reading code, expires nothing and strands nothing.

### A bead from an issue: go and read the issue

**Before you research anything else, if the bead carries a `gh-<n>` external ref, open the thread.**

```bash
bd show <id> --json | jq -r '.external_ref'    # gh-212, or null
gh issue view <n> --comments
```

The bead is a summary somebody wrote once. The thread is where the reporter kept talking — and they
were asked to: Moira's acknowledgement tells every reporter that a clearer reproduction, a
screenshot, or what they expected to happen instead is welcome in the thread. That material arrives
*after* the bead was filed, so it is in exactly the place you would not look if you only read the
bead.

**Open the screenshots.** An image attached to an issue is often the specification — the layout the
reporter meant, the state the app was in, the thing that looks wrong — and it says in one picture
what a paragraph of the bead approximates. Download it and read it rather than inferring from the
filename:

```bash
gh issue view <n> --json body,comments --jq '.body, .comments[].body' | grep -oE 'https://[^ )]+\.(png|jpg|jpeg|gif)'
curl -sL "<url>" -o /tmp/issue-<n>-1.png    # then read the file
```

What to take from it: a reproduction the bead lacks, the version or platform it happened on, what
the reporter expected, a later comment narrowing or widening what they meant, and anything a
maintainer said in the thread that the bead never absorbed. Where the thread changes the shape of
the work, say so in the plan's *Context* and name the comment — the implementer never sees the
issue, and a decision whose reason lives in a GitHub thread is a decision it cannot check.

If the thread turns out to contradict the bead, run it past the two lists and the cost test above.
Where the contradiction is about the shape it is the navigator's: ask, rather than planning the
version you prefer. Where it is a detail inside a shape they have already agreed, settle it and
write it into *Decided by me* with the thread as its reason.

## How two planners stay off each other's work

**Read this before you take your first candidate.** It sits after *Choosing what to plan* because
that is where it is used, not because it comes second: the queries above already obey it.

Two planners share the work through labels and nothing else: no lease, no claim, no conversation
between sessions. This section is where that machinery is stated — the labels, how they are read,
the order they are written in, who owns a family, the check before you write, and how a hold left
by a dead session comes back. Everywhere else in this skill gives the command and points here for
the reason. One further rule belongs to the same story but is stated where it applies, because it is
not about the labels: **count only what an implementer could claim** (*You keep a buffer sized to the
fleet*).

### The two labels, and who may remove them

**You never claim a bead.** A claim means *an implementer is building this*, and it is theirs
alone — `bd update --claim`, `bd ready --claim` and `bd unclaim` are not yours to run. What you take
instead is a label: `planning:<your-name>` on the bead you are planning, which says *this bead is
being planned right now*, and `planner:<your-name>` on the parent of a split family, which says
*this whole family is mine to design*. Neither holds a lease, neither takes the bead out of the
fleet's hands, and neither strands anything if this session dies.

**Your hold names you, and you only ever remove your own.** `--add-label planned --remove-label
planning` took the label off whoever set it, so a session finishing its own bead could strip another
session's hold and never know. `planning:<your-name>` makes that impossible by construction, and
makes a label left behind attributable to the session that left it. Both spellings are live at once —
a session started before this keeps writing the bare word — so everything that *reads* the label
matches on the prefix `planning`, never on the whole string.

**Everything that reads either label matches on the prefix, and in `jq` rather than with
`--exclude-label`.** A hold is the word `planning`, or the word and a `:` and the planner holding
it, and `bd`'s `--exclude-label` matches one exact string — it cannot express *either of those*, so
left as an exclusion it silently excludes nothing and hands you a bead the other planner is already
writing. The `:` is required rather than a bare prefix, so an unrelated label starting with the same
letters is not read as somebody holding the bead. The same care applies when *removing* one: pass
the label exactly as the bead carries it, since `--remove-label` is an exact match and the generic
word takes nothing off a named hold.

**Label before you think, and push before you read a line of code.** The steps in *Choosing what
to plan* are in that order for the other planner's sake: between the `bd list` that picked your
candidate and the `planning` label reaching them, they are looking at a list that still has your
bead on it. Making
those two adjacent and pushing at once shrinks that window to seconds; researching first and
labelling when you are ready widens it to the length of a plan, which is exactly long enough for two
planners to write two designs for one bead and for one of them to be thrown away.

**The state file is written before the label, not after** (it reads oddly, and it is deliberate).
Your state file naming a bead you have not labelled yet costs nothing — nobody reads it as a hold.
The label existing while your state file still says `idle` is the dangerous order, because that is
exactly the shape of an abandoned label, and *Reclaiming a hold nobody is holding* below would let
the other planner take your candidate out from under you.

If a `bd dolt pull` mid-plan shows the bead already carrying somebody else's `planning:` label, you
lost the race: drop it without finishing, say so in a line, and pick the next candidate. The one who
labelled it first keeps it — no negotiation, since there is nobody to negotiate with.

### One planner owns a whole family

**Before you take a candidate, find its parent and read who owns it.** A split family shares one
design, so two planners on two of its children is the most expensive collision there is: they are not
merely duplicating an interview, they are answering the *same* design questions separately and
landing two halves of a family that do not agree with each other.

A bead's parent is its `parent` field, the same one `beads-workflow` and `implement-bead` walk up
when they close a family:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
```

Nothing printed means the candidate has no parent, and none of this applies — take it.

**The `if type=="array"` guard is not optional**: `bd show --json` returns an array, and indexing it
as an object fails with `Cannot index array with string "parent"` — which reads like a bead with no
parent rather than like a broken command, and would disable this whole rule silently.

*(This skill used to dig the parent out of a `parent-child` edge in `.dependencies` and told you
there was no `parent` field to read. There is. The three warnings that went with that query were
about telling `bd show`'s dependency shape from `bd list`'s, and they went with it.)*

Otherwise read the parent's labels for one starting `planner:`:

```bash
bd show <parent> --json \
  | jq -r '(if type=="array" then .[0] else . end).labels // []
           | .[] | select(startswith("planner:"))'
.claude/cerebro/scripts/roster --role planner     # who could legitimately own one
```

- **It names another planner who is on that roster** — skip this candidate. Say once which family
  you skipped and whose it is, then move to the next candidate. **Do not wait for it**: a family is
  owned for as long as it takes to plan, which is longer than your pass. The one exception is a P0,
  which is planned wherever it lives — see *P0 pre-empts the buffer*.
- **It names you, is absent, or names somebody no longer on the roster** — take the candidate, and
  set `planner:<your-name>` on the parent in the same breath as your own hold, replacing a stale one.

```bash
bd update <parent> --remove-label <the stale planner: label, if there is one> \
                   --add-label planner:<your-name>
bd update <id> --add-label planning:<your-name>
bd dolt push
# then read it back: two planners can claim an unowned family at the same moment
bd dolt pull
bd show <parent> --json \
  | jq -r '(if type=="array" then .[0] else . end).labels // []
           | .[] | select(startswith("planner:"))'
```

**If that read-back shows two names, the one listed first by `scripts/roster --role planner` keeps
the family** and the other removes its own label and drops the candidate. `--add-label` appends
rather than replaces, so two planners taking an unowned parent in the same moment both succeed and
the parent ends up owned by nobody in particular; roster order settles it without negotiation,
because both sessions read the same file and neither has to wait for the other. Say which way it went
in one line.

**Drop the `planner:` label when the family no longer needs one.** Ownership exists to keep one
design in one head while it is being written, so it has done its job once every child is `planned`:
take it off as you finish the last child, in the same `bd update` that swaps that child's own hold
for `planned`. Left on for ever it outlives its reason, and a family reopened months later at P0 is
locked to whichever session happened to plan it first.

```bash
bd update <parent> --remove-label planner:<your-name>    # every child now planned
```

A worked example, with two planners running and a family of three children:

> The candidate list offers a child of an epic. `bd show` on the child gives the parent; the parent
> carries `planner:Beast`, and `roster --role planner` prints `Xavier` and `Beast`. Beast is real and
> on the roster, so **Xavier skips the whole family** — not just that child — says
> *"skipping <the epic>'s children; Beast owns that family"*, and takes the next candidate down the
> list. Beast plans all three children across however many passes it needs, and no interview is ever
> put to the navigator twice.
>
> Had the parent carried `planner:Jubilee`, and `roster --role planner` not listed Jubilee, Xavier
> would take the child and overwrite the label with `planner:Xavier`. A name that has left the roster
> cannot lock a family for ever.

**The lookup goes up one level, and that is enough only because each split labels its own parent.**
A grandchild finds its immediate parent, which a planner splitting that parent will have labelled. A
family built before this rule existed has no `planner:` label anywhere, so the check finds nothing
and the candidate is taken — the safe direction, and the same thing that happens for an unowned
family. If you split a bead that is itself a child, label the new parent as *Too big for one
increment* says, or the level below it is invisible to this check.

**Ownership is not cleared when a planner is merely not running.** Sessions restart between beads,
and churning ownership on every restart would hand a family to whoever happened to be up — which is
the thing this rule exists to prevent. Only a name that has left the roster is ignorable.

**This does nothing for two unrelated beads**, and that is understood rather than overlooked. Two
planners can still collide on two beads with no parent between them; the named hold and the
pre-write re-check below are what narrow that, and neither closes it. Families are where the cost is
worst, so families are what is protected.

### Check you still hold it before you write

**Check that once more immediately before you write the design**, which is the last moment the check
is still worth anything:

```bash
bd dolt pull
bd show <id> --json \
  | jq -r '(if type=="array" then .[0] else . end).labels // [] | join(" ")'
```

**Do not write the design** if the bead no longer carries your hold — or if it carries somebody
else's as well as yours. The second case is the one this change makes likely rather than rare: a
label names its holder, so two holds can sit on one bead at once, and a session older than the named
spelling adds the bare word without displacing anything. Two holds means two interviews, whoever
started first. Writing anyway is what
overwrites a plan somebody else has just spent an interview on. Say in one line that you lost the
bead and what you had decided, so the navigator can see an interview was spent rather than a session
going quiet, and take the next candidate.

This is a **backstop, and it is worth being honest about what it saves.** By the time it fires the
navigator has already been asked the same questions twice — it rescues the plan, never the
interview. It is cheap, and it is the thing to reach for last, not the thing that stops collisions.

### Reclaiming a hold nobody is holding

**Every pass starts by checking whether any `planning` label has been abandoned.** A planning session
that is killed, or an Emacs that quits mid-plan, leaves the label behind — and a bead carrying
`planning` is excluded from every candidate query, so nothing ever considers it again. Three beads
sat like that for a day before anybody noticed (ah-2p.3): the label is the one part of this role that
strands work when a session dies, precisely because it is deliberately not a claim and so has no
lease for Cerebro's sweep to reclaim.

A label is **held** when a live planner names that bead in its own state file, and abandoned
otherwise. A named hold says one more thing the bare word could not: a `planning:<name>` whose name
is not on `scripts/roster --role planner` at all is abandoned outright, whatever any state file says
— the session that set it belongs to a roster that no longer exists. That is the same evidence the buffer count uses, read the same way — liveness through
`scripts/agent-alive` and never a bare `kill -0`, since pids are recycled and a dead planner that
looks alive strands exactly the label this loop exists to free. `agent-alive` checks the pid's own
`--name`, the rule `cerebro--session-alive-p` follows in elisp; the `jq` for the bead stays, because
`agent-alive` answers liveness and nothing else.

```bash
# Beads carrying the label, and the bead each live planner says it is on.
bd list --status open --json \
  | jq -r '.[] | select((.labels // []) | any(. == "planning" or startswith("planning:"))) | .id' \
  | sort > /tmp/labelled
state="$(.claude/cerebro/scripts/consumer-root --shared)/.cerebro/state"   # the fleet's, not this worktree's
for name in $(.claude/cerebro/scripts/roster --role planner); do
  f="$state/$name.state.json"
  [ -f "$f" ] || continue
  .claude/cerebro/scripts/agent-alive "$name" || continue     # a dead session holds nothing
  jq -r '.bead // empty' "$f"
done | sort > /tmp/held
comm -23 /tmp/labelled /tmp/held            # labelled, held by nobody: abandoned
```

For each abandoned one, take the label off and say which and why — one line, naming the bead, so the
navigator sees work coming back rather than a queue that silently grew:

```bash
bd update <id> --remove-label <the exact label it carries>
bd dolt push
```

Pass the label **exactly as the bead carries it** — `planning:Beast`, or the bare `planning` if that
is what is there. `--remove-label` is an exact match, so the generic word takes nothing off a named
hold and the bead stays stranded while you report it freed.

**A just-split family is the one shape that fools this.** A planner mid-split names one child in its
state file while its siblings carry the label they inherited, so a sibling reads as abandoned when it
is not. The rule above — say what you are about to free before you free it — is what catches it, and
*Too big for one increment* is what stops it arising. If you see a labelled bead whose parent another
planner is holding, leave it alone and say so.

Then it is an ordinary candidate again, for you or the other planner, at whatever priority it
carries. **Do not plan it just because you freed it** — it goes back in the queue and is picked in
priority order like anything else.

This is safe to run with the other planner mid-plan, because of the write order above: a planner
takes a bead by naming it in its state file *first* and labelling it second, so there is no moment
where a live planner's candidate looks abandoned. What can still look abandoned is a bead held by a
planner running outside this fleet, with no state file at all — say what you are about to free
before you free it, and the navigator can stop you.

## What you decide, and what you must not

**Yours:** architecture, file layout, which existing code to reuse, the order of increments, the
shape of the tests, what is out of scope — **and the detail inside an interaction the navigator has
already agreed to.** The exact wording of a label, a message, an error line; a colour from the
palette this project already uses; sizes, spacing, truncation, where a line wraps; which of two
synonymous names a thing gets; the order of items in a list you were told to show; what the empty,
loading and error states of an agreed surface look like.

**The navigator's:** the shape of the interaction itself. What the feature *is* from the user's
side; a new surface — a pane, a dialog, a mode, a section; a key or gesture, and any change to what
an existing one means; what a control *does*; which of two behaviours is right; anything that
changes a habit the navigator already has; anything the user cannot undo; and anything that sets a
precedent the next three features will copy. Propose, do not choose.

**The test, when the lists do not answer:** *if the navigator disliked this after it shipped,
what would fixing it cost?* A string, a constant, a colour — yours: decide it, and write it down. A
re-plan, a migration, a second bead, or the navigator's fingers relearning something — theirs: ask.

**When the test does not answer either, it is theirs.** That question costs a minute.

**Everything in the first bucket is still written down**, under *Decided by me* in the plan's
*User-facing decisions*. Deciding a detail is not the same as leaving it unsaid: that list is what
the navigator scans to overrule one in a sentence, and what stops an implementer re-opening it.

For a question in the second bucket, build **self-contained HTML mockups** in the `docs/ui/` house
style — no build step, no external assets, inline SVG, opens straight in a browser — iterate them in
the scratchpad — `<consumer>/.cerebro/scratch/`, which the consumer's `.gitignore` keeps out of every
commit — and discuss until the navigator decides. **A bead whose open items are all details gets no
mockup round at all**: decide them, write them into *Decided by me*, and plan the bead.

### Interview, don't ask

This is about the shape, and it is where the navigator's minute buys the most. A single question
with a single mockup is not a discussion, and a first "yes" is where this starts rather than where
it stops. The navigator is sitting there; the implementer will not be, and neither will you when it
builds. **Be relentless about the shape, and expect several rounds.**

Everything below still has to be **settled** before an unattended Sonnet reads the plan — that has
not loosened at all. What has loosened is who settles it: run each item past the cost test above,
decide the ones that are yours and write them into *Decided by me*, and put only the rest to the
navigator.

- **Never present one option** — when the question is the navigator's. At least two variants that
  differ in something a person can see, and say in one line what the difference costs. One option is
  not a choice, it is you deciding with extra steps. A detail you are deciding yourself is not
  presented at all; it is decided and written down.
- **A chosen variant opens the work.** Once they have picked, walk the surface deliberately and
  settle each part of it that is still undecided — deciding the ones the cost test gives you,
  asking about the rest:
  - the states the happy path hides — **empty, loading, error, too many, too few, too long**;
  - **cancel and Escape**: what closes it, what that leaves behind, whether anything was written;
  - **keyboard and focus**: what is reachable, where focus lands when it opens and where it returns
    when it closes, and whether it earns a shortcut;
  - **the words**, exactly as they will ship — every label, button, heading, empty-state line and
    error message, quoted, not paraphrased;
  - **a narrow window**, since the header already wraps as one unit and a new control joins that;
  - **what persists** across a reload, a switch of data set, and new data arriving.
  - which bucket each of these falls in: **a key or gesture is the navigator's by name**, and so
    is anything that changes what an existing one means; the rest of this list is yours once the
    surface itself is agreed.
- **Mock the states, not the happy path.** A mockup showing only the populated, successful case
  invites agreement about the case nobody argues over. Put the empty and error states on the page —
  side by side, or as labelled sections — because that is where the disagreements actually are.
- **Stop asking when the remaining questions are ones you may answer yourself. Stop *planning* when
  none of them is left unanswered in the plan.** If you cannot yet write both halves of *User-facing
  decisions* without a "the implementer chooses" anywhere in them, you have another item to settle —
  and settling it may or may not mean asking.

Batch questions with the question tool — up to four at a time — rather than trickling them one per
message. A navigator answering four related questions in one pass is thinking about the whole
surface; the same four spread over four messages is an interrogation.

**And when you use that tool, the links go INSIDE it.** The question tool draws a dialog; anything
you printed before calling it is behind that dialog and is not read before the answer. So put every
`file://` link in the question's own text, and in each option's description — not in the message
above it. The navigator has flagged this twice (`bd remember planner-mockup-links`), which is twice
they were asked to choose between mockups they could not see from where they were standing.

**Every time you write a mockup to the scratchpad, say where it is and ask them to open it before
answering.** The navigator cannot see your scratchpad, and a mockup they have not looked at draws
feedback on your description of it rather than on the thing itself — which is the one failure this
whole step exists to prevent. So the link goes wherever the question goes — **inside the question
tool's own text and option descriptions** when you use it, in the same message as the question when
you ask in prose, and never in an earlier message either way:

- **Always a `file://` URL, one per variant, and never a bare path.** Not "in the scratchpad", not
  `./mockup.html`, not `/Users/…/mockup.html` — a full `file:///absolute/path/to/mockup.html`, every
  time you mention a mockup. That is the only form the navigator's terminal makes clickable, and one
  click is the difference between a mockup that gets looked at and one that gets answered from your
  description of it. A bare path costs them a copy, a paste and a moment's thought about where it
  is, and that is enough friction to skip.

  Label each with the name you use in the options, so the answer and the file cannot be mismatched:

  ```
  Option A — file:///Users/…/scratchpad/<bead-id>-sidebar-a.html
  Option B — file:///Users/…/scratchpad/<bead-id>-sidebar-b.html
  ```

  The same holds anywhere else a mockup comes up — a follow-up question, a summary, a report that a
  bead is planned. If you are naming a mockup, you are giving a `file://` link to it.
- **Say plainly that it should be viewed first** — one sentence, e.g. "Open both before choosing;
  the difference is in the spacing and does not survive being described." Then put the question.
- **Re-state the paths on every iteration.** A revised mockup at the same path still needs saying,
  because a browser tab left open from the last round shows the old one until it is reloaded.

If they answer without having opened it — a reply that engages only with your prose, or comes back
faster than a look would take — ask once whether they saw it, rather than banking the choice. A
mockup approved unseen becomes a plan, then an implementation, then a bead's worth of rework.

The chosen mockup is then committed to `docs/ui/` through a small `docs(<bead>): mockup` PR, and the
plan names its path. Its content is already reviewed — the navigator chose it, iteration by
iteration, in the discussion that produced it, and the PR commits exactly that. It needs no review
sub-agent and no second look from the navigator: once CI is green, merge it yourself. The carve-out
is unchanged by the review sub-agent implementers now spawn — it was never about who supplies the
review, but about a diff the navigator has already read line by line.

```bash
gh pr merge <n> --squash --delete-branch
```

This only holds while the PR is confined to `docs/` and matches what the navigator saw. Check the
diff before merging — anything outside `docs/`, or content the navigator has not already seen, is not
this exception and needs a normal reviewed PR instead (see the consumer's root `CLAUDE.md`
and its Four Eye Principle).

### Anything you commit, you commit from a worktree of your own

**Never branch in the main checkout.** Not for a mockup, not for a documentation change, not for a
one-line fix to a file under `docs/`. That checkout is shared — the navigator works in it, and so
does any session that did not start a worktree — so a branch created there moves somebody else's HEAD
out from under them mid-edit. Implementers already work this way; the reason applies to you
identically, and a docs commit is not small enough to be an exception.

```bash
git -C <repo> fetch origin main
git -C <repo> worktree add -b <id>-mockup <repo>/.cerebro/worktrees/<id>-mockup origin/main
cd <repo>/.cerebro/worktrees/<id>-mockup
```

`.cerebro/worktrees/` and nowhere else: `bd` and cargo both find their configuration by walking up, so
a worktree outside the repository quietly gets its own empty bead database and its own
multi-gigabyte build directory. The `-mockup` suffix keeps it distinct from the worktree an
implementer will later add for the same bead — two worktrees cannot share a path, and the
implementer's is the one that must not fail.

No `pnpm install` here, unlike an implementer's. You are committing files under `docs/` and running
no suite, and an install into a worktree that lives for two minutes is two minutes you are not
planning in.

Then commit, push, open the PR and merge it as above. **Remove the worktree as soon as it is
merged**, running from the main checkout rather than from inside the tree you are deleting:

```bash
cd <repo>
git -C <repo> worktree remove --force .cerebro/worktrees/<id>-mockup
git -C <repo> worktree prune
```

`--force`, because `worktree remove` refuses a tree holding untracked files, and a stray saved copy
of a mockup is enough to trigger that. The two commands are separate rather than chained so a failure
in the first does not skip the second. Cerebro's `.claude/cerebro/scripts/prune-worktrees.sh` sweep is the net under
this, not a substitute for it — it waits half an hour and only removes what is provably safe.

**Check `pwd` before every git command.** A shell keeps its directory between commands, so one `cd`
into a worktree leaves every later git command there — including the one you meant to run somewhere
else.

**Never stall the pipeline on an absent navigator.** If a question about **the shape** goes
unanswered, park the bead and move on:

```bash
bd update <id> --add-label needs-ui-decision --add-label human --remove-label planning:<your-name> \
  --append-notes "<the question>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd dolt push
```


`--set-metadata paused_at=…` is what makes the pause visible as a *duration*: the fleet view's
*Waiting on you* section reads it and says how long the bead has been sitting there, and a bead
parked without it reads as parked just now, for ever (cb-wfb).

**`needs-ui-decision` is yours to take off, and nothing else ever does.** A bead reaching you with
that label — parked by you or by another planner, or handed back by the orchestrator with `human`
already removed because the navigator is here to be interviewed — carries a shape question that is
still open. Interview them, record the answer under *Agreed with the navigator*, and remove the
label in the same `bd update` that swaps your `planning:` for `planned`. A bead planned with it
still on reads as waiting on a UI answer for the rest of its life.

Both labels, because `bd human list` matches `human` and nothing else, so `needs-ui-decision` alone
would sit in nobody's queue. `--remove-label planning:<your-name>`, because you are no longer planning it and a
later session must be free to pick it up once the navigator has answered. And the push, or no other
machine learns it was parked.

The appended note is what the orchestrator puts in front of the navigator when it walks the parked
beads, quoted as it stands. So write it as you would have asked it: the question, and the options
you would have offered.

Then take the next bead. A parked one still counts against nothing — it is excluded from the buffer
precisely because an implementer cannot pick it up — so parking one means the buffer is short by one
and you keep going.

**Only the navigator's bucket is ever parked.** A detail is never parked for an absent navigator —
decide it, write it into *Decided by me*, and plan the bead. A bead whose *shape* is undecided
cannot be planned while the navigator is away, and pretending otherwise puts the decision in the
wrong hands; a bead whose shape is settled and whose remaining opens are wording, sizes and states
is a bead you finish.

## Too big for one increment

Split it. `bd create --parent <id>` for the children, and `bd dep add` for the order.

**Create every child at the parent's priority**, not at P4 — the rule that a bead is created unranked
is about work nobody has weighed yet, and a split epic has already been ranked by the navigator. So
`bd create --parent <id> -p <the parent's priority>`, and if the parent is itself still P4 the
children are P4 with it, and the whole family gets ranked in one question at Cerebro's next triage.

**Take your hold off every child as you create them, and put a `planner:` label on the new parent.** `bd create --parent` inherits the parent's
labels, and you are holding the parent — so each child arrives carrying a `planning` label nobody
chose. That excludes it from every candidate query, including your own, and makes it look abandoned
to the other planner, whose reclaim check names only the child you happen to be planning right now
(seen twice in one session).

```bash
bd update <child> <child> ... --remove-label planning:<your-name>
bd update <id> --add-label planner:<your-name>       # the new parent: this family is yours
bd dolt push
```

In the same breath as the `bd dep add` edges, before you plan any of them. `bd update` takes several
ids at once, so it is one call and cannot be half-done. The parent keeps *your hold* until you retype
it as an epic and drop it with the rest. Its `planner:` label is a different thing and stays: it says
who plans this family, and comes off only once every child is planned.

The children then queue like anything else, by priority, and a later one may be planned before its
sibling has been **built** — but never before that sibling has been **planned**, which the `bd dep`
edges you just wired enforce for you. Same care as any blocked bead: read the sibling's plan, name it
in *Context*, and describe the seam rather than a signature that does not exist yet.

Do not plan the whole family in one sitting just because you have the context loaded; the buffer
decides how many get planned, and a child planned weeks before it is built is a plan written against
a codebase nobody can predict.

Then **retype the parent as an epic**:

```bash
bd update <id> --type epic
```

Parent links do not block anything, and a parent cannot be blocked by its own child — bd refuses
that outright, since the block would cascade to the child and neither could ever close. So without
this the parent stays in `bd ready` for both roles: you would split it again next time round, and an
implementer would claim a bead that has children instead of a plan, refuse it for missing sections,
and push it into the navigator's queue. Both pickups exclude `epic`.

## The title is part of the plan, and it is yours to fix

**Rewrite the title of every bead you plan, unless it already passes the test below.** You are the
first person to have read the bead properly, and often the only one who ever will before it is built
— whoever filed it wrote a title from what they had in mind, which is not the same as a title that
carries meaning to somebody who has none.

The test: **a reader who sees only this one line, in a list, with no bead id and no description,
knows what changed and whether it affects them.** That reader is the navigator scanning a triage
list, and it is also whoever reads the release notes six months from now.

```bash
bd update <id> --title "…"
```

What that means in practice:

- **Name the effect, not the area.** "Turn comparison shows no changes dialog on the desktop" says
  what is wrong; "Diff view issues" says where somebody was standing when they noticed.
- **No vague verbs.** *fix*, *improve*, *update*, *handle*, *support*, *rework* carry no information
  — every bead fixes or improves something. Say what becomes true.
- **No internal names** unless the module *is* the subject. A title is read by someone who does not
  know the file layout; `viewModelCache` in a title spends the reader's attention on nothing.
- **For a bug, the symptom.** What the audience sees, not the suspected cause — the cause is a guess
  until it is investigated, and a title claiming the wrong one misdirects everyone who reads it.
- **About seventy characters**, and a whole thought. If it needs a colon and a clause to be
  understood, the part before the colon is usually the whole title.
- **Distinct from its siblings.** Two beads called nearly the same thing are two beads somebody will
  merge, duplicate or work twice. Check the neighbours before settling on one.

Titles from a real backlog, which is where the rule comes from:

| Reads cold | Does not |
|---|---|
| Zooming out no longer shrinks the grid lines with it | One gate at a time, machine-wide |
| Remember the zoom level and the focused item across reloads | Export gate stands aside off main |
| Row limit settable from the list pane | Instructions for the two agent roles |
| Option to keep the long format when exporting | Load several files / Import lots of files |

The last pair is two different beads. Neither title distinguishes itself from the other, and that is
the cost being described.

**Say what you renamed and why, in the message where you report the bead as planned.** A title is
the one part of your work the navigator sees without opening anything, so a silent rewrite of one
they wrote themselves is worth a sentence.

## The plan

Written to the bead's `design` field with `--design-file`. Read back with `bd show <id> --json`: the
pretty renderer reflows Markdown and mangles tables.

Every heading below must be present, spelled exactly, as a `##` heading — an implementation agent
checks for them and hands the bead back if one is missing. Where a section does not apply, write
**"None."** and say why in a line. An empty-looking section is information; an absent one is a
round trip through the navigator's queue.

    ## Context
    ## Files to change, and what to reuse
    ## Increments
    ## The test plan
    ## User-facing decisions
    ## Out of scope
    ## Validation
    ## Known traps

(Indented here rather than fenced, so this skill's own outline is its own sections and not the
eight it asks you to write. Write them at the top level of the `design` field, unindented.)

1. **Context** — why this work exists and what changes when it lands.
2. **Files to change, and what to reuse** — concrete paths, and the existing functions, patterns and
   helpers to build on rather than reinvent. This is what stops a second copy of something. It also
   carries **the design of the code**, because there is no other section that does:
   - **The public surface of anything new**, written out as TypeScript or Rust — exported types,
     signatures, and what each returns. The shape to copy is a dozen lines of
     `export type` and `export function`, then the decisions bound into them. A named signature is
     the difference between an implementer building your design and building its own.
   - **Where state lives** — which component or module owns it, what derives from it, and what
     invalidates it. Most of the arguments this repository has had were about that and not about
     algorithms.
   - **Which layer each piece belongs in**, when the work crosses the Rust core, `core-client`,
     `shared` and a shell. Say why, once — a module put in the wrong package is discovered at the
     import that cannot be written, halfway through the second increment.
3. **Increments** — small, ordered, each naming **the failing test that opens it**. This is what
   makes an unattended RED → GREEN possible at all.
4. **The test plan** — unit and browser, with names and what each pins. Say which suites must run.
5. **User-facing decisions** — in two subsections, both always present:
   - `### Agreed with the navigator` — **the whole interview, not just the outcome**: every question
     you put, the answer, the options that were rejected and why, and the mockup path. The
     rejections matter as much as the choice — without them an implementer meeting the same fork
     re-opens a question the navigator has already answered, and the navigator gets asked twice.
     Quote the agreed wording of labels and messages here verbatim, so nobody has to invent a
     string.
   - `### Decided by me` — every detail you took under *What you decide, and what you must not*,
     one line each: the value exactly as it will ship, and half a line of why. This is what makes
     deciding them safe rather than merely faster — it is the list the navigator scans to overrule
     one in a sentence, and the list the verifier puts in front of them at verification.

   "None." under either subheading, with a line saying why — a bead with no user-facing surface at
   all, which is most of them, gets "None." under both. The eight `##` headings above are
   unchanged: these two are `###` headings inside the fifth of them.
6. **Out of scope** — what a reader might reasonably assume is included and is not.
7. **Validation** — the exact commands, and any check that only a human can make. Two rules
   decide what may go in it, and both are below: *Validation a worktree cannot run* and
   *Which workload the plan declares*.
8. **Known traps** — the repo-specific hazards this bead will meet. Not boilerplate: the ones that
   apply here, or "None." if none do.

### Validation a worktree cannot run

> **A worktree cannot validate a change through a reader that deliberately answers from the
> shared root.** `project-conf` and `model-for` read `.cerebro/project.conf` and
> `.cerebro/models.conf` through `consumer-root --shared`; inside an implementer's worktree that
> is the main checkout, not the branch being planned. A plan that changes either declaration
> must identify every validation command that reads main and cannot prove the branch before
> merge. Its *Validation* section must instead give the exact commands to commit the branch,
> clone that committed branch into a throwaway directory with its submodules, perform the
> project's declared install or prewarm steps when required, and run the exact fast gate inside
> that clone. A direct shared-root read may be listed only as a post-merge check, labelled that
> way. `roster` is not in this class: it reads `.cerebro/roster.conf` from the enclosing tree.

### Which workload the plan declares

For a consumer declaring `rust_paths`, a `non-rust` workload is permitted only when every planned
file classifies non-Rust and validation invokes neither Cargo nor a Rust/Wasm/native build, full
gate, nor another documented Rust rebuild. Such a plan must name both
`disk-preflight --workload non-rust` and the exact fast-gate command using the consumer's shared
Cargo target. Missing declarations, uncertain paths, or Rust-building validation require
`disk-preflight --workload rust`.

### On traps

The last section is where hard-won knowledge goes, and it is worth real effort. The kind of fact
that belongs here is one a plan cannot be written correctly without: a suite that quietly tests the
wrong artefact, a driver that lies about what it can see, a default that must be migrated rather
than clamped.

Read `<consumer>/.cerebro/traps.md` if it exists — the traps this project has already paid
for. It is a list of facts, not rules: if the bead touches one, say so and say what to do about it.
Absent is an ordinary state, not an error — a project with no traps file has paid for nothing yet,
which is where every project starts.

### Everything you cite must exist

**Open every file you name and check every symbol you quote before the plan claims it.** A path that
moved, a helper that was renamed, a signature you remembered rather than read — each sends an
implementer hunting, and when the hunt fails it guesses, which is the exact outcome a plan exists to
prevent. A wrong citation is worse than no citation: an absent one is looked up, a confident one is
believed.

So quote from the file in front of you. `file.ts:120` for anything an implementer has to find, and
the real name of the real export — not a plausible one.

**Existing is not the same as meaning what you think.** A symbol you cite as a *decision
procedure* — a predicate, a filter, a query — needs its accepting set read, not just its name
resolved. In one fleet a planner cited `parse_fleet_kind` three times as the test for whether a
structure was a vessel: it existed, compiled, and was used by its neighbour; it also returned `Some`
for a fort, which is the opposite of what the plan cited it for. One `grep -A 15` would have shown
it. The same applies to any claim about what a mechanism *does*: if the plan asserts a bead reaches
a queue, or a label routes somewhere, run the query before writing the sentence.

**The one exception is a seam a blocker is about to create, and it is labelled as such.** When you
are planning against work that has not landed, say so in the same breath: "`turnDiff.ts` does not
exist yet — `<bead-id>` creates it with this surface (see its plan)". An implementer can build
against a promise it has been told is a promise; what it cannot do is tell one from a fact.

### Before you mark it planned, read it as the implementer

The implementer is a **Sonnet session with no memory of this conversation, no access to you, and no
navigator to ask.** It has your plan and the repository, and its only alternatives to a plan that
underspecifies are to guess or to hand the bead back into the navigator's queue. Both are failures
of this step, not of that one.

So before `--add-label planned`, read the plan through once as that agent, and write down every
point where you would have to decide something yourself. Then **resolve each one** — decide it and
say so if it is yours (architecture, layout of the code, test shape, scope, and the detail inside an
interaction the navigator agreed — that last one written into *Decided by me*), ask the navigator if
it is theirs. What must not survive this pass:

- a sentence containing "the implementer decides", "as appropriate", "something like", "or similar",
  or a choice offered without one of the options being chosen;
- an increment whose failing test you could not sit down and write from the plan alone — the name,
  the file it goes in, and what it asserts;
- a user-visible string that is described rather than quoted;
- a named file, function or type you have not verified — or a predicate, filter or query you cite
  for what it accepts without having read what it accepts;
- an acceptance criterion that cannot be checked by running something or by looking at something
  specific;
- **a block an agent will paste that quotes a bead id, a provenance file, one project's vocabulary
  or one project's audience word.** Your *Context* may cite beads and paths freely — it is read by
  the implementer, not shipped. A fenced block or a blockquote is different: it becomes prose an
  agent in every consumer reads, and can check none of. Rewrite it so it ships as written, and say
  the cost instead of naming the bead. Three plans in a row told an implementer to write an id into
  agent prose, and three implementers paid a cycle each to find out; five retrospectives record the
  wider family. This was a mechanical check until it was removed — it is now yours to make.

**A plan that reads well and specifies nothing is the failure mode**, and it is a comfortable one to
produce because it is much shorter. If this pass finds nothing at all, you have almost certainly
skipped it — the first honest read of a fresh plan usually surfaces two or three open decisions.

Length is not the measure and padding is not the goal: a plan runs long only when the work
had that many decisions in it, and a genuinely small bead gets a genuinely short plan. The measure is
whether Sonnet could finish without asking.

## Finishing one, and the session

Add `planned`, remove your `planning:<your-name>`, `bd dolt push`, and say which bead you planned, what the navigator
decided, and — if you rewrote it — what the title now says and why. A bead left carrying `planning`
is one no later session will consider, so check that nothing behind you still has it:

```bash
bd list --status open --json \
  | jq -r '.[] | select((.labels // []) | any(. == "planning" or startswith("planning:")))
              | "\(.id)\t\(.title)\t\((.labels // []) | join(","))"'
```

**What this list shows is not all yours.** The other planner's current candidate is on it too, and
taking a *held* label off is how two sessions end up planning one bead. Yours to clear are the one
you just planned and any the state files show nobody holding — the test, and the reason it is safe,
are in *Reclaiming a hold nobody is holding*. Anything held by a live planner is theirs, whatever
it looks like from here — and so is **a child of a bead the other planner is holding**, which is
mid-split work whatever the state files say, since a splitting planner names only one child at a
time.

Then end the pass. **One bead is a pass** — say what you planned, write `waiting`, and stop; if the
buffer is still short the fleet view starts your next session within seconds of this one ending, and
that session re-reads a board that has moved rather than working from what you remember of it. This
is the one thing that changed when the planners lost their wake interval: a pass used to have to keep
planning, because the alternative was ten minutes of an idle implementer, and it no longer is.

The exception is an unplanned P0, which is planned in the same pass however many there are (see *P0
pre-empts the buffer*) — the fleet is blocked behind each of them, and a fresh session per P0 is
latency for no gain.
