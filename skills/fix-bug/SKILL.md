---
name: fix-bug
description: The bug-fix role — take one bug bead, reproduce it with a failing test of the agent's choice, fix the implementation, and merge once the new and existing tests are green.
---

# Fixing a bug bead

Take one bug bead from report to merge. The route is fixed: **reproduce first, then fix**.

Use `skills/produce-bead/SKILL.md` for the mechanics only: state writes, *Known traps* from
`.cerebro/traps.md` before you touch the code, the review loop, the CI wait, *The retrospective*
before the merge, the merge, the close, and ending the pass. Do **not** apply its planned-bead plan-validation gates here;
bugfix beads run through this reproduction-first contract instead.

## The bug-fix contract

1. **Start from the bead's bug claim.** Read the bead and identify the concrete behaviour that is
   wrong.
2. **Reproduce with a test before touching implementation code.** Choose the test type yourself:
   unit, integration, end-to-end, or another existing test shape in the repository.
3. **Make the reproduction test fail for the right reason.** The failure must be the bug the bead
   describes, not an unrelated setup or fixture failure.
4. **Fix the implementation with the smallest coherent change that makes the new test pass.**
5. **Keep existing behaviour green.** Run the new test and the existing relevant tests, then the
   same fast gate `produce-bead` requires before opening a PR.
6. **Merge to `main` only after review and green checks, then close the bead and end the pass,**
   exactly as `produce-bead` specifies.

## When to hand back instead of forcing a fix

Hand the bead back using `produce-bead`'s *Handing back* block when:

- the bead does not describe a reproducible bug,
- the bead's expected behaviour is ambiguous enough to need a product decision,
- or reproducing it would require a test surface that does not exist and cannot reasonably be added
  within the bead's scope.

When handing back, append notes that name what you tried, what test surface you attempted, and what
decision or missing information blocks a correct fix.
