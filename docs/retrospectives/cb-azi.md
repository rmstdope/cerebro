# cb-azi — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-31
- **PR:** #208

## `tests/launchers.sh` failed once under the parallel gate again, on a change that cannot reach it

**What happened.** The second `bash tests/gate` run of the finished change — after the review fix,
which touched four lines of a jq footer inside `scripts/fleet-cost` — went red on
`tests/launchers.sh`, whose last stderr line was
`launch: (the roster listing may be incomplete - run scripts/roster to see why)`. No `FAIL:` line
named an assertion. `bash tests/launchers.sh` standalone passed immediately afterwards, and the
next full `bash tests/gate` on the same tree, with no edit in between, was green.

The suite log was not there to read: `tests/gate` named
`.cerebro/state/suite-logs/20260831-022006-89676` on stderr, and that directory does not exist under
either the worktree or the shared root. Whatever cb-kf8 keeps, it was not reachable from the path
the red run printed, so the only record of the failure was terminal scrollback — which is the exact
situation cb-kf8 exists to prevent.

**Why.** Not established, and this bead cannot be the cause: its whole diff is `scripts/fleet-cost`,
`tests/fleet-cost.sh` and two documents, and `tests/launchers.sh` reads none of them. The stderr
line points at `scripts/roster` answering incompletely, which is the same `names()`-pipeline
neighbourhood cb-u70 hypothesised for its own sighting; I did not reproduce it either.

**Cost.** One extra full gate run, about six minutes, plus the time to establish the change could
not have caused it — the same price cb-u70 paid.

**Prevent by.** Not by a change to this bead's files. Two things would each have shortened it: a
sighting count, which this file is now the second entry of and which is the argument for looking at
`scripts/roster` under load rather than at whatever bead happens to be in flight; and finding out
why `tests/gate` named a suite-log directory that does not exist, since a flake with no kept log is
one nobody can diagnose after the fact.

**Seen before.** cb-u70 — same suite, same "red once under the parallel gate, green standalone and
green on the next gate run", same unrelated diff.
