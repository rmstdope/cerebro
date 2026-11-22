# Requirements

Agreed with the navigator 2026-11-22. Each requirement keeps its ID for ever;
a dropped one is struck, never renumbered.

## Setting up a project (SET)

SET-1  The navigator mounts cerebro as a submodule and runs the installer, which writes
       project.conf, roster.conf, agents.conf and the bead board. (was R1)
       Proven by: tests/install.sh
SET-2  The installer names every missing tool in one run before it refuses. (was R2)
       Proven by: tests/install.sh
SET-3  Sync links the skills, agents and hooks into the consumer's .claude/ and .github/,
       with links correct in every worktree and clone. (was R3)
       Proven by: tests/sync-symlinks.sh
SET-4  The fleet works in a project whose default branch, language and roster are nothing
       like cerebro's own. (was R4)
       Proven by: tests/consumer-fixture.sh

## Fleet view (FLV)

FLV-1  The navigator opens the fleet view from anywhere in the repository and sees every
       roster agent as a row with its state, bead, phase and timers. (was R5)
       Proven by: tests/fleet-rows.sh
FLV-2  A row shows an agent alive only while its session's process runs and still names
       that agent. (was R6)
       Proven by: tests/fleet-alive.sh
FLV-3  The navigator sees the board as work queues (Claimed, Ready to produce, Waiting on
       you, Merged unverified, …) that refresh on their own. (was R7)
       Proven by: tests/fleet-board.sh
FLV-4  When bd or the fleet cannot be read, the last snapshot stays on screen marked stale,
       and the other pane is unaffected. (was R8)
       Proven by: tests/fleet-stale.sh
FLV-5  s starts an agent in a session the view hosts, k kills it, f tells it to finish its
       bead or pass and not start again. (was R9)
       Proven by: tests/fleet-keys.sh
FLV-6  RET focuses a hosted session so the navigator can type to the agent in it. (was R10)
       Proven by: tests/fleet-type.sh
FLV-7  Only the first window on a checkout operates the fleet; a second draws and acts on
       nothing, and takes over when the first closes. (was R11)
       Proven by: tests/fleet-one-window.sh
FLV-8  A session that dies on a launcher refusal shows the refusal on its row and is not
       started again until the navigator presses s. (was R12)
       Proven by: tests/fleet-refused.sh
FLV-9  A producer is started, with a bead claimed for it, when a ranked UX-agreed unclaimed
       bead exists; at most one every 30 seconds. (was R13)
       Proven by: tests/fleet-producer-start.sh
FLV-10 Each interactive role starts on its own trigger (UX, Psylocke, Cerebro, Moira, Cypher,
       Forge, Sage) and is ended half a minute after it writes waiting. (was R14)
       Proven by: tests/fleet-role-triggers.sh
FLV-11 A role is not started again while its trigger names exactly the work its last pass
       was started for. (was R15)
       Proven by: tests/fleet-view-restart.sh
FLV-12 A producer whose session died mid-bead is retried on a backoff, and its row says when
       and how many starts failed. (was R16)
       Proven by: tests/fleet-retry.sh
FLV-13 The navigator sets how often each clock role (Moira, Cypher, Forge, Sage) runs, with
       role_cadence_<role> in project.conf. (was R27)
       Proven by: tests/fleet-role-triggers.sh

## The board (BRD)

BRD-1  The navigator re-prioritises a bead from the Work pane with 0–4, + / - and u. (was R17)
       Proven by: tests/fleet-priority.sh
BRD-2  x on a Sweeps finding runs the exact bd command it maps to, after the navigator
       confirms. (was R18)
       Proven by: tests/fleet-sweep-x.sh
BRD-3  A failed verification reopens the bead at P0, unassigned, in front of a builder. (was R19)
       Proven by: tests/reopen-failed.sh
BRD-4  Each hand-off between roles puts the bead in exactly the queue of the role meant to
       take it, and no other. (was R20)
       Proven by: tests/label-routes.sh
BRD-5  When the project declares a verification skill, Psylocke opens the merged build in the
       browser herself and brings the navigator the evidence and a recommended verdict. (was R28)
       Proven by: tests/fleet-verification-skill.sh
BRD-6  When Psylocke checks the app in Chrome, she leaves the navigator's own window
       and tabs as they are: a screen size comes from device emulation or a window of
       her own.
       Proven by: nothing yet
BRD-7  A green Dependabot pull request is merged by Cerebro without review; a red one
       becomes exactly one P4 bug bead, which follows the pull request when Dependabot
       replaces it.
       Proven by: nothing yet
BRD-8  When the project declares dependabot_merge review, Cerebro merges a green Dependabot
       pull request only once a reviewer sub-agent has read it and found nothing; the merge
       is held to the reviewed head, and findings or a refused merge hand it back to the
       navigator.
       Proven by: nothing yet

## Sessions and spend (SES)

SES-1  Every session starts through launch, on the CLI and model agents.conf names, with
       hooks wired so its row reads asking while a question is open. (was R21)
       Proven by: tests/fleet-launch.sh
SES-2  The navigator asks fleet-cost what each agent spent on each bead. (was R22)
       Proven by: tests/fleet-cost.sh
SES-3  The navigator reads the fleet's health and history from its own logs. (was R23)
       Proven by: tests/fleet-health.sh
SES-4  The navigator watches the fleet and its sessions from a browser through the web
       console. (was R24)
       Proven by: tests/web-console.sh
SES-5  From the web console, the navigator starts, finishes or kills an agent. Each button
       does exactly what s, f or k would do on that row in the fleet view, and shows only when
       that key would.
       Proven by: tests/web-console.sh

## Worktrees (WKT)

WKT-1  Each builder works in a worktree of its own, cut from the project's default branch. (was R25)
       Proven by: tests/prepare-worktree.sh
WKT-2  Finished worktrees are removed without losing unmerged or uncommitted work. (was R26)
       Proven by: tests/worktree-safety.sh

## Testing (TST)

TST-1  The navigator asks test-code-ratio how many lines of test code the project keeps
       for each line of production code, and Sage warns once it passes 2.
       Proven by: nothing yet
