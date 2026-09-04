# cb-cz7 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-04
- **PR:** #322

## A test green here and red on CI was main having moved, not the runner

**What happened.** Three tests added by this bead drove `start_due` /
`cerebro--start-due` and then read `.cerebro/state/decisions.jsonl` back to assert what the
evaluation line said. They were green under `bash tests/gate` on this machine and red on **both**
CI runners and in the Rust job, with the file holding the `start` line and no `evaluate` lines —
while the behaviour assertions in the same tests passed. I read that as an unstable interaction
with the CI runners, rewrote the assertions to avoid reading the file, and spent a CI cycle on the
workaround. The review round after it found what I had actually done: given up coverage of the
production field. The real cause turned up only when the branch was rebased and the same failure
appeared locally — main had split the loud half of the log into its own `evaluations.jsonl`
(`Event::basename`, `cerebro--log-basename`), and CI tests the branch **merged with main** while
this branch was two days behind. The tests were reporting exactly what was there.

**Why.** A red check that a local gate cannot reproduce has two ordinary explanations, and I
weighed only one of them. CI builds the merge; a green local gate is evidence about this branch's
own tree and about nothing else, so "cannot reproduce locally" is the *expected* symptom of main
having changed something the branch reads — not evidence of flakiness.

**Cost.** Two CI cycles and about twenty-five minutes, plus one review round spent on coverage the
workaround had dropped.

**Prevent by.** Before diagnosing a CI-only failure as environmental, fetch and compare against
current main — `git log --oneline HEAD..origin/main` over the paths the failing test reads. On this
bead that would have named the log-split commit in one line. `skills/implement-bead`'s *Red CI*
says to read the failure before believing it; what this adds is that the first thing to read is
what main has done since the branch left it. A rebase is cheap and answers the question outright.

**Seen before.** None found — no retrospective here mentions a CI-only failure caused by the merge
base.
