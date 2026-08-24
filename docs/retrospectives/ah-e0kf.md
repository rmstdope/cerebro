# ah-e0kf — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #104

## The plan again told me to write bead ids into agent prose, which a test here forbids

**What happened.** The plan's *Files to change* said the new `agents/orchestrator.md` section should
carry "the evidence (the three beads of 2026-08-23, **by id**, with their shas and distances)". I
wrote it exactly as specified, including a three-row table of ids. `bash tests/prose-decoupling.sh`
then failed with thirteen hits across four files — `orchestrator.md`, `verifier.md` and both skills,
since I had also cited beads in the prose I added to each of those.
**Why.** Established, and identical to the two earlier sightings: no file an agent session reads may
contain a bead id, because a consumer cannot resolve one, and `docs/decisions.md` exists to hold the
provenance instead. The plan was again written against the *shape* of the neighbouring sections
rather than the constraint that emptied them.
**Cost.** One gate cycle and a rewrite of four files, about twenty minutes. Caught locally, as
before, only because the bash suite is quick enough to run in full.
**Prevent by.** This is the **third** identical finding, and the previous two both proposed the same
prevention — `plan-bead` stating the split when it plans a section of `agents/**`. That has not
happened, so the recommendation is now the narrower, mechanical one: `plan-bead`'s own checklist
should refuse to ship a plan whose *Files to change* quotes a bead id inside a block destined for
`agents/**` or `skills/**`, the way it already refuses a plan missing a section. A prevention
proposed three times and not adopted is evidence the prose was the wrong place for it.
**Seen before.** `ah-kjfm` (*The plan told me to write something a test in this repository forbids*)
and `ah-tjaz` (*The plan asked for prose that this repository's own test suite forbids*).

## The plan routed work to the verifier's list without checking what builds it

**What happened.** The plan said to add a `verdict:stale` arm to `agents/verifier.md`'s work-list
query, "and say that a stale bead is taken first in the pass". I added the arm. The Copilot review
pointed out it can never match: `scripts/work-beads` defaults to `--status closed`, every other arm
of that query describes a closed bead, and a `verdict:stale` bead is deliberately **open** — the
plan's own *Known traps* says so, two paragraphs from the instruction that made it dead code. I
checked and it holds. The fix was a separate `work-beads --status open` query in its own subsection.
**Why.** The plan knew the bead was open and knew the query had to reach it, and never checked that
the query *could*. It is the same gap as the previous sighting, in the same query, one bead later.
**Cost.** One review round and one CI cycle, about fifteen minutes. It would have cost far more
unreviewed: the whole mechanism would have flagged beads that reached nobody, which the plan itself
calls "strictly worse than today".
**Prevent by.** `plan-bead`'s *Validation* should be required to name the exact command a role runs
and assert the bead appears in its output — the prevention the previous sighting already proposed.
Given it has now recurred, the sharper version: any plan that adds an arm to a `work-beads` query
must state that query's `--status`, because the default is `closed` and every mistake here has been
the same one.
**Seen before.** `ah-tjaz` (*The plan's chosen routing had no mechanism behind it*) — same script,
same default, same consequence.

## A byte-compiled `.elc` silently shadowed my source edits, and the suite went green on stale code

**What happened.** I ran `emacs --batch -L emacs -f batch-byte-compile emacs/cerebro.el` to check for
warnings, which wrote `emacs/cerebro.elc`. Every later
`emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit` loaded that `.elc` in
preference to the `.el`, so it tested the code as it stood at compile time. I wired the fifth sweep
in — changing `cerebro--findings-from`'s arity, which three existing tests call directly — and the
suite reported **297 of 297 passing**. Deleting the `.elc` and re-running gave three failures, which
were the true state and which I then fixed.
**Why.** Established. Emacs prefers a `.elc` to a `.el` of the same name on `load`, and nothing warns
that the `.elc` is older than its source. The repository does not track `.elc` files, so nothing
cleans one up either.
**Cost.** Small here — perhaps ten minutes, and only because the arity change was drastic enough that
"nothing broke" was implausible. The danger is the size of the failure it can hide rather than the
time it took: a subtler edit would have shipped green.
**Prevent by.** `CLAUDE.md`'s *Commands* section gives the two test commands; the ERT one should be
`rm -f emacs/*.elc && emacs --batch …`, or the byte-compile command should end by removing what it
produced. CI is unaffected — it compiles and tests in separate steps on a fresh checkout — which is
exactly why this can only ever bite locally and will not be caught by a red job.
**Seen before.** None found.
