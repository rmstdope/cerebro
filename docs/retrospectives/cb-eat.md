# cb-eat — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-24
- **PR:** #137

## `mergeable` read `CONFLICTING DIRTY` for twenty seconds after a clean rebase and force-push

**What happened.** The PR came back `CONFLICTING DIRTY` before CI, so the run went to the local
rebase `implement-bead`'s *Merging* section prescribes. The rebase resolved one conflict in
`emacs/cerebro.el`, the gate was green, and `git push --force-with-lease` succeeded. The very next
`gh pr view 137 --json mergeable,mergeStateStatus` still answered `CONFLICTING DIRTY` — not
`UNKNOWN`, which is the only value the skill's poll waits out. Read literally, that answer sends the
run straight back into another rebase, of a branch that has nothing left to rebase onto. Twenty
seconds later the same command answered `MERGEABLE BLOCKED`, and `git log HEAD..origin/main` was
empty.

**Why.** GitHub recomputes mergeability asynchronously after a push, and while it does so it can
serve the **previous** head's verdict rather than `UNKNOWN`. The skill's poll only treats `UNKNOWN`
as "not yet known", so a stale concrete answer passes straight through it as if it were fresh.

**Cost.** About half a minute, and a near-miss: the documented next step for `CONFLICTING DIRTY` is
another rebase, which here would have been a no-op rebase followed by a second force-push and a
second CI cycle.

**Prevent by.** `implement-bead`'s *Merging* section, in the merge-state check: after a push of your
own, compare the PR's `headRefOid` with local `HEAD` and treat any mismatch exactly as `UNKNOWN` —
`gh pr view <n> --json mergeable,mergeStateStatus,headRefOid` returns all three in one call, so the
poll condition costs nothing extra. Without that, "did GitHub see my push yet" is invisible, and a
stale `CONFLICTING` is indistinguishable from a real one.

**Seen before.** `cb-akc` and `cb-ypx` both record a `CONFLICTING DIRTY` before CI, but both were
genuine conflicts on a head GitHub had already seen; neither describes a stale verdict after a
push.
