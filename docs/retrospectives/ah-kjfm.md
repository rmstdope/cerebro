# ah-kjfm — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-23
- **PR:** #98

## The plan told me to write something a test in this repository forbids

**What happened.** The plan's *Files to change* section said the new `agents/orchestrator.md`
section should carry "the evidence (both P0s of 2026-08-23, **named**)", and gave the two Sweeps
lines to ship verbatim with real bead ids in them. I wrote it exactly as specified.
`bash tests/prose-decoupling.sh` then failed with eight hits: no file an agent session reads may
contain a bead id, because a consumer cannot resolve one.

**Why.** Established. `tests/prose-decoupling.sh` scans `agents/**`, `skills/**` and
`docs/agent-workflow.md` for `ah-<id>`, and `docs/decisions.md` exists precisely to hold the
provenance the prose is not allowed to carry. The plan was written against the *shape* of the
neighbouring sections — which do argue from named evidence — without the constraint that moved that
evidence out of them.

**Cost.** Small, because the full bash suite runs in under two minutes locally and caught it before
the PR: one gate cycle and a rewrite of one section, perhaps fifteen minutes. It would have been a
red CI job and a second cycle had I trusted `check`-equivalents that skip `tests/`.

**Prevent by.** `plan-bead` writing a section of `agents/**` should state the split explicitly:
neutral prose in the agent file, bead ids and dated evidence in `docs/decisions.md`, because
`tests/prose-decoupling.sh` enforces it. The same plan also asserted "the script has no test harness
in this repository", which is not so — `tests/*.sh` is one of CI's two jobs — and a planner that had
looked at `tests/` would have found both facts in the same glance.

**Seen before.** None found.
