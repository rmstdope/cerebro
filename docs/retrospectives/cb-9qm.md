# cb-9qm — retrospective

- **Implementer:** Rogue
- **Date:** 2026-08-25
- **PR:** #146

## A previous session of my own name died mid-bead, and nothing told the next one

**What happened.** I started, found `bd ready --label planned … --claim --json` returning `[]`,
and followed *Picking up*'s empty-queue path: `idle`, then a blocking poll. Seven minutes later the
poll saw work, and the claim printed nothing. Only `bd list --status=in_progress` showed why —
`cb-9qm` was already `in_progress` assigned to **Rogue**: an earlier session of this name had
built the bead, pushed `cb-9qm-idle-blue-diamond`, opened PR #146, had its Copilot review and its
green CI, and then died before merging. `bd ready` never lists a bead already claimed, so the queue
looked empty to me while my own name held an open PR.

**Why.** `skills/implement-bead` has no arm for this. *Picking up* reads the ready queue only, and
its empty-queue instruction is to poll — which is exactly wrong when the reason the queue is empty
is that you already hold the bead. The skill's one recovery path (`beads-workflow`'s stale-lease
reclaim) is written for taking a bead off *another* agent, and did not apply: the assignee was me.
The fleet view's own claims sweep would not have flagged it either, since a fresh session of the
same name is live and the claim reads as held by a running agent.

**Cost.** Seven minutes of idle polling that had nothing to poll for, plus the discovery. Nothing
was lost — the branch, the PR and the review all survived — but had I not looked past `bd ready`
the bead would have sat claimed with a green, reviewed, unmerged PR indefinitely, which is the
stranded-bead state one-bead-per-session exists to prevent.

**Prevent by.** `skills/implement-bead`, *Picking up*: before treating an empty ready queue as an
empty queue, check for a bead already claimed by your own name —
`bd list --status=in_progress --json | jq -r '.[] | select(.assignee=="<name>") | .id'` — and if
one comes back, resume it rather than poll: read the plan, check for a worktree under
`.cerebro/worktrees/<id>` and an open PR for its branch, and re-enter the skill at the phase
those two say you had reached. It is cheap (one `bd list` before the poll) and it is the only
signal that distinguishes "no work exists" from "your work is already in flight".

**Seen before.** None found. `cb-5yr.1.md` records a bead built twice, but that is a reopened bead
built by two deliberate runs, not a run picking up its own predecessor's unfinished one.
