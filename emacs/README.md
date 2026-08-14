# cerebro.el

An Emacs 28+ package that lists the cerebro agent fleet: `M-x cerebro` (after adding
this directory to `load-path` and `(require 'cerebro)`) opens a self-refreshing buffer
showing every agent — Xavier, Cerebro, Moira, Psylocke and the fourteen implementers — with its
state, and for a working implementer the bead it is on and for how long.

It supports a live detail window that follows the list selection, and starting/killing agents
from the list:

| Key   | Does                                                                       |
|-------|----------------------------------------------------------------------------|
| `s`   | starts a dead agent, into an Emacs-owned `vterm` buffer running its launcher |
| `k`   | kills a live one, confirming harder mid-bead                                |
| `RET` | selects the detail window, to type to the agent shown there                 |
| `TAB` | switches window, exactly as `C-x o` does — press it again to come back      |
| `n`/`p` | next/previous row                                                        |

An agent running outside Emacs is shown and marked but not viewable — a placeholder says so. This
needs **vterm** (`emacs-libvterm`); without it the list still works, and `s`/`RET` signal a clear
error instead of failing obscurely.

## Reading a row

The glyph carries the state and the weight carries the urgency:

| Row                | Means                                                          |
|--------------------|----------------------------------------------------------------|
| green `●`          | working, or an interactive agent that is up                     |
| yellow `◌`         | idle — a session is up with no bead, which may want a nudge     |
| yellow `?`, **bold** | asking: it needs an answer from you, and the whole row says so |
| green `◍`          | done, and about to be replaced by a fresh session               |
| grey `○`           | dead — nobody is there                                          |

Bold is only ever "this row wants you", so it stays worth noticing: idle and dead share the quiet
weight, and only a question earns the loud one.

## The bead panel

Under the agent list, in a window of its own, `*cerebro-beads*` answers the three questions the
navigator asks about the queue, in the order they are asked:

```
Claimed 1
  ah-13o  P1 Resizable split between the unit and orders panes
Planned, unclaimed 0
  (none)
Unplanned 5
  ah-3cs  P1 Config option for fixed unit-in-hex pane size
  ah-7s7  P1 Psylocke, the verification session: prove merged…
  +3 more
```

Sorted by priority then id, so P0 reads first and the order does not shuffle under a redraw. Each
section names its own count, because the rows are what gets capped — `cerebro-beads-per-section`,
eight by default, keeps an unbounded backlog from pushing the first two sections off the bottom.

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
