# cb-x3u — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-02
- **PR:** #277

## The plan's own "run it under load" check reddened an unrelated test

**What happened.** The plan's *Validation* ends with a check only contention can make: run the
cargo suite under load, twice, because the defect being removed only ever showed itself under
contention. I ran ten concurrent `cargo test --workspace --all-targets --locked` runs in cold
target directories, some beside a concurrent `cargo build`. All ten were green. The run
immediately afterwards was not:

    ---- session::tests::a_finished_child_leaves_its_screen_and_a_status_line stdout ----
    panicked at fleet-view/src/session.rs:972:64:
    the session spawns: Spawn { source: "the session for Cyclops",
      message: "failed to openpty: Os { code: -6, kind: Uncategorized, ... }" }

**Why.** Pty exhaustion, caused by the load check itself. `session.rs`'s cases allocate a real pty
per session through `portable-pty`; ten concurrent suite runs allocate ten times as many at once,
and the machine's allocation had not been released by the time the next run started. Not
established beyond that: I did not measure the limit or watch it recover, only that the very next
run was green and every run since has been.

**Cost.** About three minutes — one confused re-read of a `session.rs` failure in a bead that
touches neither `session.rs` nor any pty, then one re-run.

**Prevent by.** A sentence in `plan-bead`'s guidance for the load-check step, or in this project's
`.cerebro/traps.md`: *a suite that allocates a scarce per-process OS resource — a pty, a port, a
lock — can fail for `N` concurrent runs of it what passes for one, and that failure is about the
load check rather than about the branch.* The tell is a failure in a file the diff does not touch.
This is the navigator's to decide, not mine — I record it.

**Seen before.** None found: `grep -rl openpty docs/retrospectives/` is empty, and the four
retrospectives mentioning contention (cb-azi, cb-kcs.6, cb-kcs.4.1, cb-u70) are all about
`ETXTBSY`, a shared lease port, or a shared zombie process table — the same *shape* as this, and
the shape this bead exists to remove from `readers.rs`, but never a pty and never caused by the
validation step itself.
