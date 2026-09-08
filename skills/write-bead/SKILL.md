---
name: write-bead
description: "Interview the navigator about a piece of work they want filed, then write the bead — what they want, why, what is wrong today, what done looks like, and whether it touches something a person sees — show it before anything is written, and file it unranked at P4. Use whenever somebody asks for a new bead. Invoked by hand as /write-bead, and loaded by the orchestrator when the navigator asks for one."
---

# Writing a bead

Somebody has asked for a bead. You interview them until you can **describe** the work, show them the
bead you mean to file, and write nothing until they approve it.

## What this skill is for, and what it is not

The bar here is deliberately lower than the planner's. `skills/plan-bead/SKILL.md` interviews until
it can **specify** — architecture decided, files named, increments and their tests written out,
something an agent could build unattended. This skill interviews until it can **describe**: enough
that a planner picking the bead up cold knows what the navigator wants and why, and does not have to
ask them again for facts they have already given once.

So, in this skill: no design decisions, no file lists, no test plan, no priority. Those are the
planner's and the navigator's, and a skill that made this session decide them would put a second
planner on the board.

Where the bead's own anatomy lives is `skills/beads-workflow/SKILL.md`, *Writing a good bead* —
which field each thing goes in, why every bead is created at P4, and what makes a title stand on its
own. Read it rather than guessing; this skill gathers the material and that one says where it goes.

## Before you ask anything: has this already been filed?

One command's worth of searching, before the first question:

```bash
bd dolt pull
bd search "<the strongest noun of the request>"
bd search --desc-contains "<the same noun>"
```

Two or three nouns, not the whole sentence. `bd search` includes closed beads by default, and that
default is kept on purpose: *was this already fixed?* must not silently answer no.

Show whatever comes back — ids and titles, closed ones included. If anything looks close, ask before
interviewing whether to file a new bead, add what was said to the existing one, or drop it. If
nothing comes back, say nothing about it and go straight to the interview.

## The interview

Five things, and the bead is not describable until you have them all:

1. **What the navigator wants.** The change itself, in their words.
2. **Why now, and what it is costing today.** This is the argument the ranking is later made from.
3. **What is wrong or missing today.** The current behaviour, concretely.
4. **What done looks like from the outside.** Observable, not internal — this becomes the
   acceptance line.
5. **Whether the change touches anything a person sees or presses.**

Ask them in rounds, up to four questions per round through the question tool, and choose each round
from what the last one answered — a follow-up that only the first answer would have suggested is the
whole reason this is a conversation rather than one form. **There is no cap on rounds.** Keep going
until you can describe the work; a vague request costs more interruptions than a clear one.

The fifth is **not** a design question. A *yes* is the planner's cue that the shape of the
interaction needs the navigator, and you record that fact in the description. You do not start
designing it, and you do not ask what it should look like.

## The draft, and the approval

Show the whole bead as it will be filed — type, priority `P4 (unranked)`, title, description, and
the acceptance line — and **write nothing until the navigator approves it**.

Any clear go-ahead is approval: "yes", "file it", "go". Anything else is a change to make, after
which you show the draft again.

A navigator who says nothing, cancels the question, or answers with a `[cerebro]` line leaves **no
bead filed**. Say so in one line and stop. Filing what you had is the un-interviewed bead this whole
skill exists to end.

## Filing it

Write the description to a file first — a bead's description is paragraphs, and `--description` on a
command line is not:

```bash
bd create "<the title>" --type task -p 4 --body-file /tmp/bead-body.md \
  --acceptance "<what done looks like, in the navigator's own terms>"
bd dolt push
```

Two commands, not a chain: a `bd create ... && bd dolt push` whose first half fails quietly leaves a
bead no other machine can see.

`--body-file` and `--acceptance` are where those two answers go because
`skills/beads-workflow/SKILL.md`'s *Writing a good bead* table says so; `--type` is one of
`feature`, `bug`, `task`, `epic`, and `-p 4` is explicit because bd's own default is P2.

Then report the id and the title back to the navigator.

## Offering the ranking, once

After filing, ask **once** whether to rank it now. If the navigator takes it, rank it through
`agents/orchestrator.md`'s *Ranking the backlog* — that same pass, not a second one of your own. If
they decline or do not answer, say the bead will come to the next ranking pass, and stop.

Never rank it unasked.

## When the navigator says "just file it"

Honour it. Skip the interview, write the bead from what they said, and **name in your report exactly
which of the five things went unanswered**, so both the navigator and the planner know the planner
will have to ask.

Two steps still run. The duplicate search, because it is one command and the one step that can save
the entire bead. And the draft, because a navigator approving a bead they have read is the cheapest
correction there is.

## When one request is several beads

When the request plainly holds more than one piece of work, **name the pieces you heard and ask**
whether to file one bead or several — before interviewing.

Never split silently, and never quietly file only the first thing you heard. If several are wanted,
interview and file them one at a time.

Add a `bd dep add` edge only where the navigator says the order matters. A guessed edge is worse
than none, because `bd ready` then lies about what is workable.

## What you never do

- Never decide a design, a file layout or a test plan. You are describing work, not planning it.
- Never set a priority the navigator did not choose. Every bead is filed at P4, unranked.
- Never file without showing the draft first.
- Never plan the bead you just filed.
