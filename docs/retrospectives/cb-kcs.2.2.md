# cb-kcs.2.2 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-09-01
- **PR:** #258

## A previous session left a finished implementation on a local branch with no PR

**What happened.** `prepare-worktree --path .cerebro/worktrees/cb-kcs.2.2 --branch
cb-kcs.2.2-hosted-session` refused with `fatal: a branch named
'cb-kcs.2.2-hosted-session' already exists`. `git branch -v` showed seven commits — every
increment of the plan — with no worktree, no open or closed PR, and the bead back on the
`planned` queue for me to claim. A session had built the whole bead and ended without pushing a
pull request, and nothing about the bead said so: `bd show` reads exactly like a bead nobody has
touched.

**Why.** Not established. The commits are dated four hours before I claimed it and the worktree
had already been pruned, so whatever ended that session left no trace I can read. The janitor
prunes worktrees; nothing prunes or reports a branch, which is what made the work invisible until
the tree refused to be created.

**Cost.** About twenty minutes, and it was a *saving* rather than a loss — but only because the
refusal happened to name the branch. The failure mode worth naming is the other one: had I
branched from `origin/main` under any other name, I would have rebuilt nine increments that
already existed, and the fleet would have paid for one bead twice.

**Prevent by.** `skills/implement-bead`'s *Workspace* section could say what to do when
`prepare-worktree --branch` refuses because the branch exists: it is not always leftover
scaffolding, it may be a complete abandoned implementation of the very bead being claimed, and
`git log --oneline origin/main..<branch>` is the one command that tells them apart. There is
currently no instruction for that refusal at all, and the obvious recoveries — a second branch
name, or `git branch -D` without looking — both discard the work silently. `prepare-worktree`
itself has no mode for an existing branch; I deleted and recreated the branch at its own sha,
which works but is a step that should not have to be invented under time pressure.

**Seen before.** None found — `grep -rl "already exists" docs/retrospectives/` matches nothing.

## The plan's cited helper had been retired by a refactor that merged first

**What happened.** The plan (and the abandoned branch built from it) called
`model::row_document_line` and `FLEET_STALE_PREFIX_LINES`. Both were retired by cb-0ps (#253),
which merged between the plan being written and me claiming the bead, in favour of
`app::fleet_body` + `app::body_line_of_row`. The rebase resolved cleanly and then failed to
compile with two `E0425 cannot find value` errors.

**Why.** Established: the plan names the helper as a citation with a line number, and
`skills/implement-bead`'s *When the plan is wrong* asks a current-source claim to be checked
before the increment that depends on it — which is exactly what a compiler error is a late,
cheap version of here.

**Cost.** Ten minutes, and it was caught by `cargo test` rather than by review, which is the
right end. Recorded because the compile error is only the *lucky* shape of this: had cb-0ps kept
the name and changed the meaning, the same drift would have produced a scroll offset with two
owners and no red test.

**Seen before.** None found.
