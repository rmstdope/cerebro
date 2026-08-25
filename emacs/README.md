# cerebro.el

An Emacs 28+ package that lists the cerebro agent fleet: `M-x cerebro` opens a self-refreshing
buffer showing every agent on `scripts/roster` — with its
state, and for one working a bead (an implementer, or one of the interactive agents
mid-verification or mid-triage) the bead it is on and for how long.

## Getting the fleet view

Nothing to install by hand — from anywhere inside the consumer:

```bash
.claude/cerebro/scripts/cerebro
```

That opens the fleet view in a fresh Emacs, loading your own init (which is where vterm, and so
the view's live sessions, comes from). `EMACS` names the binary, for an Emacs.app that is not on
`PATH`.

To have `M-x cerebro` in the Emacs you already work in, add to your init:

```elisp
(add-to-list 'load-path "/path/to/consumer/.claude/cerebro/emacs")
(autoload 'cerebro "cerebro" "List the Cerebro agent fleet." t)
```

It supports a live detail window that follows the list selection, and starting/killing agents
from the list:

| Key   | Does                                                                       |
|-------|----------------------------------------------------------------------------|
| `s`   | starts a dead agent, into an Emacs-owned `vterm` buffer running its launcher |
| `k`   | kills a live one, confirming harder mid-bead                                |
| `f`   | tells an Emacs-owned implementer to finish: mid-bead it completes the bead first (row shows ■) and is not replaced; idle, it stops at once. Refuses for a dead one, or one idle outside Emacs |
| `RET` | in the agent list: selects the detail window, to type to the agent shown there. In the bead panel: shows the marked bead there |
| `TAB` | next window: list → beads → detail → list. Works from all three             |
| `n`/`p` | next/previous row                                                        |

`TAB` is bound in the session buffers too, which means taking it off vterm — done with a minor mode
(`cerebro-session-mode`) so it applies only to the buffers the fleet view created, never to the
navigator's own vterms. `C-c TAB` sends a real tab on to the agent when one is wanted.

Rows whose `.cerebro/roster.conf` line carries a third word `autostart` are started as the fleet
buffer is created — once, not on every `M-x cerebro`, or the next one would restart whatever `k`
had just killed — with one echo line saying who started and who was already up. A stop flag left on
such a name is cleared, as `s` would, and for every kind rather than implementers only. Nothing
restarts an autostarted agent that later dies; that is still `s`.

An agent running outside Emacs is shown and marked but not viewable — a placeholder says so. This
needs **vterm** (`emacs-libvterm`); without it the list still works, and `s`/`RET` signal a clear
error instead of failing obscurely.

A session that dies on its own — a launcher refusing because `claude` is missing or the submodule
never brought its agent file in, or `claude` exiting on its own — leaves its last printed line behind:
once in the echo area, and in the dead row's placeholder until the next `s` starts it again.
A session `k` killed, or one the ten-minute poll ended on purpose, records nothing.

## Reading a row

The glyph carries the state and the weight carries the urgency:

| Row                | Means                                                          |
|--------------------|----------------------------------------------------------------|
| green `●`          | working, or an interactive agent that is up                     |
| yellow `●`         | idle — a session is up with no bead, which may want a nudge     |
| yellow `◐`         | waiting — an interactive role between passes; it is ended within half a minute |
| blue `◌`           | standby — the view ended this role after its pass and starts a fresh one when the trigger in the For column fires; `RET` shows its last pass |
| yellow `?`, **bold** | asking: it needs an answer from you, and the whole row says so |
| green `◍`          | done, and about to be replaced by a fresh session               |
| grey `○`           | dead — nobody is there                                          |

Bold is only ever "this row wants you", so it stays worth noticing: idle and dead share the quiet
weight, and only a question earns the loud one.

A row is only as alive as its process: the state file's pid must still be running **and** its command
line must still carry `--name <that agent>`. Pids are recycled, and a state file left behind by a
finished session used to come back green hours later once the operating system handed its number to
something else. The fleet view now deletes an agent's state file whenever it ends that agent's
session, so the file rarely outlives the pid in the first place.

Idle and working are the same dot and differ only in colour, which is what the State column beside
them spells out in words. The yellow is the `cerebro-idle` face — its own face rather than the stock
`warning`, which Emacs defines as DarkOrange **and bold**: orange where yellow was wanted, and bold
where bold is supposed to mean something else. Customize that one face if gold does not read against
your theme.

## The bead panel

Under the agent list, in a window of its own, `*cerebro-beads*` answers the questions the navigator
asks about the queue, in the order they are asked:

```
Claimed 1
  bd-13o  P1 Resizable split between the two side panes

Planned, unclaimed 0
  (none)

Being planned 2
  bd-8m0  P1 Fleet-wide question-state hooks
  bd-2p1  P2 Second planner: the buffer counts pickable work

Unplanned 4
  bd-3cs  P1 Config option for a fixed detail-pane size
  bd-4ao  P2 Drive the implementer fleet from the Emacs agent…
  +2 more

Merged, unverified 0
  (none)
```

**Being planned** is what the planners are holding right now — open beads carrying `planning:<the
planner holding it>`, or the bare `planning` from a session older than that spelling, one per
planning session. They are deliberately not folded into either neighbour: Unplanned is
work nobody has started, and Planned, unclaimed is work an implementer can take this second, while
these can be neither claimed nor picked up until the plan lands. Read next to Planned, unclaimed it
also answers the question a short queue raises — whether the planners are behind, or simply mid-bead.

The panel shows work the fleet can act on, and stops there. **Merged, unverified** is what has landed
and still wants checking — Psylocke's queue — sorted newest first, since priority says nothing about
finished work.

Quite deliberately, not every bead appears. Verified work is finished; a bead marked
`verification:passed` or `verification:not-needed` is settled either way. Epics are parents rather
than work. bd's own `event` records are its bookkeeping — and they carry the very labels these rules
key on, so without excluding them "State change: verification → passed" arrives looking like merged
work. Blocked and deferred beads cannot be picked up. A panel is a list of what to do about
something, so what there is nothing to do about is left out.

One `bd` call fetches every status and the panel partitions it, which keeps those exclusions in one
readable place rather than spread across five invocations.

A failed verdict reopens a bead into the unclaimed pile at P0, where it is an ordinary open bead —
which is the point. The row carries a `↻` so that pile can still say which work came back rather
than arrived:

```
↻ bd-t65  P0 came back from a failed verdict
  bd-t70  P0 never left
```

The open sections are sorted by priority then id, so P0 reads first and the order does not shuffle
under a redraw. Each
section names its own count, because the rows are what gets capped — `cerebro-beads-per-section`,
eight by default, keeps an unbounded backlog from pushing the first two sections off the bottom.

Re-prioritising is what the panel is for as much as reading it:

| Key       | Does                                                            |
|-----------|-----------------------------------------------------------------|
| `0`–`4`   | set the marked bead's priority outright (0 is most urgent)      |
| `+` / `-` | one step more / less urgent, clamped at P0 and P4               |
| `u`       | put back the last priority this panel changed — one step        |

The change is immediate, with no confirmation, which is the point during a triage pass — the echo
area says `bd-3cs: P1 -> P0` and the row re-sorts under the mark. `u` exists because that is also
how a mis-keyed digit behaves; it is one step rather than a stack, so a second `u` says there is
nothing to undo instead of quietly redoing the change. Setting the priority a bead already has
writes nothing and records no undo.

Digits are `digit-argument` elsewhere in Emacs; this buffer spends them on priorities, there being
nothing here a numeric prefix would have been for.

It reads like the agent list: one bead is marked, `n`/`p` (or the arrow keys) step between them, and
navigation skips the section headers, blank lines and `(none)` rows. `RET` shows the marked bead in
the detail window on the right — `bd show`'s own rendering, read-only, in one reused buffer rather
than a drift of them. A bead `bd` cannot show says which one and why instead of leaving an empty
buffer, which would read as a key that did nothing. The mark is `hl-line`, sticky,
so the picked bead stays visible while you are working in another window.

The mark follows the *bead*, not the line: the panel redraws on a timer, and restoring by position
would slide the mark onto whatever row took that line when the queue changed. If the marked bead is
merged, closed or claimed away, the mark falls back to the first row rather than to nothing.

It refreshes every `cerebro-beads-refresh-seconds` (30) and on `g`, without ever holding Emacs: `bd`
is asked in the background and the rows stay put until it answers. The header line above the panel
says what the rows date from (`Beads · as of 12:03:41`), that a refresh is out (`· refreshing…`), and
when `bd` did not answer — absent, unconfigured, mid-write, or past
`cerebro-subprocess-timeout-seconds` — (`· bd did not answer at 12:04:32`), rather than showing
numbers that do not say they are stale. The sweeps run the same way on their ten-minute cadence, and
a sweep that does not answer leaves the last findings standing.

There is deliberately no owner column. `bd`'s `owner` is whoever *filed* the bead and is set on
every one of them; who is *working* on a bead is what the agent list directly above already says.

## Supervising the implementers

Implementers are interactive sessions that take one bead each, so they cannot end themselves. The
same five-second poll that refreshes the list acts on what each one reports in
`.cerebro/state/<name>.state.json`:

- **`done`** — the bead is merged, closed and cleaned up. The session is ended and a fresh one
  started for the next bead, which is how a session's context stays one bead deep.
- **`done` with `.cerebro/state/<name>.stop` present** — ended, and no replacement; the flag is
  removed with it. `s` on a name with a flag removes it too, and says so. That is what "stop an
  implementer" means: it finishes what it is on, and then does not come back until started again.
- **`asking`** — blocked on a question only the navigator can answer. Answer it in the detail
  window. After `cerebro-answer-timeout` (900s) with no answer, the session is told to hand the
  bead to the `human` queue and finish, once, so a fleet left alone does not sit blocked.
- **`idle` with the flag present** — ended at once, no replacement: nothing is in flight to finish.
  `f` on an idle row does this on the keypress rather than waiting for the next poll.

Only implementers Emacs itself started are supervised: one running in somebody's own terminal is
theirs to end, and a dead one stays dead rather than fighting your own `k`.

## Supervising the interactive roles

The same poll runs the interactive roles the same way, and for the same reason: a session that
carries one pass is one whose context is that pass and nothing before it.

- **`waiting`**, or **`idle`** for a role that ends its pass with that instead (Forge) — the session
  is ended `cerebro-end-grace` (30s) later, long enough for the one line it prints after writing the
  state to land. Its **buffer is kept** as the record of the pass, renamed `*fleet: <Name> (ended
  HH:MM)*` and made read-only; the row goes to **standby** and `RET` shows it.
- **standby** — nothing is running, and the For column says what would start one: `→ buffer < 4` for
  a planner, `→ merged, unverified` for the verifier, a countdown (`→43m`, `→21h04`, `→due`) for a
  role on a cadence. When the trigger comes true the view starts a fresh session and says which and
  why: `cerebro: started Psylocke — 2 merged, unverified`.
  ` gh?` on a standby row means `gh` did not answer the fleet view — Moira and Cypher then come
  back hourly only, until it does.
- **`waiting` or `idle` with `.cerebro/state/<name>.stop` present** — ended at once, whatever the
  grace says: nothing is in flight for it to protect. The flag is removed with it and the name is
  disarmed, so nothing starts in its place.

**Arming lives in this Emacs and nowhere else.** `s` — and `autostart` in `roster.conf` — arms a
role; `k` and `f` disarm it. Nothing is written to any file, so a new Emacs starts nothing until you
start something: opening the fleet view does not resurrect a fleet you took down last night.

`f` on a running role writes the flag and says *told <Name> to finish its pass - it stays down until
you press s*; on a standby row there is no pass to finish, and it says *<Name> is on standby - press
k to disarm it, or s to start it now*. `k` on a standby row asks *Disarm <Name>?* and forgets the
kept buffer.

`cerebro-wake-intervals` is no longer a sleep the role asks for: it is the **floor between two
starts** of one role, which is what stops a trigger its pass cannot clear — a P0 nobody can plan, a
verification you have not run — restarting it on every tick.

Run the tests with:

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit
```

The suite exercises the pure core on plain data, plus one **reader contract** per impure reader:
the real reader run against a fixture, its output handed to the pure function that consumes it.
When you add a reader, add its contract case in the same change — that is the only test that can
tell "this pure function is right" from "this pure function is right about inputs nobody
produces".
