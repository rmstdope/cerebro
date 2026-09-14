# cb-10d.3 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-14
- **PR:** #389

## A bead named by the navigator mid-turn had no path in the skill

**What happened.** The session started with no bead in its prompt. Before it could run `end-pass`,
the navigator typed "build cb-10d.3". `bd show` said the bead was `open` with no assignee, so
it had not been handed out. *Picking up* says two things that collide here: never claim a bead
(hand back one that is not yours), and a prompt with no bead ends the pass. I took it with
`scripts/assign-bead Storm cb-10d.3`, the fleet view's own writer, which refuses a bead somebody
else holds and would also have made this very worktree once cb-10d.3 is merged.
**Why.** The skill assumes the fleet view is the only thing that gives a builder its bead. It does
not cover a navigator's direct instruction.
**Cost.** A judgement call on the first turn, and a risk of racing a view start on the same bead.
No time was lost.
**Prevent by.** `skills/implement-bead` *Picking up*: one sentence for a bead the navigator names
directly — take it only through `scripts/assign-bead <name> <id>`, never with `bd update --claim`,
and hand it back if that exits 3.
**Seen before.** none found
