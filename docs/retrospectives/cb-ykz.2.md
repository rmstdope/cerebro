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
