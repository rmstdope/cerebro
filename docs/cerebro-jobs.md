# What Cerebro does, and how much of it the fleet view can do instead

Cerebro is a `claude` session on Fable that does almost nothing a model actually has to reason
about: it writes a flag to start or stop an implementer, sweeps worktrees, claims and epics on a
timer, and reports counts. That is `touch`, `pgrep` and a handful of `bd` queries wearing an agent's
clothes — and it costs a terminal, a model and the navigator's attention to drive.

This is the recommendation `ah-4ao` was scoped to produce: which of those jobs are now commands on
the selected agent in the Emacs fleet view (`emacs/cerebro.el`), which still belong to a session
started on demand, and which are retired outright because the sessionless design makes them
unnecessary rather than merely automatable. It sorts every job Cerebro's own instructions
(`agents/orchestrator.md`) describe into exactly one of the three, and it is the bead's whole
acceptance artifact — read it before changing what runs where.

## Now in the fleet view

| Job | Key | Landed in |
|---|---|---|
| Start an agent | `s` | ah-vcf.3 (PR #229) |
| Tell an implementer to finish | `f` | ah-4ao |
| Kill an agent | `k` | ah-vcf.3 (PR #229) |
| Claimed / planned / unplanned / merged counts | (the beads panel) | PR #6 |
| Worktree pruning | (automatic, on `M-x cerebro`) | ah-4ao |
| Claims sweep — detection and confirmed close/reclaim | `x` on a finding | ah-4ao |
| Epics sweep — detection and confirmed close | `x` on a finding | ah-4ao |

Every one of these was a paragraph of judgement in `orchestrator.md` that turned out, on inspection,
to be a fixed decision table plus a subprocess call. The judgement moved into a pure Lisp function
with its own ERT case per guard (`cerebro--claim-finding`, `cerebro--epic-finding`,
`cerebro--finding-command`), so "no path reaches a destructive `bd` or `git worktree` invocation
without the guards Cerebro's instructions require" is something the test suite proves rather than
something a session's prompt merely asks for.

**Detection is on a timer; nothing destructive runs without a keypress.** The claims and epics
sweeps refresh every ten minutes (`cerebro-sweep-refresh-seconds`) and render as a Sweeps section
under the bead panel — one line per finding, hidden entirely when there is nothing to report, so a
clean sweep costs nothing to look at. Acting on one (`x`) always shows the exact `bd` command first
and runs it only on `y`. Worktree pruning is the one exception the navigator asked for: it stays
fully automatic, because `prune-worktrees.sh`'s own guards (clean tree, work already on `origin/main`,
untouched for half an hour) can only ever discard a copy of something that is safely elsewhere —
there is nothing here for a confirmation to protect against — and one named worktree, `psylocke`,
that is kept by name because it is reset rather than merged.

## Stays with a session, started when wanted

- **Release cutting** (`orchestrator.md`, "Cutting a release"). Judgement about what belongs in a
  release, plus a long `gh run watch` — not a fixed decision table, and not something to compress
  into a keybinding.
- **Diagnosing a stuck implementer.** Reading a transcript, working out why an agent has gone quiet
  or is looping, is exactly the kind of open-ended reading a model does and a decision table cannot.
- **Anything `bd update --force`-shaped.** Reassigning a claim, overriding a lease, anything the
  workflow already routes through the navigator's explicit approval — see `beads-workflow`. A
  keybinding that could do this on its own judgement is worse than the session it would replace.
- **Recovering a stale claim and pruning what the watcher declined.** The fleet view detects a dead
  lease and asks before acting; a Cerebro session, when one is running, does not wait — it runs
  `bd reclaim --id` on a claim no live session holds and removes a worktree that is merged, clean and
  unowned on its own judgement, then reports (2026-08-16, `orchestrator.md`, "Beads that finished
  without being closed" and "Keeping the worktrees tidy"). Same guards, no keypress: this is the
  reading a session is for.

Nothing here changes: start a session with `.claude/cerebro/scripts/run-orchestrator` exactly as
before, for exactly these three things.

## Retired with the sessionless design

- **The keepalive loop** (`orchestrator.md`, "Staying alive between questions") — a forked
  subagent blocking on `sleep 300` so sweeps happen without the navigator asking. A timer in Emacs
  needs no subagent holding a sleep to get the same cadence; the fleet view's own 30-second bead
  timer and 10-minute sweep timer already are that loop, and they cost nothing to keep running
  because nothing is blocked waiting on them.

## What is left open

**Whether Cerebro the session is still started by default, or only on demand**, is the navigator's
to decide and this bead does not answer it. The case for on-demand: every *routine* job it did — the
flags, the three sweeps, the counts — now happens without it, continuously, whether or not a Cerebro
session is open; what is left needs a person's attention to trigger in the first place (a release, a
stuck agent, a forced reassignment), so there is little for an always-running session to be doing
between those. The recommendation here is on-demand. The decision is not made here.
