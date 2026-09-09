# cb-yug — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-09
- **PR:** #361

## A fixture that removes a shared library disables the scripts under test *and* the ones they call

**What happened.** A review finding asked for a case proving `scripts/agent-asking end` still
restores when `scripts/state-write.sh` is missing. The fixture for that is
`rm -f "$tmp/.claude/cerebro/scripts/state-write.sh"` — but `agent-asking`'s restore path calls
`scripts/agent-state`, which sources the *same* file, unguarded. So the assertion
(`end` flips `asking` → `working`) could never pass, and the weaker assertions I replaced it with
(`begin` leaves the row unflipped) could never *fail*, for the same reason. Two consecutive delta
rounds were spent on that one case: the first caught that it exercised the wrong branch, the second
that its remaining claim was unfalsifiable. Both were right.

**Why.** A consumer fixture's `scripts/` directory is shared by every script placed in it
(`tests/lib/place-scripts` resolves each script's `source` lines transitively into one directory),
so removing one library removes it for the whole call chain, not just for the script named in the
case. Nothing about the `rm` line says that.

**Cost.** Two extra delta review rounds and three commits, about twenty-five minutes of a
fifty-minute bead. The gate was never red; the defect was a test that passed for the wrong reason.

**Prevent by.** Mutation, not reading: before believing a new case, break the line it names in the
script under test and confirm the case goes red. That is what settled all three rounds here, and it
is cheap — one `perl -0pi` and one suite run. `skills/implement-bead`'s *The review loop* asks that
every fix be read by somebody who did not write it; the complement, for a case whose whole job is to
pin one line, is to prove it can fail before asking anybody to read it.

**Seen before.** `cb-bch.2` — a vacuous test, caught before it ran rather than after; this is the
second sighting of the class and the first where it survived into a pushed commit.
