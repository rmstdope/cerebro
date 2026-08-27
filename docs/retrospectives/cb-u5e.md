# cb-u5e — retrospective

- **Implementer:** Rogue
- **Date:** 2026-08-24
- **PR:** #135

## A rule that could match nothing reported itself clean

**What happened.** With the rule table in place and the old check bodies removed,
`tests/lint.sh`'s planted bare `work-beads` call stopped firing. The tree lint printed
`ok - rule work-beads-status: clean` — a pass, not an error — while the same grep run by hand on
the same file found the planted line. The cause was one layer below the row: that row's
line-exempt pattern is `--status|--print-excluded-types`, and `grep -vE "$line_x"` reads a pattern
beginning with `--` as an option, fails, and — under the `|| true` every one of these greps
carries so a no-match is not an error — hands back an empty string. An empty hit list is
indistinguishable from a clean rule.

**Why.** Established. Every pattern in `tree_rule` now goes through `-e`, and the code says why.

**Cost.** About fifteen minutes: one wrong hypothesis (the path filter), one isolation script, one
fix. No CI cycle — the suite caught it before the push, which is the loop working.

**Prevent by.** The plan's *Known traps* did warn about this row's `--`-leading argument, but
about the wrong consumer of it: it said "leave `rule` positional, or a future `getopts` will eat
it". The hazard was `grep`, two functions further down, and it would have been equally live for a
row whose *pattern* began with `-`. A trap about a leading `--` should name every command the
value reaches, not the first one. The deeper shape is worth stating in `scripts/lint` itself and
now is: **a rule whose grep fails reports `ok`**, because `|| true` cannot tell "matched nothing"
from "did not run". The file already guards the empty-file-list case with an advisory; there is no
equivalent guard for a grep that never ran, and adding one — distinguishing grep's exit 1 (no
match) from its exit 2 (error) — is the change that would make this class impossible rather than
merely unlikely. That is outside a planned bead, so it is recorded here rather than done.

**Seen before.** None found. `docs/retrospectives/cb-e33.md` is the nearest neighbour — a
predicate whose exit status was read as an answer when it was an error — but it is about
`scripts/ci-needed` and CI, not about a grep swallowing its own pattern.
