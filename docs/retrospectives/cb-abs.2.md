# cb-abs.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-09
- **PR:** #365

## A renderer test broke because a header string changed, in a case about neither

**What happened.** `ui::tests::unverified_state_dims_only_the_question_mark` failed with
`assertion failed: !style_of(&buffer, "l").add_modifier.contains(Modifier::DIM)` after this bead
changed `App::new()`'s header from `Cerebro — read-only` to `Cerebro — starting`. The case is about
a fleet row: an unverified pid dims the `?` beside the phase word and nothing else. But
`style_of(buffer, needle)` scans the WHOLE screen top-to-bottom for the first cell whose symbol is
`needle`, and the first `l` on screen had been the one in the header's `read-only` — undimmed, so
the assertion passed for a reason unrelated to its subject. With no `l` left in the header the scan
walked on to a dim hint clause and the case went red.

**Why.** A one-character needle over a whole screen is not a locator. `style_where` beside it takes
the same needle but anchors to the line containing it, which is what this case wanted;
`style_of` predates it and three calls still pass single characters (`ui.rs:2563`, `2650`, `2678` —
`?`, `!`, `?`). Those three are punctuation rather than letters, so they are less likely to collide,
but the mechanism is identical and none of them says which row it means.

**Cost.** About ten minutes: the failure names a modifier and a letter and nothing about the header,
so the first guess was that the dimming rule had changed.

**Prevent by.** Nothing mechanical — this is the first sighting, and `CLAUDE.md`'s *Development
practices* earns a check on the second. What a future bead can do cheaply: when a change to
`supervision_title`, the hint clauses or any other header text reddens a `ui.rs` case that is about
a fleet row, look at the needle before the rule. If a whole-screen `style_of` with a one- or
two-character needle is ever seen re-anchoring a second time, that is the second sighting, and the
fix is to give `style_of` the same line anchoring `style_where` already has.

**Seen before.** None found — `grep -rl "style_of" docs/retrospectives/` is empty.
