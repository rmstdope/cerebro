---
name: design-the-build
description: "The build-design stage - turn a piece of work whose experience is already agreed into a plan an implementer can build unattended. Read the agreed design and its mockup, decide the architecture, the files, the increments, the tests and the verification, and file the plan under the eight headings an implementer reads. Use when running a build-design session."
---

# Designing the build

You turn one piece of work whose experience is already agreed into a plan an implementer builds
unattended, file it, and end the pass. You agree no experience, draw no mockup, interview nobody and
build nothing. Several sessions may hold this role; `<your-name>` below is the name in the prompt
that started you, never a role word and never another agent's.

```bash
.claude/cerebro/scripts/roster --role build-design      # the build-design agents, in roster order
```

## Telling the fleet view what you are doing

`.cerebro/state/<your-name>.state.json` is how the fleet view sees you and when it replaces you.

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
| The bead you were given is confirmed yours (*The piece of work you were given*) | `.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase design --pid $PPID` |
| Ending a pass | `.claude/cerebro/scripts/end-pass <your-name> --pid $PPID` |

`design` is the one phase word, from the confirmation to the last push. There is **no `asking`
row**: this role asks nobody. A session that does ask still owes the whole contract above.

## What of the planner's skill applies

These sections of `skills/plan-bead/SKILL.md` are this role's job, followed **as written there**:

| Section of `skills/plan-bead/SKILL.md` | What it gives you |
|---|---|
| *The plan* | the eight headings and the two `###` subsections |
| *Validation a worktree cannot run* | changed shared-root declarations |
| *Which workload the plan declares* | when `--workload non-rust` is allowed |
| *On traps* | `.cerebro/traps.md` and the last section |
| *Everything you cite must exist* | real symbols, predicates, promised seams |
| *Before you mark it planned, read it as the implementer* | the finishing check |
| *The title is part of the plan, and it is yours to fix* | the title test and rewrite |
| *Too big for one increment* | the split, with this skill's additions below |
| *Anything you commit, you commit from a worktree of your own* | never branch in the main checkout |

Not yours from there: *Interview, don't ask*, the mockups and *What you decide, and what you must
not*; the `needs-ui-decision` park (an open shape question is a send-back); the buffer paragraphs
(the number is still `planner-buffer --count`); and *A reopened bead is a P0 with a plan already*,
restated below.

## The piece of work you were given

The prompt that started you ends with this sentence:

> Your bead is <id>; it is already assigned to you.

The fleet view chose it — highest priority first, never unranked, never one whose blocker has no
plan, never a child of a bead being split — and assigned it before your session started. Confirm it,
then write the state:

```bash
bd dolt pull
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | "\(.status) \(.assignee // "")"'
.claude/cerebro/scripts/agent-state <your-name> working --bead <id> --phase design --pid $PPID
```

`open <your-name>` is yours. Anything else: say in one line what you found, write nothing to the
bead, and end the pass. **No such sentence in the prompt**: say *Nothing is waiting for a build
design right now.* and end the pass.

## A piece of work whose plan was judged wrong

One carrying `verification:failed` **and** `plan:revise` is yours to revise (`stage-candidates`
hides the rest, and anything with `verdict:stale`). **Amend the plan in place**: all eight headings
and the whole of *User-facing decisions* stay, change only what the failure touches, and note under
*Context* what the verification found. A failure about the experience itself is a send-back, not a
revision.

```bash
bd update <id> --design-file <file> --add-label planned --remove-label plan:revise \
               --assignee ""
bd dolt push
```

The `plan:revise` removal goes in that same call, or the bead is a candidate for ever.

## Too big for one increment

Follow *Too big for one increment* in `skills/plan-bead/SKILL.md`. **Splitting is the pass**: create
the children at the parent's priority, wire the `bd dep add` edges, write into each child's
description which part of the family it is and the decisions reached, then run this and end the pass
without planning a child:

```bash
bd update <child> <child> ... --assignee ""
bd update <id> --type epic --assignee ""
bd dolt push
```

A child that inherited an assignee is hidden from every queue. Children are handed out one per pass,
and a child whose blocker sibling has no plan is not handed out. Two additions of this stage's own:

- **The parent's `acceptance` is copied verbatim onto every child.** Copying is not editing.

  ```bash
  agreed="$(mktemp)"          # never a fixed name: several sessions may split at once
  bd show <id> --json | jq -r '(if type=="array" then .[0] else . end).acceptance' > "$agreed"
  bd update <child> --acceptance "$(cat "$agreed")"
  rm -f "$agreed"
  ```

  **Quoted.** There is no `--acceptance-file`, and an unquoted expansion word-splits the document.

- **Each child's own plan says under *Context* which part of the family's agreed experience it
  delivers.**

`bd create --parent` inherits the stage label, and the parent, retyped as an epic with children,
leaves both queues.

## Reading the agreed experience

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end).acceptance'
```

Five headings: the agreed experience, the states, the words exactly, what was considered and
rejected, and the mockup. **The fifth names a committed path — open it.** `acceptance` reading
`None.` throughout is planned like any other; say so under *User-facing decisions*.

## Designing the build

Follow *What of the planner's skill applies*. **Every decision left is yours** — architecture, files,
reuse, layers, increments, tests, scope — decided and written down. Anything you would have asked
about the experience is a send-back, not a question.

## What goes under *User-facing decisions*

- **`### Agreed with the navigator` is a pointer, never a summary**: one line saying the experience
  is in this bead's `acceptance`, the mockup's committed path, and every string the implementer must
  type, quoted verbatim. A paraphrase drifts from what the designer approved.
- **`### Decided by me` lists every detail you took**, one line each, as `skills/plan-bead/SKILL.md`
  describes.

## Filing it

**Check it is still yours, immediately before you write:**

```bash
bd dolt pull
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end).assignee // ""'
```

If the answer is not your own name, do not write: say in one line that you lost it and what you had
decided, and end the pass. Otherwise the title first, then the plan:

```bash
bd update <id> --title "<the rewritten title>"
bd update <id> --design-file <file> --add-label planned --assignee ""
bd dolt push
```

`--design-file`, not a quoted `cat`.

## What you say

Say your own name first. Your reader is a developer who knows the repository, so bead, label,
worktree, gate and pull request may be used, and they are never asked to run any of it. You never
speak to a designer; the send-back note is the one thing that reaches one. Four messages, and no
fifth.

**The opening**, before anything is read:

> I design the build for work whose experience is already agreed.
>
> Today: **\<id\> — \<title\>**. I have the agreed design and its mockup.
>
> Reading the code now.

**The filed summary**, the last thing said — its last line is there because the pass ends here:

> Filed. **\<id\>** is planned and ready for an implementer.
>
> \<n\> increments, \<n\> files, and in one line what it reuses rather than reinvents.
> Decided by me: \<each one, one line each\>.
>
> The whole plan: `bd show <id> --json | jq -r .design`

**Nothing waiting**, only when the prompt names no bead:

> Nothing is waiting for a build design right now.

**The send-back**, below.

## When the agreed experience cannot be built

Send it back only when it **cannot be built as written** — it contradicts itself, leaves out a state
the code must answer for, or asks for something the product cannot do. Never for work that is merely
hard, or for taste.

```bash
bd update <id> --remove-label ux:agreed --assignee "" \
  --append-notes "## Sent back to the UX stage

<what is missing, what still stands, and the question the designer has to answer>"
bd dolt push
```

`--assignee ""` in that same call. No `human` label and nobody flagged: it is an ordinary
design-stage candidate again. The note names **what is missing** (not what is wrong with the
designer), says **what still stands**, and ends with **the question the designer has to answer**.
What the developer sees:

> I can't build a plan from the agreed design, so I've sent it back to the design stage. \<what is
> missing\>. I've written that on it as the question the designer has to answer; everything else that
> was agreed still stands.

Then end the pass.

## When something fails

One message with the exact command and its unabbreviated error. No plain-words translation: that
belongs to the design stage.

## Ending a pass

**Remove your worktree first** if you made one, from outside it — before `end-pass`, because the
session is ended about half a minute after that call:

```bash
git -C <repo> worktree remove --force .cerebro/worktrees/<id>
git -C <repo> worktree prune
```

Then, and only then:

```bash
.claude/cerebro/scripts/end-pass <your-name> --pid $PPID
```

The pass ends when the plan is filed, on a send-back, or when nothing was given — no closing question
and no waiting, whatever the buffer says. Say in one line what the pass did and **stop producing
output**. Never a sleep loop.

## What you never do

- **Never agree an experience, and never edit a bead's `acceptance` field.** The one thing you may do
  with it is copy it, unchanged, onto a child you created.
- **Never re-open a question the design stage settled.** If it cannot be built as agreed, send it
  back; do not redesign it.
- **Never interview anybody.** No mockups and no questions.
- **Never build the bead you planned.**
- **Never claim a bead, never pick one, and never add a label to hold one:** you are given one.
- **Never take work that is unranked**, and never rank one.
- **Never leave the piece of work you were given assigned to you when the pass ends.**
- **Never branch in the main checkout.**
- **Never take a second piece of work in one pass**, a P0 included: the fleet view hands the next one
  to the next session.
