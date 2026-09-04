# cb-lor — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #313

## `cat >>` into a fixed `/tmp` path injected another project's test code into `app.rs`

**What happened.** I staged the new test block with `cat >> /tmp/t1.rs <<'EOF' ... EOF` and then
spliced that file into `fleet-view/src/app.rs`. `/tmp/t1.rs` already existed — left by some earlier
session on this machine, and holding Rust tests from an entirely different project (an Atlantis
report parser: `ReportUnit`, `hex_after_gifts`, `codes::PRODUCE_WITHOUT_SKILL`). The append put my
tests *after* seventy lines of that, and all of it landed inside `mod tests`. The build then failed
with two dozen `cannot find type ReportUnit in this scope` errors pointing at line numbers in a file
I had just edited, which reads exactly like a mistake in my own splice.

**Why.** `>>` on a path that is not mine. Nothing about `/tmp/t1.rs` is unique to this session, and
`cat >>` neither truncates nor warns.

**Cost.** About five minutes, and a stretch of reading compiler errors about symbols that exist
nowhere in this repository — the confusing part, not the deletion.

**Prevent by.** Scratch files go under the bead's own worktree, or carry the bead id in the name
(`/tmp/cb-lor-tests.rs`), and are written with `>` rather than `>>`. `implement-bead` already names
`/tmp/review-<id>.md` for the review text, which is the right shape; the same shape is worth using
for every scratch file a pass writes.

**Seen before.** None found.

## The plan's own test case would have arrived at the pane it was proving you do not arrive at

**What happened.** The plan's `f2_and_f3_and_a_tab_that_misses_fleet_keep_the_pinned_bead` ended
with "from Work press `BackTab`: focus is Session". `PaneFocus::previous(Work)` is `Fleet`, so that
leg arrives at Fleet and drops the bead — the opposite of what the case exists to guard. Caught
before writing it, by reading `PaneFocus::previous` rather than the plan's sentence; used `Tab` from
Work instead and recorded the deviation.

**Why.** A plan can be confidently wrong about a small symbol it did not open.

**Cost.** Two minutes, because the doubt arrived while writing the assertion.

**Prevent by.** `implement-bead`'s *When the plan is wrong* already says a helper the plan cites for
what it decides is read before it is built on. This is that rule applying to a two-line `match` and
paying for itself; nothing to add.

**Seen before.** None found.
