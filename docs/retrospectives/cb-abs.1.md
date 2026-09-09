# cb-abs.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-09
- **PR:** #362

## `a_declaration_change_moves_the_lease_and_back` flaked again, on its third sighting

**What happened.** The review sub-agent's first full `cargo test --workspace --all-targets --locked`
on this branch (cold compile, loaded machine) failed
`main_tests::a_declaration_change_moves_the_lease_and_back` with
`ReadOnly(DeclarationUnreadable("cannot locate the supervision lease"))` where it wanted
`Supervising`. It passed on three subsequent full runs and three isolated ones, and on every run of
`bash tests/gate` in the worktree and in a throwaway clone.
**Why.** Not established here, but the test's own comment at `fleet-view/src/main.rs:7654-7659`
names the mechanism: each attempt inside its `probe::wait_for(probe::POLL_BOUND, …)` **forks
`fleet-supervisor`**, so the number of attempts a five-second budget buys depends on how loaded the
machine is. Nothing in this bead touches that test, its budget, or anything it reads — the branch
deletes an unrelated pair of Emacs tests — so this reads as pre-existing rather than introduced.
**Cost.** None to this bead: it was seen by the reviewer, not by CI, and CI was green on both heads.
The cost is the next one — a lease test that is red about one run in four is how a fleet learns to
re-run rather than read.
**Prevent by.** Not by widening `POLL_BOUND` blindly: cb-kcs.5.3 spent 25 minutes on exactly the
"one attempt short" failure and cb-a54 recorded that its own fix was very nearly one attempt short
in turn, so the budget has already been tuned twice by hand. What is not yet written down anywhere
is that this test's cost per attempt is a **process fork**, which is what makes it load-sensitive
where the rest of `probe::`'s callers are not. A bead that makes the attempt cheap — reading the
declaration once and driving the controller with the string, the way
`reconcile_supervision`'s own cases do — would end the class rather than move the threshold.
This is the third sighting, so it is worth filing rather than tolerating.
**Seen before.** cb-kcs.5.3 (diagnosed, 25 minutes), cb-a54 (recorded; the fix was itself nearly
one attempt short). Both are about the same test and the same budget.

## A plan's increment boundary can be un-buildable when one suite spans two increments

**What happened.** The plan's increment 1 inverted `tests/app-paths.sh`'s assertion to "no document
names `emacs/`", to be made green by dropping the clause from `agents/architect.md` and
`CLAUDE.md:429`. That assertion greps the **whole** of `CLAUDE.md`, which still carried the
`## emacs/cerebro.el` section until increment 4. So increment 1 could not end green, and increment 4
could not open red — the two are one commit or nothing.
**Why.** The plan reasoned about the two `emacs/` *clauses* it was removing, and the suite reasons
about the file. Both are right; the coupling is only visible once the inverted assertion is run.
**Cost.** About ten minutes — one stash, one restore, and re-planning the commit boundary.
**Prevent by.** Nothing in the fleet's instructions: `skills/implement-bead`'s *When the plan is
wrong* already covers "a detail the plan missed is yours to decide, and record the deviation", which
is what happened, and the PR body records it. Worth recording only as evidence for a planner: an
increment whose RED is a **whole-file** grep is not separable from any later increment that edits
that file, however unrelated the two edits are.
**Seen before.** None found.
