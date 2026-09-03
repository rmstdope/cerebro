# cb-41r — retrospective

- **Implementer:** Rogue
- **Date:** 2026-09-03
- **PR:** #294

## Adding a header clause overflowed the hint line and failed two unrelated tests

**What happened.** The plan's increment 8 asked for one clause appended to `header_line`
(`fleet-view/src/ui.rs`): `" | Enter bead"` beside the priority keys. Adding it turned two existing
`TestBackend` cases red — `stale_work_keeps_all_last_good_sections_and_exact_error` at 99 columns
and, after a first attempt at a fix, `a_long_ownership_title_shortens_the_hints_rather_than_losing_them`
at 60 — because the hint line's two-step shortening had no room left: at 99 columns the shortened
form now ran past the terminal and `q/Esc/Ctrl-C quit` was cut in half. Neither test names the
header clause it broke on, so the failure reads as a change to stale-pane rendering.

**Why.** Established. `header_line` shortens once (movement hints give way, lifecycle keys stay)
and then truncates. Each of cb-d31, cb-kcs.5.4 and this bead added a cursor clause to the same
line; the margin at 99–100 columns was already spent, and this was the clause that crossed it. The
fix was a third step that drops the cursor clauses and keeps refresh and quit — which is what the
existing shortening comment already says the rule is.

**Cost.** About twenty minutes: two red gate runs, one wrong fix (dropping the lifecycle keys with
the cursor clauses), and a question to the navigator, because the narrow-terminal behaviour is
user-visible and `docs/ui/cb-41r-bead-detail.html` does not cover it.

**Prevent by.** A plan that adds a clause to `ui::header_line` should say what gives way when it no
longer fits, in its *User-facing decisions* section — the header is a fixed-width line that three
beads in a row have now added to, so "one more clause" is a width decision rather than an
append. Anyone adding a fourth should read `the_cursor_clauses_are_the_last_thing_to_give_way`
first: it now names the three steps at 200 and 100 columns.

**Seen before.** None found — `grep -rl "shorten\|header_line" docs/retrospectives/` matches only
cb-azi, which is about something else.
