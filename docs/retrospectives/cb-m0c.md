# cb-m0c — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-09
- **PR:** #359

## The plan's render case asserted a string the pane it named could not draw

**What happened.** The plan asked for `a_ten_implementer_fleet_reads_its_whole_stage_note` "rendered
at 120×24, asserting the line contains the whole string", and said that if it failed "the fix belongs
in `natural_bead` and nowhere else". It failed, and `natural_bead` was not where the fix belonged:

    ◌ Beast build-de… standby → planned 10┃

`natural_bead` sizes correctly from what the row will draw (15 cells here). What cuts the cell is the
clamp below it in `ui::columns` — `bead = natural_bead.min(width - fixed - agent).max(BEAD_FLOOR)` —
against a Fleet pane that is 40 cells in the split layout. Even the realistic `→ planned 2/4`
(13 cells) draws as `→ planned 2/` on any window from `SPLIT_COLUMNS` (100) to 133; it is whole only
in the stacked pane and at 134 and above, where `WIDE_LEFT_COLUMN_SCREEN` gives the left column 52.
So the agreed wording is drawn as a truncated fraction in the ordinary layout — audience-visible, and
not something the plan or the mockup had settled, the mockup drawing its rows at a wide width.

**Why.** The plan reasoned about `natural_bead` alone, which is the function that *wants* cells, and
not about the two clamps that decide what it *gets*: `AGENT_FLOOR` (14) and `STATE_FLOOR` (12) are
taken before BEAD, so a 40-cell pane has 13 left whatever the label is. cb-hjf's rule that the role
column is paid out of AGENT/STATE slack and never out of the work cell is intact — the squeeze here
is the pane width itself, one level above it.

**Cost.** About twenty minutes: the render case, three width probes to find the band, and a question
to the navigator. Not large, but the same reasoning would have shipped a lie had the plan not asked
for a render case at all — a string-level test on `standby_label` passes at every width.

**Prevent by.** A plan that asserts a *rendered* string in `fleet-view` should name the width band it
holds at, not a single width, and should reason from `ui::columns` rather than from `natural_bead`:
the natural width is what a column asks for, and the clamp is what it is given. `BEAD_FLOOR` is 10,
so any standby label over ten cells is a candidate for this, and the pre-existing
`↻ retry in 30s, 2 failed` (24 cells) is the standing proof that long labels are already cut there.

**Seen before.** None found for this cause. `cb-41r` records the neighbouring shape — a plan's own
test case arriving at a pane it was proving you do not arrive at.
