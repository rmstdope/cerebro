# cb-kcs.5.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #279

## A test that writes its own executable and then spawns it is green here and red on Linux

**What happened.** The `run_finding` cases needed a `bd` that records rather than writes. I wrote
one into the case's tempdir, `chmod +x`ed it and spawned it. `bash tests/gate` was green three
times on this machine; CI failed two of the four on ubuntu-latest with an empty call log:

    ---- lifecycle::tests::running_a_finding_pushes_after_it_succeeds stdout ----
    assertion `left == right` failed
      left: []
     right: ["unclaim cb-a", "dolt push"]

**Why.** `ETXTBSY`: on Linux a file still open for writing anywhere in the process cannot be
executed, and `cargo test`'s threads make that window real. Two of the four cases lost the race and
two did not, which is why the failure read as something specific to those two rather than as a
race. This crate had already paid for it — `fleet-view/src/readers.rs`'s own module doc says four
patches in that module were each a new wrapper around a fixture spawn rather than a way of not
spawning at all, and cb-x3u's answer was `tests/fixtures/`, tracked, because *a file no test writes
cannot be `ETXTBSY`*. I had read that paragraph while working in the same file and still wrote the
fixture the other way in a different module.

**Cost.** One CI cycle, about eight minutes, plus the rewrite.

**Prevent by.** The rule is written where the reader lives (`readers.rs`) and not where the writer
looks (`lifecycle.rs`, `main.rs`, or the crate doc in `lib.rs`). It belongs beside the crate's other
whole-crate rules: **a test fixture that has to be executed is tracked under
`fleet-view/tests/fixtures/`, never written by the test** — per-case variation goes in data files
in the cwd, which is what `recording-bd` does now. The root `CLAUDE.md`'s *fleet-view/* section is
where an implementer reads the crate's rules before starting, and this is not in it.

**Seen before.** cb-x3u (the same class, answered for `readers.rs` alone); `c25701f`, `4e70768`,
`dd3066d`, `fa52613` are the four patches that doc names.

## A shared case table cannot catch a defect that lives between two of its rows

**What happened.** `tests/lib/sweep-findings.json` is the regression test this bead exists to leave
behind, and every one of its 37 rows passed on both implementations. The review still found a real
bug: `read_sweeps` looked a finding's candidate up **by id across all six sweeps**, and
`sweep-claims.sh` and `sweep-stalled.sh` both emit one object per `in_progress` bead — so every
real `unclaim` line would have read `no commit for nilm` in front of a navigator. The table cannot
see it: each row feeds exactly one sweep, which is the one shape the collision needs two of.

**Why.** The plan specified the table as the regression test for the port and specified `Judged` as
carrying the already-formatted label, but nothing in it said where the candidate for that label
comes from — and the obvious implementation is the wrong one. I wrote the comment "found by id
within its own sweep, which is unique" above a search that was not within its own sweep, which is
the tell.

**Cost.** None to the fleet: the review caught it before merge. About twenty minutes to fix and
prove.

**Prevent by.** Nothing to change in the harness — this is what the review round is for, and it
worked. Worth knowing for the next port: **a shared table proves the pure decisions and says
nothing about the wiring around them**, so the seam between the judging and the rendering needs its
own case even when the table is green.

**Seen before.** None found.
