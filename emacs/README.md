# cerebro.el

An Emacs 28+ package that lists the cerebro agent fleet: `M-x cerebro` (after adding
this directory to `load-path` and `(require 'cerebro)`) opens a self-refreshing buffer
showing every agent — Xavier, Cerebro, Moira, Psylocke, Bishop and the thirteen implementers — with its
state, and for a working implementer the bead it is on and for how long.

It supports a live detail window that follows the list selection, and starting/killing agents
from the list:

| Key   | Does                                                                       |
|-------|----------------------------------------------------------------------------|
| `s`   | starts a dead agent, into an Emacs-owned `vterm` buffer running its launcher |
| `k`   | kills a live one, confirming harder mid-bead                                |
| `RET` | in the agent list: selects the detail window, to type to the agent shown there. In the bead panel: shows the marked bead there |
| `TAB` | next window: list → beads → detail → list. Works from all three             |
| `n`/`p` | next/previous row                                                        |

`TAB` is bound in the session buffers too, which means taking it off vterm — done with a minor mode
(`cerebro-session-mode`) so it applies only to the buffers the fleet view created, never to the
navigator's own vterms. `C-c TAB` sends a real tab on to the agent when one is wanted.

An agent running outside Emacs is shown and marked but not viewable — a placeholder says so. This
needs **vterm** (`emacs-libvterm`); without it the list still works, and `s`/`RET` signal a clear
error instead of failing obscurely.

## Reading a row

The glyph carries the state and the weight carries the urgency:

| Row                | Means                                                          |
|--------------------|----------------------------------------------------------------|
| green `●`          | working, or an interactive agent that is up                     |
| yellow `●`         | idle — a session is up with no bead, which may want a nudge     |
| yellow `?`, **bold** | asking: it needs an answer from you, and the whole row says so |
| green `◍`          | done, and about to be replaced by a fresh session               |
| grey `○`           | dead — nobody is there                                          |

Bold is only ever "this row wants you", so it stays worth noticing: idle and dead share the quiet
weight, and only a question earns the loud one.

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
  ah-13o  P1 Resizable split between the unit and orders panes

Planned, unclaimed 0
  (none)

Unplanned 4
  ah-3cs  P1 Config option for fixed unit-in-hex pane size
  ah-4ao  P2 Drive the implementer fleet from the Emacs agent…
  +2 more

Merged, unverified 0
  (none)
```

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
↻ ah-t65  P0 came back from a failed verdict
  ah-t70  P0 never left
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
area says `ah-3cs: P1 -> P0` and the row re-sorts under the mark. `u` exists because that is also
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

It refreshes every `cerebro-beads-refresh-seconds` (30) and on `g`, rather than on the agent list's
five-second tick: a refresh is three `bd` subprocesses, and beads move on human timescales. If `bd`
cannot answer — absent, unconfigured, mid-write — the panel goes quiet rather than taking the fleet
view down with it.

There is deliberately no owner column. `bd`'s `owner` is whoever *filed* the bead and is set on
every one of them; who is *working* on a bead is what the agent list directly above already says.

## Supervising the implementers

Implementers are interactive sessions that take one bead each, so they cannot end themselves. The
same five-second poll that refreshes the list acts on what each one reports in
`.claude/implementers/<name>.state.json`:

- **`done`** — the bead is merged, closed and cleaned up. The session is ended and a fresh one
  started for the next bead, which is how a session's context stays one bead deep.
- **`done` with `.claude/implementers/<name>.stop` present** — ended, and no replacement. That is
  what "stop an implementer" means: it finishes what it is on, and then does not come back.
- **`asking`** — blocked on a question only the navigator can answer. Answer it in the detail
  window. After `cerebro-answer-timeout` (900s) with no answer, the session is told to hand the
  bead to the `human` queue and finish, once, so a fleet left alone does not sit blocked.

Only implementers Emacs itself started are supervised: one running in somebody's own terminal is
theirs to end, and a dead one stays dead rather than fighting your own `k`.

Run the tests with:

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit
```
