# cb-tbrh — retrospective

- **Implementer:** Rogue
- **Date:** 2026-11-26
- **PR:** #598

## A new periodic call from the view ran against every system suite's stub board

**What happened.** The view gained a worker that runs `scripts/ship --sweep` at start-up.
`bash tests/gate` then went red on `tests/fleet-retry.sh` (`after 30s, still waiting for: Rogue's
second session`) and passed when the suite ran alone. That suite's stub `bd list` honours
`--status` and ignores `--assignee`, so the sweep's listing could include Rogue's own claim, which
the sweep treated as a half-finished hand-back and tried to unclaim.

**Why.** The script trusted the listing's filter. That this caused the red is not proven; the code
path was real and is now filtered in the script, with a case in `tests/ship.sh`.

**Cost.** One red gate and one more full run, about ten minutes.

**Prevent by.** `.cerebro/test-architecture.md`, system suites: a new program the view runs on its
own clock is checked against the fleet suites' stubs in the increment that adds it, and a script
that writes the board filters what it lists before it writes.

**Seen before.** None found.

## `cargo build` named no executable under a loaded gate

**What happened.** The first `bash tests/gate` went red on `tests/fleet-view-restart.sh`:
`FAIL: cargo build named no cerebro-tui executable`. The build itself exited 0. Alone, the suite
passed, and so did the next full runs.

**Why.** Not established.

**Cost.** One suite re-run and one more full gate, about eight minutes.

**Prevent by.** `tests/fleet-view-restart.sh` (and the fleet suites sharing its build block): on
that failure print the `compiler-artifact` messages cargo did give, so the next sighting can be
explained.

**Seen before.** Not with this message. `docs/retrospectives/cb-pe3y.md` and
`docs/retrospectives/cb-8484.md` record other load-bound reds in view suites.
