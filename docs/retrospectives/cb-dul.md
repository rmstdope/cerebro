# cb-dul — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-24
- **PR:** #125

## One gate run stalled for 19 minutes inside tests/launch-preflight.sh and never finished

**What happened.** `bash tests/gate` hit the harness's ten-minute ceiling and was moved to the
background. `ps` showed `bash tests/launch-preflight.sh` had been running for 19 minutes and 35
seconds with no output; it was still there at 24 minutes, when I killed it. The same suite run alone
immediately afterwards finished green in about 40 seconds, and the two full gate runs after that
finished green in 3 minutes 15 seconds each. The stall never reproduced.

**Why.** Not established. The suite's cases run `git fetch` against local bare origins, and one case
is *about* an unreachable origin (`an unreachable origin stays quiet`) — a fetch that resolves a
name rather than failing fast is the obvious suspect on a laptop whose network state changes, but I
did not capture the stack or the child process at the time, so this is a suspicion and not a finding.
Nothing in the commit under test touched that suite: the stall came between the increment that
migrated three unrelated fixtures and the identical run that passed.

**Cost.** About 25 minutes of wall clock, one killed tool call, and one re-run of the whole gate to
establish that the tree was in fact green. No CI cycles.

**Prevent by.** Two concrete things, neither of which I did here (both are outside a planned bead).
First, `tests/gate` prints nothing between suites, so a stalled suite is invisible until somebody
runs `ps` — it should name each suite as it starts it, which turns "the gate is hung" into "the gate
is hung in launch-preflight" without a diagnosis step. Second, `tests/launch-preflight.sh`'s
unreachable-origin case should point at a path that cannot resolve as a hostname (a bare local path
that does not exist, which it already does) *and* run under `GIT_TERMINAL_PROMPT=0` with a short
`http.lowSpeedLimit`/`lowSpeedTime`, so a fetch that would block returns instead.

**Seen before.** `docs/retrospectives/ah-il8j.md` — the same ten-minute ceiling on the same suite
loop, but a different shape: there the whole 21-suite loop was genuinely slow on macOS and finished
in 48 seconds in CI, with no single suite named. This one is one suite blocking indefinitely while
the aggregate is otherwise 3 minutes. Both point at the same missing thing: the gate does not say
where it is.
