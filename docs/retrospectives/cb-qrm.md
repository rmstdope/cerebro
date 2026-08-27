# cb-qrm — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #190

## `tests/suite-runner.sh` failed once inside the gate and passed standalone and on every re-run

**What happened.** The full `bash tests/gate` run at the end of increment 2 ended `FAILED:
tests/suite-runner.sh` / `gate: RED`. Run on its own immediately afterwards, `bash
tests/suite-runner.sh` passed all seven assertions. Two further full gate runs — one right then, one
after increment 3 — were green, as was CI. The gate's replay of the failing suite was not captured
before the re-run, so the failing assertion was never identified.

**Why.** Not established, and I did not prove it. What is true of that suite: it fabricates suites
that `sleep`, two of which take 44s, and asserts on *concurrency* — `suites run N at a time, and
--jobs 1 is one at a time`. Run inside the gate it competes for cores with the other 33 suites,
which `scripts/suite-runner` runs one per processor (cb-x05), so its wall-clock assumptions hold
under a different load than when it is run alone. That is a hypothesis about which assertion failed,
not a finding.

**Cost.** About seven minutes: one standalone suite run and one full gate re-run. The larger cost was
doubt rather than time — this bead's own diff is a mechanical edit to all 34 suites, so a red suite
in the gate reads first as "the conversion broke the runner suite", which is exactly the
distinction this bead exists to make possible.

**Prevent by.** Two concrete things, neither of which is mine to do inside a planned bead. First,
`scripts/suite-runner`'s replay is the only record of a failing suite and it is lost the moment the
next run starts — a gate that wrote the replay to a file would have made this diagnosable instead of
a hypothesis. Second, `tests/suite-runner.sh` is the one suite in the tree whose assertions are
wall-clock concurrency measurements taken while the gate is itself saturating the machine; either it
is given headroom that does not depend on ambient load, or the fact that it can be flaky under the
gate is written down where the next implementer reads it — `.cerebro/traps.md`, which this
repository does not yet have.

**Seen before.** None found. `docs/retrospectives/cb-bqp.md` and `docs/retrospectives/cb-ue0.md` both
turn on timing, but neither is about a suite failing under the gate's own parallel load.

## The plan's by-hand validation recipe proves nothing where it is run

**What happened.** The plan's *Validation* section ends with a by-hand proof of the defect: copy a
suite to `/tmp/broken-suite.sh`, inject `source /nope/no-such-file.sh` after the library's own
`source` line, and check the exit status is non-zero. Run as written it printed

    /tmp/broken-suite.sh: line 17: //tests/lib/consumer.sh: No such file or directory
    exit=1

A suite under `/tmp` resolves `repo_root` — `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` — to
`/`, so it dies on the library's *own* source line, before the EXIT trap that carries the guard is
ever installed. The `exit=1` is bash failing to find the library, not the guard firing. Re-run from
inside the tree it says what it should:

    FAIL: tests/zz-broken-proof.sh died before reaching suite_passed (bash reported status 0)

**Why.** Established. Every suite derives `repo_root` from its own location, so a suite is not
relocatable; the recipe was written without that step being run.

**Cost.** About a minute, and no CI cycle. It is recorded despite that because of the *shape* of the
failure rather than its size: the wrong recipe exits 1, which is the answer the check is looking
for, so it reads as a passing proof. A validation step that confirms the wrong thing is the same
class of defect as the one this whole bead is about — an `ok` that was never earned.

**Prevent by.** A validation recipe in a plan that fabricates or relocates a file under `tests/`
belongs under `tests/`, not `/tmp`, and its expected *output* should be quoted in the plan, not just
its expected exit status. Had the plan said "must print `died before reaching suite_passed`" — which
it does say two lines earlier, in prose — the recipe would have failed visibly rather than
plausibly.

**Seen before.** None found.
