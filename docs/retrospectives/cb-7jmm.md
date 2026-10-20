# cb-7jmm retrospective

## The local gate stays red under load after the port collision is fixed

**What happened.** With the fix in place, `bash tests/gate` ran three times locally, at load averages of 15, 21 and 40, with other fleet sessions building. All three were red, each in a different step. `tests/fleet-view-restart.sh` hit its 90 s start wait twice. `tests/fleet-keys.sh` failed twice: once on "the stub agent to start", once on "roster did not answer within 5s" on a view that was already supervising. The Rust `a_released_lease_is_bindable_by_a_successor` failed once, with "cannot locate the supervision lease": a `fleet-supervisor` call failed rather than the bind. The roots involved got distinct ports (31280, 30003, 25732). Every failing suite and test passed when run alone, and CI was green on both heads.

**Why.** Load, not the lease. Five-second reader timeouts and the 90 s bounds are not met while about 40 runnable processes share the machine. cb-eguq's retrospective treated cb-gyw0's local red as "the same" collision. This shows that collision was one cause among others, not the only one.

**Cost.** About 20 minutes and three full local gate runs, spent ruling out that the new hash had made a new collision.

**Prevent by.** When a fleet-view system suite fails, print the load average and the view's endpoint in its dump (`tests/fleet-view-restart.sh` and `tests/fleet-keys.sh` failure blocks). Then a red run says at once whether it was a lease or a clock.

**Seen before.** cb-gyw0 (fleet-view-restart red locally at load 68), cb-abs.1 (a fork-per-attempt test is load-sensitive), cb-eguq (attributed cb-gyw0 to the port collision, which this bead fixed).
