# cb-1or.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-26
- **PR:** #160

## My loaded `implement-bead` was five hours out of date, and it was this fleet that changed it

**What happened.** I started with an empty `bd ready` queue and followed the copy of
`implement-bead` loaded into my context, whose *Picking up* section said to block and poll rather
than report `done`. I polled for roughly five hours. In the middle of that wait, cb-1or.1 merged
(`db47a60`) and rewrote exactly that section: an implementer with nothing to claim now writes
`waiting` and ends its pass, and the fleet view restarts it when a planned bead appears. I only
found out because a `system-reminder` told me `CLAUDE.md` had changed on disk and I went and read
the skill file, at which point the queue also happened to fill.

**Why.** Established. A skill is loaded once, at the top of a session, and nothing re-reads it. That
is harmless in a consumer repository, where the harness a session runs is a submodule pinned for the
session's whole life. It is not harmless *here*: cerebro is a consumer of itself and `.claude/cerebro`
is a symlink to the working tree, so the fleet edits the very instructions its live sessions are
running, and a long-lived session is running whatever was true when it started.

**Cost.** About five hours of one implementer session sitting in a poll loop that the current rules
had already replaced with "end the pass". No wrong code, no CI cycles — the whole cost was idle
time, and the bead itself took about forty minutes once claimed.

**Prevent by.** `implement-bead`'s *Picking up* section could say, for a wait that has gone past
(say) half an hour, to re-read `.claude/cerebro/skills/implement-bead/SKILL.md` from disk before
continuing to wait — it is one `git log --oneline -5` and one `grep` away, and in this repository a
long wait is itself evidence that the rule about waiting may have moved. Anything narrower will not
catch it: nothing else in a session's life re-opens a skill file.

**Seen before.** None found. `docs/retrospectives/` has nothing about a skill changing under a
running session; the "stale" hits there are about symlinks and byte-compiled `.elc` files.
