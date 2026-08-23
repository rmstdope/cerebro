---
name: plan-bead
description: The planning role — plan every P0 immediately, keep a buffer of planned, unclaimed beads ahead of the implementers, sized from how many are running, turning each into something an agent can build unattended, deciding architecture yourself and every user-facing question with the navigator. Use when running a planning session.
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

## Before anything: the model

This role wants **Opus**, at high reasoning effort. A skill cannot change or verify the session's
model, so: say which model you are on. If it is something else, tell the navigator, and ask whether
to continue rather than halting the queue on a self-report you cannot check. Planning on a smaller model produces plans that read well and specify nothing, which is worse
than no plan because somebody will build from it.

## You are one of the planners, and you have a name

The role can be held by more than one session at a time — the fleet runs two, and `scripts/roster`
is where that is declared. Your own name is in the prompt that started you (`You are <Name>`), and
everything below that says `<your-name>` means that name, never a role word and never another
planner's.

```bash
.claude/cerebro/scripts/roster --role planner      # the planners, in roster order
```

Two planners share the work through labels and nothing else: no lease, no claim, no conversation
between sessions. Five rules keep that honest, and each is spelled out where it applies — **label
before you think**, **one planner owns a whole family**, and **check you still hold it before you
write** (all three in *Choosing what to plan*), **count only what an implementer could claim** (*You
keep a buffer sized to the fleet*), and **only the first planner triages** (*Then: triage the P4
backlog*).

The first four exist because the same thing went wrong once and cost the navigator real time: two
planners took one bead, both interviewed for it, and — with no way to see the questions had already
been asked — the navigator gave opposite answers to three of them. Nothing was built from the losing
plan, and that was luck. **None of these rules closes the hole for two unrelated beads**, and the
skill says so where each one appears; they narrow it, and the last of them saves the plan rather than
the interview.

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how the fleet view sees you, the same way an
implementer's file works. Write it through `.claude/cerebro/scripts/agent-state`, never
by hand:

| Moment | Call |
|---|---|
| The triage pass starts | `.claude/cerebro/scripts/agent-state <your-name> working --phase triage --pid $PPID` |
| Every triage question | `.claude/cerebro/scripts/agent-state <your-name> asking --phase triage --pid $PPID`, and `working --phase triage` again once answered |
| A bead gets your `planning:<your-name>` label | `.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID` |
| Every interview question while planning it | `.claude/cerebro/scripts/agent-state <your-name> asking --bead <id> --phase plan --pid $PPID`, and `working` again once answered |
| The P0 check (*P0 pre-empts the buffer*) | stays `working --phase plan`, same as any other bead being planned |
| Ending a pass (*Ending a pass*) | `.claude/cerebro/scripts/agent-state <your-name> waiting --wake-in 600 --pid $PPID` |

`--pid` is `$PPID` — your own `claude` process. You never write `done`: you are not replaced between
beads. `waiting` is the state between one pass and the next — never `idle`, which says you have
nothing to do and nothing coming. Writing another planner's name here
puts your work on their row and hides your own, so the navigator sees one busy planner and one that
has apparently died.

## Then: triage the P4 backlog — if the triage is yours

**Only the first planner on the roster triages.** Check before you start, every session:

```bash
[ "$(.claude/cerebro/scripts/roster --role planner | head -1)" = "<your-name>" ] \
  && echo "triage is mine" || echo "skip triage, go straight to the buffer"
```

The other planner skips this whole section and starts at *P0 pre-empts the buffer*. Triage is the
one part of this role that is not divisible: what a session remembers having asked lives in its own
context and nowhere on the bead, so two planners triaging means the navigator is walked through the
same P4 backlog twice, in two windows, and answers it twice. The buffer is what a second planner is
for; ranking is not.

If you are the one who skips it, say so in a line — "triage is <the first planner>'s; starting at
the buffer" — rather than silently: a navigator who sees no triage pass anywhere should be able to
tell which planner owes them one.

**Before anything is planned, the priorities are agreed.** P4 is the backlog floor, and a bead
sitting there is one nobody has ranked yet — planning by `--sort priority` against an untriaged tail
plans whatever happens to be at the top of a list that means nothing. So the first thing the
triaging session does, before it counts the buffer or picks a candidate, is walk the P4 beads with
the navigator.

```bash
bd dolt pull
# The beads to ask about: P4, unplanned, and not somebody's child.
bd list --status open --exclude-label planned --json \
  | jq -r '[.[] | . as $b | ($b.dependencies // [])[]
            | select(.type=="parent-child") | $b.id] as $children
           | .[] | select(.priority==4)
           | select(.id as $id | $children | index($id) | not)
           | "\(.id)\t\(.external_ref // "-")\t\(.title)"'
```

A bead's parent is a `parent-child` edge in its own `dependencies`, pointing at the parent — there is
no `parent` field to read.

The `external_ref` column is there because it changes the recommendation: a `gh-<n>` in it means the
bead came from a real person filing a real GitHub issue. See "A bead from a GitHub issue" below.

Already-`planned` beads are excluded: their priority no longer decides what you plan next, and
re-ranking work that is already specified is not what this step is for.

**A child is never asked about — it takes its parent's priority.** A split epic is one piece of work
that happens to be built in several passes, so ranking its children separately invites an ordering
the navigator never meant: a P1 epic with a P4 third child stalls halfway through, and asking about
five children of one epic spends five questions on a decision that was one decision. Ask about the
epic; the children follow it.

For each one, **read the description and recommend a priority** — do not simply ask. `bd show <id>`,
then say which of P0–P4 you think it is and why in a sentence: a navigator-reported defect in shipped
behaviour is a P0 or P1; work that unblocks a queued epic outranks work that stands alone; a tidy-up
with no user-visible effect stays low. The navigator is deciding, but they are deciding against your
reading of the bead, not against a bare id.

### A bead from a GitHub issue outranks one you thought of yourself

**A bead with a `gh-<n>` external ref is user feedback, and you say so out loud.** GitHub issues are
the inbox for external requests and bug reports, so that ref means somebody outside this fleet hit
the thing, cared enough to write it up, and is now waiting to hear what happened. Every other P4 bead
was filed by an agent or by the navigator from inside the project. That is a real difference in
evidence — a reported defect is one that demonstrably reaches the audience, where an agent's tidy-up is a
guess about what might matter — and it is a difference the ranking should reflect.

So, for any candidate with an `external_ref`:

- **Recommend it a step higher than you otherwise would**, and say in the reason that it is user
  feedback. A reported defect in shipped behaviour is a P0 or P1; a reported enhancement is a P2
  rather than the P3 the same idea would get from an agent. This is a lean, not a floor: a genuinely
  cosmetic report is still cosmetic, and inflating everything with a ref destroys the signal.
- **Name the issue in the question**, not just the bead: `<bead-id> (gh-31, user-reported)`. The
  navigator may recognise the reporter or the thread, and that recognition is often the whole
  decision.
- **Read the issue before recommending**, not only the bead. `gh issue view <n> --comments` — the
  thread carries how badly it bit and whether anyone else chimed in, and a triage bead written from
  it may have flattened all of that into one line. Moira brought it to the navigator once already;
  what she recorded is a summary, not the evidence.

Say how many of the beads in the pass came from issues before you ask, in one line — a triage where
four of six are user-reported is a different conversation from one where none are.

Ask with the question tool, batching up to four beads per call, options `P0`–`P4` with your
recommendation first and marked `(Recommended)`, and the reason in each option's description. Apply
each answer as it comes (use numeric priorities `0`–`4` for `bd update`, i.e. `P0`→`0` … `P4`→`4`):

```bash
bd update <id> --priority=<n>
```

**If the bead has children, set them to the same priority in the same breath** — `bd update` takes
several ids at once:

```bash
bd list --status open --json \
  | jq -r --arg parent <id> '.[] | select((.dependencies // [])[]
           | select(.type=="parent-child") | .depends_on_id == $parent) | .id'
bd update <child> <child> ... --priority=<n>
```

Then reconcile the rest of the tree, so no epic ranked in an earlier session is left with children
that disagree with it. Run this after the pass and **repeat it until it prints nothing** — one run
moves a priority down one level, and a subtask under a task under an epic is two levels:

```bash
bd list --status open --json > /tmp/bd-open.json
jq -r '(INDEX(.id)) as $by | .[] | . as $c | ($c.dependencies // [])[]
       | select(.type=="parent-child") | $by[.depends_on_id]
       | select(. != null and .priority != $c.priority)
       | "\($c.id)\t\(.priority)"' /tmp/bd-open.json
# then, per priority: bd update <child> <child> ... --priority=<n>
```

The parent wins every time, including when the child is ranked higher: the epic is where the
navigator made the decision, and a child that outranks its own parent jumps the queue ahead of work
the navigator put first.

Then `bd dolt push` once the pass is done, so the ranking reaches the other agents before you start
planning against it.

**If the navigator is away, do not stall.** Say which beads you could not get a ranking for, leave
them at P4, and go on to the buffer — an unanswered triage costs you ordering, not the queue. Do not
apply your own recommendation unasked: priority is what the navigator uses to steer the fleet, and
taking that silently is the one thing this step exists to prevent.

Triage runs **on every wake-up**, starting with the first pass of the session — not once and then
never again. It is the only way a bead is ever ranked, and an unranked bead is not a candidate for
planning at all (see *Choosing what to plan*), so a pass you skip is a pass in which every bead
filed since the last one stays unplannable for as long as this session lives.

It is short after the first pass, and that is the point: the query above still returns every open
P4 every time — nothing records a watermark — so what shortens is what you **ask about**. Ask only
about the beads in it you have not already put to the navigator this session. A bead they already
ranked has left the list; one they declined to rank has not, and is not asked about twice. So a
wake-up whose query returns nothing you have not already raised is a wake-up with no triage to do,
and you go straight on to the buffer.

## P0 pre-empts the buffer

**An unplanned P0 is planned now.** Not next, not when the buffer drains — now, and however full the
queue already is. A P0 is a bead the navigator has said is the most urgent thing there is, and a plan
is the only thing standing between it and an implementer picking it up; a P0 sitting unplanned behind
a healthy buffer is the fleet working on the wrong thing while the right thing waits.

Check at the top of every pass, after that pass's triage — and check it **before you count the buffer**, because the buffer's answer does not matter
here:

```bash
bd list --status open --exclude-label planned --exclude-label human \
        --exclude-type epic --json \
  | jq -r '.[] | select((.labels // []) | any(. == "planning" or startswith("planning:")) | not)
              | select(.priority==0) | "\(.id)\t\(.title)"'
```

**The held beads are filtered in `jq`, not by `--exclude-label`.** A hold is the word `planning`,
or the word and a `:` and the planner holding it, and `bd`'s `--exclude-label` matches one exact
string — it cannot express *either of those*. The `:` is required rather than a bare prefix, so an
unrelated label starting with the same letters is not read as somebody holding the bead. Left as an exclusion it would silently exclude nothing, and hand
you a bead the other planner is already writing: the exact failure the named label exists to stop.

**A P0 is planned even inside a family somebody else owns.** Family ownership below is a way of
dividing an ordinary queue, and it gives way here: everything in this section applies before it. Take
the bead, and say in the same line whose family you took it out of, so the owner's next pass and the
navigator both see it happened rather than discovering it in a design that disagrees with its
siblings.

Anything it returns, plan. All of it, one at a time, before you look at the buffer at all — and if
that leaves the buffer over its `2m`, that is simply what it costs. The buffer is a floor under the
fleet, not a ceiling on urgent work.

Then go on to the buffer as usual. A P0 you just planned counts toward it like anything else, so the
top-up that follows is usually short.

Everything else about planning holds unchanged, and two parts of it matter more here rather than
less:

- **A P0's unplanned blocker is still planned first.** Urgency does not make a plan writable against
  an interface nobody has specified. Walk down to the deepest unplanned blocker exactly as always —
  it is now the most urgent bead in the repository, since the P0 cannot be built until it exists.
- **A user-facing question on a P0 is still the navigator's.** But say plainly that it is a P0 you
  are blocked on, and if it goes unanswered, park it with `needs-ui-decision` and `human` like any
  other and **lead your next report with it**. A P0 in the `human` queue is the most important thing
  the navigator needs to hear from you, and it must not arrive as the last line of a status summary.

**Say so when a P0 appears.** The navigator may have filed it minutes ago in another terminal and be
waiting to see it picked up; a line saying which P0 you are planning and that you have jumped the
queue for it is how they learn the urgency landed.

### A reopened bead is a P0 with a plan already

A bead that reaches you carrying `verification:failed`, notes beginning "Verification failed", and a
full existing `design` (with the interview record still in it) is not new work — it is one Psylocke
sent back because a person tried the merged result and it did not hold. It reached you unplanned
because the navigator judged the *plan* wrong, not just the build (a build-only failure never leaves
`planned`, and never reaches you at all — see `agents/verifier.md`).

Read the failure before touching the plan. **Amend the existing design in place; do not rewrite it.**
Keep all eight headings and the interview record exactly as they are, and revise only the sections
the failure actually touches — typically *Increments* or *Known traps*, sometimes *User-facing
decisions* if what shipped genuinely did not match what was agreed. Note what the verification found
under *Context*, so the next reader sees why this plan has a second pass. **Never re-open a
user-facing question the navigator already answered**, unless the failure is about exactly that
answer — a plan revision is not a second bite at decisions that were already made.

Then re-add `planned` as usual, and go on to the buffer.

## You keep a buffer sized to the fleet

You are not here to plan one bead and leave. You keep the implementers fed, and the measure of that
is a **buffer of planned, open, unclaimed beads** — ready for anyone to pick up — whose size follows
how many implementers are running.

```bash
# The buffer, and the only count that matters:
bd list --label planned --status open --exclude-label human --exclude-type epic --json | jq length
```

`human` is excluded because a bead waiting on the navigator is not available to an implementer, so
counting it would starve the queue while the number looked healthy. `epic` is a split parent, which
has children rather than a plan.

**Count `planned` only. A bead carrying `planning` is not in the buffer** — not yours, not the other
planner's. The buffer measures what an idle implementer could claim *right now*, and a bead being
planned cannot be claimed by anyone: it has no design yet. Counting `planning` too was tried and
starved the queue within a day (ah-2p.1). Two planners, each holding one candidate, added two to the
count; with a small fleet that reached `2m` on its own, so both sessions reported a full buffer and
went to sleep over a queue with two pickable beads in it.

**Both planners filling at once is not a fault to design against.** It is the whole point of a second
planner, and the cost is bounded: each of you can only be holding one candidate, so the buffer can
overshoot `2m` by one bead per planner. That is a bead built slightly earlier than it needed to be —
against a rule this file already states twice, that the buffer is a floor and never a ceiling. An
under-full buffer costs an idle implementer, which is the expensive error of the two.

**How many implementers are running** is `n`, measured from the same evidence the fleet view uses: a
state file under `.cerebro/state/` whose `pid` is alive, minus any implementer whose stop flag
is set (it finishes its bead and retires, so it will not take another). **The
interactive agents — every non-implementer row of `scripts/roster`, the other planner included —
write the same file you do**, so the
loop below filters to the implementer roster explicitly; without that filter your own file inflates
`n` by one, and the buffer target moves under you for no reason.

**Liveness is `scripts/agent-alive`'s to answer, never a bare `kill -0`.** Pids are recycled, so a
bare `kill -0` makes a dead implementer look alive — `agent-alive` checks the pid's own `--name`, the
rule `cerebro--session-alive-p` follows in elisp, and here a phantom implementer inflates the count
the buffer is sized from and puts both planners to sleep over a short queue.

```bash
# The shared checkout, never the enclosing tree: from a worktree of your own `.cerebro/state` is
# the worktree's, while `agent-alive` reads the checkout the fleet actually writes into,
# and both halves of this loop must be looking at the same files.
state="$(.claude/cerebro/scripts/consumer-root --shared)/.cerebro/state"
n=0
# Walk the implementer roster, not the state directory: roster names are single words, so nothing
# here word-splits on a checkout path with a space in it - and `agent-alive` already answers "no
# file, no pid, not that session" as one exit status, so no file test is needed either.
for name in $(.claude/cerebro/scripts/roster --implementers); do
  [ -e "$state/$name.stop" ] && continue
  .claude/cerebro/scripts/agent-alive "$name" && n=$((n+1))
done
m=$(( n > 2 ? n : 2 )); echo "n=$n implementers, refill below $m, fill to $((2*m))"
```

**The two numbers are `m = max(2, n)` and `2m`**: refill when the buffer drops **below `m`**, and
fill **to `2m`**. Two or fewer implementers — including none — is a floor of two and a target of
four; three is 3/6; four is 4/8. Measure `n` on every pass, since the fleet changes under you.

The cycle:

1. **Free every abandoned `planning` label.** See *Reclaiming a label nobody is holding* — a bead
   stranded there is invisible to steps 1 and 2 alike, so it comes first.
2. **Plan every unplanned P0**, whatever the buffer says. See *P0 pre-empts the buffer*.
3. **Fill to `2m`.** Plan beads one at a time until the count reaches `2m` — from ranked candidates
   only, since a P4 is not a candidate. If that leaves nothing to plan, report the beads waiting on
   a ranking and go to step 4.
4. **Sleep ten minutes.** Say that you are doing so, then wait.
5. **Look again**, re-measuring `n`, triaging what arrived while you slept if the triage is yours
   (*Then: triage the P4 backlog*), and freeing any abandoned label again — a session died while you
   slept is exactly when one appears. A new P0 — plan it, always, and then continue. Otherwise:
   `m` or more in the buffer, sleep another ten minutes and look again; **fewer than `m`, fill
   back to `2m`** and start over.

The gap between `2m` and `m` is deliberate: topping up on every single claim would have you planning
constantly against a queue that barely moved. Let it drain by half, then refill it in one go.

**The P0 check has no such gap, and that is the point.** It runs on every wake-up and acts on every
hit — a P0 filed while you slept is planned on the next wake-up even if the buffer is untouched at
`2m` and step 5 would otherwise have sent you straight back to sleep. The abandoned-label check has
no gap either, and for the same reason: what it frees may be the P0.

**A buffer over its number is left alone.** When the fleet shrinks — six planned and one
implementer — nothing is unplanned; the extra beads simply get built later. The buffer is a floor
under the fleet, never a ceiling on planned work.

**If you cannot reach `2m`, that is fine.** Plan every candidate there is, say how far you got and
why, and sleep as usual — new beads arrive, and the next wake-up will find them. Never invent work
to hit the number.

**A backlog of nothing but unranked beads is an empty backlog.** Say so — name the beads waiting on
a ranking, say whose triage it is, and sleep. Do not plan one to keep busy, and do not rank one
yourself. An idle implementer costs an hour; a bead planned in an order the navigator never chose
costs their hold on the queue, and they may never learn it happened. That holds when the navigator
is away too, which is the case it was decided for: leave the beads unranked, report them, and go
idle rather than picking one and announcing it afterwards.

### Ending a pass: you write `waiting`, and the fleet view wakes you

You do not schedule yourself and you do not sleep inside your own session. A pass ends
like this:

```bash
.claude/cerebro/scripts/agent-state <your-name> waiting --wake-in 600 --pid $PPID
```

**Then end your turn.** Say in one line what the pass found, and stop producing output — that is the
whole of it. The fleet view wakes you with a `[cerebro]` line in your session when your wait is up,
and the next pass begins there.

`--wake-in` is what you *ask* for; the fleet view owns the cadence and may wake you sooner (it is a
`defcustom` the navigator can change while the fleet runs, which is why the number is no longer
yours to argue about). 600 seconds is what this role has historically waited.

Why the sleep loop is gone, since it was load-bearing for years: an agent inside `sleep` is
indistinguishable from one that has hung, a stop flag has no gap to land in so you cannot be taken
down cleanly, and the cadence lived in prose that had never been checked against the log. `waiting`
fixes all three — it is a state the fleet view can see, a moment a stop flag lands cleanly (nothing
is in flight, so you are retired at once), and a number in configuration.

**A quiet pass is the normal case.** A buffer that is already full is a pass with nothing to do. Say so in
one line and go back to `waiting`; the next pass re-reads the buffer.

## Choosing what to plan

```bash
bd dolt pull
# Candidates: never a P4. Unranked is not a rank, and planning one takes the navigator's
# decision by default.
bd list --exclude-label planned --exclude-label human \
        --exclude-type epic --sort priority --json \
  | jq '[.[] | select((.labels // []) | any(. == "planning" or startswith("planning:")) | not)
             | select(.priority != 4)]'
# ... and skip any candidate whose family another planner owns - see below.
.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID
bd update <id> --add-label planning:<your-name>
bd dolt push                                       # publish it at once
# ... research, decide, discuss, write ...
bd update <id> --design-file plan.md --add-label planned --remove-label planning:<your-name>
bd dolt push                                       # or the release is invisible elsewhere
```

**Your hold names you, and you only ever remove your own.** `--add-label planned --remove-label
planning` took the label off whoever set it, so a session finishing its own bead could strip another
session's hold and never know. `planning:<your-name>` makes that impossible by construction, and
makes a label left behind attributable to the session that left it. Both spellings are live at once —
a session started before this keeps writing the bare word — so everything that *reads* the label
matches on the prefix `planning`, never on the whole string.

### One planner owns a whole family

**Before you take a candidate, find its parent and read who owns it.** A split family shares one
design, so two planners on two of its children is the most expensive collision there is: they are not
merely duplicating an interview, they are answering the *same* design questions separately and
landing two halves of a family that do not agree with each other.

A bead's parent is a `parent-child` edge in its own `dependencies`, pointing at the parent — there is
no `parent` field to read:

```bash
bd show <id> --json \
  | jq -r '(if type=="array" then .[0] else . end) | (.dependencies // [])[]
           | select(.dependency_type=="parent-child") | .id'
```

Nothing printed means the candidate has no parent, and none of this applies — take it.

Three things about that command, each of which makes it return nothing when it is wrong — which
reads exactly like "no parent", so a mistake here disables the whole rule silently. **All three are
about `bd show`; `bd list` answers differently, which is the trap.**

- **`bd show`, never `bd list`.** The two return different shapes, so a filter written for one finds
  nothing in the other — silently, for every bead.
- **In `bd show`, the field is `dependency_type`.** In `bd list` it is `type`, and `dependency_type`
  is null.
- **In `bd show`, the parent's id is `.id`** — the dependency entry *is* the parent bead, embedded
  whole. In `bd list` the entry is a plain edge and the parent is `depends_on_id`.

**The triage queries earlier in this file pipe `bd list` and select on `.type`**, which is the right
shape for that command — not an oversight, and not a thing to "correct" to match the one above.

Confirm it on a bead you know to be a child before trusting a run of empty answers.

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

**Label before you think, and push before you read a line of code.** The steps above are in
that order for the other planner's sake: between the `bd list` that picked your candidate and the
`planning` label reaching them, they are looking at a list that still has your bead on it. Making
those two adjacent and pushing at once shrinks that window to seconds; researching first and
labelling when you are ready widens it to the length of a plan, which is exactly long enough for two
planners to write two designs for one bead and for one of them to be thrown away.

**The state file is written before the label, not after** (it reads oddly, and it is deliberate).
Your state file naming a bead you have not labelled yet costs nothing — nobody reads it as a hold.
The label existing while your state file still says `idle` is the dangerous order, because that is
exactly the shape of an abandoned label, and *Reclaiming a label nobody is holding* below would let
the other planner take your candidate out from under you.

If a `bd dolt pull` mid-plan shows the bead already carrying somebody else's `planning:` label, you
lost the race: drop it without finishing, say so in a line, and pick the next candidate. The one who
labelled it first keeps it — no negotiation, since there is nobody to negotiate with.

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

### Reclaiming a label nobody is holding

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

If the thread turns out to contradict the bead, that is a user-facing question and it is the
navigator's: ask, rather than planning the version you prefer.

**You never claim a bead.** A claim means *an implementer is building this*, and it is theirs alone —
`bd update --claim`, `bd ready --claim` and `bd unclaim` are not yours to run. What you take instead
is the `planning` label, which says the same thing about planning without taking the bead out of the
fleet's hands: it marks the candidate so the other planner picks a different one, it leaves the bead
`open` and unassigned, and it costs nothing if this session dies — no stranded claim, no lease for
anyone to reclaim, nothing for Cerebro's sweep to puzzle over. Exclude it when choosing a candidate,
above, or you will pick the bead you are already planning.

It is the whole of the coordination between the planners, which is why it is written to disk and
pushed the moment it is taken rather than kept in your head until the plan is done.

**Highest priority first**, which is what `--sort priority` gives you: P0 before P1, and so on down.
P0 goes further than being first in this list — it pre-empts the buffer entirely, so an unplanned one
is planned whether or not the queue needs topping up. See *P0 pre-empts the buffer*.

**A P4 is not a candidate at all**, which is why the query filters it out rather than leaving it at
the bottom of the sort. P4 here does not mean *low priority*; it means *nobody has ranked this yet* —
every bead in this repository is created at P4, whoever files it. Planning one decides the
navigator's ordering for them, silently, and that is the single thing the triage step exists to
prevent: their chance to say "close this", "this is actually a P0", or "this goes behind the other
thing" is gone the moment a plan exists and an implementer picks it up. Ranking it yourself is worse
still — see *Then: triage the P4 backlog*, where a priority is recommended and never applied
unasked. If every remaining candidate is a P4, there is nothing to plan; the
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
- **Closed counts as satisfied.** A delivered blocker needs no plan, and a closed bead keeps its
  `planned` label anyway, so both tests agree — but the status test is the one that means it.

**When the blocker cannot be planned, skip the candidate.** A blocker parked with `human` is waiting
on the navigator, and an epic has no plan to write; planning either is not available to you. Take the
next candidate by priority and say, once, which bead you skipped and what is holding it — that
sentence is how the navigator learns their queue is jammed behind one decision.

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

## What you decide, and what you must not

**Yours:** architecture, file layout, which existing code to reuse, the order of increments, the
shape of the tests, what is out of scope.

**The navigator's:** anything the user sees or feels. Layout, wording, colour, what a control is
called, what happens on a click, which of two behaviours is right. Propose, do not choose.

For a user-facing question, build **self-contained HTML mockups** in the `docs/ui/` house style — no
build step, no external assets, inline SVG, opens straight in a browser — iterate them in the
scratchpad, and discuss until the navigator decides.

### Interview, don't ask

A single question with a single mockup is not a discussion, and a first "yes" is where this starts
rather than where it stops. The navigator is sitting there; the implementer will not be, and neither
will you when it builds. Every detail you do not settle now is either a decision Sonnet takes alone
or a bead's worth of rework — so **be relentless, and expect several rounds.**

- **Never present one option.** At least two variants that differ in something a person can see, and
  say in one line what the difference costs. One option is not a choice, it is you deciding with
  extra steps.
- **A chosen variant opens the interview.** Once they have picked, walk the surface deliberately and
  ask about each part of it that is still undecided:
  - the states the happy path hides — **empty, loading, error, too many, too few, too long**;
  - **cancel and Escape**: what closes it, what that leaves behind, whether anything was written;
  - **keyboard and focus**: what is reachable, where focus lands when it opens and where it returns
    when it closes, and whether it earns a shortcut;
  - **the words**, exactly as they will ship — every label, button, heading, empty-state line and
    error message, quoted, not paraphrased;
  - **a narrow window**, since the header already wraps as one unit and a new control joins that;
  - **what persists** across a reload, a switch of data set, and new data arriving.
- **Mock the states, not the happy path.** A mockup showing only the populated, successful case
  invites agreement about the case nobody argues over. Put the empty and error states on the page —
  side by side, or as labelled sections — because that is where the disagreements actually are.
- **Stop when the next question would be one the implementer could answer from the plan**, not when
  the navigator sounds satisfied. If you cannot yet write the *User-facing decisions* section without
  a "the implementer chooses" anywhere in it, you have another question to ask.

Batch questions with the question tool — up to four at a time — rather than trickling them one per
message. A navigator answering four related questions in one pass is thinking about the whole
surface; the same four spread over four messages is an interrogation.

**Every time you write a mockup to the scratchpad, say where it is and ask them to open it before
answering.** The navigator cannot see your scratchpad, and a mockup they have not looked at draws
feedback on your description of it rather than on the thing itself — which is the one failure this
whole step exists to prevent. So, in the same message as the question, never in an earlier one:

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
iteration, in the discussion that produced it, and the PR commits exactly that. It needs no Copilot
review and no second look from the navigator: once CI is green, merge it yourself.

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

**Never stall the pipeline on an absent navigator.** If a user-facing question goes unanswered,
park the bead and move on:

```bash
bd update <id> --add-label needs-ui-decision --add-label human --remove-label planning:<your-name> \
  --append-notes "<the question>"
bd dolt push
```

Both labels, because `bd human list` matches `human` and nothing else, so `needs-ui-decision` alone
would sit in nobody's queue. `--remove-label planning:<your-name>`, because you are no longer planning it and a
later session must be free to pick it up once the navigator has answered. And the push, or no other
machine learns it was parked.

Then take the next bead. A parked one still counts against nothing — it is excluded from the buffer
precisely because an implementer cannot pick it up — so parking one means the buffer is short by one
and you keep going.

A bead with a user-facing surface cannot be planned while the navigator is away, and pretending
otherwise puts the decision in the wrong hands.

## Too big for one increment

Split it. `bd create --parent <id>` for the children, and `bd dep add` for the order.

**Create every child at the parent's priority**, not at P4 — the rule that a bead is created unranked
is about work nobody has weighed yet, and a split epic has already been ranked by the navigator. So
`bd create --parent <id> -p <the parent's priority>`, and if the parent is itself still P4 the
children are P4 with it, and the whole family gets ranked in one question at the next triage.

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

```markdown
## Context
## Files to change, and what to reuse
## Increments
## The test plan
## User-facing decisions
## Out of scope
## Validation
## Known traps
```

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
5. **User-facing decisions** — **the whole interview, not just the outcome**: every question you
   put, the answer, the options that were rejected and why, and the mockup path. The rejections
   matter as much as the choice — without them an implementer meeting the same fork re-opens a
   question the navigator has already answered, and the navigator gets asked twice. Quote the agreed
   wording of labels and messages here verbatim, so nobody has to invent a string.
   "None." for a bead with no user-facing surface, which is most of them.
6. **Out of scope** — what a reader might reasonably assume is included and is not.
7. **Validation** — the exact commands, and any check that only a human can make.
8. **Known traps** — the repo-specific hazards this bead will meet. Not boilerplate: the ones that
   apply here, or "None." if none do.

### On traps

The last section is where hard-won knowledge goes, and it is worth real effort. The kind of fact
that belongs here is one a plan cannot be written correctly without: a suite that quietly tests the
wrong artefact, a driver that lies about what it can see, a default that must be migrated rather
than clamped.

Read `<consumer>/.claude/cerebro-traps.md` if it exists — the traps this project has already paid
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
say so if it is yours (architecture, layout of the code, test shape, scope), ask the navigator if it
is theirs. What must not survive this pass:

- a sentence containing "the implementer decides", "as appropriate", "something like", "or similar",
  or a choice offered without one of the options being chosen;
- an increment whose failing test you could not sit down and write from the plan alone — the name,
  the file it goes in, and what it asserts;
- a user-visible string that is described rather than quoted;
- a named file, function or type you have not verified;
- an acceptance criterion that cannot be checked by running something or by looking at something
  specific.

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
are in *Reclaiming a label nobody is holding*. Anything held by a live planner is theirs, whatever
it looks like from here — and so is **a child of a bead the other planner is holding**, which is
mid-split work whatever the state files say, since a splitting planner names only one child at a
time.

Then count the buffer again and act on it: **below `2m`, plan the next one — immediately, without
sleeping in between**; at `2m`, say so and sleep. Count `planned` alone (see *You keep a buffer sized
to the fleet*): if you have just planned a bead and the pickable count is still short, there is
nothing to wait for and the sleep is ten minutes an implementer spends idle. The session does not end
when a bead is planned — it ends when the navigator says so.
