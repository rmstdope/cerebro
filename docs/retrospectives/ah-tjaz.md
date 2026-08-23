# ah-tjaz — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #99

## The plan asked for prose that this repository's own test suite forbids

**What happened.** The plan's *Files to change* told me to name the bead that produced the rule in
both the planner-facing sections, "in the way this skill already names beads for its other hard-won
rules". I did, and `tests/prose-decoupling.sh` failed: bead ids are not allowed in `agents/` or
`skills/` prose, because a consumer's agent cannot resolve them. Both sentences were rewritten to
describe the case without naming it.
**Why.** The planner wrote the plan against how the skills read today; that suite post-dates the
habit it removed, and nothing in the plan-writing path runs it.
**Cost.** One gate run and a rewrite, about five minutes — cheap only because the fast gate here is
`for t in tests/*.sh`, run before the PR opened.
**Prevent by.** A plan that specifies prose for `agents/` or `skills/` should not quote a bead id in
the text it specifies. `skills/plan-bead` could say so where it tells a planner to name the case that
produced a rule — the rule is worth keeping, but the *citation* belongs in the bead, not in the file.
**Seen before.** none found.

## The plan's chosen routing had no mechanism behind it

**What happened.** A user-facing decision, taken with the navigator, was that an implementer handing
back a `verification:failed` bead with nothing to build drops `human` so the bead "returns to
Psylocke, whose list that label already builds". I implemented exactly that. The Copilot review
pointed out that the verifier's work list is built from **closed** beads — `scripts/work-beads`
defaults to `--status closed` — so the bead reached no role at all: no `planned` for implementers, no
`plan:revise` for the planners, no `human`, and not closed. I checked both claims and they hold. The
fix was to close the bead instead of leaving it open, which is the state a reopened bead returns in
anyway.
**Why.** The decision named the destination ("her list") and the plan never checked what builds it.
The bead's own subject is routing by label, so the label looked sufficient.
**Cost.** One review round, one extra CI cycle, about fifteen minutes. It would have cost far more had
the review not caught it: the recipe would have read correct and stranded every bead it was used on.
**Prevent by.** When a plan routes work to a role, its *Validation* should name the query that role
actually runs and assert the bead appears in it — the same standard this plan already applied to the
planners' two candidate queries, which it did check and which were right.
**Seen before.** none found.
