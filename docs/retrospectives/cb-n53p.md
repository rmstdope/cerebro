# cb-n53p — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-10-20
- **PR:** #494

## R15's system test failed at its first start, before anything the change touched

**What happened.** Timing `tests/fleet-view-restart.sh` locally on macOS, 4 of about 12 runs failed
with `after 90s: the view starting Rogue on the first ready bead, cb-b1`. In those runs
`decisions.jsonl` and `evaluations.jsonl` were empty and the view never started anything. A copy
of the pty capture showed the header `Cerebro — read-only; this window could not take charge of
the fleet`, then `supervising`, with Rogue `dead` and `Press s to start Rogue.`

**Why.** Partly established. `main.rs` runs `arm_and_autostart` only when the *first*
`SupervisorController::apply()` supervises. A transient `LockError` on that first attempt,
followed by a successful retry five seconds later, leaves a supervising view with an empty armed
set for the rest of its life. Which error the first attempt hit was not established: once a debug
line was added to `acquire`'s error arm, 16 runs in a row were green.

**Cost.** About twenty minutes of diagnosis and roughly fifteen extra suite runs, all on a fault
that is on main and has nothing to do with this bead's diff.

**Prevent by.** cb-eguq: arm the roster's declaration on the first tick that takes the lease, not
only when the startup attempt does. Also, `explain()` in `tests/fleet-view-restart.sh` should
print the view's header line (the supervision mode), so a run like this names the read-only start
straight away.

**Seen before.** None found.
