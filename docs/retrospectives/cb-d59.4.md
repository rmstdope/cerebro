# cb-d59.4 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-27
- **PR:** #176

## A nine-minute wait loop that hit its Bash timeout printed nothing at all

**What happened.** The CI wait was written as a 16-iteration `for` loop with `sleep 30`, run with
`timeout: 540000` — under the ten-minute ceiling `implement-bead` names. The loop never reached its
break, the call was killed at nine minutes with exit 143, and **every line it had echoed was
discarded**: the tool result was the timeout message and nothing else. Nine minutes of polling
produced no observation at all, and the next call had to start the question from scratch.

**Why.** Established: the harness returns a killed `Bash` call's output as nothing, not as a partial
stream. A loop whose worst case is the timeout therefore has a worst case of zero information, not
of a truncated log. (The same loop shape had worked minutes earlier when it broke on its own.)

**Cost.** About nine minutes, and one blind CI cycle — small here only because the checks had in fact
gone green in the meantime.

**Prevent by.** Sizing the loop so it **returns on its own** before the timeout, rather than merely
setting the timeout below the ceiling: iterations × sleep should be comfortably under the `timeout`
value (e.g. 12 × 30s = 6m under a 9m timeout), so the call always exits normally and its output
survives. `implement-bead`'s *Waiting, without ending your run* says to keep each call under ten
minutes and to call again — worth adding that the loop must be the thing that ends, not the timeout.

**Seen before.** None found.
