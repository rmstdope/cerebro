---
name: write-bead
description: "Interview the navigator about a piece of work they want filed, then write the bead"
---

# Writing a bead

Somebody has asked for a bead.

## What this skill is for, and what it is not

Interview until a designer or developer picking the bead up cold knows what the navigator wants and
why, and need not ask them again. No design decisions, no file lists, no test plans: those are the
planner's and the navigator's. Which field each thing goes in, P4, and the title rule are *Writing a
good bead* in `beads-workflow`.

## Before you ask anything: has this already been filed?

```bash
bd dolt pull
bd search "<the strongest noun of the request>"
bd search "<a second noun>"
```

Two or three nouns, one search each. Closed beads are included on purpose. `--desc-contains` only
narrows the query, so it cannot search descriptions alone.

Show what comes back. If anything is close, ask whether to file new, add to it, or drop it. If
nothing comes back, say nothing.

## The interview

Three things, and the bead is not describable until you have them all:

1. **What the outcome is.** What improves for the user or the developer?
2. **What done looks like from the outside.** Observable, not internal — this becomes the
   acceptance line.
3. **Whether the change touches anything a person sees or presses.**

Ask through the question tool, up to four questions per round, each round chosen from what the last
one answered. There is no cap on rounds: keep going until you can describe the work.

The third is **not** a design question: record a *yes* in the description, and design nothing.

When you have all three, file the bead without asking for approval.

## Filing it

Write the description to a file first:

```bash
bd create "<the title>" --type task -p 4 --body-file /tmp/bead-body.md \
  --acceptance "<what done looks like, in the navigator's own terms>"
bd dolt push
```

Two commands, not a chain: a `&&` whose first half fails quietly leaves a bead no other machine can
see. The flags follow *Writing a good bead* in `beads-workflow`. Report the id and the title.

If the request is a defect to be fixed (wrong behaviour, regression, breakage), file it as
`--type bug` **and add the `bugfix` label** at creation time. `bugfix` is the routing label that
sends the bead to the bugfixer flow instead of UX → producer.

## Offering the ranking, once

After filing, ask once how to rank it, through *Ranking the backlog* in `agents/orchestrator.md` —
that pass, not one of your own. If they decline, say it goes to the next ranking pass and stop.
Invoked by hand outside a Cerebro session there is no pass: say it goes to the next one and stop.

## When the navigator says "just file it"

Honour it: skip the interview, write the bead from what they said, and name in your report which of
the three things went unanswered, so the planner knows to ask. The duplicate search still runs.

## When one request is several beads

Name the pieces you heard and ask whether to file one bead or several, before interviewing. Never
split silently, and never file only the first. If several, interview and file them one at a time.
Add a `bd dep add` edge only where the navigator says the order matters; a guessed edge makes
`bd ready` lie.

## What you never do

- Never decide a design, a file layout or a test plan.
- Never set a priority the navigator did not choose. Every bead is filed at P4, unranked.
- Never plan the bead you just filed.
