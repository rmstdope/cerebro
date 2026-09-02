# Moving supervision between the two fleet views

**Status: procedure.** Read this to cut over, to roll back, or when neither view will act. The
reasoning behind the lease is in `CLAUDE.md`; the measurement that chose this shape is in
`docs/fleet-view-alternatives.md`. This file is the steps.

Two questions, and they have different answers. **Which program may act** on a checkout is
`fleet_supervisor` in `.cerebro/project.conf` — `emacs`, `tui`, or absent, which means `emacs`.
**Which process is acting** is whichever one holds a bound loopback listener on a port derived
from the shared root. The bind is the lock. There is no pid file, no heartbeat, no lease
duration and no stale-entry sweep: the kernel closes the listener when its holder dies, so a
crashed supervisor releases immediately and nobody has to judge that it crashed.

## Cutting over

Both views re-read the declaration within five seconds of it changing, so nothing has to be
restarted for the handover itself. What does need care is the *order*, because a view that
acquires the lease after it has started comes up with nothing armed.

1. Write the declaration:

   ```
   fleet_supervisor tui
   ```

2. Watch the view that is losing it. Within five seconds its mode line or header says so:
   `Cerebro[read-only: Ratatui supervises]` if it hosts nothing, `Cerebro[handoff pending]` if
   it does. A drain is not a fault — see the next section.

3. **Start the new supervisor fresh**, after the declaration has changed:

   ```bash
   .claude/cerebro/scripts/cerebro-tui
   ```

   Starting it fresh matters. The roster's `autostart` and `standby` declarations are read
   once, as a view comes up, and only by a view that may act. A view that was already running
   read-only and then acquires the lease has an empty armed set: it supervises correctly, and
   it starts nothing until you press `s` once per name. Both views behave this way. If yours
   was already open, quit it and open it again.

4. Confirm one view and only one is acting. The owner's header says `Cerebro — supervising`;
   the other says `read-only`. If both say read-only, go to *When neither view will act*.

## What a drain is, and what it is not

A view that holds the lease when the declaration moves away from it does not drop what it is
hosting. It **drains**: it keeps the lease so the new owner cannot start duplicates of the
sessions it is still holding, keeps those sessions usable, starts and nudges nothing, stops its
worktree pruner, and releases the moment the last one ends.

So during a drain `f` and `k` act and `s` does not, and the view says `Handoff pending: 2
sessions still hosted; only f and k act now`. Let the sessions finish, or finish them yourself;
the handover completes on its own.

A drain is **not** an error and is never reported as one. It is also not a state you can be
stuck in: ending the last hosted session ends it.

## Rolling back

The same procedure with the words swapped, and it is one line either way:

```
fleet_supervisor emacs
```

or delete the key, which means the same thing. The TUI drains or goes read-only within five
seconds; Emacs acquires within five. Then **restart the view that acquired**, for the reason
step 3 gives. Nothing else is undone: no bead, no state file, no stop flag and no worktree is
touched by a change of supervisor.

## After the supervisor crashes

Nothing to clean up. The listener closes with the process, so the lease is free the instant the
crash happens, and the next tick of the other view — or the next start of the same one — takes
it. `.cerebro/state/supervisor.json` beside it is **diagnosis only**: it names who to put on the
screen. A record that is missing, malformed or names another checkout never grants supervision;
it produces a visible lock error instead.

The one thing a crash leaves behind is the sessions it was hosting, which die with it. Their
state files are removed by whichever view ends them; one left behind by a killed process is
deleted before that name is started again.

## When neither view will act

Read the sentence on the screen; each has one cause.

| What it says | What is true |
|---|---|
| `read-only: invalid fleet_supervisor "rat"` | The declaration is neither word. Fail-closed on purpose: a typo grants supervision to nobody and drops no session. Fix the line. |
| `read-only: the supervision lease could not be taken` | The port is bound and the record does not explain by whom, or the record could not be written. Usually a second checkout on the same port, or a `cargo test` running the lease tests. |
| `read-only: ownership could not be worked out` | Working out whose the checkout is failed — not the lease. This view may still be holding a live listener. |
| `read-only: fleet_supervisor could not be read` | The reader did not run or did not answer. The next tick retries; `g` retries now. |

The detail behind each is in `.cerebro/state/errors.jsonl`, one line per outage, never on the
screen: an absolute path in a mode line is unreadable and pushes everything else off it.

## What both views do whichever one supervises

The lease gates the **session lifecycle** and nothing else. Both views go on drawing the fleet
and the six queues, running the six sweeps, offering `x` on a finding, and writing a bead's
priority. Those write to the shared board rather than to this checkout's sessions, they are your
own act and each asks first, and the same `bd` would run from any machine.
