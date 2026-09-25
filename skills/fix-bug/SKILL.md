---
name: fix-bug
description: The bug-fix role — take one bug bead, reproduce it with a failing test of the agent's choice, fix the implementation, and merge once the new and existing tests are green.
---

# Fixing a bug bead

Take one `bugfix` bead from report to merge. The route is fixed: **reproduce first, then fix**. A
bug bead never went through UX and never will: it carries no `ux:agreed`, no `ux:none` and no
mockup, and `scripts/bugfix-candidates` is the one queue it is handed from.

**Follow `skills/produce-bead/SKILL.md` for everything that is not the contract below**, with
these readings: the *State file* and its phases (`design` while you read the bead and decide the
test, then `build`, `gate`, `review`, `ci`, `rebase`, `merge`); *Workspace* and its ports;
*Building*, whose fast gate you run before the PR; *Waiting, without ending your run*; *The review
loop*, where the reviewer reads the diff against **the bead's bug claim and your reproduction
test**, since a bug bead has no plan, and your posted review says so in place of "the plan";
*Red CI*; *Merging*; *The retrospective*; *Finishing*, the parent walk included. You write no
`design` and add no `planned`: the reproduction test is the plan. *Known traps* from
`.cerebro/traps.md` are read before you touch the code.

## The bug-fix contract

1. **Start from the bead's bug claim.** Read the bead, and for a `gh-<n>` bead the issue; identify
   the concrete behaviour that is wrong. A bead carrying `verification:failed` is a fix the
   navigator saw fail: read the dated failure note first, and what shipped
   (`git log origin/main -F --grep "(<id>):"`), before choosing the test.
2. **Reproduce with a test before touching implementation code.** Choose the test type yourself:
   unit, integration, end-to-end, or another existing test shape in the repository.
3. **Make the reproduction test fail for the right reason.** The failure must be the bug the bead
   describes, not an unrelated setup or fixture failure.
4. **Fix the implementation with the smallest coherent change that makes the new test pass.**
5. **Keep existing behaviour green.** Run the new test and the existing relevant tests, then the
   fast gate `produce-bead` *Building* names.
6. **Merge only through the pull request, after review and green checks** (`produce-bead`
   *Merging*), then close the bead, close its parent if you were the last child, and end the pass.

## When to hand back instead of forcing a fix

A bug is never parked for UX: `producer-park` refuses a `bugfix` bead, since the UX queue excludes
it. Hand it back through `produce-bead` *Handing back*, the `human` form, when:

- the bead does not describe a reproducible bug,
- the bead's expected behaviour is ambiguous enough to need a product decision,
- or reproducing it would require a test surface that does not exist and cannot reasonably be added
  within the bead's scope.

Use the `second-look` form of that block when a `verification:failed` bug has **nothing left to
fix**: the behaviour the navigator saw is already gone from main, or another bead carries it.

When handing back, append notes that name what you tried, what test surface you attempted, and what
decision or missing information blocks a correct fix.
