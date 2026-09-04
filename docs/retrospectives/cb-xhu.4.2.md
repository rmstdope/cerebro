# cb-xhu.4.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #333

## The pull request's CI never fired, and the failure looks exactly like a slow queue

**What happened.** The branch was pushed and the PR opened normally. Twenty minutes later
`gh pr checks 333` still said `no checks reported on the 'cb-xhu.4.2-health-in-tui' branch`,
`gh run list --branch cb-xhu.4.2-health-in-tui` was empty, and
`gh api repos/rmstdope/cerebro/actions/runs?branch=…` answered `total_count: 0` — not a queued run,
not a skipped one, *no run at all*. `.github/workflows/ci.yml` was untouched by the diff, it carries
`on: pull_request`, `gh workflow list` showed CI `active`, and CI had run four times that afternoon
on the previous bead. `scripts/ci-needed` answered `run=true`. A second push (the commit answering
the review) fired nothing either.

`gh workflow run CI --ref <branch>` queued instantly and went green in 1m26s on the exact head, so
Actions itself was healthy: GitHub simply dropped the `pull_request` event for this PR. Closing and
reopening the PR — the usual way to re-fire it — produced no run either.

**Why.** Not established, and it is not diagnosable from here. The evidence says the event was lost
on GitHub's side: the same workflow, the same repository and the same runner answered a
`workflow_dispatch` for the same sha a minute later.

**Cost.** About twenty-five minutes of polling, plus the diagnosis and a close/reopen cycle. No
rework — the code was never in question.

**Prevent by.** `implement-bead`'s *Waiting, without ending your run* tells an implementer to poll a
CI condition, and every failure mode it names is a run that exists. **A run that does not exist
polls identically to one that is slow**, so the wait has no natural end. The section should say: if
`gh run list --branch <branch>` is *empty* — as against pending — for more than about five minutes
after a push, the event was dropped rather than delayed; confirm with
`gh api "repos/<owner>/<repo>/actions/runs?branch=<branch>" --jq .total_count`, and reach for
`gh workflow run CI --ref <branch>` to prove the code green while the missing PR check goes to the
navigator, which is where a missing required check belongs anyway.

**Seen before.** None found — `grep -rl "no checks reported\|workflow_dispatch" docs/retrospectives/`
is empty. This is the first time in this repository.

## A plan decided a header hint clause that does not fit at a hundred columns — again

**What happened.** The plan's *Decided by me* fixed the new clause as
`HintClause { text: "h health", rank: HintRank::Cursor }`, offered **unconditionally**. Built as
written, `the_ordinary_screen_keeps_every_hint_at_a_hundred_columns` and
`a_pinned_bead_keeps_the_header_line` went red: the ordinary read-only header is **99 of 100 cells**
after cb-5kk, so the eleven cells of `" | h health"` push it over and `fit_hints` drops a whole rank
at a time — taking the pane and scroll hints with it. Unlike cb-5kk there was no shorter spelling to
find: at one cell of slack, *no* unconditional clause of any length fits. The fix was a new rank
below `Movement` (`HintRank::Optional`), dropped first and alone, which costs no existing hint
anything.

**Why.** Established, and it is cb-5kk's own diagnosis unchanged: `hint_clauses` is a list of rows
with ranks and no widths, so nothing in front of the author shows that a clause is too long. What is
new is that cb-5kk's own fix — folding two clauses into `Tab/Shift-Tab/F1-F3 pane` — left the line
at 99 rather than 93, so the budget that was 7 cells is now **1**. The line is effectively full, and
the next plan that fixes a clause literal will hit this again.

**Cost.** About fifteen minutes: two red `cargo test` runs, reading `fit_hints`, measuring the drawn
header by hand, and updating three existing cases plus the tier step in
`a_new_clause_is_one_row_and_breaks_no_other_test`.

**Seen before.** `docs/retrospectives/cb-5kk.md` — the same class, the same line, the same file, one
day earlier and by this same session's name; and `docs/retrospectives/cb-41r.md` before it. **Third
sighting.** cb-5kk's *Prevent by* asked `plan-bead` to state a clause's cell width against the
budget, or leave the spelling to the implementer; that has not been done, and the budget has since
shrunk to one cell. This one is worth more than a note: the hint line has no room left, so either
`plan-bead` stops naming clause literals at all, or `fit_hints` grows the `Optional` tier this bead
added as the documented home for anything unconditional — that tier is now in the code and is the
cheap answer for the next one.
