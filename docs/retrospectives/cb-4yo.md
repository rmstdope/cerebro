# cb-4yo — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #109

## The plan's verbatim test contradicted the plan's verbatim shipped string

**What happened.** The plan specified two things word for word: the new suite
`tests/bead-board-untracked.sh`, whose third assertion was `grep -q 'issues\.jsonl' CLAUDE.md`, and
the exact sentence to append to CLAUDE.md's *Work tracking* paragraph, which says `.beads/*.jsonl`
and never contains the string `issues.jsonl`. Building both exactly as written left the suite red at
GREEN: `FAIL: CLAUDE.md does not state the issues.jsonl decision`. Nothing about the repository was
wrong — the plan's own two quoted blocks did not agree with each other.

**Why.** Established, by reading the two blocks side by side. The bead's *description* frames the
question as being about `.beads/issues.jsonl` (the file the other project tracks), and the assertion
was written in that vocabulary; the *decision* the plan reached generalised to the glob
`.beads/*.jsonl`, and the shipped sentence and the `.gitignore` line both moved to the glob while
the assertion did not.

**Cost.** Small — one extra local suite run and a judgement call, perhaps five minutes, no CI cycle.
The real cost is that it forced an implementer's deviation on a bead whose whole point was that the
wording is the deliverable: I had to decide which of two verbatim quotes was authoritative, and
justify it in the PR body, on a bead explicitly planned so that no such decision was mine.

**Prevent by.** When `plan-bead` specifies both an assertion and the literal string it asserts on,
it should run the assertion against the string before writing the plan — here, checking that the
proposed `grep` pattern actually occurs in the proposed sentence. A cheaper structural rule for the
same class: an assertion about shipped prose should grep for the *identifier the decision is about*
(here `.beads/*.jsonl`, which appears in the sentence, the `.gitignore` and the suite alike), not for
a name that only appears in the bead's framing.

**Seen before.** `ah-kjfm` — adjacent rather than identical: there the plan's verbatim text
contradicted a test already in the repository, here it contradicted the plan's own other quote. Both
are "the plan's word-for-word spec was not buildable as written", and both were caught only by
running the suite.
