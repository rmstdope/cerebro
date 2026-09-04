# cb-xhu.1 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-09-04
- **PR:** #320

## A gate-wide guard is inherited by the suites that exercise it

**What happened.** The bead adds a guard that `scripts/suite-runner` exports to every suite
(`CEREBRO_PROTECTED_STATE_DIR`, plus a report file and `CEREBRO_SUITE_NAME`). Each new suite passed
on its own, and the first `bash tests/gate` was red — on the two suites proving the feature. Two
distinct inheritance faults, one in each:

- `tests/jsonl-log.sh` refuses writes *on purpose*, and inherited the outer run's
  `CEREBRO_PROTECTED_STATE_REPORT`, so its deliberate refusals were recorded as violations of the
  run that was running it: `suite-runner: these suites wrote to the fleet's live logs … tests/jsonl-log.sh -> …`.
- `tests/suite-runner.sh`'s `run` helper was written per the plan as
  `local guard="${CEREBRO_PROTECTED_STATE_DIR-$work_dir/protected}"` — "unless the caller set one in
  the environment for that call". Under the real gate that is indistinguishable from the outer run's
  guard being *inherited*, and it was: the guard-off case read the navigator's real state directory.

**Why.** A guard the runner exports to every suite reaches the suites that test the guard, and there
is no expansion that can tell "the caller set this for this call" from "this was inherited". The
plan anticipated the `--log-dir` shape of this (it says `run` must always set a guard) but expressed
it as a default rather than as an override, which reintroduces the inheritance it was avoiding.

**Cost.** One full gate run and its diagnosis, roughly 15 minutes.

**Prevent by.** A plan that adds a gate-wide environment guard should name, as an explicit
increment, what the suites *exercising* that guard do about inheriting it — an `unset` at the top of
the library's own suite, and an explicit `--guard VALUE` flag (never an environment default) in any
helper that spawns the runner. `tests/suite-runner.sh`'s `run` already carries the same rule for
`--log-dir` and its comment is where the pattern is written down.

**Seen before.** None found under `docs/retrospectives/` for this shape; `cb-kf8` is the same
mechanism for the log directory rather than for an environment variable.

## A "fixed" answer is worth re-running before it is posted

**What happened.** The cold read's third finding was an overlong comment line. The fix reflowed the
paragraph by one word, moving the long line down rather than rewrapping it, and the answer posted to
the reviewer said "rewrapped". The next delta round caught it and said so.

**Why.** The claim was written from the intent of the edit rather than from the file.

**Cost.** One delta round, about two minutes — cheap here only because the review chain caught it.

**Prevent by.** `skills/implement-bead` already says a sentence in a PR body about what a helper does
is read with the trust a plan gets. The same applies to a finding's answer: for any finding with a
mechanical test (a column count, a mutation, a grep), run it and quote the result in the answer.
`awk 'length>100'` would have taken a second.

**Seen before.** None found.
