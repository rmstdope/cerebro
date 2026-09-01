# cb-kcs.6 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-01
- **PR:** #256

## `cargo test` in a bead worktree fails, then passes, because the lease port is shared

**What happened.** The first `cargo test --workspace --all-targets --locked` in the fresh worktree
failed one test — `readers::tests::real_roster_output_feeds_fleet_derivation`, a five-second
timeout on this checkout's own `scripts/roster`. Every run after it was green, three times.
Independently, the review sub-agent running `cargo test` in the same worktree saw six failures in
the lib binary and then three clean runs, and traced it to `supervisor.rs`'s real-listener tests
contending with a `cargo test` in the main checkout.
**Why.** Not established for the roster timeout — a cold worktree with an uninitialised submodule
path and a cold page cache against a hard five-second bound is the plausible reading, but I did not
prove it. The lease half is established and is by design: `scripts/fleet-supervisor` derives the
port from the **shared** root, so every worktree of one repository contends for one port, which is
exactly what makes the lock correct and exactly what makes two concurrent `cargo test` runs fight.
**Cost.** One wasted full-suite run for me, and about the same for the reviewer — perhaps ten
minutes between us, plus the risk that either of us had read it as a defect in the diff.
**Prevent by.** Two runs of the Rust suite on one machine — a worktree and the main checkout, or
two worktrees, or a suite and a live `M-x cerebro` — cannot both hold the lease. Naming this in
`implement-bead`'s *Traps this fleet has already paid for* alongside the leftover-preview-server
entry would let the next implementer read a first-run red as contention rather than as its own
change. This is a third sighting of one class, which is the threshold CLAUDE.md sets for guarding a
defect mechanically rather than tolerating it — worth the navigator's decision, not an
implementer's.
**Seen before.** cb-m7u — the same shared-root lease port, contended by the navigator's live
`M-x cerebro` against a batch run.
