# cb-6uc — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-31
- **PR:** #206

## A stub on the head of PATH does not make a command missing

**What happened.** The suite's *"gh missing from PATH exits 1, not 3"* case ran the script with
`PATH="$stub_dir:/usr/bin:/bin"` and an empty stub directory. It passed on this machine, where `gh`
is installed under `/opt/homebrew/bin` and therefore genuinely absent from that PATH. On
ubuntu-latest, which is what CI runs, `gh` ships at `/usr/bin/gh` — so the case would have found the
real GitHub CLI, tested nothing, and attempted `gh pr edit 42 --add-reviewer @copilot` against this
repository. It was caught in review, not by the gate.

**Why.** A stub prepended to PATH proves what is *found first*; a case about a command being
**absent** needs PATH to contain nothing else that could supply it, and the machine that runs the
suite is not the machine that decides that. Every case now runs with its stub directory as its whole
PATH, with the two externals actually needed (`grep`, and `bash` for the stub's own
`#!/usr/bin/env bash`) symlinked in.

**Cost.** One review round and one extra local gate cycle; about fifteen minutes, and no CI cycle,
because it was found before the merge. Had it shipped, the visible failure would have been a flaky
or PR-mutating CI job on a machine nobody was looking at.

**Prevent by.** In `tests/lib/consumer.sh`, a helper that builds a *hermetic* bin directory — whole
PATH, chosen utilities symlinked in — so a suite asserting "this command is missing" cannot borrow
the host's. `tests/request-review.sh` has a local `link_utils` doing exactly this; the second suite
that needs it is the moment to move it into the library. The narrower rule, worth stating wherever
stubs are described: **a stub at the head of PATH tests precedence, never absence.**

**Seen before.** none found — `cb-ccl.md` mentions PATH, but about a stub that exits 127 on purpose,
which is the opposite direction.
