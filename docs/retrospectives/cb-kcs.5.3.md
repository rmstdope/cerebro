# cb-kcs.5.3 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #285

## A new test was green run alone and failed one run in four under the gate

**What happened.** `a_real_emacs_releases_on_the_declaration_and_this_process_takes_it` spawns a
real Emacs that reports readiness through a file after its first
`cerebro--reconcile-supervision` returns, then reads the supervisor record that Emacs wrote. Run
on its own — `cargo test --workspace --locked a_real_emacs_releases` — it passed every time, six
in a row. Under `bash tests/gate` it printed `gate: RED` twice, and `cargo test --workspace
--all-targets --locked` on its own failed once in four with
`the Emacs supervisor wrote its own record: Os { code: 2, kind: NotFound }`. The cause is that
readiness is not acquisition: the first reconciliation may not be the one that binds, because a
released listener is not instantly rebindable and Emacs retries on its own loop, so the record can
lag the readiness file by one tick. Under load that tick is longer.

**Why.** Established. The plan and both the crate's own comments state the retry rule for
*binding* a released listener (`apply_until`, `acquire_once_free`), and I applied it to every
`apply` call — but not to *observing a peer process's side effect on disk*, which is the same
asynchrony seen from the other end. A reviewer raised the identical shape as a finding about the
Emacs test in the same PR; the flake was already sitting in the Rust test that had stated the rule.

**Cost.** About twenty-five minutes: two red gates diagnosed as possible contention, four bare
`cargo test` runs to reproduce, then the fix and six confirming runs.

**Prevent by.** `skills/implement-bead`, *Building* — when a test asserts on a file, record or
process state another process produces, poll it with a bound rather than reading it once, on the
same rule the repository already writes down for rebinding a listener. The narrower version worth
having in the crate: a readiness signal from a spawned peer says *it has started*, never *it has
finished the thing you are about to assert on*, so the two need separate waits.

**Seen before.** cb-azi and cb-u70 — both "red once under the parallel gate, green standalone",
which makes this the third sighting of that shape and the first where the cause was found in the
test rather than in the environment.
