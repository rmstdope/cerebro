# Decisions, and the beads that established them

The prompts under `agents/` and `skills/` state rules and the cost that justifies them, but they
name no bead. A bead id is provenance for **this** repository's history: an agent running in a
consumer's checkout cannot resolve one, and a citation it cannot check is a cost to its credibility
rather than a support for the rule.

So the rules keep their claims and their costs, and this file keeps the provenance. **Nothing loads
it.** It is read by a person asking "where did this rule come from", never carried into a session —
if a prompt ever starts referencing it, the coupling it was written to remove has come back with
worse structure. `scripts/lint` advises on both halves.

Ids here are from the `atlantis-hud` bead database, the consumer cerebro grew up in.

## `agents/orchestrator.md`

| Rule it established | Bead |
|---|---|
| Every interactive agent writes the same state file an implementer does | ah-2n3.2 |
| `bd ready` and the planners' buffer count different things; a blocked bead is not a gap | ah-vp3.1, ah-vp3.2 |
| The retrospective sweep aggregates *Seen before* lines, so a third sighting is visible | ah-x7gr |
| A stop flag is removed automatically once it has taken effect | ah-kgc |
| The fleet view runs the worktree, claims and epics sweeps itself | ah-4ao |
| A bead delivered on main but left `in_progress` by a dead implementer | ah-6xq.8 |
| A `docs(<id>): mockup` commit on main is not delivery | ah-52b, ah-f8u |
| `scripts/launch` is the only way a session starts, and stamps `BEADS_ACTOR` | ah-rnz |
| Two beads found stale under a human-looking assignee, 2026-08-14 | ah-r2e, ah-52b |
| "Gone" is about the session, not the name: a live agent on a different bead | ah-v2l, ah-u4e.2, ah-u4e.3 |
| Epics left open at 2/2 children closed | ah-1is, ah-vp3 |
| The stalled-claims sweep | ah-4xm4 |

## `agents/verifier.md`

| Rule it established | Bead |
|---|---|
| A `pending` label outlives its session, so a pending bead is an ordinary candidate again | ah-60w |
| Never label an event bead — labelling one writes another, forever | ah-9gm |
| Closed epics are excluded from the work list | ah-cg1 |

## `agents/planner.md`, `agents/reviewer.md`, `agents/user-feedback.md`, `agents/architect.md`

| Rule it established | Bead |
|---|---|
| Interactive roles end a pass with `waiting` rather than sleeping inside the session | ah-hiib.3 |
| Every interactive agent writes the same state file an implementer does | ah-2n3.2 |
| Status comments name the issue as well as the bead | ah-2vy (gh-31) |
| `-F` and the parentheses are load-bearing when grepping a bead id | ah-1is, ah-1is.2 |

## `skills/plan-bead/SKILL.md`

| Rule it established | Bead |
|---|---|
| `agent-alive` reads the shared checkout, never the enclosing worktree | ah-e0w |
| `select(.dependency_type=="blocks")` — a child would otherwise demand its parent be planned | ah-vp3, ah-vp3.1, ah-vp3.2 |
| Children of a split inherit the holding label and must have it removed | ah-3ox |
| One planner owns a whole split family, marked `planner:<name>` on the parent | ah-ywj7 |
| A hold names its holder (`planning:<name>`) so a finishing session cannot strip another's | ah-ywj7 |
| Holding labels are read by PREFIX; `bd --exclude-label` is exact, so the filter moved into `jq` | ah-ywj7 |
| Re-check the hold immediately before writing the design — a backstop that saves the plan, not the interview | ah-ywj7 |
| The public surface written out as signatures is the shape a plan copies | ah-jg6.2 |
| Never ask for an effect-level test in a package with no jsdom | ah-nass |

## `skills/implement-bead/SKILL.md`

| Rule it established | Bead |
|---|---|
| Check the merge state before entering a CI wait after a rebase or force-push | ah-k6i.5 |
| An update that leaves an empty diff against main closes unmerged rather than merging a no-op | ah-u3i |
| Retrospectives are one file per bead, named for the bead | ah-t65, ah-t12 |

## `skills/beads-workflow/SKILL.md`

| Rule it established | Bead |
|---|---|
| Reading a lease: an agent actively working, ten minutes in | ah-xde |

## `emacs/README.md`

| Rule it established | Bead |
|---|---|
| The interactive agents appear in the fleet view like an implementer | ah-2n3.2 |
| A dead session's last printed line is kept in its placeholder row | ah-bri |
| The sample panel and echo lines were drawn from real beads | ah-13o, ah-8m0, ah-2p1, ah-3cs, ah-4ao, ah-t65 |

## `docs/agent-workflow.md`

| Rule it established | Bead |
|---|---|
| The fleet view owns the cadence of the interactive roles | ah-hiib.3 |

## ah-kjfm — the assignee sweep, and why a stranded P0 shouts

`agents/orchestrator.md`'s *Open beads carrying an assignee nobody backs up* comes from two P0s
stranded on 2026-08-23, within half an hour of each other:

| Bead | Assignee on file | What that session was actually doing |
|---|---|---|
| `ah-fjty` | `Cyclops` | building `ah-gjq4` |
| `ah-t2pn.3` | `Wolverine` | building `ah-1ad6.1` |

Both had been reopened by a failed verification, which returns a bead to `status=open` — no lease —
while leaving its old assignee in place. `ah-fjty` then sat 32 minutes at the top of `bd ready`
while Cyclops finished a bead and took a P1 below it. Both were found only because a planner read
`bd ready` by hand, and both were cleared by hand with the navigator's approval.

The navigator chose, against `docs/ui/ah-kjfm-sweep.html`: the sweep confirms like the other four
rather than acting on its own, so every destructive path stays in `cerebro--finding-command`; but a
stranded **P0**'s line renders in the `warning` face, because the failure being fixed is that nobody
was looking and a line nobody presses strands the P0 just as silently. `cerebro-stale-assignee-minutes`
is 10 — one sweep cycle, so a bead is seen twice before it is offered; 30 would only just have caught
`ah-fjty` at 32 minutes.

## ah-e0kf — a verification verdict acted on after main has moved past it

`agents/orchestrator.md`'s *Failed verdicts main has moved past* comes from three beads verified on
2026-08-23, each of which had been overtaken by main before its verdict reached anybody:

| Bead | Verdict at | Merges since | What landed after | Cost |
|---|---|---|---|---|
| `ah-t2pn.3` | `ce9d2817` | 4 | `ah-t2pn.4`, carrying exactly the wording the verification had called the sharper half | An implementer claimed it as a P0, found nothing to build, handed it back — two sessions and a planner pass |
| `ah-vocw` | `0b444332` | 2 | `ah-gjq4`, which shipped it outright (`silver.rs:385`, `:632`) | Closed unbuilt |
| `ah-fjty` | `dd3f67bd` | 6 | `ah-e66j` and `ah-eacd` | A planner audit that found the shipped code matched the plan exactly, and named two candidate causes that were both correct behaviour introduced after the bead was planned |

Nothing recorded *which commit* a verdict was formed against in a place a later reader checks: the
sha existed only in the prose of a `--reason` string and an appended note, and nothing compared it to
the default branch's head before the bead reached an implementer or a planner. A stale verdict was
therefore indistinguishable from a live one, and it gets worse as a fleet gets faster.

The navigator chose, against `docs/ui/ah-e0kf-stale-verdict.html`:

- **The line says the commit and the count of merges since**, not a time behind main (a quiet three
  hours and a busy three hours read identically) and not the name of what merged (the longest line in
  the section, and it must truncate and pick one exactly when several merged, which is when the line
  matters most).
- **The key sends the bead back to the verifier** rather than being a pure alert — the failure being
  fixed is that nobody was looking, and a line with no key behind it strands the bead just as quietly
  — and it still confirms like the other five, so every destructive path stays in
  `cerebro--finding-command`.
- **`verdict:stale`, a dimension of its own**, put to the navigator as a correction:
  `verification:` is a bd state dimension and `bd set-state` replaces the whole of it, so a
  `verification=stale` would erase the verdict itself and `--add-label verification:stale` would
  leave two labels in one dimension.
- **`cerebro-stale-verdict-merges` is 1.** Three would be quieter but would have missed `ah-vocw` at
  two merges; erring toward a re-verification is much cheaper than erring toward an implementer
  building a no-op.

Two decisions the planner took and stated so the implementer would not reopen them: the field carries
the **full 40-character sha** (it is read by `git merge-base` and `git log`, and a short sha is
ambiguous in a large repository) while every prose mention keeps the short one; and a **missing
`verified_at` yields no finding at all**, because unknown is not stale and every verdict recorded
before this shipped is in that state.
