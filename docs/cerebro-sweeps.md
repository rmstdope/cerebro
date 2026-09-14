# The four sweeps: what they look for, and the guards they run under

**Status: specification.** The fleet view runs every one of these itself — `sweep-epics.sh`,
`sweep-assignees.sh`, `sweep-verdicts.sh` and `sweep-paused.sh` on a ten-minute timer — and turns
each into a line in the bead panel's Sweeps section, where `x` shows the exact `bd` command and runs
it only on confirmation. The judgement lives in pure functions with a case per guard
(`sweeps::Sweep::judge`, `sweeps::finding_command`, held to `tests/lib/sweep-findings.json`), so "no
path reaches a destructive command without the guards Cerebro's instructions require" is something
the suite proves rather than something a prompt asks for. See `docs/cerebro-jobs.md` for the
decision that moved them there.

**This file is what those functions were built from**, and it is where the reasoning for each guard
is kept — why sixty minutes and not thirty, why a claim whose work is not on main is not a
sweep-close, why an epic needs ten minutes of quiet after its last child. It lived in
`agents/orchestrator.md` until it was moved here: a specification a session cannot act on does not
belong in that session's prompt, and the sweeps below leave a Cerebro session nothing
to do at all.

**A Cerebro session reads `agents/orchestrator.md`, not this file** — it carries the two sweeps that
leave a residue and points here for the rest. Change a guard here and change the Lisp function and
its ERT case with it; they are one rule in two places, and this is the half that explains itself.

`sweep-paused.sh`'s non-board cases are not decided here — they are Cerebro's, in
`agents/orchestrator.md`, *The paused beads are yours to walk*.

## What the fleet view takes back itself

A session that is gone while it still holds something is reconciled by the fleet view, every tick,
with no sweep and no keypress:

- **A gone implementer's claim** goes to `scripts/release-bead --ended`. When
  `scripts/bead-delivery.sh` finds its work on main the bead is closed, as that implementer, with
  the fleet view named in the reason; otherwise it is kept, and nothing is written.
- **Its worktree** goes to `scripts/release-bead --worktree`, which removes it only when nothing in it
  can be lost, and otherwise keeps it.
- **Both reasons are in `.cerebro/state/decisions.jsonl`** — a `release` line and a `tidy` line, each
  with `outcome` and `reason` — and Cerebro judges what was kept (`agents/orchestrator.md`, *What the
  view kept*).

The delivery test keeps three rules:

- **Match with the colon and the parentheses** (`commit_ref_pattern`, default `({id}):`). A bare
  `<parent>` also matches every `<parent>.<n>` commit, and would close the parent because a child
  merged.
- **A mockup commit is not delivery** where the project declares it so
  (`non_delivery_commit_pattern`, for example `docs({id}): mockup`), because it lands while the bead
  is still being planned.
- **A `verification:failed` bead is never closed.** Its old commits are on main already and prove
  nothing about whether the rework has landed.

## Epics left open under closed children

**The fleet view detects these**, on the same ten-minute timer as every other sweep: `sweep-epics.sh` finds every eligible epic, the Sweeps section shows it once
it is stale enough, and `x` runs the `bd close` shown, on confirmation. `cerebro--epic-finding`
enforces the ten-minute-since-last-child guard below; this prose is what it was built from.

The third thing a sweep looks for, and the cheapest. An epic is nothing but its children: when the
last one closes there is no work left under it, and the implementer that closed that child is meant
to close the epic too (see `implement-bead`). It is the same seconds-wide gap as the claim above —
an implementer that dies, or one that ran before that rule existed, leaves an epic open with every
child closed, sitting on `bd ready` and in every count of open work as a bead nobody can build.
Two epics here were both found this way, at 2/2 children closed.

One command finds them:

```bash
bd epic status --eligible-only --json | jq -r '.[] | "\(.epic.id)\t\(.closed_children)/\(.total_children)\t\(.epic.title)"'
```

`eligible` means every child is closed — bd is doing the counting, so there is no judgement about
delivery to make here and none of the on-main test above applies. Two checks before closing:

- **Nothing closed in the last ten minutes.** `bd children <epic> --json` and look at the most
  recently closed child: an implementer closes its parent within seconds of the child, so a fresh
  close is an agent mid-cleanup and the epic is about to close itself.
- **The count is the whole test, and the epic's own status is `open`.** Do not read the epic's scope
  and form a view on whether it is *really* finished — if there is work left it belongs in an open
  child, and adding one is the navigator's call, not yours.

Then, per epic:

```bash
bd close <id> --reason "All children closed; closed by Cerebro, the implementer did not"
bd dolt push
```

Use `bd close` on the ids you picked, one at a time. **Not `bd epic close-eligible`** — it closes
every eligible epic in one go with no ten-minute check and no chance to look, which is the same
objection this file makes to `bd reclaim` without `--id`. Let bd find them; decide each yourself.

`bd epic status` only sees parents of type `epic`, so a plain bead that acquired children would be
missed. That has not happened here — every parent in this database is an epic — but if you meet one,
it is the same test by hand: `bd children <parent> --json`, all `closed`, close the parent.

**Report every epic you closed**, with the same reasoning as a claim: it means an implementer did
not finish its own tidying, and the navigator wants to know. A pass that found none stays silent.

**Psylocke reopens a closed parent chain when a failed verification reopens a child** (see
`agents/verifier.md`), and the implementer that eventually re-closes that child re-closes the parent
on its way out, the same as any other bead (see `implement-bead`). Neither of those fights this sweep
— the "all children closed, nothing closed in the last ten minutes" test above already leaves a
parent alone for as long as one child is genuinely open, reopened or not.

## Open beads carrying an assignee nobody backs up

**The fleet view detects these too**, on the same ten-minute timer as the other three:
`sweep-assignees.sh` reports every `open` bead that still names an assignee, the Sweeps section
shows a line once that has stood for ten minutes, and `x` runs the `bd update <id> --assignee ""`
shown, on confirmation. `cerebro--assignee-finding` enforces the guards below; this prose is what it
was built from.

The fifth thing a sweep looks for, and the most damaging of the family, because it strands the
*highest-priority* work specifically. A bead reopened by a failed verification comes back
`status=open` — **no lease** — but still naming its old assignee, and an open bead carrying an
assignee is then never taken by `bd ready --claim`. It sits at the top of the queue looking
perfectly healthy while every implementer walks past it.

It happened twice within half an hour on 2026-08-23, and both times to a **P0**: each bead named an
implementer that was demonstrably building something else at the time. One of them sat 32 minutes
while the session it named finished a different bead and then took a **P1** below it. Both were
found only because a planner read `bd ready` by hand. Nothing in the fleet was looking, which is why a
stranded **P0**'s Sweeps line renders in the `warning` face — the same face an `asking` session's
`?` marker uses. That is the whole of the escalation: the line is visibly different from the four
ordinary ones, and there is no new glyph, popup or sound.

The line ships in one of two forms, and says what the assignee is doing rather than what the bead
costs:

```
unassign <id> — Cyclops is on <the bead it is actually building>
unassign <id> — Cyclops is not running
```

Four guards, each of which is a case the sweep must stay out of:

- **The bead is `in_progress`.** It is never emitted at all: a live claim is the claims and stalled
  sweeps' business, and emitting it here would put two lines in front of the navigator for one bead.
- **The assignee is not a roster name.** Somebody assigned it by hand, and undoing a deliberate
  assignment is not the fleet view's to do.
- **A live session is on this very bead.** It is a moment from claiming it; clearing the assignee
  under it would achieve nothing and read as the fleet view fighting an implementer.
- **The bead was touched inside `cerebro-stale-assignee-minutes`** (ten, one sweep cycle, so a bead
  is effectively seen twice before it is offered). A bead somebody has just touched is one somebody
  is attending to. The clock is `updated_at`, and an edit resets it — which is right, and is also
  the only clock available: an open bead has no lease to measure from.

Note what is *not* a guard: the assignee's session not running at all. A roster session that is not
running cannot be about to claim anything, so that case falls straight through to the offer.

**What this buys, and what it does not.** Clearing the assignee makes the bead pickable, which on
the reopen path is the difference between a P0 being built and a P0 being walked past. It does
**not** answer why the assignee was left behind in the first place — whether that is `bd`, the
reopen path in `agents/verifier.md`, or an implementer's own exit is a separate question and a
better fix. This sweep is a net, not a cure. Report every assignee you cleared and who it named, so
the navigator can see the pattern rather than only its symptom.

## Failed verdicts main has moved past

**The fleet view detects these too**, on the same ten-minute timer as the other four:
`sweep-verdicts.sh` reports every `open` bead carrying `verification:failed` and not already
carrying `verdict:stale`, the Sweeps section shows a line for each whose verdict main has moved past,
and `x` runs the `bd set-state <id> verdict=stale` shown, on confirmation.
`cerebro--verdict-finding` enforces the guards below; this prose is what it was built from.

The sixth thing a sweep looks for, and the one that costs whole sessions rather than minutes. A
verdict is formed against **one specific commit**. On a fast day the fleet merges several beads while
the verification is happening, so by the time the verdict reaches anybody a sibling may already have
delivered the very thing it found missing. The verdict is then true of the tree that was looked at
and **false of main** — and nothing distinguishes the two, because until now the commit existed only
in prose. It gets worse as the fleet gets faster, which is the wrong direction.

Three beads in one project on 2026-08-23, all within a day:

| Verdict was | What landed after | Cost |
|---|---|---|
| 4 merges behind | A sibling bead carrying exactly the wording the verification had called the sharper half | An implementer claimed it as a P0, found nothing to build, handed it back — two sessions and a planner pass |
| 2 merges behind | A sibling that shipped the asked-for behaviour outright | Closed unbuilt |
| 6 merges behind | Two later beads | A planner audit that found the shipped code matched the plan exactly, and named two causes that were both *correct behaviour* introduced after the verdict |

The commit now lives in the bead's `verified_at` metadata field, written by Psylocke at every verdict
as the **full 40-character sha** — the prose keeps the short one, because `git merge-base` reads the
field and a person reads the prose. A stale verdict on a **P0** renders its Sweeps line in the
`warning` face, the same escalation a stranded assignee gets and for the same reason.

The line says the commit and the distance, and nothing about which files moved:

```
recheck <id> — verdict at ce9d2817, 4 merges since
recheck <id> — verdict at dd3f67bd, 1 merge since
```

Three guards, each of which is a case the sweep must stay out of:

- **The bead carries no `verified_at`.** Every verdict recorded before this shipped is in that state,
  and so is any recorded by a session running an older `verifier.md`. **Unknown is not stale** — a
  sweep that read absence as staleness would flag the entire history on its first run.
- **The commit is not in this clone**, or is not an ancestor of the default branch — a worktree that
  had drifted, a force-push. The distance is then not a number, and a distance that is not known is
  not a small distance. The script says `null`, never `0`, and the finding leaves it alone.
- **Fewer than `cerebro-stale-verdict-merges` commits have landed since** — one, by default. Anything
  landing on main since the verdict is enough to be worth a second look; three would be quieter but
  would have missed the two-merge case above, one of the three this was filed for.

Note what is *not* a guard: whether any of those merges touched the files this bead's plan names.
The cheap question is deliberate — it errs toward a second look rather than toward an implementer
building a no-op — and a mockup commit counts like any other, because the question is *has main
moved*, not *was this bead delivered*.

**What this buys, and what it does not.** Flagging takes the bead out of the two queues that would
act on a stale verdict — `implement-bead`'s pickup and `plan-bead`'s candidate queries both exclude
`verdict:stale` — and puts it at the top of Psylocke's next pass, which takes a stale bead first
because re-reading a finding against current main is the cheapest verification there is. It does
**not** decide whether the verdict still holds: only Psylocke and the navigator do that. Nothing is
destroyed either — the verdict, the notes and the plan all stay exactly as written, which is why the
label is `verdict:stale` and not a `verification:` value: `verification` is a bd state dimension and
`bd set-state` replaces the whole of it, so writing staleness there would erase the finding itself.

Psylocke removes the label whenever she records a new verdict, unconditionally. Without that the
sweep would re-offer the same bead every cycle after the next merge lands.
