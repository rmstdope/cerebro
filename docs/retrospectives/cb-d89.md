# cb-d89 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-28
- **PR:** #198

## Thirteen green assertions against a fixture tidier than reality, and the script matched nothing

**What happened.** `tests/fleet-cost.sh` was written first and passed in full — every attribution
rule, both horizons, the unpriced column, all three refusals. The first run against this machine's
real store then answered `No cerebro sessions in the last 30d.` for a fleet that had spent ten
thousand credits that week. Not an error, not an empty table: the sentence the script prints when
nothing ran, which is the most convincing possible way to be wrong.

**Why.** Established. The join cuts the agent and the root out of cerebro's marker sentence, and the
root capture was anchored at the end of the message:

    capture("of the cerebro fleet rooted at (?<r>.*)\\.$")

The marker is turn 0's `user_message`, and it is the **first sentence of a whole seed prompt** — the
launcher's own second sentence follows it, then a blank line, then the role's instructions. So `.*$`
swallowed all of it and the capture matched no root at all, and every session was filtered out as
belonging to somebody else's tree. The fixture never showed it because the fixture wrote the marker
sentence and stopped there: a tidied version of a field that is never tidy in life.

**Cost.** Small only because it was caught immediately — the plan's *definition of done* required
running the script against this checkout, so the first real invocation was one command after the
suite went green. Perhaps fifteen minutes. Had that line not been in the plan, the script would have
reached review with a full suite behind it and reported a silent zero for every consumer whose
prompt has more than one sentence in it — which is all of them.

**Prevent by.** When a fixture fabricates a record that some *other* part of this system writes, copy
a real one rather than composing a plausible one. Concretely, for anything cut out of the marker
sentence: `scripts/launch` composes it, and the shape that matters is that it is a **prefix** of a
larger field, not the whole of it. `tests/lib/session-args.cases` already exists for exactly this
reason on the argv side, where `cerebro--session-args-p` and `scripts/agent-alive` are held to one
table of real spellings; the store side had no such table and this suite invented its own strings.
A third reader of that sentence now exists, so the next change to it should ask whether the case
table should cover the store's copy too.

This is the same shape as cb-os4 in a third place: **a display spelling is normalised by the reader
that produces it, never assumed by the comparator.** The trailing slash on the root was handled
exactly that way and was tested; the surrounding prompt was not thought of as part of the spelling
at all.

**Seen before.** cb-os4 — four green cases against invented inputs, all of them wrong about the
real one, which is why `emacs/cerebro-test.el` grew its "Reader contracts" section. The lesson
transferred to elisp and not to the bash suites.
