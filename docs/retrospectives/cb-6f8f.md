# cb-6f8f — retrospective

## The web console UI leg went red on another session's Playwright install lock

**What happened.** The first local `bash tests/gate` failed its web console UI leg before any test
ran. Playwright reported an active lockfile at `~/Library/Caches/ms-playwright/__dirlock` and
refused to go on. The lock is per user, not per worktree, and another fleet session was installing
or checking browsers at the same moment. The leg passed when re-run alone a few minutes later.

**Why.** The browser cache is shared by every session of the user on the machine. The UI leg's
browser install takes that one lock, and `smoke-port` gives each session its own ports, but
nothing gives it its own browser cache or waits on the lock.

**Cost.** One red gate leg to diagnose, and a separate re-run of `tests/web-console-ui` (about two
minutes) on a machine already under load.

**Prevent by** `tests/web-console-ui`: when the install step fails on `__dirlock`, wait and retry
within a bound, since the lock is held by a sibling session and is not a fault in the change. The
alternative is a per-worktree `PLAYWRIGHT_BROWSERS_PATH`, at the cost of a browser download per tree.

**Seen before.** Not under `docs/retrospectives/` (searched for `dirlock` and `playwright.*lock`).
The fleet-* suite timeouts in the same gate run are already recorded (cb-gyw0, cb-gkhx).
