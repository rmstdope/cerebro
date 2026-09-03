# cb-5kk — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #311

## A plan decided a header hint clause that does not fit at a hundred columns

**What happened.** The plan's *Decided by me* named the exact new hint clause —
`HintClause { text: "F1/F2/F3 pane", rank: HintRank::Movement }`, drawn after `Tab/Shift-Tab pane`
— and decided in the same breath to leave `Tab/Shift-Tab pane` unchanged, to spare thirteen tests
that use it as a locator. Built exactly as written, `cargo test --workspace --all-targets --locked`
went red on `the_ordinary_screen_keeps_every_hint_at_a_hundred_columns` and
`a_pinned_bead_keeps_the_header_line`: the default read-only header is 93 cells, the new clause
costs 16, and `fit_hints` gives way a whole rank at a time, so the movement rank vanished and the
screen lost both its pane hint and its scroll hint. Only 7 cells were spare, so no separate clause
of any spelling fits. The two were folded into one, `Tab/Shift-Tab/F1-F3 pane` — 24 cells against
the old 18, leaving the line at 99 and twelve narrower than the planned pair — and the thirteen
anchors were updated, which is the cost the plan had explicitly declined to pay.

**Why.** Established. The hint line's budget is not visible from the code being edited:
`hint_clauses` is a list of rows with ranks and no widths, and the width consequence lives in
`fit_hints` and in a test whose doc comment records a navigator request by name. A plan can
therefore fix the exact text of a clause without anything in front of it showing that the text is
too long, and the arithmetic is a subtraction nobody does.

**Cost.** About ten minutes: one red `cargo test`, reading `fit_hints` and the two failing cases,
and one review round spent answering a finding about the substitution.

**Prevent by.** `plan-bead`'s *Decided by me* should not fix the literal text of a `cerebro-tui`
header clause without stating its cell width against the 100-column budget the
`the_ordinary_screen_keeps_every_hint_at_a_hundred_columns` case guards — or should leave the
spelling to the implementer, who has the failing test in front of them. The check is one
subtraction: the drawn header at 100 columns for the screen concerned, plus `" | "` and the new
clause.

**Seen before.** `docs/retrospectives/cb-41r.md` — the same class, in the same line: adding a
header clause overflowed the hint line and failed two tests with nothing to do with the change.
That one paid for the ranked-clause mechanism (cb-51u); this one is the mechanism working as
designed and the *plan* being the thing that did not know the budget.
