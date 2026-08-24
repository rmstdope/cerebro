# cb-8cn — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-24
- **PR:** #132

## The plan's file name landed in a namespace two suites guard, and the gate found it

**What happened.** The plan specified the new script as `scripts/run-suites`, named it in five
places (the script header, `tests/gate`, `ci.yml`, `scripts/lint` check 10, `CLAUDE.md`), and
nothing in the plan's *Known traps* mentioned a conflict. The first `bash tests/gate` run went red
in two suites at once — `tests/launchers.sh:541` and `tests/consumer-fixture.sh:225` both assert
`find scripts -maxdepth 1 -name 'run-*'` returns nothing, because `scripts/run-*` is the retired
launcher-shim namespace (ah-qled.5.3). The failure names the new file, so it reads at first glance
like the new script being rejected rather than its name being.
**Why.** Established. The guards are deliberately broad — any `scripts/run-*` — while the retired
shims were specifically `run-<role>`. A new script that is not a launcher still matches. The
planner had no reason to grep for its chosen file name, and nothing prompts one to.
**Cost.** One full gate run (~3 min) plus the rename across six files, ~15 minutes. No CI cycle: the
gate caught it before the PR opened, which is the gate doing its job.
**Prevent by.** `skills/plan-bead`'s plan check, and this skill's *Known traps* habit, should
include one grep before a plan fixes a new file name: `grep -rn "<name>" tests/ scripts/` and a
`find` against any namespace assertion — cheap, and it turns a red gate into a naming decision made
at plan time. The narrower alternative — teaching the two guards to name roles rather than the whole
`run-*` prefix — was rejected here: weakening two deliberate guards to admit one file is the worse
trade, and the house style (`ci-needed`, `consumer-root`, `app-paths`) already prefers noun names.
**Seen before.** None found — `grep -rl "namespace\|run-\*" docs/retrospectives/` returns nothing.
The closest relative is `implement-bead`'s standing trap "an accessible name is a shared namespace",
which is the same shape one layer up: a new name colliding with an existing assertion about names.
