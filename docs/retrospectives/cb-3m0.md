# cb-3m0 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #185

## A plan's validation step read the declaration the bead was adding — fourth sighting

**What happened.** The plan's *Validation* section says to run
`.claude/cerebro/scripts/project-conf role_start_spacing_planner` by hand and expects it to print
`60` "after increment 7". Run in the bead's worktree with the key freshly written into
`.cerebro/project.conf`, it printed `project-conf: role_start_spacing_planner unset, and no
default` — twice, for both keys. The edit was correct: `project-conf` resolves its root with
`consumer-root --shared`, which answers the **main** working tree, where the key does not exist
until this PR merges.

**Why.** Established, and established four times now. `--shared` is deliberate — the fleet's
configuration is one answer per checkout — and is invisible except to a bead whose diff *is* a
shared declaration. What is new here is only that `cb-s7i` recorded this exact shape two days
earlier, named the two files that would prevent it, and the next plan touching
`.cerebro/project.conf` carried the same step again. So the finding is no longer "this surprised
an implementer"; it is "a recorded, diagnosed finding did not reach the role that files the
step".

**Cost.** About two minutes, and no CI cycle. The same risk cb-s7i names: the obvious response to
"the key I just added reads as unset" is to keep editing a file that is already right.

**Prevent by.** Exactly what `cb-s7i` already asked for and has not had: `skills/plan-bead` saying
that a bead touching `.cerebro/project.conf`, `.cerebro/roster.conf` or `.cerebro/models.conf` may
not put a `project-conf`/`roster` read in its *Validation* list without stating that it answers
about main and passes only after the merge. On a fourth sighting the count is the argument — a
class of defect earns a check the second time it happens, and this is twice that. (Recording only;
the change is the navigator's.)

**Seen before.** `cb-s7i` (third sighting, same validation-step shape), `cb-epr` (a red suite),
`ah-il8j` (`bd`'s database rather than `project-conf`).
