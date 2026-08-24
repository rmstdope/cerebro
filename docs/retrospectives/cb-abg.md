# cb-abg — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-24
- **PR:** #119

## The plan for the bead that prevents this told me twice to write prose the lint rejects

**What happened.** Twice while following the plan, `bash scripts/lint` went red on text the plan
quoted for me to paste in verbatim.

The paragraph the plan specified for `skills/plan-bead/SKILL.md` ended "the provenance goes in
`docs/decisions.md`". That file is `prose_files`, and check 1's third advisory forbids prose an
agent reads from referencing `docs/decisions.md` at all — so the sentence explaining where the
provenance lives could not itself name where it lives. I rewrote it to say the check names the file
when it fires, which the `--plan` advisory text does.

The `context-only.md` test fixture the plan quoted contained
`see docs/retrospectives/ah-e0kf.md`. Check 12 forbids a suite naming a `docs/` path that
`scripts/ci-needed` lets CI skip, and `tests/lint.sh` is a suite. I made the fixture cite the
retrospectives without the path.

**Why.** The plan was written against `tests/prose-decoupling.sh`, noticed correctly that cb-194 had
moved that rule into `scripts/lint`, and then reasoned about check 1's *first* advisory (bead ids)
only. Checks 1c and 12 of the same file were never consulted. Neither is visible to a planner: the
`--plan` check this bead adds reads one rule out of fourteen.

**Cost.** Two gate runs and two rewrites, about ten minutes. No CI cycle — both fired locally.

**Prevent by.** `--plan` currently answers one question ("does this plan quote a bead id into agent
prose?"). The cheap widening is for it to run the *tree* checks that a plan can violate by
specification — at minimum check 1c (`docs/decisions.md` named in agent prose) and check 12 (a
`docs/` path in a suite) — over the plan's blocks, using the same destination heuristic already
built. Concretely: `scripts/lint`, the `--plan` block, gaining a second and third pattern beside
`bead_id_re`. That is a follow-up bead, not something to decide here.

**Seen before.** `ah-tjaz`, `ah-kjfm`, `ah-e0kf` — all three are the same shape (the plan specified
prose this repository's own checks reject), and this bead was filed to end that family. It is the
fourth and fifth sighting, and neither would have been caught by the check the bead adds, because
the rule each broke was not the bead-id one. That is the finding: the family is "a planner cannot
see the lint", not "a planner cannot see the bead-id grep".
