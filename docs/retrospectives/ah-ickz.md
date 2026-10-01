# ah-ickz — retrospective

- **Implementer:** Storm
- **Date:** 2026-10-01
- **PR:** rmstdope/cerebro#473

## The supervisor lease test failed under the full gate, then passed alone

**What happened.** Two consecutive `bash tests/gate` runs failed
`main_tests::a_released_lease_is_bindable_by_a_successor` at `fleet-view/src/main.rs:8937`:
it got `ReadOnly(LockError("cannot locate the supervision lease"))` instead of `Supervising`.
The exact filtered Cargo test passed, and a subsequent full gate passed. This bead changes no Rust
files.
**Why.** Not established. The symptom resembles the load-sensitive supervisor-test failures
recorded in cb-abs.1 and cb-kcs.5.3, but this occurrence was not instrumented.
**Cost.** Two failed full-gate runs, one targeted Cargo rerun, and a confirming full gate; about
fifteen minutes of local validation.
**Prevent by.** `fleet-view/src/main.rs`,
`main_tests::a_released_lease_is_bindable_by_a_successor` — investigate and make the lease
acquisition assertion deterministic rather than relying on a transient supervisor state. That
test change is outside this shell-policy bead.
**Seen before.** cb-abs.1 and cb-kcs.5.3 describe the same transient supervision-lease failure
shape.
