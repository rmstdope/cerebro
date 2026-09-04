# cb-ykz.2 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-04
- **PR:** #328

## A hand-fabricated fleet row needs the marker sentence, not just a live pid

**What happened.** The plan's *Validation* section says to fabricate a stuck row by writing a state
file with `"state":"working"`, a `phase`, a `bead`, `a pid of a live process`, and a past
`turn_ended`. Two attempts that satisfied that literally drew no stuck row: the first used an
unrelated live pid, the second a name that turned out to have a live session of its own. A row only
derives from its state file when `cerebro--session-alive-p`'s rule holds — the named pid's command
line must carry `This session is <Name> of the cerebro fleet rooted at <root>/.` — so an arbitrary
live pid derives the row from the process scan instead and drops `turn_ended` with it. What worked:

```bash
nohup /bin/sh -c 'exec -a "fake This session is Wolverine of the cerebro fleet rooted at /Users/henrikku/repos/cerebro/." sleep 120' &
```

and a state file naming that pid, for a roster name with **no** live session
(`scripts/agent-alive <Name>` answers that; a `ps` grep for the marker also does).

**Why.** The Validation instruction described the state file and not the liveness rule the reader
applies to it, and the two are documented in different places (`CLAUDE.md`'s "A live pid means the
agent's own session" paragraph is the rule).
**Cost.** About fifteen minutes and three attempts, two of which briefly wrote a state file for a
name the live fleet view was drawing.
**Prevent by.** A plan whose *Validation* asks for a fabricated fleet row should give the
marker-carrying `exec -a` line above, or point at `CLAUDE.md`'s liveness paragraph, rather than
saying "a pid of a live process" — and should say to pick a name `scripts/agent-alive` reports
dead, since fabricating over a live session's name interferes with the running fleet.
**Seen before.** None found; `cb-d59.3` and `cb-d89` are about readers of the same sentence
disagreeing, not about fabricating a row with it.

## A mutation check restored in the same second left cargo running the mutated binary

**What happened.** To prove a new guard was load-bearing I did the usual mutation check —
`cp src/main.rs /tmp/main.bak`, `sed -i ''` the guard out, `cargo test <one test>` (red, as wanted),
`cp /tmp/main.bak src/main.rs` — all inside one shell command. The next two `cargo test` runs, in
`tests/gate` and on its own, failed that same test with the *mutated* behaviour, against source
that plainly carried the guard. Adding one `eprintln!` made it green, and it has been green over
seven full runs since. Cargo compares mtimes at second granularity: the restore landed in the same
second as the mutated build's fingerprint, so the stale binary was reused, and the next edit of any
kind forced the real rebuild.
**Why.** Established: nothing else touched the file, and the failure moved exactly with a rebuild
rather than with any source state.
**Cost.** About twenty minutes, spent looking for a race in supervision-mode handling that was
never there. It also read as a flaky test, which would have been the wrong thing to conclude.
**Prevent by.** After restoring a mutated file, force the rebuild rather than trusting mtimes:
`touch` the file (or `cargo test` twice) before believing a red result. Worth a line in
`skills/implement-bead`'s *Traps this fleet has already paid for* if it is seen a second time —
"a green gate that then goes red with no edit between" is otherwise indistinguishable from a flake.
**Seen before.** None found for cargo; `.cerebro/traps.md` has no entry for it.
