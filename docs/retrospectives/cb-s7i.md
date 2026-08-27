# cb-s7i — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-25
- **PR:** #147

## A plan's validation step read the declaration the bead was adding, and cannot pass in the worktree

**What happened.** The plan's *Validation* section lists
`.claude/cerebro/scripts/project-conf verification` with the expectation that it "prints `none'
(this repo declares it)". Run in the bead's worktree, immediately after adding the key to
`.cerebro/project.conf`, it printed `project-conf: verification unset, and no default`. Nothing was
wrong with the edit: `project-conf` resolves its root with `consumer-root --shared`, which by design
answers the **main** working tree, where the key does not exist until this PR merges. The check can
only pass after the merge it was meant to gate.

**Why.** Established, and already established twice before — `--shared` is deliberate (the fleet's
configuration is one answer per checkout, not one per worktree), and it is invisible except to a
bead whose diff *is* a shared declaration. What is new here is only where it surfaced: not in a red
suite, but in a plan's own validation list, where a step that cannot pass reads as a broken edit.

**Cost.** About two minutes, and no CI cycle — the gate was green throughout. The risk it carries is
larger than the cost it charged: the obvious response to "the key I just added reads as unset" is to
go on editing the declaration, which is how a correct file gets made wrong.

**Prevent by.** Two places, both the navigator's to change. `skills/plan-bead` should say that a
bead touching `.cerebro/project.conf`, `.cerebro/roster.conf` or `.cerebro/models.conf` must not put
a `project-conf`/`roster` read in its *Validation* list without saying it answers about main and
passes only after the merge. And `skills/implement-bead`, *Building*, still lacks the escape hatch
`cb-epr` asked for a day earlier: run the gate in a throwaway clone of the branch when the bead's
diff is one of those files. (Recording only.)

**Seen before.** `cb-epr` — same `--shared` shape, surfaced as a red suite instead of a validation
step; `ah-il8j` — same shape again, with `bd`'s database rather than `project-conf`. Third sighting.
