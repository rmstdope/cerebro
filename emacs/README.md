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

Run the tests with:

```bash
emacs --batch -L tools/emacs -l cerebro-test -f ert-run-tests-batch-and-exit
```
