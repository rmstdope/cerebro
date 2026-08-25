# cb-hzs — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-25
- **PR:** #149

## `cerebro-retry-backoff`'s docstring is off by one against `cerebro--retry-delay`

**What happened.** I wrote the tests for `cerebro--retry-wait` and the standby row label from the
schedule as its `defcustom` states it: "The Nth entry is the wait after N failed starts", schedule
`(0 30 120 600)`. So one failed start should wait 0s, two 30s, three 120s. `cerebro--retry-delay`
does not do that: `failures` of 1 indexes `(nth 0)`, so *one* failure waits 0s and *two* wait 0s as
well — the schedule is shifted one place, and the first non-zero wait arrives on the third start.
Four `should` forms failed on values that were arithmetically fine and simply a step out.

**Why.** `(nth (1- failures) schedule)` with `(<= failures 0)` also answering `(car schedule)`: two
different `failures` values map to the same first entry. The plan's own *Validation* section had it
right — "start lines come 0s, 0s, 30s, 2m, 10m, 10m apart" — and the docstring one line above the
code did not, so I trusted the wrong one of the two.

**Cost.** About ten minutes and one round of test-expectation edits. No CI cycle: it failed locally,
which is where it should fail.

**Prevent by.** The schedule is explicitly out of scope for this bead, so nothing here changes it.
The next bead that touches `cerebro-retry-backoff` or `cerebro--retry-delay` — changing the schedule,
or making the first non-zero step arrive sooner — should fix the docstring's sentence to say what
the code does (the first entry covers both "no failures" and "one failure") or change the indexing
to match the sentence, and `cerebro-test/retry-wait-and-figure` is now the test that pins whichever
of the two is chosen.

**Seen before.** None found — `grep -rl "retry-delay\|off-by-one" docs/retrospectives/` matches
nothing on this.
