# cb-4wf1 — retrospective

- **Implementer:** Rogue
- **Date:** 2026-11-21
- **PR:** #549

## A declared role spacing read as the 30s default in the local gate, with no complaint

**What happened.** `tests/fleet-producer-start.sh` now declares `role_start_spacing_producer 5`. It was green 4 out of 4 runs alone, in about 13s. In both local `bash tests/gate` runs it went red: the view's `evaluations.jsonl` logged `"spacing":30` on every producer row, so the startup read of the declaration had not taken effect. Nothing in `errors.jsonl` or on the screen said so. In the same run the view took 39s from arm to its first start.
**Why.** `readers::read_role_seconds` runs `project-conf` once at startup under the 5s `COMMAND_TIMEOUT`, and treats any `Err`, a timeout included, as "declared nothing" (`let Ok(stdout) = … else { continue; }`). Its comment justifies that for a non-zero exit, not for a timeout. Under load the call outlived 5s, and the view ran the whole session on the default. Inferred from the logged `spacing` and the startup latency; the timeout itself was not captured.
**Cost.** Two full local gate runs (about 10 minutes) and the time spent reading them, before CI (green, the suite in 30s) settled it.
**Prevent by.** `fleet-view/src/readers.rs` `read_role_seconds` (and `read_ux_multiple`, which uses the same pattern): tell a timeout or spawn failure apart from a non-zero exit, and return it as a complaint, as a malformed value already is. That keeps it inside CLAUDE.md's "a failed read is never an empty answer". It would also make the fleet suites that declare a value fail on the cause rather than on a timing assertion.
**Seen before.** None found for the silent fallback.

## The full local gate was red in seven fleet-view system suites while CI was green

**What happened.** `bash tests/gate` failed `fleet-keys`, `fleet-board`, `fleet-launch`, `fleet-stale`, `fleet-type`, `fleet-view-restart` and this suite, none touched by the diff except the last. Four producer worktrees were building on the machine at the same time. CI was green on the first run.
**Why.** Load on the local machine, not established further.
**Cost.** As above; the local gate gave no verdict on the change.
**Prevent by.** Already proposed in the files below. Nothing new to add.
**Seen before.** cb-6uc, cb-70mv, cb-7jmm, cb-8dha, cb-8484.
