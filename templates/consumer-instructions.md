# Instructions for the fleet

Copy this to the root of a project that mounts cerebro, as `CLAUDE.md`: Claude Code loads it, and
Copilot loads the same file as its custom instructions when no `AGENTS.md` sits beside it. Replace
*The project* and *Work tracking* are headings the skills read by their exact names; edit the rest
until it says what is true here.

## The project

One paragraph: what this application is, who uses it, and what "working" means for it.

## Producer review

Nothing merges red. Before delivery, a producer obtains and addresses one independent, full review
of the complete diff and bead. If its changes are substantial enough to make another review useful,
the producer chooses the right follow-up scope and obtains it; minor, self-contained answers need
not create a review loop. Unresolved findings, a red or missing check, or a reviewer that cannot
produce a usable result go to a person.

## Work tracking

*Read by every role through `skills/beads-workflow`, which carries the commands; this section is
where a project says anything that differs.*

Planned work is tracked in beads. An external issue tracker, if there is one, is the inbox for
outside requests and bug reports only. Every bead is created unranked and ranked later with a human;
a bead is planned in one session and implemented in another.

## Development practices

*Read by planners and producers when deciding how much to build at once and how to test it.*

- Work is delivered in small increments that stand on their own.
- Code is written test-first.
- Prefer the simple design; say so when you decline a more general one.
