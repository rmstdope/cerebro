# cb-epr — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #110

## A bead that moves this repository's own declarations cannot be gated in a worktree

**What happened.** `bash tests/project-facts.sh` — the suite that asserts *this* repository's facts —
failed in the bead's worktree with `FAIL: project_name: got ''`, while every other suite passed and
CI was green. The bead moves `.claude/cerebro-project.conf` to `.cerebro/project.conf`; the worktree
had the new file, but `scripts/project-conf` resolves its root with `consumer-root --shared`, which
by design answers the **main** working tree every worktree shares. Main was still unmigrated, so the
reader found no file at the new path, one at the old, and did exactly what this bead added: refused.
The gate could not be run green anywhere inside the checkout until the merge itself.

**Why.** Established. `--shared` is deliberate and documented — the fleet's configuration is one
answer per checkout, not one per worktree — so a worktree legitimately reads main's declarations.
That is invisible for an ordinary bead, because both trees hold the same file; it only bites a bead
whose diff *is* the declaration. It is not a defect in `--shared` and not something the bead could
have avoided.

**Cost.** About fifteen minutes: the failure first read as a bug in the new refusal, and the way out
was to clone the branch into `/tmp` and run `bash tests/gate` there, which reproduces CI exactly
(a clone's `.claude/cerebro` symlink and `--shared` both resolve to the clone). Nothing was pushed
red and no CI cycle was spent on it.

**Prevent by.** `skills/implement-bead/SKILL.md`, *Building*, should name the escape hatch: when a
bead changes a file that `consumer-root --shared` resolves to the main checkout —
`.cerebro/project.conf`, `.cerebro/roster.conf`, `.cerebro/models.conf` — the fast gate is run in a
throwaway `git clone` of the branch, not in the worktree, because the worktree cannot be made
self-consistent without dirtying main. One line, and it turns a confusing red suite into an expected
one. (Recording only — the change to the skill is the navigator's.)

**Seen before.** `ah-il8j` — different subject (`bd` resolving its database to the shared checkout
rather than the worktree), same underlying shape: a worktree does not carry the shared checkout's
state, and a suite that asserts against that state fails there for a reason that is not the bead's.
