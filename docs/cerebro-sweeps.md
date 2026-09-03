# The six sweeps: what they look for, and the guards they run under

**Status: specification.** The fleet view runs every one of these itself — `sweep-claims.sh`,
`sweep-epics.sh`, `sweep-stalled.sh`, `sweep-assignees.sh`, `sweep-verdicts.sh` on a ten-minute
timer, and `prune-worktrees.sh --watch` continuously — and turns each into a line in the bead
panel's Sweeps section, where `x` shows the exact `bd` or `git worktree` command and runs it only
on confirmation. The judgement lives in pure Lisp with an ERT case per guard
(`cerebro--claim-finding`, `cerebro--epic-finding`, `cerebro--stalled-finding`,
`cerebro--assignee-finding`, `cerebro--verdict-finding`, `cerebro--finding-command`), so "no path
reaches a destructive command without the guards Cerebro's instructions require" is something the
suite proves rather than something a prompt asks for. See `docs/cerebro-jobs.md` for the decision
that moved them there.

**This file is what those functions were built from**, and it is where the reasoning for each guard
is kept — why sixty minutes and not thirty, why a claim whose work is not on main is not a
sweep-close, why an epic needs ten minutes of quiet after its last child. It lived in
`agents/orchestrator.md` until it was moved here: a specification a session cannot act on does not
belong in that session's prompt, and four of the six sweeps below leave a Cerebro session nothing
to do at all.

**A Cerebro session reads `agents/orchestrator.md`, not this file** — it carries the two sweeps that
leave a residue and points here for the rest. Change a guard here and change the Lisp function and
its ERT case with it; they are one rule in two places, and this is the half that explains itself.

`sweep-paused.sh`'s non-board cases are not decided here — they are Cerebro's, in
`agents/orchestrator.md`, *The paused beads are yours to walk*.

## Keeping the worktrees tidy

**The fleet view runs this sweep for you now**, automatically, on every `M-x cerebro` and
without asking: `prune-worktrees.sh --watch` starts alongside the fleet buffer and stops when it is
killed. The watcher's own removals need no judgement from you — the script's guards are the whole
safety story for those. What is left for a session is the trees it *declines* or never looks at:
those are yours to judge and remove, on your own, by the tests further down.

Implementers build in `.cerebro/worktrees/<bead>` and are told to remove the tree on the way out. They
do not always get there — a crash, a kill, a bead somebody else merged — and the leftovers are not
merely untidy: an abandoned tree holding `main` makes the next agent's `git checkout main` fail for
no visible reason.

So sweep. Once on startup, and then every ten minutes for as long as you are running:

```bash
.claude/cerebro/scripts/prune-worktrees.sh                       # the startup sweep, in the foreground
.claude/cerebro/scripts/prune-worktrees.sh --watch &             # every ten minutes thereafter
```

Start the `--watch` sweep in the background once, on startup, and never a second time — check
whether one is already running before you start another.

The script decides what is safe for an implementer's tree, and it is conservative on purpose: it
removes a worktree only when nothing can be lost from it — clean tree, work already on main, and
untouched for half an hour — and keeps everything else, saying why. **The trees it declines are
yours to judge, and you decide on your own** (the navigator asked for this on 2026-08-16, after a
sweep that stopped to ask about the obvious): remove a worktree the script kept, or one it never
looks at (a scratchpad tree from an old session, a role's tree outside `.cerebro/worktrees/`, a tree
detached at a commit already on main), when all of these hold:

- no live session is in it — no `ListAgents` name whose bead is that tree's, and no process with its
  working directory there (`lsof +D <path>` or `pgrep -f <path>`);
- its branch is merged into `origin/main`, or its HEAD is already on `origin/main`
  (`git branch --merged origin/main`, `git merge-base --is-ancestor <sha> origin/main`);
- it has no uncommitted or untracked changes (`git -C <path> status --porcelain` is empty), or its
  only such changes are build output and caches (`node_modules/`, `target/`, `dist/`).

**Never the verifier's tree at `.cerebro/worktrees/`** — whatever the tests say: Psylocke's tree is
reset to main between passes rather than merged, so it always looks abandoned and never is (see
`.claude/cerebro/docs/cerebro-jobs.md`). `prune-worktrees.sh` keeps it by name there for the same
reason.

**`.cerebro/worktrees/` is the one place worktrees live**, and `prune-worktrees.sh` looks nowhere
else. A tree registered under any other path — a scratchpad tree, a role's tree from an old
session — is not an agent worktree: the sweep never reports it and never touches it, and it is
yours to judge by the three tests above.

**It walks two worktree lists, not one.** Besides the consumer's, it walks
`.claude/cerebro`'s — because a worktree of the submodule is registered there and nowhere else, so
for a long time nothing enumerated one and two sat on this machine with their merged branches still
checked out. Every rule above applies to such a tree unchanged; only the repository each is asked of
changes, so `keeping … — it holds work that is not on main yet` means *cerebro's* main for a cerebro
tree. This is cleanup for a category `implement-bead` no longer creates — a bead whose diff is inside
the submodule now works in place, in its own consumer worktree's copy — so expect the submodule's
list to hold nothing but its own git dir, which is not an agent worktree and is never reported. A
cerebro remote that cannot be reached costs the submodule half of the sweep only, and says so.

Then `git worktree remove <path>` and `git worktree prune`. A tree that fails the third test is
somebody's unpushed work: leave it, and say whose tree it is and what it holds, because that is a
decision about someone else's edits and not one to take alone. **`--force` is for the cache-only
case and nothing else** — a tree the script declined for uncommitted source is declined because a
removal would have destroyed something, and the reason is printed.

Report a sweep only when it did something, or when the navigator asks. A janitor announcing that it
found nothing, every ten minutes, is noise. A tree you removed on your own judgement is something it
did: say which one and why it was safe.

## Beads that finished without being closed

**The fleet view now detects these candidates for you**: `sweep-claims.sh` gathers the
same facts this section describes, every ten minutes, and the Sweeps section of the bead panel shows
each one as a line — `x` on it runs the exact `bd close` or `bd reclaim` shown, only after you
confirm. The guards below are exactly what `cerebro--claim-finding` in `emacs/cerebro.el` enforces,
pinned by its own ERT cases; this prose is the specification they were built from, not a duplicate
process. What is left for a Cerebro session is the judgement the fleet view does not attempt: a claim
whose work is not on main, which is not a sweep-close at all (see below).

A worktree is not the only thing a dead implementer leaves behind. An implementer closes its bead in
the seconds after the merge, so a crash anywhere in that gap leaves the work delivered and the bead
still `in_progress` — claimed by an agent that no longer exists, invisible to `bd ready`, and blocking
everything that depends on it for as long as nobody looks. One bead here was exactly this: its pull
request merged, the bead never closed.

So whenever you sweep the worktrees — on startup, and each time you notice the ten-minute sweep has
come round — sweep the claims too. It is three commands and it is yours to run, not the script's,
because closing a bead needs a judgement the script cannot make.

```bash
bd list --status in_progress --json                       # every live claim, with its assignee
git -C <repo> fetch --quiet origin main
git -C <repo> log origin/main --grep "(<id>):" --oneline  # per claim: did it land?
```

The commit subject carries the bead ID — `feat(<bead-id>): <a short description of the work>` — so a hit on
`(<id>):` means something for that bead is on main. Two ways to read that wrong, and both have
happened here:

- **Match with the colon and the parentheses.** Bare `<parent>` also matches every `<parent>.<n>` commit,
  and you would close the parent because a child merged.
- **A `docs(<id>): mockup` commit is not delivery.** `/plan-bead` merges the chosen UI mockup into
  `docs/ui/` while the bead is still being planned, so that commit sits on main for the whole of the
  implementation. Read the subjects, not just the count: two beads here each had one while both
  were still `planned` and unbuilt. Discount them —
  `... --oneline | grep -v "docs(<id>): mockup"` — and if nothing else is left, the bead is not done.

**A bead carrying `verification:failed` is never sweep-closed.** Psylocke's failed verdict reopens a
bead whose *old* commits are already on `origin/main` — that is what a reopen is — so the
`git log --grep "(<id>):"` test above matches every time and proves nothing about whether the rework
has landed. Check the labels before closing anything: `bd show <id> --json | jq -r '.labels'` (or the
array from the sweep query itself), and if `verification:failed` is there, report it as a reopened
bead being rebuilt rather than closing it.

And read the assignee before anything else: a bead the navigator is holding — parked mid-thought, or
being worked by hand — is `in_progress` under a human name, and none of this applies to it. Only
claims held by implementer names are yours to sweep.

**A claim can only ever be an implementer's or a human's.** Claiming belongs to the implementer role
alone (see `beads-workflow`): a planner marks what it is planning with a `planning:<its own name>` label and holds no
lease, Moira claims nothing at all, and you claim nothing either. So `in_progress` narrows to two
possibilities rather than four — which is what makes the lease check below decisive.

**The assignee name now tells you who claimed a bead — but only for a claim made from a launched
session.** The one launcher, `scripts/launch` (the only way a session starts), exports
`BEADS_ACTOR=<agent name>` before starting its session, so a claim made from one is stamped with the
roster name that made it: `assignee: Cyclops` means Cyclops's session claimed it, full stop.
An assignee that is **not a name on `scripts/roster`** now specifically means a claim made by hand,
outside a launched session — still check the lease before touching it, since a claim from before this
change, or from a stale session started off the old launchers, predates the naming and carries none
of this guarantee. Two beads held under such a name were found stale this way on 2026-08-14: both
`in_progress`, both with leases expired and last heartbeat ten hours gone, neither held by any process in `ListAgents` or `pgrep`.

So a human-looking assignee is not license to skip a bead in the sweep — check the lease before
deciding it is off-limits:

```bash
bd show <id>     # look for "Lease: expires expired (heartbeat <age>)"
```

An expired lease with no live agent behind it (`ListAgents`, and `pgrep` for implementer launchers)
is a stale claim regardless of what name is on it, and **you recover it yourself, on your own
judgement** — an implementer's name or a human's makes no difference once the lease is dead and
nobody is behind it. The navigator asked for exactly this on 2026-08-16: a sweep that finds a claim
eight hours dead, reports it, and then waits to be told to run the one command that fixes it has
turned the fix into a question, and the question into a bead nobody could pick up in the meantime.
Recover it (below), and report what you did.

**Close a claim only when all three hold:**

- its work is on main, by the test above;
- **that bead's** commit is more than ten minutes old. Ask for its date specifically — a bare
  `git log -1` answers for whatever HEAD happens to be, which is not the commit you are judging:

  ```bash
  git -C <repo> log -1 --grep "(<id>):" --format='%h %cr %s' origin/main
  ```

  An implementer closes within seconds of merging, so anything fresher is an agent mid-cleanup, not
  a dead one. The subject is in the output so you can see which commit you got: if `-1` handed you
  the `docs(<id>): mockup` commit, that is not the delivery and you are not judging its age;
- no live implementer is on it — `ListAgents` for who is alive, and the bead's `assignee` for who
  claimed it. A name that is still running keeps its bead, however old the merge looks.

Then:

```bash
bd close <id> --reason "Delivered in PR #NN; closed by Cerebro, the implementer did not"
bd dolt push
```

`bd dolt push` matters as much as the close — until it runs, the other machines still see the claim.

**Always report a claim you closed**, even though you stay quiet about a sweep that found nothing.
A bead closing itself is the visible end of an implementer that died, and the navigator wants to know
that happened — including which agent's name was on it.

A claim whose work is *not* on main is a different case and not one to close. If the session that
claimed it is gone, that is the narrow recovery in `beads-workflow`, and **you run it as part of the
sweep — on startup, on every pass, and without asking**:

```bash
bd reclaim --id <bead> --older-than 10m     # one named bead, by ID, never a sweep
bd dolt push
```

**"Gone" is about the session, not the name.** An implementer is one session per bead, so a fresh
Wolverine that came up a minute ago and is heartbeating one bead is not the Wolverine that claimed
another eight hours earlier — that session died, and its claim is stale however alive the name looks
in `ListAgents`. The test is: does any live session hold *this* bead? Read `.cerebro/state/<name>.state.json`
for what each running implementer is on, and treat a claim as held only when a live session's `bead`
is that id (or its lease is fresh — a heartbeat inside the last five minutes means somebody is on it,
whatever the state files say). A bead here on 2026-08-16 was exactly this: `assignee: Wolverine`, lease
expired eight hours, live Wolverine on a different bead, one child blocked behind it.

**Do not add a waiting period of your own on top of that `10m`.** It counts from lease expiry, not
from the last heartbeat, so with a five-minute lease it already declines to touch anything that was
alive within about the last fifteen minutes. The command enforces the window; your job is only to be
sure the agent is gone. Sitting on it for a further quarter of an hour is silence nobody needs.

Never without `--id`, and never for a bead a live session is on — a long CI watch looks identical to
a death from out here, which is why the lease and the state file, not the name, are what you read.
It also only works on the machine that granted the lease, so a claim from another machine will simply
be skipped; that is not a failure to retry, it is the navigator's to sort out. Anything less
clear-cut than "the session is gone and the work is not there" — a fresh lease, a state file naming
the bead, work half on main — is the navigator's call: say what you found and leave it alone.

**Always report a claim you reclaimed**, the same as one you closed: which bead, whose name was on
it, how old the lease was, and what it unblocked. Doing it yourself does not make it silent.

## Epics left open under closed children

**The fleet view now detects these too**, the same way and on the same ten-minute timer as
the claims sweep above: `sweep-epics.sh` finds every eligible epic, the Sweeps section shows it once
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

## Claims held by a session that has stopped moving

**The fleet view detects these too**, on the same ten-minute timer as the other two:
`sweep-stalled.sh` reports how long every `in_progress` bead has gone without a sign of progress,
the Sweeps section shows a line once that passes an hour, and `x` runs the `bd unclaim` shown, on
confirmation. `cerebro--stalled-finding` enforces the guards below; this prose is what it was built
from.

The fourth thing a sweep looks for, and the one the other three cannot see. The claims sweep above
keys on a *dead* session — `assignee` off the live roster, plus an expired lease. An implementer
that ended its turn waiting for something that never came is neither: its pid exists, so it counts
as live and the claims sweep steps over it, and its lease is heartbeated or expires under a name
that is still on the roster. Over the 72 hours to 2026-08-20 four such beads held 21.7 hours of
claim between them — nearly as much as the entire working fleet spent on the 36 beads that ran
cleanly — and nothing noticed any of them.

**The signal is progress, not elapsed time.** A bead legitimately sits quiet for forty minutes in
CI. What separates that from a parked one is time since the last commit on the bead's own branch,
measured `origin/main..HEAD` from a worktree under `.cerebro/worktrees/`, falling back to the claim
itself (`started_at`) when the branch has no commit of its own yet. Every one of those 36 clean
beads made its first commit 6 to 36 minutes after being claimed; the four parked ones sat 2.3 hours
or more. Sixty minutes separates them with no false positive in that window, which is where
`cerebro-stalled-minutes` comes from — a `defcustom`, so the navigator can change it while the
fleet runs.

Three guards, each of which is a case the sweep must stay out of:

- **Nobody live holds it.** That is the claims sweep's bead, not this one's; offering it here as
  well would put two lines in front of the navigator for one bead.
- **The session is `asking`.** It is blocked and it said so, and `cerebro--supervise-action` already
  nudges it after fifteen minutes. Two mechanisms firing on one session is noise.
- **No age to judge, or an age inside the hour.** Including every bead sitting in CI.

`bd unclaim`, not `bd reclaim --older-than`: reclaim's window is about a session that is *gone*, and
would refuse a bead whose lease the stalled session is still heartbeating.

**What this buys, and what it does not.** Unclaiming releases the bead so another session can take
it. It does **not** answer whatever question the stalled implementer was stuck on, and it does not
end that session — the implementer keeps whatever it was holding, and the navigator may still want
to look at its terminal. Nor does a released bead become throughput on its own: it is only worth
something when there is a session free to pick it up. Report every claim you released, and say which
implementer was on it, so the navigator can go and see what it was waiting for.

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
