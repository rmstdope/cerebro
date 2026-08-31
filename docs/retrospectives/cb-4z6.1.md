# cb-4z6.1 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-31
- **PR:** #215

## A suite that passes standalone failed inside the parallel gate, on a case that times its own subprocesses

**What happened.** `bash tests/gate` went red on `tests/suite-runner.sh`, at
`--jobs 2 on two sleeping suites: expected exit 0, got 1`, followed by
`No such file or directory` for both of that case's per-suite log files. The change under test is an
extraction inside `scripts/model-for` and `scripts/launch` and cannot reach `scripts/suite-runner`
at all. Run on its own immediately afterwards — and again against `origin/main` with the diff
stashed — the same suite passed every assertion. The next full `tests/gate` run was green with no
change to anything.

**Why.** Not established. The case builds two sleeping suites and asserts the runner completes them
in parallel; it runs inside a gate that is itself running one suite per processor, so its
subprocesses compete with eighteen other suites for the cores its own timing assumes. That is
consistent with what was seen — the failure is in the timing case and nowhere else, and the missing
log files say the runner's children did not get where it expected them — but nothing was proven.

**Cost.** One full gate cycle, about six minutes, plus a baseline run against `origin/main` to
establish that the failure was not mine. The larger cost is the reading: a red gate on a suite the
diff cannot touch is indistinguishable at first sight from a real regression, and the correct
response (re-run, then baseline) is not written down anywhere an implementer reads.

**Prevent by.** `tests/suite-runner.sh`'s parallel-timing cases are the one place in this gate whose
subject is *the gate's own scheduler*, and they are run by that scheduler. Either those cases should
be run serially — `suite-runner` invoked with `--jobs 1` around the sub-runner under test does not
work, since the case is about `--jobs 2` — or they should assert on completion rather than on
elapsed time. Failing that, `CLAUDE.md`'s **Commands** section, which already explains that suites
run in parallel one per processor and that a suite reaching outside `$work_dir` breaks the whole
gate, is the place to add the sentence: a red suite whose subject is timing is re-run before it is
believed, and a baseline against `origin/main` settles it.

**Seen before.** `docs/retrospectives/cb-azi.md` — same class exactly: "`tests/launchers.sh` failed
once under the parallel gate again, on a change that cannot reach it", also green on the re-run.
Different suite, same shape, and this is at least its second sighting.
