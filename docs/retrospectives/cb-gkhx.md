# cb-gkhx — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-10-20
- **PR:** #507

## Two producers launched together, and one session died with `ln: … File exists`

**What happened.** On its first run, the new R13 suite (`tests/fleet-producer-start.sh`) saw the
view start Rogue and Gambit in the same tick. One session then exited with code 1 and the last line
`ln: <consumer>/.claude/agents/reviewer.md: File exists`, and the view gave its bead back as
`did-not-start`. Later, under the parallel gate on a loaded machine, it happened again with
producers 30 s apart: Rogue's `launch-preflight` was still syncing when Gambit's began.

**Why.** Two causes. The first: `triggers::role_peers` returned no peers for a producer, so producers
were never spaced. It is fixed in this PR, at the navigator's call. The second: `launch-preflight`
runs `sync-symlinks.sh` on every launch, and `ln -sfn` unlinks and then links, so two concurrent
syncs on a consumer with missing links race each other. This one is not fixed. Spacing only makes
it rarer, and two different roles can still start in one tick.

**Cost.** One question to the navigator, a scope widened to a Rust change, and a suite fixture that
pre-syncs the links to stay out of the race.

**Prevent by.** A bead for the race: make `sync-symlinks.sh` tolerate a link another process has
just made correctly (EEXIST with the right target is success), or serialise it under a lock in
`launch-preflight`. Then drop the pre-sync from `tests/fleet-producer-start.sh`.

**Seen before.** None found.

## The full local gate was red in every real-TUI suite while CI was green

**What happened.** `bash tests/gate` failed twice locally (machine load 10–16, endpoint security
near 240 % CPU), and every suite that runs the real `cerebro-tui` failed in both runs, four
existing ones included. The captured headers read `Cerebro — read-only; this window could not take
charge of the fleet`. CI on ubuntu passed all of them on the same head.

**Why.** Not established. The view's lease endpoint comes from a `fleet-supervisor --endpoint`
subprocess under `COMMAND_TIMEOUT`, and a slow exec under load would explain it, but this was not
proved.

**Cost.** Two full gate runs, about 25 minutes, plus a five-suite rerun to tell this diff's
failures from the machine's.

**Prevent by.** The view should print *why* it could not take charge (which call, which error) on
the read-only header or in `errors.jsonl`, so a suite's evidence names the cause. Every real-TUI
suite's evidence should also print the header line, as cb-n53p asked.

**Seen before.** cb-n53p, cb-8dha.
