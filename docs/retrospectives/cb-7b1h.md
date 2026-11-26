# cb-7b1h: a suite whose script commits was green locally and red in CI

**What happened.** `tests/ux-deliver.sh` runs `scripts/ux-deliver` against a real git consumer, and the script makes its own `git commit`. Locally the suite was green, and so was `bash tests/gate`. On ubuntu-latest, `Bash suites` failed at `ux-deliver: commit: git commit failed`.

**Why.** The CI runner has no git identity. The suite's own commits go through `git_q` (`tests/lib/consumer.sh`), which passes `-c user.name/-c user.email`. A *script under test* that commits gets no such help: locally it inherits the developer's `~/.gitconfig`. The fix was to give the suite's invocation `GIT_AUTHOR_*`/`GIT_COMMITTER_*`. Running the suite with `HOME=$(mktemp -d) GIT_CONFIG_NOSYSTEM=1` reproduces the CI condition on a Mac.

**Cost.** One CI round, about 5 minutes, and one of the bead's three fix attempts.

**Prevent by.** `tests/lib/consumer.sh`'s header or CLAUDE.md's *Writing a suite*: a suite whose script under test runs `git commit` must lend it an identity through `GIT_AUTHOR_*`/`GIT_COMMITTER_*`, since `git_q` only covers the suite's own git calls. Or `scripts/suite-runner` could run every suite with an empty `HOME` and `GIT_CONFIG_NOSYSTEM=1`, so local runs meet the runner's conditions.

**Seen before.** Not in `docs/retrospectives/`.
