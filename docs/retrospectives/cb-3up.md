# cb-3up — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-31
- **PR:** #204

## No Copilot review arrived, and the standing approval has no path without one

**What happened.** The PR was opened and `gh pr edit 204 --add-reviewer @copilot` succeeded, but
`repos/rmstdope/cerebro/pulls/204/reviews` returned zero Copilot reviews for the whole wait (and one
`TLS handshake timeout` mid-loop). The navigator interrupted to say GitHub reviews were unavailable
and directed a `code-review` sub-agent over the diff instead, which is what actually reviewed this
change.

**Why.** GitHub Copilot code review was unavailable at the time. Not established beyond that; the
request itself was accepted, so this is the reviewer not running rather than the request failing.

**Cost.** About nine minutes of review wait, plus the navigator's interruption. No CI cycles.

**Prevent by.** The consumer's root `CLAUDE.md` (*Four Eye Principle*) makes Copilot's review the
second pair of eyes and names only one alternative — "everything else needs the navigator" — so an
implementer whose review never comes has exactly one documented move: escalate the bead and leave
the PR open (`implement-bead`, *The review*, the twenty-minute rule). That is correct when the
navigator is asleep and wasteful when they are present and can nominate a substitute reviewer, as
happened here. If a sub-agent review is to count as the second pair of eyes, the Four Eye Principle
is where that has to be written — an implementer cannot decide it, and this run only merged because
the navigator said so directly.

**Seen before.** None found — no retrospective in `docs/retrospectives/` describes a missing or
unavailable review.

## The plan's measured runtime had tripled by the time the bead was built

**What happened.** The plan measured `scripts/fleet-cost --by-bead --since 7d` at **1.5s** with the
fix in place, and used that number to decline windowing the `SELECT` as out of scope. The same
command on the same machine at build time takes **14.4s**.

**Why.** The store grew between planning and building — the plan's own analysis says the blob grows
with every session the fleet runs, and the whole-store read is unwindowed by design.

**Cost.** None to this bead: 14s is still an answer, the shape is unchanged, and the decision to
leave the `SELECT` unwindowed is unaffected. Recorded because the *reasoning* behind that decision
has a measurement in it that is decaying.

**Prevent by.** The plan's *Out of scope* already names the trigger — "if the store ever grows
enough to be felt, that is its own bead with its own measurement". Whoever files that bead should
know the number moved 1.5s → 14.4s in roughly a day of fleet activity, so the threshold will be
reached by the store growing rather than by anything anyone changes.

**Seen before.** None found.
