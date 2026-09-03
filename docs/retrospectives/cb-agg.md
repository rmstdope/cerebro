# cb-agg — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-03
- **PR:** #304

## The plan's stated drop order was wrong, and I copied it into the code

**What happened.** The plan gave `LoopState`'s field order literally — `pruner, told, host, ledger,
logger, controller` — with a *Known traps* entry saying that order "reproduces the drop order these
values have as locals in `start` today" and to keep it. I kept it. It is wrong: in `start` at the
merge base the locals were declared `controller, ledger, logger, host, told, pruner`, so as locals
the **logger** dropped before the **ledger**, and the struct as planned drops them the other way
round. The cold read caught it (`gh pr view 304` — finding 2), and the fix was to declare `logger`
before `ledger`.

**Why.** The plan asserted a fact about current source — a declaration order in `fn start` — and
wrapped it in a trap entry telling the implementer to preserve it. `implement-bead`'s *When the plan
is wrong* says to check a current-source claim before the increment that depends on it; I checked
the *load-bearing* half of the trap (that `LoopState` must be constructed before `TerminalGuard`,
which was right) and took the field list on trust because it read as a decision rather than as an
observation. Nothing mechanical could catch it: neither `StartLedger` nor `Logger` has a `Drop`
impl, so the whole gate is green either way.

**Cost.** One review finding and one delta round, about eight minutes. Would have been a latent
wrong premise for the next field added to the struct.

**Prevent by.** In `implement-bead`, *When the plan is wrong* already covers this ("a current-source
claim the plan relies on is checked before its increment begins"). What it does not say is that a
**verbatim ordering or list the plan asks you to preserve is a current-source claim**, not a
decision — a field order, an argument order, a call order, a match-arm order. Those read like
architecture and are actually observations, and they are exactly the ones a plan can be confidently
wrong about. One `git show <base>:<file>` before copying one in is the whole check.

**Seen before.** None found in `docs/retrospectives/` for a plan-stated ordering; the nearest
neighbours are the doc-comment-stealing trap in `cb-21g.md` and `cb-kcs.3.md`, which are about edits
to the same file rather than about trusting the plan.
