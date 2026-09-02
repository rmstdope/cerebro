# cb-kcs.4.3 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-02
- **PR:** #273

## A new fixture-script test passed three times locally and failed in CI with `Text file busy`

**What happened.** The bead adds three `readers.rs` cases that write a fake `gh` under a
`TempDir` and run it. All three passed locally and in the full gate; in CI,
`readers::tests::a_failed_login_leaves_the_lists_answering` failed with
`Spawn { source: ".../gh", message: "Text file busy (os error 26)" }`. The crate already has
`retry_if_text_busy` for exactly this, and every pre-existing fixture-script case in that file
wraps its read in it — the new ones did not, because the plan's increment 6 specified the fixture
and the assertions and said nothing about the wrapper.
**Why.** On Linux the kernel can still hold a write descriptor open on a just-written file when
`execve` runs, which is `ETXTBSY`. macOS does not do this, so the failure cannot occur on the
machine the tests are written on.
**Cost.** One CI cycle and a delta review round, about 15 minutes.
**Prevent by.** `readers.rs`'s `write_executable` is the marker: any test that runs what it wrote
must go through `retry_if_text_busy`. A plan increment that specifies a new fixture script in this
crate should name the wrapper alongside the script, the way it names `Programs::gh`.
**Seen before.** None found in `docs/retrospectives/`; the defect class is recorded in the code
instead, in `retry_if_text_busy`'s own comment and in `readers::tests::TEST_TIMEOUT`.
