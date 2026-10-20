# cb-kmxs — retrospective

## Fleet-view system suites read-only locally: same-length consumer names share the legacy lease port

**What happened.** `bash tests/gate` was red in six system suites: `fleet-board`, `fleet-rows`, `fleet-stale`, `fleet-keys`, `fleet-type` and `fleet-view-restart`. In each, the view's header read "read-only; this window could not take charge of the fleet". The new `fleet-role-triggers.sh` went read-only the same way in two of its first five runs. All of them passed when rerun alone, three only on a second try, and CI was green.

**Why.** `scripts/fleet-supervisor --legacy-endpoint` computes the port from `cksum("A:<root>") ^ cksum("B:<root>")`, which depends on the root's *length* alone (its own header says so). Every view holds that port beside its real one (cb-ebqd). The suites' consumers are `$work_dir/<name>`, with `$work_dir` a `mktemp -d` of fixed length, so consumers whose names have the same length all take one legacy port:
- `board` and `stale`;
- `keys` and `rows`;
- `typing` and `sweepx`.

This was checked by computing the legacy endpoint for three such roots: all three gave 21303. Those suites therefore lock each other out when run in parallel, and they lock out any other producer's suites running on the same machine at the same time. This is a concrete cause for at least part of what cb-8484's retrospective left "not established".

**Cost.** About twenty minutes: re-running six suites one at a time, and a lease dump added to the new suite's evidence.

**Prevent by.** cb-6f8f (remove the legacy lease port) removes the cause. Until then, a suite's `evidence` should print `fleet-supervisor --endpoint` and `--legacy-endpoint` with `lsof` for each, as `tests/fleet-role-triggers.sh` now does, so a read-only failure names the port and its holder.

**Seen before.** cb-8484 (read-only views under load, cause not established), cb-7jmm and cb-eguq (system suites red locally, green in CI).
