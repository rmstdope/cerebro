# cb-lt16 — retrospective

- **Implementer:** Storm
- **Date:** 2026-10-20
- **PR:** #514

## The full local gate was red in eleven fleet-view system suites and the lease test while CI was green

**What happened.** `bash tests/gate` failed eleven pty system suites. The failures were timeouts ("the work pane to draw the board", "the stub agent to start", "Rogue's session to start"), and at least one view's header read `read-only; this window could not take charge of the fleet`. In a later Cargo run, `main_tests::a_released_lease_is_bindable_by_a_successor` failed with `ReadOnly(LockError("cannot locate the supervision lease"))`, and `four_builders_are_given_four_different_beads` failed with `launch-Storm.args was never written`. Run alone, every one of them passed, three times for the Rust tests. `suite-runner --jobs 4` passed everything except my own wall-clock assertion (the next section). Load average was 7–9 from other producers' gates.
**Why.** Partly established. The view finds the lease through `scripts/fleet-supervisor` under a wall-clock bound, so under load that call times out. The view then goes read-only, which matches the header line and the lease test's `LockError`. Not established for the timeouts in suites that never showed read-only.
**Cost.** About 20 minutes: the gate run, the per-suite reruns, and a second gate split into its legs.
**Prevent by.** The gate's suite-runner call (`tests/gate`) defaulting `--jobs` to a smaller number when the 1-minute load average is already above the core count, or `docs/agent-workflow.md` telling producers that a red pty suite is re-run alone before it is believed.
**Seen before.** cb-8484, cb-yq4c, cb-8dha.

## The web console UI leg failed on another session's Playwright install lock

**What happened.** `tests/web-console-ui` failed with `Failed to install browsers … An active lockfile is found at ~/Library/Caches/ms-playwright/__dirlock`. Another session on the machine was installing browsers into the shared per-user cache at the same moment. Re-run later, 51 of 51 passed.
**Why.** Playwright's browser cache is per user, not per worktree, and concurrent installs refuse rather than wait.
**Cost.** One re-run of the leg.
**Prevent by.** `tests/web-console-ui` retrying the browser install for a bounded time when the error names `__dirlock`, or setting `PLAYWRIGHT_BROWSERS_PATH` per worktree.
**Seen before.** None found.

## A wall-clock assertion in the new suite failed under the same load

**What happened.** The first version of `tests/fleet-retry.sh` asserted that the first three starts happened within 30 s. Under load each launch's preflight and tree took about 10 s, so the check failed although no backoff held them. It now reads `backed_off` from `evaluations.jsonl`. The cold review then flagged the same risk in the row check that follows the 30 s backoff.
**Why.** Established: launch time is machine time, not the view's decision.
**Cost.** One extra commit and suite run.
**Prevent by.** In a fleet-view system suite, assert a timing rule from the view's own `evaluations.jsonl` and `decisions.jsonl` (`tests/fleet-producer-start.sh` already does for the spacing), never from the clock alone.
**Seen before.** None found.
