---
name: produce-bead
description: Produce one UX-agreed bead end to end: decide the build and tests, implement it with TDD, review it, validate it, and deliver it.
---

# Producing a bead

Load `beads-workflow` and the consumer's root `CLAUDE.md`. You take one UX-agreed bead already
claimed for you; `bugfix` beads stay with the bugfixer.

1. Confirm the prompt's bead is `in_progress` and assigned to you. Work only in the prepared
   worktree. Write `working --phase design` through `agent-state`.
2. Read its acceptance and mockup. The agreed experience is fixed. Decide the architecture, files,
   increments, test plan, validation, and any non-UX details. Write those decisions to the bead's
   `design` field under the usual eight plan headings, then add `planned`. If the experience cannot
   be built as written, remove `planned`, add `human`, unclaim it, push, and end the pass.
3. Design each test with the increment it proves. Work RED -> GREEN -> REFACTOR, beginning every
   increment with its failing test. Use `build`, `gate`, `review`, `ci`, `rebase`, and `merge` as
   the phase changes; heartbeat before long work.
4. Run the declared gate. Obtain and answer a review sub-agent round under the Four Eye Principle,
   then rerun required checks. Deliver by this consumer's configured merge convention, close and
   push the bead, and run `end-pass` last.

Never take another bead, alter agreed UX, or skip a failing test, review, or required check. Ask
the navigator only for a genuine UX, scope, or approach decision; otherwise decide and record it.
