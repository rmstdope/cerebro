# cb-kf8 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-28
- **PR:** #192

## Confining a suite's calls to `$work_dir` by changing one helper missed five inline calls

**What happened.** The plan named the recursion trap precisely — this suite runs inside the gate and
the gate runs `suite-runner`, so with a cwd-relative default log root the inner runs' prune-at-start
would delete the outer run's directory while it was still being written to — and prescribed the fix
as "change `run()` to prepend `--log-dir "$work_dir/logdir"` to every call". I did that, the suite
was green standalone, and the first `bash tests/gate` went red on eight unrelated suites with
`scripts/suite-runner: line 169: .cerebro/state/suite-logs/<run>/work-beads.sh.log: No such file or
directory`.

**Why.** Established. `tests/suite-runner.sh` does not route every call through `run()`: five cases
invoke `bash "$script" ...` inline, because they need stdout and stderr captured separately or
`GITHUB_ACTIONS` set, and `run()` merges the two streams. Those five used the shared default root,
created three run directories in it while the outer gate was running, and the third one's prune
deleted the outer run's directory. The failure surfaced as a missing-file error in whichever suites
happened to start after that moment, which names neither the cause nor the change that introduced
it.

**Cost.** One full gate run and the diagnosis, about six minutes. No CI cycle — the gate caught it
before the PR, which is the one thing the plan correctly said only the gate could prove.

**Prevent by.** When a plan confines a suite's calls to `$work_dir` by editing one helper, the step
is `grep -n 'bash "$script"' <suite>` and auditing every hit, not editing the helper. A helper is a
convention rather than a chokepoint, and a suite that has cases needing stdout and stderr apart will
always have calls outside it. Concretely: `skills/implement-bead`'s *Known traps* has "a suite that
reaches outside its own `$work_dir` breaks the whole gate" as a general statement; what it does not
say is that a plan's "change `run()`" is a claim about call sites that must be checked against the
file. The same shape applies to any per-call flag a suite must not omit.

**Seen before.** None found — `grep -rl work_dir docs/retrospectives/` matches nothing.
