# cb-hzl — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-03
- **PR:** #307

## A jq snippet the plan supplied could not run at all

**What happened.** The plan's *Files to change* gave the filter that drops parented epics from
`scripts/work-beads` verbatim: `[.[] | select(($p | index(.id)) == null)]`. It fails with
`jq: error: Cannot index array with string "id"` on every input — inside `$p | index(.id)` the `.`
has already been re-bound to `$p`, so `.id` asks an array for a field. It has to capture first:
`select(.id as $i | ($p | index($i)) == null)`. The suite went red at the case that was supposed to
be GREEN, which reads as a defect in the code just written rather than in the line copied.
**Why.** Established. The plan's own *Decided by me* records the filter as a decision, but nothing
in the plan claims it was run; the surrounding facts (`bd list --json` has no `parent` field, `bd
children` answers direct children) each say "verified" and were.
**Cost.** About ten minutes: one wrong-suspect pass over the loop above it, then reproducing the jq
in isolation.
**Prevent by.** `skills/implement-bead`, *When the plan is wrong*, already says a **helper the plan
cites** is read before it is built on. A code snippet the plan supplies is the same class of claim
and is not covered by that paragraph — it says nothing about executable text the plan hands over.
Extending it to "a snippet the plan supplies is run against a two-line fixture before the increment
that depends on it" would have cost thirty seconds here.
**Seen before.** None found — `grep -rl "index(\.\|re-bind" docs/retrospectives/` matched two files,
both about unrelated things.

## A test stub that truncates cannot see a second call

**What happened.** `tests/work-beads.sh`'s `bd` stub wrote one `argv` file per call, truncating it
each time. The plan foresaw this and had the stub dispatch on subcommand — but per-subcommand files
still truncate, and `bd children` is asked **once per epic**, so the assertion that it was asked
about `tt-lone` read only the argv of the last epic and failed. Appending instead, and clearing the
files at the start of each `run`, is what makes "asked per epic" provable at all.
**Why.** Established: the plan's stub design solved "two different subcommands overwrite each
other" and not "one subcommand called twice".
**Cost.** Two iterations, about eight minutes, one of them spent believing the dispatch was broken.
**Prevent by.** When a plan changes a stub so a second call becomes visible, the question to ask of
the new shape is *how many times is each subcommand called*, not *how many subcommands are there*.
Worth a line in a plan's *Known traps* wherever a stub is being extended for a loop.
**Seen before.** `docs/retrospectives/cb-1or.1.md` and `cb-d59.4.md` mention truncation, both of
different things (a truncated `bd show`, a truncated log). Not this.
