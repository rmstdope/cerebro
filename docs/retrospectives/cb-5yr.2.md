# cb-5yr.2 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-24
- **PR:** #129

## The plan's shape for a context key could not be written as given

**What happened.** The plan said `cerebro--trigger-context` sets the `gh` key to
`(cerebro--gh-moved issues prs me ended-at)`. `ended-at` is not in that function: it is per role and
is added afterwards by `cerebro--agent-context`. The key had to carry a resolver — a function of
`ended-at` that `cerebro--agent-context` calls per standby row — instead of an answer.
**Why.** The plan named the inputs of the expression but not where each of them comes from, and two
of the four (`issues`, `prs`) are the fleet's while one (`ended-at`) is the role's. The split had
been made in cb-5yr.1, so the fact was available to read.
**Cost.** About fifteen minutes: one test written against the wrong signature and rewritten, and one
extra function.
**Prevent by.** In `skills/plan-bead`, a plan that spells out an expression for a value should name
the function each input is read from, not only the value's shape — here that would have shown
`ended-at` arriving one layer down and named the resolver in the plan rather than in the build.
**Seen before.** None found.

## Two opaque elisp diagnostics, both from a character inside a name or a docstring

**What happened.** An unescaped `"` in a docstring I inserted (`"what moved"`) ended the string
early, and the file then failed to load with `void-variable what` — three unrelated tests failing on
a symbol that appears nowhere in them. Separately, an apostrophe in an `ert-deftest` name
(`…-against-the-role's-own-pass`) split the symbol and the whole test file failed to macro-expand
with `Eager macro-expansion failure: (wrong-number-of-arguments ert-deftest 2)`, which names neither
the test nor the character.
**Why.** Established for both: the reader ends a string at the first unescaped `"`, and `'` ends a
symbol. Editing `emacs/*.el` through a patch script makes both easy to introduce, because the
inserted text is not read by Emacs until the suite runs.
**Cost.** About ten minutes across the two, most of it reading backtraces that named the wrong thing.
**Prevent by.** After any scripted edit to `emacs/cerebro.el` or `emacs/cerebro-test.el`, run
`emacs --batch -L emacs -l cerebro-test --eval '(ert-run-tests-batch-and-exit "<nothing>")'` — or the
gate's byte-compile step — before reading any test result: a load failure and a test failure look
alike in the summary and are not diagnosed alike. The two characters to check in inserted text are
`"` inside a docstring and `'` inside a `defun`/`ert-deftest` name.
**Seen before.** None found.
