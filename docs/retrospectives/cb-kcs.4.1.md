# cb-kcs.4.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #272

## Two new tests that spawn a child turned an unrelated test red

**What happened.** `bash tests/gate` was green on this branch and I opened the PR on it. The
review sub-agent then ran `cargo test --workspace --lib --locked` five times and got five reds in
`readers::tests::command_timeout_kills_and_reaps_the_child` — *the timed-out child was left as a
zombie* — against five greens on `main`. Nothing in the production code had changed for it. The
cause was the assertion itself: it took one snapshot of `ps` and failed if **any** child of the
test process was in state `Z`. Every `run_with_timeout` anywhere leaves its child a zombie for the
window between the child exiting and its own `wait_timeout` returning, so the assertion was always
a claim about whatever else `cargo test` happened to be running. This bead's two new `readers`
tests spawn six more short-lived `sh` fixtures, which was enough to land inside that window. Below
the default thread count (`--test-threads=8` on this ten-core machine) it stayed green, which is
why my own gate run passed.

**Why.** Established. A test asserting about *every* child of the test process is asserting about
its neighbours, and cargo runs the suite as threads of one process. The fix is a poll rather than
a snapshot: somebody else's zombie is reaped within milliseconds and a leaked one never is, so a
moment with none is the proof. A pid-scoped version was tried first and is worse — the fixture is
SIGKILLed one second in, and under load it never reaches an `echo $$`.

**Cost.** One review round and about twenty minutes, most of it spent on the pid-scoped attempt
that then failed under load for a different reason.

**Prevent by.** A test that reads the process table, the filesystem outside its own `TempDir`, or
any other shared resource must scope its assertion to what it created. This is the Rust-side twin
of the rule `CLAUDE.md` already states for the bash suites — *every suite builds its fixtures under
its own `$work_dir`; a new suite that reaches outside it breaks the whole gate, not just itself*.
Where scoping is genuinely unavailable, poll to a deadline rather than snapshot, and say in the
comment which neighbour made the snapshot wrong.

**Seen before.** None found — `grep -rl zombie docs/retrospectives/` was empty. The
`TEST_TIMEOUT`/`TEXT_BUSY_RETRY_WINDOW` comments in `readers.rs` are the same *shape* of finding
(one test's fixtures failing another's), twice already, which is why this one is worth a third
entry rather than a shrug.
