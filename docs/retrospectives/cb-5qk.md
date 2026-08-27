# cb-5qk — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-25
- **PR:** #143

## The plan's own validation command asserted a count that a correct edit does not produce

**What happened.** The plan's *Validation* section named
`grep -c 'headRefOid' skills/implement-bead/SKILL.md   # expect 3: the block, the paragraph, the trap`.
After making the four edits exactly as the plan specified them — verbatim, including the fenced
block and the appended "Observed here" sentence — the count was 5. `grep -c` counts matching
*lines*, and the new fenced block spells `headRefOid` on two separate lines (the `--json` flag and
the `-q` template), while the appended sentence the plan dictated names it as well. Four named
places, five matching lines, and an assertion that reads as failed.

**Why.** The expected number was derived from the four places the plan describes in prose, not from
the text the plan itself dictates. Nothing in the plan was wrong about *what to write*; only the
number beside the check was.

**Cost.** About a minute, and no wasted cycle — I counted the occurrences by hand and carried on.
The cost is not the point here; the direction of the risk is. An implementer that trusts a
plan's validation assertion over its own diff would "fix" prose that was already exactly what the
plan asked for, in a file this repository explicitly says must not be held to a grep
(`CLAUDE.md`, *Development practices*: "a suite that greps prose fails on the day somebody changes
their mind").

**Prevent by.** A plan validating a prose change should assert what is *present*, not how many
times — `grep -n 'headRefOid' <file>` and "expect it in the poll, the paragraph following it, the
Observed-here note and the trap bullet" is checkable by reading and cannot be off by a line. Where
a count really is wanted, `grep -o … | wc -l` counts occurrences rather than lines. This belongs in
`skills/plan-bead`'s guidance for the *Validation* section of a prose-only bead.

**Seen before.** None found — `grep -rl "grep -c" docs/retrospectives/` matched nothing across the
twenty files present.
