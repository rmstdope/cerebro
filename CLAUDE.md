# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Cerebro is an **AI harness**, not an application: agent definitions, skills, docs, a sync script, and
an Emacs fleet viewer. It is consumed by other repositories as a git submodule at `.claude/cerebro`,
whose `scripts/sync-symlinks.sh` symlinks the skills and agents into the consumer's discovery paths.

Almost nothing here executes in this repository. The agents and skills describe a workflow that runs
in a *consumer* repo (they were extracted from `atlantis-hud` and still name it throughout), and the
launchers in `scripts/` only make sense from a consumer root, where this repo is mounted at
`.claude/cerebro`. So a change here is generally not testable by running it in this tree.

## Commands

Only the Emacs package has a test suite:

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit    # all tests
emacs --batch -L emacs -l cerebro-test \
  --eval '(ert-run-tests-batch-and-exit "cerebro-test/elapsed-minutes-hours-days")'   # one test (name or regexp)
```

Sync symlinks into a consumer repo (run from that repo, not this one):

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

## The agent fleet these files describe

Six roles, each an agent definition in `agents/`; most are backed by a skill in `skills/`:

- **Xavier** (`planner`, Fable/high) — loads `plan-bead`. Turns unplanned beads into plans a Sonnet
  agent could build unattended. Decides architecture itself; takes every user-facing decision to the
  human ("the navigator"). Keeps a buffer of planned beads ahead of the builders, sized from how
  many are running (twice the count, never fewer than four).
- **Cerebro** (`orchestrator`, Fable/medium) — stops implementers on request by writing their stop
  flag; it cannot start one, since that means starting a session. **Starts nothing on its own.** The
  worktree, claims and epics sweeps it used to run on a timer now run from the fleet view itself
  (`ah-4ao`; see `docs/cerebro-jobs.md`); what is left for a Cerebro session is release cutting,
  diagnosing a stuck implementer, and anything needing a forced reassignment.
- **implementer** (Sonnet) — loads `implement-bead`. One bead per session: claim, build test-first in
  its own git worktree, PR, answer the Copilot review, merge, close, report `done`. Interactive, so
  it cannot end itself — the Emacs fleet view ends it and starts a fresh session, which is what keeps
  a session's context one bead deep.
- **Moira** (`user-feedback`, Sonnet) — owns GitHub issues: acknowledges, triages into beads, keeps
  the issue's status comments in step with its bead.
- **Psylocke** (`verifier`, Sonnet) — loads no separate skill; her whole job lives in
  `agents/verifier.md`. Walks beads merged since her last pass, judges which touched the application,
  prepares each verification before ever asking for the navigator's time, then briefs, launches and
  records their verdict. A failed verdict reopens the bead at P0 and sends it back to the fleet.
- **Bishop** (`architect`, Fable/xhigh) — loads no separate skill either; its whole job lives
  in `agents/architect.md`. One sweep per session: reads what merged since its last sweep (daily) or
  the whole codebase (weekly), and files a `Refactoring:` bead at P4 for each smell that names a cost
  already being paid, never a fix. Watermark kept in bd memory. Ends its own turn when the sweep is
  reported — the one role here that does not loop, because it holds no claim, lease or PR to strand.

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
  `idle`/`working`/`asking`/`done`; the implementer writes it, `cerebro.el` acts on it. Since ah-u3i
  it also carries `phase` (`build`/`gate`/`review`/`ci`/`rebase`/`merge`, or null) and `phase_since`
  — supervision (`cerebro--supervise-action`) reads `state` alone, never `phase`, so a typo in the
  phase vocabulary can only mislabel a column, never break the restart loop. An unrecognised `state`
  string shows its raw word in yellow rather than reading as `idle`, which used to mean "fine" when
  it meant "an error".
- **Nothing merges unreviewed, red, or stale.** The implementer's standing approval to merge without
  asking comes from the consumer repo's CLAUDE.md ("Four Eye Principle") and applies only to a
  planned bead.
- **Agents never decide anything a user sees**, never take work off another agent (except the
  documented crashed-agent recovery), and never act outside a planned bead.
- Each agent announces its own name in its first message — the human watches several sessions at once.
- **Closed is not terminal.** A failed verification reopens a bead at P0, and every role above
  describes what it does when one comes back — Psylocke reopens it, Xavier amends the plan if the
  plan was wrong, an implementer picks it up like any other P0, and Moira tells the reporter it was
  taken back. A change to any one of those has to keep the others consistent with it.
- **Bishop files, never fixes.** It never edits `packages/`, `crates/`, `apps/` or `emacs/`, and a
  finding that cannot name a cost already being paid — a repeated fix, a change that touched several
  files, a retrospective, a misread module — is not filed at all.

## emacs/cerebro.el

`M-x cerebro` lists the fleet (Xavier, Cerebro, Moira, Psylocke, Bishop + thirteen implementers) with state,
current bead and elapsed time; `s` starts, `k` kills, `f` tells an implementer to finish (writes its
stop flag; the bead in flight is unaffected), `RET` focuses the detail window. Emacs 28+, no
dependencies except optional **vterm** for live sessions.

Under the list, the bead panel (`RET`, `n`/`p`, digits and `+`/`-`/`u` to reprioritise) also shows a
**Sweeps** section: the claims and epics sweeps `agents/orchestrator.md` describes, run every ten
minutes by `scripts/sweep-claims.sh` and `scripts/sweep-epics.sh` (read-only; they gather facts and
mutate nothing), turned into findings by pure decision functions, and hidden entirely when there is
nothing to report. `x` on a finding shows the exact `bd close`/`bd reclaim` it maps to and runs it
only on confirmation. Worktree pruning (`prune-worktrees.sh --watch`) starts automatically alongside
the fleet buffer and needs no confirmation - see `docs/cerebro-jobs.md` for why.

The file is deliberately split into a **pure core** (`cerebro--derive*`, `cerebro--entry`,
`cerebro--*-action`, `cerebro--launch-command`, `cerebro--claim-finding`, `cerebro--epic-finding`,
`cerebro--finding-command`) and a small set of **impure readers** at the bottom (`cerebro--roster`,
`cerebro--read-state-file`, `cerebro--system-args`, `cerebro--owned`, `cerebro--gather-sweeps`). The
tests only exercise the pure half, passing state in as plain data. Keep new logic on the pure side or
it becomes untestable.

Two data sources it depends on, both under `.claude/implementers/` in the consumer repo:

- `<name>.state.json` — `{state: "idle"|"working"|"asking"|"done", phase, bead, since, phase_since,
  pid}`, written by the **implementer itself** at each transition through `scripts/implementer-state`
  (never by hand — see that script's header). The launcher used to write the file and no longer
  does: it `exec`s a session and cannot see it claim a bead. `phase` is one of `build`/`gate`/
  `review`/`ci`/`rebase`/`merge`, meaningful with `working` and `asking`; `since` is the last change
  of `state` or `bead`, `phase_since` the last change of `phase`. Whoever changes the `state`
  vocabulary must change `cerebro--derive-implementer` with it — an unrecognised `state` now maps to
  `'unknown` and shows its raw word in yellow, not `idle`.
- `scripts/run-implementer --roster` — the implementer names, shelled out to from
  `cerebro--roster`.

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
- **`.claude/cerebro/scripts/` is a hard-coded path in two places that must agree**:
  `cerebro--script-directory` in `cerebro.el`, and every doc that tells someone what to type. The
  launchers themselves take no view — they are `exec claude …` and work from anywhere — so a wrong
  path here fails at `s` in the fleet view, not at the script.
- The launchers start **one interactive session** each. Nothing loops, nothing polls a flag, nothing
  writes a state file: the agent writes its own state, and `cerebro--supervise` owns the cadence.
  Adding a loop back to a launcher would put two supervisors on one session.
- Emacs backup files (`*.el~`, `*.md~`, `*.sh~`) are committed alongside the originals; ignore them
  and never edit them.

# Test driven development

Develop the emacs elisp code using test driven development, but do not stop after each phase and ask for user approval.
Instead, continue running until done and ready to commit.
