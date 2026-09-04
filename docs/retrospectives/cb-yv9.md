# cb-yv9 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-09-04
- **PR:** #329

## A plan's manual `cerebro-tui` step cannot be run while the navigator's view holds the lease

**What happened.** The plan's *Validation* ended with a manual look: start
`.claude/cerebro/scripts/cerebro-tui`, press `s`, then `k` and `y`, and read the new `disarm` line
back out of `decisions.jsonl`. That cannot be done from a bead worktree while the fleet is
running. `cat .cerebro/state/supervisor.json` showed `{"owner":"tui","pid":86554}` — the
navigator's own view holding the supervision lease — and the lease is a bound listener rather than
a timeout, so a second view comes up **read-only**, where `s` and `k` do nothing at all. The only
way to perform the step as written is to stop the live fleet's supervisor, which is not an
implementer's to do for a validation step.
**Why.** Established. Every `cb-kcs`-era plan that ends "look at it once" was written for a
navigator running it by hand; an implementer running the same step is a *second* view on a
checkout that already has one, and `fleet_supervisor tui` means the first one always wins.
**Cost.** About ten minutes: reading the lease rule to be sure it was not a mistake of mine,
then writing the PR comment that says what stands in the step's place.
**Prevent by.** A plan whose *Validation* asks for a manual `cerebro-tui` (or `M-x cerebro`) step
should say what the implementer does when the lease is held — which is normally "the automated
case is the evidence; say on the pull request that the manual look is the navigator's, after
merge". `skills/plan-bead`'s guidance on *Validation* is where that belongs, since it is every
fleet-view bead in this repository and not this one.
**Seen before.** None found — `grep -rl "read-only\|manual" docs/retrospectives/` turns up cb-5kk
and cb-kcs.2.3, both about the read-only *code path* rather than about a step an implementer could
not run.

## The plan's prose and its own code block disagreed about a predicate

**What happened.** The plan described `clear_failures_if_a_pass_ran`'s condition as "exactly
`!start_failed(started_at(name), Some(at))`" and, three lines below, gave the code as
`self.started_at.get(name).is_some_and(|started| at > *started)`. Those differ for a name this
view never started: `start_failed(None, _)` is `false`, so the prose version clears a count with no
start behind it. Writing the prose version made the plan's own third test arm — "a name this view
never started keeps whatever count it was given" — fail.
**Why.** Established: two spellings of one rule in one document, and only one of them was run
against the tests the same document specified.
**Cost.** One RED-GREEN cycle, about three minutes. Small, and recorded only because it is the
`implement-bead` rule "a helper the plan cites for what it decides is read before it is built on"
firing on the plan's *own* helper rather than on an existing one — the same failure mode, one step
earlier, and the tests the plan wrote are what caught it.
**Prevent by.** Nothing new. The existing rule and the plan's own test arms were sufficient; this
is a data point for how often a plan carries two spellings of one predicate, not a gap.
**Seen before.** None found.
