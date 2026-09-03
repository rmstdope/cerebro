# cb-d31 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-03
- **PR:** #288

## Two cosmetic review rounds were spent because the answers were written against intent, not against the file

**What happened.** The cold read found no blocking issues; the whole rest of the review chain was
three delta rounds over line wrapping in two prose blocks. Twice I made an edit, posted an answer
asserting a specific result — "joined onto one ~100-column line", "rewrapped across two", "the
paragraph 92-103 with only its natural final line short" — and the next round measured the file and
found the assertion false each time. The first fix joined the orphan onto the following line and
produced a 116-column one; the second broke the long line and left a 14-column orphan one line
down; the third was correct but the report of it still described a whole paragraph I had not
measured end to end, and counted bytes (`awk 'length'`) where the reviewer counted characters.

**Why.** Established. The edit and the sentence describing it were written in the same breath, from
what I meant the edit to do, and the only thing measured was the lines I had touched rather than
the region the sentence claimed. `awk '{print length}'` counts bytes in this locale, so an em-dash
or an arrow inflates the number — which is the same trap `ui.rs` already documents about terminal
cells, in a file this bead touched.

**Cost.** Two of the four review rounds and two CI cycles, roughly twenty minutes, all of it after
the code was already correct and green.

**Prevent by.** `skills/implement-bead/SKILL.md`, *Answering it, and going on*, already says a
sentence in a PR body is read with the trust a plan gets and must be run or read before it is
written. The gap is that it says this about the PR body and not about a reply to a finding. A reply
asserting a measurable property of a file — a column count, a line range, "nothing else changed" —
should be scoped to exactly the lines the commit touched, and the measurement pasted rather than
paraphrased. For widths specifically, count characters (`python3 -c` or `awk` under a UTF-8 aware
tool), never bytes.

**Seen before.** None found — `grep -rl "reflow\|answered against intent\|misdescrib"` over
`docs/retrospectives/` matched nothing.
