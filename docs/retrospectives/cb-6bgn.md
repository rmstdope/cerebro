# cb-6bgn — retrospectives

## `tests/ux-brief.sh`'s hung-pull bound went red under load, on a diff that does not touch it

**What happened.** `bash tests/gate` was red on one case: `ux-brief: a hung pull is cut off at its
bound, took 20s`. The assertion is `[[ $((SECONDS - started)) -lt 10 ]]`. It ran while
`suite-runner` ran every suite in parallel and another project's Playwright suites (`--workers 3`,
`--repeat-each`) were loading the same machine. Run alone straight after, the suite was green. CI
was green as well.

**Why.** Not established beyond the timing. The case measures elapsed wall-clock seconds against a
fixed limit, so time spent waiting for the CPU counts as if the script were hung.

**Cost.** One extra suite run and the time spent reading its log to tell a flake from a
regression: a few minutes. Before the re-run the gate was red, so the pull request could not
honestly claim a green gate.

**Prevent by.** `tests/ux-brief.sh`'s hung-pull case: assert that the pull was cut off (its stub
was killed and the brief says "pull failed") rather than a wall-clock limit, or measure against a
bound derived from the script's own timeout with generous headroom.

**Seen before.** Not in `docs/retrospectives/`. The trap *A port a probe just released* is the
same family, a test made unreliable by a busy machine.
