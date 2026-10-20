---
name: verify-bead
description: Psylocke looks herself - launch the merged build, inspect it in Chrome against what the bead agreed, and bring the navigator the evidence and a recommended verdict; the navigator decides.
---

# Verifying a bead by looking yourself

A project names this skill as `verification_skill` in `.cerebro/project.conf` when it would rather
have Psylocke look than hand the navigator a prepared run. Everything in `agents/verifier.md` that
is not about the look still holds: which beads are candidates, the fresh `origin/main` worktree,
the commit check, `verification=pending`, the port refusal, the sha in every verdict, the three
verdicts and their recipes, and the end of a pass. `verification none` wins over this skill: there
is nothing to launch, and this skill is never reached. What changes is who looks, and that the
verdict reaches the navigator as a recommendation with evidence rather than as a question about
what they saw.

**Every question here is the three-action sandwich** of the verifier's state contract:
`agent-state Psylocke asking --bead <id> --phase verify --pid $PPID`, the question, then `working`
before anything else. Write `working --bead <id> --phase verify` the moment you start the declared
server; everything before that is `prepare`.

## Prepare

Prepare as *Preparing, before you ask for anything* in `agents/verifier.md` says: the outcome, the
acceptance, both halves of the plan's **User-facing decisions**, the latest `## The bug, as fixed`
note for a bug bead, and every in-scope child for an epic. The briefing it asks for is written for
your own report rather than for the navigator: for each criterion, what you will do in the app and
what success looks like.

Load the `claude-in-chrome` skill before the first browser action. If no `mcp__claude-in-chrome__*`
tool exists in this session, the browser integration is unavailable, and that is a blocker (below).
The browser is the navigator's own Chrome on this machine, so the server you start is reachable at
`http://localhost:<port>`, the port being `project-conf launch_<name>_port`.

## Launch

Run the declared launch command exactly as `agents/verifier.md` says, from the fresh worktree, on
the declared port, after the port check it spells. Never improvise a command, and never kill or
reuse a server you did not start: an occupied port is a question to the navigator ("something is
already serving on <port> (pid …); stop it and say when"), and the wait is a sandwich.

A blocker is anything that stops the look: no launch target, a command that fails, an app that
never becomes usable, no browser tools. Put the specific help or decision you need to the navigator
through the question tool, and wait. Never substitute a different command, build, browser, fixture
or test for the look. If the navigator cannot clear it, leave the bead pending and say what stopped
it in one line.

## Look

Open the app in Chrome and walk the journey the bead changed, as a person would: the interactions,
the navigation, and the empty, loading, error and phone-width states where the acceptance names
them. Along the path, notice whether what the bead did not touch still behaves. For an epic, walk
every child in scope: a family verdict must not hide a child nobody looked at.

The evidence is a log, one entry per criterion: what you did, what appeared, and a screenshot taken
through the Chrome integration, named in the entry. A test result, a reading of the source, or the
DOM is not evidence that a person would see it; it may tell you where to look, never what you saw.
A criterion you could not reach in the running app is a gap in the log, not a pass: say so, and if
the way to reach it is unclear, ask.

## Recommend

Before you ask anything, write the report onto the bead, so an unanswered question leaves the
evidence with the bead and the next pass re-asks instead of re-looking. Its first line is always
`Verification report at <full sha>`, so a later pass can find it with `bd show`:

```bash
bd update <id> --append-notes "<the report>"
bd dolt push
```

A pending candidate whose latest note is a report at the sha `prepare-worktree` just printed is
re-asked from that note, with no new look. A report at any other sha is stale: main has moved, and
you look again, as the sha rule demands.

The report, one per bead and per child where a family was walked, answers the two questions the
verdict turns on in `agents/verifier.md`'s *Taking the verdict*, each from the log:

1. **Does it do what was agreed?** The acceptance, and the mockup where there is one.
2. **Does it solve the problem it was filed for?** The `## Outcome`.

The recommendation follows that section's rule: yes and yes is **Passed**; yes and no is **Passed,
with a follow-up** unless the delivered work should not stand, which is **Failed**, `--fault plan`;
no to the first is **Failed**. The report carries the bead's title, the full sha you looked at, the
log, every gap, and for each follow-up you think is worth a bead, a title, the outcome for the
audience (`project-conf audience_noun`) or the developer, one acceptance line, and why it is not a defect in this bead.

Then ask, in one call of the question tool, with a sandwich: accept or change the verdict, and
file or drop each proposed follow-up. Write the board only with what they answered, by the recipes
in *Taking the verdict*: a follow-up they approved is filed at P4, unranked; a declined one is not
filed; a failure asks plan or build and runs

```bash
.cerebro/cerebro/scripts/reopen-failed <id> --sha <full sha> \
  --notes "<your evidence, as the navigator accepted it>" --fault plan   # or: build
```

If they are away, the bead stays pending with the report attached, and the silence closes the
sandwich as the verifier says: `working --phase prepare`, or `end-pass`. Keep the server only while
the look or a question needs it, and stop only the process you started.
