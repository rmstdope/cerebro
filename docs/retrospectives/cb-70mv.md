# cb-70mv — retrospective

- **Implementer:** Rogue
- **Date:** 2026-11-10
- **PR:** #537

## The local gate was red twice in fleet-keys.sh, and one restart run stayed read-only, while CI was green

**What happened.** While I was timing the changed `tests/fleet-view-restart.sh` alone, it failed 3 times in about 14 runs. Each time the header read `read-only; this window could not take charge of the fleet` for the whole 90 s first wait, and the run left no `supervisor.json`, `decisions.jsonl` or `errors.jsonl`. The next 28 runs were green. Both runs of `bash tests/gate` then failed only `tests/fleet-keys.sh`, on "timed out waiting for: the stub agent to start" (its 20 s bound). It passed twice alone. The same fleet-keys failure appears in cb-15cw's and cb-yf8h's suite logs from the same hour. The load average was 6 to 9. In CI, fleet-keys took 19 s and the restart suite 27 s, both green.

**Why.** Not established for this run. It fits cb-8484's account: `main.rs` reads the lease endpoint once at startup (`read_supervisor_endpoint(...).ok()`), so a `fleet-supervisor` call that is slow under load leaves the view read-only for its whole life.

**Cost.** About 35 minutes: two extra full gates and roughly 40 diagnostic suite runs.

**Prevent by.** cb-8484's fix, which has not been filed as a bead as far as I can see: re-read the four `fleet-supervisor` answers on the supervision tick while any of them is missing, and print why a read failed. Also, I grepped `docs/retrospectives/` for "could not take charge" only after diagnosing, which cb-8dha and cb-8484 had already warned against.

**Seen before.** cb-8484, cb-7jmm, cb-eguq, cb-gkhx, cb-lt16, cb-kmxs, cb-8dha, cb-n53p.
