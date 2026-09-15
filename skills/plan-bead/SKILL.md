---
name: plan-bead
description: The planning role — plan the one bead the fleet view hands you, P0s first, keeping a buffer of planned, unclaimed beads ahead of the implementers, sized from the roster's implementers, turning each into something an agent can build unattended, deciding architecture yourself, deciding the detail inside an interaction the navigator has already agreed, and taking the shape of every new one to them. Use when running a planning session.
---

# Planning a bead

You turn unplanned beads into plans, and you never implement one: if you are editing the project's
application paths (`scripts/app-paths`), you have taken the wrong job. **Write for a Sonnet agent
that cannot ask you anything.** It has your plan and the repository; anything left open it guesses
or hands back. A plan is finished when it could be built without a single question (*Before you
mark it planned, read it as the implementer*). Read `beads-workflow` for the label lifecycle and the
commands. Several sessions may hold this role; `<your-name>` is the name in the prompt that started
you, said in your first message and used in every state write.

```bash
.claude/cerebro/scripts/roster --role planner      # the planners, in roster order
```

The fleet view makes each planner the assignee of its own bead before its session starts, so two
never share one.

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how the fleet view sees you.

<!-- state-contract:begin -->

Write it at every transition, in the same `Bash` call as the thing it describes, only through
`.claude/cerebro/scripts/agent-state`, never by hand. There are four state words and no others:

- `working` — everything you are doing.
- `asking` — blocked on the navigator; nothing moves until they answer.
- `idle` — live, nothing in hand, waiting to be spoken to.
- `waiting` — pass over, turn ended. About half a minute later the fleet view ends the session,
  keeps its buffer as the pass's record, and starts a fresh one on your role's own trigger.

The table below says which to write when. A wrong one misleads: a session shown with nothing in
flight may be `k`-ed, and one shown `asking` looks blocked on the navigator.

`working` and `asking` take `--phase`, with your role's words from that table. The script keeps
`since` across a phase-only change and stamps `phase_since`: another reason never to write by hand.

`--pid` is `$PPID`, whichever agent CLI runs you, captured in the call that writes the file. A stale
pid shows you dead; the navigator starts a second session over you.

**Every question to the navigator is three actions.** Write `asking`, ask, then write `working` as
the very first thing you do with the answer, before any `bd`, `git` or reply. Typing `bd` or `git`
straight after an answer means you skipped the third: stop and write it.

**The hook does not excuse you.** `hooks/session-state.settings.json` and `scripts/agent-asking`,
from `scripts/launch`, flip the file to `asking` during a question tool call and back on answer or
cancellation. It misses a prose question, a wait on a port or a "say when", and cannot tell `idle`
from `working`. Write `asking` for a prose question too: one under `working` looks wedged, and the
stuck clock ends wedged sessions.

**You cannot see your own state file.** Read it at the start of a pass and before ending one. If it
is wrong, fix it with `agent-state` first and say so in one line ("my state file still said `asking`;
corrected").

<!-- state-contract:end -->

| Moment | Call |
|---|---|
| The bead you were given is confirmed yours (*Choosing what to plan*) | `.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID` |
| Every interview question while planning it | `.claude/cerebro/scripts/agent-state <your-name> asking --bead <id> --phase plan --pid $PPID`, and `working` again once answered |
| Ending a pass (*Ending a pass*) | `.claude/cerebro/scripts/end-pass <your-name> --pid $PPID` |

Another planner's name there puts your work on their row.

## Ranking is Cerebro's

P4 means *unranked*. The orchestrator ranks with the navigator (`agents/orchestrator.md`, *Ranking
the backlog*). You never rank, never plan a P4, and never set a priority the navigator did not
choose. `human` and `triage:declined` beads are outside the buffer;
`scripts/planner-buffer --print-excluded-labels` is the list.

## P0 pre-empts the buffer

An unplanned P0 is handed to you ahead of everything else, one per pass, with its unplanned blocker
handed out before it. The filters live in `scripts/plan-candidates`, the authority: open, not
`planned`, not `human`, not assigned, `verification:failed` only with `plan:revise`, never
`verdict:stale`, not a child of an assigned parent, not a bead whose blocker has no plan, and an
epic only while nothing is under it. A `verdict:stale` bead is never yours: main has moved past the
verdict, and it waits for the verifier's second look.

A P0's shape question is still the navigator's. Say it is a P0 you are blocked on; if it gets
parked, **lead your next report with it**. Say so when you take a P0, and that it jumped the queue.

### A reopened bead is a P0 with a plan already

A reopened bead is yours only when it carries `verification:failed` **and** `plan:revise`, the
verifier's label for *the plan was wrong* (see `agents/verifier.md`). Never infer it from `planned`
being absent: `planned` comes off for other reasons, including an implementer handing a bead back.
Without `plan:revise` it waits for the verifier, not for you.

Read the failure first. **Amend the design in place**: keep all eight headings and the interview
record, revise only what the failure touches, and note the finding under *Context*. Never re-open a
user-facing question the navigator already answered, unless the failure is about that answer.
Remove `plan:revise` in the same update that re-adds `planned`:

```bash
bd update <id> --add-label planned --remove-label plan:revise --assignee "" \
  --remove-label needs-ui-decision
```

## You keep a buffer sized to the fleet

The buffer is **planned, open, unclaimed beads**, and `scripts/planner-buffer` is where the rule
lives:

```bash
# The buffer, and the only count that matters - `planned=<p> want=<m>', short whenever p < m:
.claude/cerebro/scripts/planner-buffer --count
```

```bash
# `m' on its own, if the count line above is not what you want:
.claude/cerebro/scripts/planner-buffer --want
```

`m = max(2, multiple × n)`. The multiple comes from the `.cerebro/project.conf` key that
`--print-multiple-key` names, and is 1 when absent; `--print-floor` declares the 2. `n` is the
implementer rows of the roster minus those whose stop flag is set, not a count of running sessions:
a builder retired with `f`, or `dead`, still counts.

Count `planned` only; a bead being planned is not buffer. `human`, `triage:declined` and `epic` are
excluded, and the script owns that list. Two planners overshooting by one bead each is accepted: the
buffer is a floor, never a ceiling, and an over-full buffer is left alone.

A pass plans **one bead**, whatever the buffer says. If there is nothing you may plan, say why and
end the pass; never invent work. If every candidate is unranked, name the beads waiting on the
orchestrator's triage and end the pass, **even when the navigator is away**: plan none and rank none.

### Ending a pass

```bash
.claude/cerebro/scripts/end-pass <your-name> --pid $PPID
```

Then end your turn: say in one line what the pass found and stop producing output, with no sleep
loop. The fleet view ends the session and starts a fresh one on its own trigger. Nothing survives
except the board, files and `bd remember`. Cadence is the fleet view's, not yours. A quiet pass is
the normal case.

## Choosing what to plan

**You do not choose.** The prompt that started you ends with
`Your bead is <id>; it is already assigned to you.` Confirm it, then write the state:

```bash
bd dolt pull
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | "\(.status) \(.assignee // "")"'
.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase plan --pid $PPID
```

`open <your-name>` is yours. Anything else: say in one line what you found, write nothing, and end
the pass. No such sentence in the prompt: say nothing is waiting for a plan, and end the pass.

**Never pick, never add a label to hold anything, and never take a second bead**, a P0 included.
File the plan and give the bead up in one call:

```bash
# ... research, decide, discuss, write ...
bd update <id> --design-file plan.md --add-label planned --assignee "" \
  --remove-label needs-ui-decision   # a no-op unless the bead was parked on a shape question
bd dolt push                         # or the release is invisible elsewhere
```

### Which bead, and in what order

Highest priority first. If a hand-typed launch gave you a P4, give it back, push, say so and end the
pass:

```bash
bd update <id> --assignee ""
bd dolt push
```

Plan beads whose blockers are unbuilt, never one whose blocker is unplanned; the queue enforces that,
and `beads-workflow` says why it is not `bd ready`. For a blocked bead, read the blocker's plan
(`bd show <blocker> --json`), name the blocker in *Context*, say in *Files to change* which parts
depend on unlanded work, and describe the seam rather than quoting a signature that does not exist.

A `## Navigator's answer` heading in the notes is a decision already made: record it under *Agreed
with the navigator* and never ask it again.

No heartbeats: you are an assignee without a claim, and nothing expires.

### An epic with no children is a bead nobody split

Repair it before planning. Two outcomes:

- **Too big for one increment**: split it, as *Too big for one increment* says. The split is the
  pass.
- **One increment's work**: retype it, then plan it in place:

  ```bash
  bd update <id> --type feature     # `task` for a chore, `bug` for a defect
  ```

Never leave an epic `planned`: `scripts/assignable-beads` excludes epics while
`scripts/planner-buffer` counts them, so the buffer reads high for ever. Say what you did in the
report line, e.g. `<id> was an epic with nothing under it; retyped to feature and planned.`

### A bead from an issue: go and read the issue

If the bead carries a `gh-<n>` external ref, read the thread before anything else; reporters are
invited to add detail there after filing.

```bash
bd show <id> --json | jq -r '.external_ref'    # gh-212, or null
gh issue view <n> --comments
```

Download and read the screenshots:

```bash
gh issue view <n> --json body,comments --jq '.body, .comments[].body' | grep -oE 'https://[^ )]+\.(png|jpg|jpeg|gif)'
curl -sL "<url>" -o /tmp/issue-<n>-1.png    # then read the file
```

Take from it a reproduction, the version or platform, what the reporter expected, later comments
narrowing or widening the request, and anything a maintainer said. Name the comment in *Context*.
Where the thread contradicts the bead about shape, ask the navigator; about a detail, decide it into
*Decided by me* with the thread as the reason.

## Check it is still yours before you write

You never claim: no `bd update --claim`, no `bd ready --claim`, no `bd unclaim`. Immediately before
writing the design:

```bash
bd dolt pull
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end).assignee // ""'
```

Do not write unless it prints your own name. If it does not, say in one line that you lost the bead
and what you had decided, and end the pass.

## What you decide, and what you must not

**Yours:**

- architecture, file layout, reuse, increment order, test shape, scope;
- the detail inside an interaction the navigator agreed: exact wording of labels, messages and
  errors; a colour from the existing palette; sizes, spacing, truncation, wrapping; which of two
  synonymous names; the order of a list you were told to show; the empty, loading and error states
  of an agreed surface.

**The navigator's:**

- what the feature *is* from the user's side;
- a new surface: pane, dialog, mode, section;
- a key or gesture, or a change to what an existing one means;
- what a control *does*, and which of two behaviours is right;
- anything that changes a habit, cannot be undone, or sets a precedent.

**The cost test**, when the lists do not answer: *if the navigator disliked this after it shipped,
what would fixing it cost?* A string, constant or colour is yours. A re-plan, migration, second bead
or relearned habit is theirs. When the test does not answer either, it is theirs.

Everything you decide goes into *Decided by me*. A shape question gets self-contained HTML mockups
in the `docs/ui/` house style (no build step, no external assets, inline SVG), iterated in
`<consumer>/.cerebro/scratch/`. A bead whose open items are all details gets no mockup round.

### Interview, don't ask

- **Be relentless about the shape, and expect several rounds.** Everything must be settled before
  planning; run each item through the cost test, decide yours, ask the rest.
- **Never present one option.** At least two variants that differ visibly, with the cost of the
  difference in one line. A detail you decide is not presented.
- **A chosen variant opens the walk.** Settle each of:
  - the states: empty, loading, error, too many, too few, too long;
  - cancel and Escape: what closes it, what it leaves, whether anything was written;
  - keyboard and focus: what is reachable, where focus lands and returns, whether it earns a
    shortcut;
  - the words, quoted exactly as they ship;
  - a narrow window;
  - what persists across a reload, a data-set switch and new data.

  A key or gesture, or a change to an existing one's meaning, is the navigator's by name.
- **Mock the states, not the happy path.** Put empty and error states on the page.
- **Stop asking when the rest is yours to answer. Stop planning when nothing is unanswered** in both
  halves of *User-facing decisions*.
- **Batch up to four questions** in the question tool. The `file://` links go **inside** the
  question text and each option's description, never in an earlier message
  (`bd remember planner-mockup-links`).
- **Every mockup mention is a full `file://` URL**, one per variant, labelled with the option name,
  never a bare path:

  ```
  Option A — file:///Users/…/scratchpad/<bead-id>-sidebar-a.html
  Option B — file:///Users/…/scratchpad/<bead-id>-sidebar-b.html
  ```

- **Say to open them before answering.** Re-state the paths on every iteration.
- **An answer that engages only with your prose, or comes too fast**, gets one "did you see it?".

The chosen mockup goes to `docs/ui/` in a `docs(<bead>): mockup` PR and the plan names its path.
Once CI is green, merge it yourself, with no review sub-agent:

```bash
gh pr merge <n> --squash --delete-branch
```

That holds only while the diff is confined to `docs/` and matches what the navigator saw; otherwise
it is a normal reviewed PR under the consumer's root `CLAUDE.md` and its Four Eye Principle.

### Anything you commit, you commit from a worktree of your own

Never branch in the main checkout: it moves someone else's HEAD.

```bash
git -C <repo> fetch origin main
git -C <repo> worktree add -b <id>-mockup <repo>/.cerebro/worktrees/<id>-mockup origin/main
cd <repo>/.cerebro/worktrees/<id>-mockup
```

Only under `.cerebro/worktrees/`: `bd` and cargo find their configuration by walking up. The
`-mockup` suffix keeps the path free for the implementer's worktree. Install no dependencies. Once
merged, remove it from the main checkout:

```bash
cd <repo>
git -C <repo> worktree remove --force .cerebro/worktrees/<id>-mockup
git -C <repo> worktree prune
```

`--force` because untracked files block removal; two separate commands so a failure in the first
does not skip the second. `.claude/cerebro/scripts/prune-worktrees.sh` is a net, not a substitute.
Check `pwd` before every git command.

### Parking a shape question

Never stall on an absent navigator. A shape question nobody present can answer is parked:

```bash
bd update <id> --add-label needs-ui-decision --add-label human --assignee "" \
  --append-notes "<the question>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd dolt push
```

Why each part is there is in `beads-workflow`, *The lifecycle a bead moves through*. Write the note
as the question with the options you would have offered, because the orchestrator quotes it to the
navigator. Then end the pass.

A bead that arrives carrying `needs-ui-decision` is yours to clear: interview the navigator, record
the answer, and remove the label in the same update that adds `planned`. Only the navigator's bucket
is ever parked, never a detail.

## Too big for one increment

Split it: `bd create --parent <id> -p <the parent's priority>` for the children (the priority rule is
in `beads-workflow`, *Dependencies and breakdown*), and `bd dep add` for the order. **Splitting is
the pass.** Each child's description says which part of the family it is and the decisions already
reached. Clear every assignee, retype the parent as an epic, push, and plan no child:

```bash
bd update <child> <child> ... --assignee ""
bd update <id> --type epic --assignee ""
bd dolt push
```

The first line is defensive. Children are handed out one per pass, never before a blocker sibling is
**planned**; read the sibling's plan and describe the seam. The parent is retyped because parent
links do not block and bd refuses a child blocking its parent, while both pickups exclude `epic`.

## The title is part of the plan, and it is yours to fix

Rewrite the title unless a reader seeing only that line, with no id or description, knows what
changed and whether it affects them.

```bash
bd update <id> --title "…"
```

- Name the effect, not the area.
- No vague verbs (*fix*, *improve*, *update*, *handle*, *support*, *rework*).
- No internal names unless the module is the subject.
- For a bug, the symptom, not the suspected cause.
- About seventy characters.
- One whole thought.
- Distinct from its siblings.

Say what you renamed and why when you report the bead planned.

## The plan

Written with `--design-file`, read back as `beads-workflow` says. Every heading below must be present,
spelled exactly, as a `##` heading, or the implementer hands the bead back. Where one does not apply,
write **"None."** and say why.

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

1. **Context**: why the work exists and what changes when it lands.
2. **Files to change, and what to reuse**: concrete paths, and the existing functions and patterns to
   build on. It also carries the design of the code:
   - the public surface of anything new, written out in the project's language: the exported types
     and signatures, and what each returns;
   - where state lives: who owns it, what derives from it, what invalidates it;
   - which layer each piece belongs in when the work crosses the project's layers, and why.
3. **Increments**: small, ordered, each naming the failing test that opens it.
4. **The test plan**: each kind of test the project runs, with names and what each pins, and which
   suites must run.
5. **User-facing decisions**, with two `###` subsections, both always present:
   - `### Agreed with the navigator`: the whole interview, every question, answer, rejected option
     and why, the mockup path, and agreed strings verbatim;
   - `### Decided by me`: every detail you decided, one line each, the value as it ships and why.

   "None." under both for a bead with no user-facing surface.
6. **Out of scope**: what a reader might assume is included and is not.
7. **Validation**: the exact commands and any human check, under the two rules below.
8. **Known traps**: the hazards that apply here, or "None.".

### Validation a worktree cannot run

> **A worktree cannot validate a change through a reader that deliberately answers from the
> shared root.** `project-conf` and `agents-conf` read `.cerebro/project.conf` and
> `.cerebro/agents.conf` through `consumer-root --shared`; inside an implementer's worktree that
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

A trap is a fact a plan cannot be written correctly without. Read `<consumer>/.cerebro/traps.md` if
it exists and name any trap the bead touches with what to do about it; a missing file is ordinary.

### Everything you cite must exist

- Open every file you name and verify every symbol, quoting `file:line` and real names. A wrong
  citation is worse than none, because it is believed.
- Cite a predicate, filter or query only after reading what it accepts: one that exists may accept
  the opposite of what you cite it for. Run the query before asserting what a mechanism does.
- A seam a blocker is about to create is labelled as a promise: "`turnDiff.ts` does not exist yet —
  `<bead-id>` creates it with this surface (see its plan)".

### Before you mark it planned, read it as the implementer

Read the plan once as that agent and resolve every point where it would have to decide: decide yours
into *Decided by me*, and ask the navigator theirs. None of these may survive:

- "the implementer decides", "as appropriate", "something like", "or similar", or an unchosen option;
- an increment whose failing test you could not write from the plan alone (name, file, assertion);
- a user-visible string described rather than quoted;
- an unverified file, function or type, or a predicate cited without reading what it accepts;
- an acceptance criterion nothing can check;
- a block an agent will paste that quotes a bead id, a provenance file, one project's vocabulary or
  one project's audience word. *Context* may cite freely; a fenced block or blockquote ships to
  every consumer.

If this pass finds nothing, you skipped it. Length is not the measure: whether Sonnet could finish
without asking is.

## Finishing one, and the session

Report which bead you planned, what the navigator decided, and any title rename. Then end the pass:
one bead per pass, and the next session re-reads the board.
