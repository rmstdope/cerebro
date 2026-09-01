# cb-m7u — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-01
- **PR:** #243

## `bash tests/gate` is red on a developer machine while the navigator's Emacs is running

**What happened.** `bash tests/gate` in the bead's worktree ended `gate: RED` on
`cerebro-test/tick-refreshes-the-panel-only-when-due`, with
`(should (= supervise-calls 1)) :form (= 0 1)`. The diff touched no elisp at all. Running the same
one test in the shared checkout on unmodified `main` —
`emacs --batch -L emacs -l cerebro-test --eval '(ert-run-tests-batch-and-exit
"cerebro-test/tick-refreshes-the-panel-only-when-due")'` — failed identically, which is what told me
it was not mine.
**Why.** Not established beyond the shape: the supervision lease is a bound loopback listener on a
port derived from the shared root, and the navigator's live `M-x cerebro` holds it, so the batch
Emacs cannot acquire it and the tick takes no supervise action. I did not prove it by stopping the
fleet view.
**Cost.** About ten minutes — two full gate runs to find which leg was red, then one run against
main to establish it was pre-existing.
**Prevent by.** Two things would each have saved it. `skills/implement-bead`, *Building*, could say
that a red gate leg is checked against unmodified `main` **before** it is read as a defect in the
bead — the single-test command above is the whole check, and it is cheap. And the test itself could
skip, rather than fail, when the lease is already held by something outside the test: a
`cerebro-test` case that depends on being able to take a machine-wide lock is red for a reason that
has nothing to do with the code under test, on exactly the machine that runs the fleet.
**Seen before.** None found — `grep -rl supervis docs/retrospectives/` matched nothing.
