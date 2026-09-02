# cb-kcs.5.4 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #284

## A test written to answer a review finding was itself the next defect, twice

**What happened.** Two of the five review rounds this bead cost were spent on defects introduced by
the commit answering the round before it, both in code the finding had just pointed at.

Round one found the History section unreachable — the cursor could not leave the last bead row, and
nothing else wrote `work.scroll`. The fix made `move_work_cursor` return whether it moved, with an
early `if self.work_cursor.is_some() && target == current { return false }`. Round two found that
this read a *stale* cursor (`work_cursor_index` → `None` → `unwrap_or(0)`) as a cursor already at
index 0, so `Up` on a bead whose section had just been collapsed left the selection stale for ever.

Round four found the same shape one level down. Round one had also found the new reader-contract
case too weak to catch a renamed field; the fix added a second assertion comparing the numbers
`scripts/fleet-history --summary` printed against the fields that read them — by running the script
a **second** time. `open_min` is elapsed-since-open, recomputed from the clock on each invocation,
so the two runs disagree by 0.1 whenever they straddle a tenth of a minute. It passed six times
alone and failed one workspace run in three, and it can only ever fail on a machine with an open
transition — the navigator's own fleet — never in CI.

**Why.** Both fixes were written against the finding rather than against the code around it. The
first folded a new "did nothing" case into an existing `unwrap_or(0)` that already meant something
else; the second reached for a second call to the thing under test when the bytes it needed were
already in hand. Answering a finding is exactly where attention is narrowest, which is what the
`implement-bead` skill says about delta rounds — this bead is two more sightings of it.

**Cost.** Two extra review rounds and two extra pushes, roughly 25 minutes. Both defects were
caught by the round after them, so neither reached main; the flake in particular would have reached
main under any process that stopped reviewing once the findings were answered.

**Prevent by.** Nothing to change in the harness — the rule that caught both is already written
down (`skills/implement-bead`, *The review loop*: "every fix is still read by somebody who did not
write it… a fix that answers a finding is exactly where the next defect goes"). What this bead adds
is evidence for a narrower habit worth having when a fix touches a test that runs a real program: a
test that invokes the program under test more than once is comparing two different moments, and any
clock-derived field in its output makes that comparison a coin toss. Parse once, assert many times.

**Seen before.** None found — `grep -rln "per invocation\|two runs\|wall clock" docs/retrospectives/`
matched only two files, both about unrelated tool timeouts.
