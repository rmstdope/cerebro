# ah-4n2r retrospective

## A green tracked-links suite went red in CI on its own cleanup

**What happened.** On PR #476, `Bash suites (ubuntu-latest)` failed twice in a row in
`tests/tracked-links.sh`. Every assertion in the suite had printed `ok`. The red came from the EXIT
trap: `rm: cannot remove '/tmp/.../selfrepo-.../.git/objects/pack': Directory not empty`. The same
suite passed six runs out of six locally on macOS, and the PR did not touch it.

**Why.** The suite's `new_fixture` commits a whole copy of cerebro into a fresh repository, then
commits several times more. That is enough for `git gc --auto` to detach and start packing objects,
and the trap's `rm -rf` then races the background gc writing into `.git/objects/pack`. Main run
37822889461 failed the same way. This is inferred from the error and the fix holding, not traced.

**Cost.** Two red CI runs, and one fix attempt out of the bead's three, on a defect that predates
the bead.

**Prevent by.** `tests/tracked-links.sh` `new_fixture` now sets `gc.auto 0` and
`maintenance.auto false`. Any other fixture that commits a large tree several times can race the
same way. Setting those two keys for every fixture repository in `tests/lib/consumer.sh` (for
example through `GIT_CONFIG_COUNT`) would close the class rather than this one case.

**Seen before.** main, CI run 37822889461 (same suite, same `Directory not empty`); not recorded
in `docs/retrospectives/` until now.
