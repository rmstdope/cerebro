# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Cerebro is an **AI harness**, not an application: agent definitions, skills, docs, a sync script, and
an Emacs fleet viewer. It is consumed by other repositories as a git submodule at `.claude/cerebro`,
whose `scripts/sync-symlinks.sh` symlinks the skills and agents into the consumer's discovery paths.

Almost nothing here executes in this repository. The agents and skills describe a workflow that runs
in a *consumer* repo (they were extracted from `atlantis-hud` and still name it throughout), and they
refer to launcher scripts — `scripts/run-planner`, `scripts/run-orchestrator`, `scripts/run-user-feedback`,
`scripts/run-implementer`, `scripts/prune-worktrees.sh` — that live in the consumer repo, **not here**.
Do not go looking for them in this tree, and do not assume a change here is testable by running it.

## Commands

Only the Emacs package has a test suite:

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit    # all tests
emacs --batch -L emacs -l cerebro-test \
  --eval '(ert-run-tests-batch-and-exit "cerebro-test/elapsed-minutes-hours-days")'   # one test (name or regexp)
```

Note `emacs/README.md` gives the path as `tools/emacs` — that is the old path in the origin repo; use
`-L emacs`.

Sync symlinks into a consumer repo (run from that repo, not this one):

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

## The agent fleet these files describe

Four roles, each an agent definition in `agents/` backed by a skill in `skills/`:

- **Xavier** (`planner`, Fable/high) — loads `plan-bead`. Turns unplanned beads into plans a Sonnet
  agent could build unattended. Decides architecture itself; takes every user-facing decision to the
  human ("the navigator"). Keeps four planned beads ahead of the builders.
- **Cerebro** (`orchestrator`, Fable/medium) — stops implementers on request (it cannot start one:
  that means starting a session), sweeps
  worktrees/claims/epics, reports. **Starts nothing on its own.**
- **implementer** (Sonnet) — loads `implement-bead`. One bead per session: claim, build test-first in
  its own git worktree, PR, answer the Copilot review, merge, close, report `done`. Interactive, so
  it cannot end itself — the Emacs fleet view ends it and starts a fresh session, which is what keeps
  a session's context one bead deep.
- **Moira** (`user-feedback`, Sonnet) — owns GitHub issues: acknowledges, triages into beads, keeps
  the issue's status comments in step with its bead.

`skills/beads-workflow/SKILL.md` is the shared substrate all of them read: work is tracked in **beads**
(`bd`), not GitHub issues; GitHub issues are the external inbox only. The planner/builder handover is
a single `planned` label; anything needing the human gets a `human` label and surfaces in `bd human list`.

`docs/agent-workflow.md` is the human's operating guide — read it before changing any role, because
it documents the observed behaviour and costs the roles were tuned against.

### Invariants the agent files encode

These are load-bearing; changing them changes how the fleet behaves in every consumer repo.

- **Wait by blocking inside a tool call, never by ending a turn.** `Monitor` and background `Bash`
  promise a re-invocation that nothing delivers; this stranded a claimed bead, an open PR and
  unanswered review comments. Implementers are interactive now, so an ended turn no longer kills the
  process — it just sits there until a human types something, which is not better.
- **The state file is the contract.** `.claude/implementers/<name>.state.json` carries
  `idle`/`working`/`asking`/`done`; the implementer writes it, `cerebro.el` acts on it. Changing
  either side's vocabulary breaks supervision silently — `cerebro--derive-implementer` maps unknown
  states to `idle`, which reads as "fine" rather than as an error.
- **Nothing merges unreviewed, red, or stale.** The implementer's standing approval to merge without
  asking comes from the consumer repo's CLAUDE.md ("Four Eye Principle") and applies only to a
  planned bead.
- **Agents never decide anything a user sees**, never take work off another agent (except the
  documented crashed-agent recovery), and never act outside a planned bead.
- Each agent announces its own name in its first message — the human watches several sessions at once.

## emacs/cerebro.el

`M-x cerebro` lists the fleet (Xavier, Cerebro, Moira + fifteen implementers) with state, current bead
and elapsed time; `s` starts, `k` kills, `RET` focuses the detail window. Emacs 28+, no dependencies
except optional **vterm** for live sessions.

The file is deliberately split into a **pure core** (`cerebro--derive*`, `cerebro--entry`,
`cerebro--*-action`, `cerebro--launch-command`) and a small set of **impure readers** at the bottom
(`cerebro--roster`, `cerebro--read-state-file`, `cerebro--system-args`, `cerebro--owned`). The tests
only exercise the pure half, passing state in as plain data. Keep new logic on the pure side or it
becomes untestable.

Two data sources it depends on, both owned by the consumer repo:

- `.claude/implementers/<name>.state.json` — `{state: "idle"|"working", bead, since, pid}`, written by
  `scripts/run-implementer` at each transition. `cerebro--state-file-path` mirrors `statePath` in the
  consumer's `runImplementer.ts`; the two must stay in step.
- `scripts/run-implementer --roster` — the implementer names.

Interactive agents have no state file: liveness is inferred by scanning system process args for
`--name <Name>`, which is why the launchers must pass it.

## Gotchas

- `scripts/sync-symlinks.sh` and `githooks/` only ever run in a **consumer** repo, one directory level
  above this submodule. Both resolve their paths from `${BASH_SOURCE[0]}`, so `.claude/cerebro/scripts`
  and `.claude/cerebro/githooks` are load-bearing locations — moving either breaks the `../../..`
  climb to the consumer root. To test a change, build a throwaway consumer repo rather than running
  the script here (it will refuse: there is no `.claude/` above this tree).
- `githooks/install.sh` sets `core.hooksPath`, which is repository-wide and replaces `.git/hooks`
  entirely. It refuses rather than clobbering a `core.hooksPath` already pointing elsewhere.
- Emacs backup files (`*.el~`, `*.md~`, `*.sh~`) are committed alongside the originals; ignore them
  and never edit them.

# Test driven development

Develop the emacs elisp code using test driven development, but do not stop after each phase and ask for user approval.
Instead, continue running until done and ready to commit.
