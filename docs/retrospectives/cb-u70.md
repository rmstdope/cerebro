# cb-u70 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-27
- **PR:** #189

## `tests/launchers.sh` failed once under the parallel gate and never again

**What happened.** The first `bash tests/gate` run of the finished change went red on
`FAIL: launch Nobody: expected exit 2, got 1` (`tests/launchers.sh:603`). `bash tests/launchers.sh`
standalone passed immediately afterwards, and the next full `bash tests/gate` passed with the same
tree and no edit in between.

**Why.** Not established. The suite is not reachable from this bead's change: every fixture in
`tests/launchers.sh` is built with `consumer_new --copy`, which copies the whole `scripts/`
directory and never goes through `link_scripts` — the one function this bead altered. The refusal
path under test is `scripts/launch:68-82`, whose `names()` (`scripts/launch:54`) is
`"$here/roster" | while IFS=$'\t' read -r n _ _`; a non-zero status out of that pipeline under
`set -euo pipefail` exits the script with **1** before it reaches its own `exit 2`, which is exactly
the observed status. That is a hypothesis fitting the symptom, not a proven cause: I did not
reproduce it. The suites run one per processor (cb-x05), so "a loaded runner" is every gate run,
which is the condition the two sightings below share.

**Cost.** One extra full gate run, about six minutes, plus the time to establish that the change
could not have caused it.

**Prevent by.** Establishing whether `scripts/launch`'s `names()` pipeline can return non-zero under
load — and if it can, giving the refusal path a status it cannot lose, since a refusal that exits 1
instead of 2 is a real defect in the launcher and not only a flaky assertion. The suite cannot
distinguish the two today: it asserts the status and gets no diagnosis when the status is wrong. A
first step that costs nothing is for that assertion to print `$out` on failure the way its
neighbours do.

**Seen before.** `docs/retrospectives/cb-ue0.md` — same suite, same shape: an assertion red once
under load and green on six local runs, whose established cause was a `set -euo pipefail` pipeline
losing a status (SIGPIPE at `tests/launchers.sh:528`). That one was in the suite; this one, if the
hypothesis holds, is in the launcher the suite runs. `docs/retrospectives/cb-ccl.md` and
`docs/retrospectives/cb-e33.md` are named there as earlier sightings of `set -euo pipefail`
behaving other than expected, which makes this the fourth in that family.
