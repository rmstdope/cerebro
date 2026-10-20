# Requirements

Agreed with the navigator 2026-10-19. Each requirement keeps its number for ever;
a dropped one is struck, never renumbered.

## Setting up a project

R1  The navigator mounts cerebro as a submodule and runs the installer, which writes
    project.conf, roster.conf, agents.conf and the bead board.
    Proven by: tests/install.sh
R2  The installer names every missing tool in one run before it refuses.
    Proven by: tests/install.sh
R3  Sync links the skills, agents and hooks into the consumer's .claude/ and .github/,
    with links correct in every worktree and clone.
    Proven by: tests/sync-symlinks.sh
R4  The fleet works in a project whose default branch, language and roster are nothing
    like cerebro's own.
    Proven by: tests/consumer-fixture.sh

## Fleet view: seeing the fleet

R5  The navigator opens the fleet view from anywhere in the repository and sees every
    roster agent as a row with its state, bead, phase and timers.
    Proven by: tests/fleet-rows.sh
R6  A row shows an agent alive only while its session's process runs and still names
    that agent.
    Proven by: tests/fleet-alive.sh
R7  The navigator sees the board as work queues (Claimed, Ready to produce, Waiting on
    you, Merged unverified, …) that refresh on their own.
    Proven by: tests/fleet-board.sh
R8  When bd or the fleet cannot be read, the last snapshot stays on screen marked stale,
    and the other pane is unaffected.
    Proven by: tests/fleet-stale.sh

## Fleet view: driving sessions

R9  s starts an agent in a session the view hosts, k kills it, f tells it to finish its
    bead or pass and not start again.
    Proven by: tests/fleet-keys.sh
R10 RET focuses a hosted session so the navigator can type to the agent in it.
    Proven by: tests/fleet-type.sh
R11 Only the first window on a checkout operates the fleet; a second draws and acts on
    nothing, and takes over when the first closes.
    Proven by: tests/fleet-one-window.sh
R12 A session that dies on a launcher refusal shows the refusal on its row and is not
    started again until the navigator presses s.
    Proven by: tests/fleet-refused.sh

## Fleet view: starting on triggers

R13 A producer is started, with a bead claimed for it, when a ranked UX-agreed unclaimed
    bead exists; at most one every 30 seconds.
    Proven by: tests/fleet-producer-start.sh
R14 Each interactive role starts on its own trigger (UX, Psylocke, Cerebro, Moira, Cypher,
    Forge, Sage) and is ended half a minute after it writes waiting.
    Proven by: tests/fleet-role-triggers.sh
R15 A role is not started again while its trigger names exactly the work its last pass
    was started for.
    Proven by: tests/fleet-view-restart.sh
R16 A producer whose session died mid-bead is retried on a backoff, and its row says when
    and how many starts failed.
    Proven by: nothing yet

## The board

R17 The navigator re-prioritises a bead from the Work pane with 0–4, + / - and u.
    Proven by: tests/fleet-priority.sh
R18 x on a Sweeps finding runs the exact bd command it maps to, after the navigator
    confirms.
    Proven by: tests/fleet-sweep-x.sh
R19 A failed verification reopens the bead at P0, unassigned, in front of a builder.
    Proven by: tests/reopen-failed.sh
R20 Each hand-off between roles puts the bead in exactly the queue of the role meant to
    take it, and no other.
    Proven by: tests/label-routes.sh

## Sessions and spend

R21 Every session starts through launch, on the CLI and model agents.conf names, with
    hooks wired so its row reads asking while a question is open.
    Proven by: tests/fleet-launch.sh
R22 The navigator asks fleet-cost what each agent spent on each bead.
    Proven by: tests/fleet-cost.sh
R23 The navigator reads the fleet's health and history from its own logs.
    Proven by: tests/fleet-health.sh
R24 The navigator watches the fleet and its sessions from a browser through the web
    console.
    Proven by: tests/web-console.sh

## Worktrees

R25 Each builder works in a worktree of its own, cut from the project's default branch.
    Proven by: tests/prepare-worktree.sh
R26 Finished worktrees are removed without losing unmerged or uncommitted work.
    Proven by: tests/worktree-safety.sh
