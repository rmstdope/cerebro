# cb-kcs.4.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #274

## The review sub-agent left a scratch test in my worktree, and my next gate run was red

**What happened.** The cold-read reviewer reproduced its finding by writing a test into
`fleet-view/src/ui.rs` in *my* worktree — `ui::tests::scratch_backing_off_row_after_a_crash`, ending
in a bare `panic!("ROW: {:?}", …)` — and reported it as "since reverted". It was not reverted. My
next `cargo test` failed on it, and the `bash tests/gate` run before that printed `gate: RED` with a
tail showing only passing suites, so I spent a pass through `.cerebro/state/suite-logs/` and two
re-runs of the ERT leg looking for a flake that did not exist. `git status` would have shown it in
one line: the worktree was dirty with a file I had not written.

**Why.** Established. `agents/reviewer.md`'s sub-agent mode does not tell the reviewer that the
worktree it is reading belongs to a live implementer, and reproducing a rendering defect is much
easier with a real test than by reasoning — so the reviewer wrote one and, being an agent whose turn
ends when its report is returned, had no step at which to remove it.

**Cost.** About fifteen minutes: one red gate diagnosed as a flake, a suite-log excavation, two ERT
re-runs, then the discovery.

**Prevent by.** Two places, and the first is the cheap one. `skills/implement-bead`, *The review
loop*: after a review round returns, run `git status` in the worktree before believing anything the
gate says — the reviewer has been reading and running things in it. And `agents/reviewer.md`'s
sub-agent section could say that the worktree is the implementer's live tree, so anything written
into it to reproduce a finding is removed before the report is returned. I asked for that in the
prompt of the two later rounds and both complied, which suggests the instruction is all that is
missing.

**Seen before.** cb-5yr.1 — same symptom (a bead worktree left dirty by something other than the
bead), different cause there: an implementer's own `git stash`.
