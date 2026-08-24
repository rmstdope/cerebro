# cb-ypx — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #113

## Two beads in flight both appended "check 11" to `scripts/lint`

**What happened.** The plan specified the new advisory as *"check 11"*, by number, and the number
appears in the check's own heading comment and in three prose references (`CLAUDE.md`,
`scripts/ci-needed`'s header, `tests/ci-needed.sh`'s header). While this bead was in review, cb-k6r
merged (#112) with its own `# --- 11. the retired worktree path is named nowhere ---` appended at
the same anchor — the last check before the final `if [[ $status -eq 0 ]]`. The pull request read
`CONFLICTING DIRTY` before the CI wait, and `git rebase origin/main` conflicted on `scripts/lint`
with the two checks stacked against each other.

**Why.** The number is a name allocated at planning time from a global sequence, and two planners
allocated the same one because both read the same tree. Nothing in the file or the gate detects the
collision: two checks numbered 11 lint perfectly well, so only the textual conflict caught it, and
only because both landed at the identical anchor.

**Cost.** A conflict resolution, a renumber across four files, and one extra CI cycle — about
fifteen minutes, plus the earlier CI cycle spent on the pre-rebase head.

**Prevent by.** A plan for `scripts/lint` should name the new check by *what it checks*, not by its
ordinal — "append a check, headed with the next free number" — so an implementer allocates the
number against the tree it is merging into rather than the tree the plan was written against. The
same applies to any prose that cites one: `CLAUDE.md`'s reference to "check N" is a second place the
number has to be corrected, so citing the check's sentence ("the advisory that CI's skip list names
nothing a suite opens") rather than its number would survive a renumber untouched.

**Seen before.** none found.
