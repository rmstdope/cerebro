# cb-bqp — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-25
- **PR:** #141

## `mergeable` read `CONFLICTING DIRTY` for a second time after a clean rebase and force-push

**What happened.** Before the first CI wait the PR read `CONFLICTING DIRTY`, correctly: main had
moved and `git rebase origin/main` really did conflict, in `tests/lint.sh`, where cb-u5e had
appended its own cases at the same anchor as mine. I resolved it keeping both blocks, ran the whole
gate green, and `git push --force-with-lease` succeeded. The merge-state check immediately after
that push answered `CONFLICTING DIRTY` again — not `UNKNOWN`, which is the only value the skill's
poll waits out. Read literally, that sends the run into a second rebase of a branch with nothing
left to rebase onto. `git fetch origin main` showed `HEAD..origin/main` empty, and ten seconds
later the same command answered `MERGEABLE BLOCKED`.

**Why.** GitHub recomputes mergeability asynchronously after a push and can serve the previous
head's concrete verdict while it does. The skill's poll treats only `UNKNOWN` as "not yet known",
so a stale concrete answer passes straight through it as if it were fresh. Established here only
as far as the observation goes — the mechanism is GitHub's and I did not prove it beyond the timing.

**Cost.** About a minute, and the same near-miss cb-eat records: the documented next step for
`CONFLICTING DIRTY` is another rebase, which here would have been a no-op rebase, a second
force-push and a second CI cycle.

**Prevent by.** The change cb-eat already proposed, unmade: `implement-bead`'s *Merging* section,
in the merge-state check, should treat a `CONFLICTING` answer arriving within a few seconds of
your own push as not yet computed — re-read it once after a short sleep, and only believe a
`CONFLICTING` that survives that or that arrives without a push behind it. As written the poll
waits out `UNKNOWN` and nothing else, so the stale answer is indistinguishable from a real
conflict. This is the second run to hit it, which is the evidence that the wording rather than the
implementer is what needs changing.

**Seen before.** `cb-eat` — same symptom, same command, same near-miss, one bead earlier.
