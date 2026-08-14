# cerebro.el

An Emacs 28+ package that lists the cerebro agent fleet: `M-x cerebro` (after adding
this directory to `load-path` and `(require 'cerebro)`) opens a self-refreshing buffer
showing every agent — Xavier, Cerebro, Moira and the fifteen implementers — with its state, and for
a working implementer the bead it is on and for how long.

It supports a live detail window that follows the list selection, and starting/killing agents
from the list: `s` starts a dead agent (into an Emacs-owned `vterm` buffer running its launcher),
`k` kills a live one (confirming harder mid-bead), `RET` selects the detail window to type to the
agent shown there. An agent running outside Emacs is shown and marked but not viewable — a
placeholder says so. This needs **vterm** (`emacs-libvterm`); without it the list still works, and
`s`/`RET` signal a clear error instead of failing obscurely.

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
emacs --batch -L tools/emacs -l cerebro-test -f ert-run-tests-batch-and-exit
```
