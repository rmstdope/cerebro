# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Cerebro is an **AI harness**, not an application: agent definitions, skills, docs, a sync script, and
an Emacs fleet viewer. It is consumed by other repositories as a git submodule at `.claude/cerebro`,
whose `scripts/sync-symlinks.sh` symlinks the skills and agents into the consumer's discovery paths,
and `templates/consumer-dir-locals.el` in as the consumer's root `.dir-locals.el` so that `M-x
cerebro` exists for everyone working in that repository.

Almost nothing here executes in this repository. The agents and skills describe a workflow that runs
in a *consumer* repo, and the launchers in `scripts/` only make sense from a consumer root, where
this repo is mounted at `.claude/cerebro`. So a change here is generally not testable by running it
in this tree.

Every project-specific fact is read from `<consumer>/.cerebro/project.conf`
(`scripts/project-conf`), and the fleet's names from `<consumer>/.cerebro/roster.conf`
(`scripts/roster`). Nothing in this repository names a consumer.

## This repository is also a consumer

Since cb-i3l.1 cerebro is mounted in itself, so the fleet works on its own source and this file has
two readers. Everything above is the harness a contributor reads; everything under the four headings
below is what an agent working here reads, and it is the same declaration
`templates/consumer-CLAUDE.md` asks of every other project. The template's own "The project"
section is the one thing not repeated: **What this repository is**, above, already is it.

## Four Eye Principle

*Read by `skills/implement-bead` and `skills/plan-bead` by this exact heading. In a project that
uses cerebro this lives in the consumer's root CLAUDE.md; here that file is this one. An
implementer's standing approval to merge without asking comes from this section and from nowhere
else — delete it and every implementer in this repository builds, opens its pull request, and then
stops.*

Nothing merges unreviewed and nothing merges red.

For a change built by an agent, GitHub Copilot's automatic review counts as the second pair of eyes
when all of these hold: it has reviewed the head commit that is being merged; every comment it left
is answered, by a change or by a posted reply saying why not; and every check is green. That is the
whole standing approval, and it covers a planned bead only.

Everything else needs the navigator — a change nobody planned, a red or missing check, a review
comment answered by neither a change nor a reply, and any pull request that came from outside the
fleet, which is Cypher's to review and the navigator's to merge.

## Work tracking

Planned work is tracked in **beads** (`bd`), with the prefix `cb`; `skills/beads-workflow` carries
the commands. GitHub issues are the external inbox only. Every bead is created unranked at P4 and
ranked later with the navigator; a bead is planned in one session and implemented in another.

The board syncs through the Dolt remote rather than through git — a clone gets the code, `bd sync`
gets the work. That is deliberate, not an omission (cb-4yo): no `.beads/*.jsonl` snapshot is
tracked, the root `.gitignore` keeps a stray `bd export` out of every commit, and
`scripts/lint` advises on it. Reading the board means `bd sync`, never browsing git.

## Development practices

- Work is delivered in small increments that stand on their own.
- Code is written test-first. That is not a style preference here: the two suites are the only thing
  that can tell a change to this harness from a change that quietly breaks every consumer, since
  almost nothing in this repository executes in this repository.
- **Tests assert behaviour; decisions are advisories.** A test here exercises the code this
  repository ships — the elisp in `emacs/` and the bash in `scripts/`. Prose and configuration are
  not code: an agent file, a skill file, a declaration file gets no test, because a suite that
  greps prose fails on the day somebody changes their mind rather than on the day something breaks
  (cb-194 — one line added to the roster turned the gate red in three places). The decisions worth
  guarding live in `scripts/lint`, which runs at the end of `tests/gate` and as a
  `continue-on-error` step in CI, and **never blocks a merge**. An advisory that fires on a
  deliberate change means: update `scripts/lint` in the same pull request. `tests/lint.sh` tests
  the lint's mechanics and never that this tree is clean: a firing advisory is not a red suite, on
  `main` or in CI (cb-ypx).
- A change to a role's agent file or skill changes how the fleet behaves in every consumer. Say so
  in the bead, and keep the invariants above consistent with each other.
- Prefer the simple design; say so when you decline a more general one.

## Where the project declares its facts

Not prose — files, each tracked so that every clone has it.

- `.cerebro/project.conf` — this project's name, default branch, audience, which paths are
  the application, and the gate. Both gates name `tests/gate`, which runs exactly what
  `.github/workflows/ci.yml` runs (cb-i3l.2).
- `.cerebro/roster.conf` — which agents this project runs, and in what order. Absent means the
  built-in fleet. An optional third word, `autostart`, makes the fleet view start that agent as it
  comes up (cb-0r6).
- `.cerebro/traps.md` — the traps this project has already paid for, read by planners and
  implementers before they start. Absent means it has paid for none yet, which is where every
  project starts.

## Commands

The whole gate, which is what an implementer runs before it opens a pull request and what CI runs
on it (cb-i3l.2) — byte-compile, ERT, every `tests/*.sh`:

```bash
bash tests/gate
```

Its three parts, for when only one of them is the question. The Emacs package (ERT):

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit    # all tests
emacs --batch -L emacs -l cerebro-test \
  --eval '(ert-run-tests-batch-and-exit "cerebro-test/elapsed-minutes-hours-days")'   # one test (name or regexp)
```

And the scripts, in plain bash (no framework; each file exits non-zero at its first failed
assertion), run from this repository's root:

```bash
for t in tests/*.sh; do bash "$t"; done    # all of them
bash tests/launchers.sh                     # one suite
```

The advisory lint — the prose and configuration decisions, reported but never blocking:

```bash
bash scripts/lint            # exit 0 clean, 1 when an advisory fired, 2 on a bad root
```

CI (`.github/workflows/ci.yml`) runs both: ERT on Emacs 28.2 and 30.1, and every `tests/*.sh` on
ubuntu-latest. A suite that only passes on macOS is a red PR.

A pull request that touches only `docs/` (except `docs/agent-workflow.md`, which a suite reads),
`README.md`, `LICENSE` or `models.conf.example` runs none of that: `scripts/ci-needed` is the one
place that list lives, with the reason beside each entry, and the three required checks report
*skipped*, which GitHub counts as green (cb-ypx). Anything else runs the whole matrix, and a push
to `main` always does. `scripts/lint` check 12 advises when a suite starts reading a path on that
list.

Sync symlinks into a consumer repo (run from that repo, not this one):

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

## The agent fleet these files describe

Seven roles, each an agent definition in `agents/`; most are backed by a skill in `skills/`. A role is
not a session count — **`planner` is held by two agents, Xavier and Beast** (`scripts/roster --role
planner`), which is the one place a name and a role stop being interchangeable:

- **Xavier** and **Beast** (`planner`, Opus/high) — load `plan-bead`. Turn unplanned beads into
  plans a Sonnet agent could build unattended. Decide architecture themselves; take every
  user-facing decision to the human ("the navigator"). Keep a buffer of planned beads ahead of the
  builders, sized from how many are running (twice the count, never fewer than four). They divide
  the work through the `planning:<name>` label alone, and a whole split family through a
  `planner:<name>` label on its parent — taken before research and pushed at once (after the
  state file names the bead, which is what makes an abandoned label safe to tell apart from a held
  one), freed again by whichever planner finds it held by nobody, and with
  the P4 **triage pass belonging to the first planner on the roster only**, since two triaging
  sessions interview the navigator twice over the same backlog. The buffer counts `planned` beads
  and never held ones: a bead being planned is not claimable, and counting it put both
  planners to sleep over a two-bead queue (ah-2p.1).
- **Cerebro** (`orchestrator`, Opus/medium) — stops implementers on request by writing their stop
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
- **Cypher** (`reviewer`, Opus/high) — loads no separate skill; its whole job lives in
  `agents/reviewer.md`. Reviews **pull requests from outside the fleet** — anyone may open one — on
  five questions: does it do what it says, does it fit the architecture, are the regression tests
  enough, what does it cost the application and CI, and everything else a reviewer owes a project
  (dependencies, secrets, error handling, docs, scope). Interactive by design: **every piece of user
  experience the PR touches is looked at by the navigator, in the running application, before Cypher
  recommends anything.** It comments and recommends; merging, approving and closing stay the
  navigator's. It reviews a PR again when the head sha changes, and never touches the fleet's own
  PRs, which have Copilot and the implementer's own gate.
- **Forge** (`architect`, Opus/xhigh) — loads no separate skill either; its whole job lives
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
- **The state file is the contract, for every agent.** `.cerebro/state/<name>.state.json`
  carries `idle`/`working`/`asking`/`waiting`/`done`; every agent in the fleet writes it, and
  `cerebro.el` acts on it. Since ah-u3i it also carries `phase` (an implementer's `build`/`gate`/`review`/`ci`/`rebase`/
  `merge`, or a role word for the interactive agents since ah-2n3.2, or null) and `phase_since` —
  supervision (`cerebro--supervise-action`) reads `state` alone, never `phase`, so a typo in the
  phase vocabulary can only mislabel a column, never break the restart loop. An unrecognised `state`
  string shows its raw word in yellow rather than reading as `idle`, which used to mean "fine" when
  it meant "an error". **`done` is an implementer's state alone** — `scripts/agent-state` refuses it
  from an interactive name, and a live file that carries it anyway maps to `'unknown` rather than
  being handed to the restart/retire logic as a finished bead. **`waiting` is the mirror image**
  (ah-hiib.3): an interactive role's state alone, refused from an implementer, carrying a `wake_at`
  and meaning *this pass is over and my turn has ended*. It is what removed the sleep loops from
  every role document — the fleet view owns the cadence (`cerebro-wake-intervals`) and wakes a
  waiting role by typing into its session, safe precisely because a waiting role is at its prompt by
  construction. It is also the one state a stop flag lands cleanly on for an interactive role:
  nothing is in flight, so it retires at once. **`asking` has a hook behind it**:
  `hooks/question-state.settings.json` + `scripts/agent-asking`, wired into the whole fleet by the
  two lines `scripts/launch` gives every session (`agent-hooks-env`, `--settings`), flip the file
  for the lifetime of a question tool call, because telling an agent three ways did not make it so.
  The agent files still describe the transitions and must keep doing so — the hook covers the
  question tool, not a question asked in prose, and knows nothing about `idle` versus `working`.
- **Nothing merges unreviewed, red, or stale.** The implementer's standing approval to merge without
  asking comes from the consumer repo's CLAUDE.md ("Four Eye Principle") and applies only to a
  planned bead.
- **Agents never decide anything a user sees**, never take work off another agent (except the
  documented crashed-agent recovery), and never act outside a planned bead.
- Each agent announces its own name in its first message — the human watches several sessions at once.
- **Closed is not terminal.** A failed verification reopens a bead at P0, and every role above
  describes what it does when one comes back — Psylocke reopens it, a planner amends the plan if the
  plan was wrong, an implementer picks it up like any other P0, and Moira tells the reporter it was
  taken back. A change to any one of those has to keep the others consistent with it.
- **An external PR is untrusted code, and reviewing it by building it runs it.** `agents/reviewer.md`
  makes Cypher read the diff — `package.json` scripts, lockfiles, `build.rs`, `.github/`, test files
  — *before* it builds or tests anything, ask the navigator when the PR changes any of them, and run
  only in `.cerebro/worktrees/cypher`, never the shared checkout. It never pushes to a contributor's
  branch and never commits in that worktree.
- **The reviewer gates nothing by itself.** Cypher's review is a recommendation on somebody else's
  PR; the navigator merges. Implementers are unaffected — their path is still Copilot plus the
  standing approval in the consumer's CLAUDE.md.
- **Forge files, never fixes.** If you are editing the project's application paths
  (`scripts/app-paths`), you have taken the wrong job — and so is editing `emacs/`, cerebro's own
  source rather than any consumer's application. A
  finding that cannot name a cost already being paid — a repeated fix, a change that touched several
  files, a retrospective, a misread module — is not filed at all.

## emacs/cerebro.el

`M-x cerebro` lists the fleet (every agent on `scripts/roster` — the interactive roles first, then
the implementers) with state,
current bead and elapsed time; `s` starts, `k` kills, `f` tells an implementer to finish (writes its
stop flag; the bead in flight is unaffected), `RET` focuses the detail window. Emacs 28+, no
dependencies except optional **vterm** for live sessions.

Under the list, the bead panel (`RET`, `n`/`p`, digits and `+`/`-`/`u` to reprioritise) partitions
one `bd` call into Claimed / Planned, unclaimed / **Being planned** (the word `planning`, or
the word and a `:` and the holder's name, which is what a planner holds
mid-bead — never counted as buffer, since nobody can claim it) / Unplanned / Merged, unverified. It
also shows a
**Sweeps** section: the claims and epics sweeps `agents/orchestrator.md` describes, run every ten
minutes by `scripts/sweep-claims.sh` and `scripts/sweep-epics.sh` (read-only; they gather facts and
mutate nothing), turned into findings by pure decision functions, and hidden entirely when there is
nothing to report. A sweep is **one row of `cerebro--sweeps`** — key, script, finding function, which
fleet slices it needs, an optional label enrichment; adding one is a row, a `cerebro--<x>-finding`, a
`cerebro--sweep-label` arm and a `cerebro--finding-command` arm, and
`cerebro-test/a-sixth-sweep-is-one-row` proves the row alone is enough for the runner (cb-4s8). `x` on a finding shows the exact `bd close`/`bd reclaim` it maps to and runs it
only on confirmation. Worktree pruning (`prune-worktrees.sh --watch`) starts automatically alongside
the fleet buffer and needs no confirmation - see `docs/cerebro-jobs.md` for why.

The file is deliberately split into a **pure core** (`cerebro--derive*`, `cerebro--entry`,
`cerebro--*-action`, `cerebro--launch-command`, `cerebro--claim-finding`, `cerebro--epic-finding`,
`cerebro--finding-command`, `cerebro--findings-from-snapshot`) and a small set of **impure readers**
at the bottom (`cerebro--fleet`, `cerebro--roster`, `cerebro--read-state-file`,
`cerebro--system-args`, `cerebro--owned`, `cerebro--gather-sweeps`, `cerebro--fleet-snapshot`). The tests only exercise the pure half, passing state in as plain data. Keep
new logic on the pure side or it becomes untestable.

Two data sources it depends on, both under `.cerebro/state/` in the consumer repo:

- `<name>.state.json` — `{state: "idle"|"working"|"asking"|"waiting"|"done", phase, bead, since,
  phase_since, wake_at, pid}`, written by **the agent itself** at each transition through
  `scripts/agent-state` (never by hand — see that script's header). Every implementer writes one, and since ah-2n3.2 so does each of
  the interactive agents, `done` excepted. The launcher used to write the file and no longer does: it
  `exec`s a session and cannot see it claim a bead. `phase` is one of `build`/`gate`/`review`/`ci`/
  `rebase`/`merge` for an implementer, or a role word (`triage`/`plan`, `prepare`/`verify`, `sweep`,
  `sweep`/`release`, `daily`/`weekly`) for the interactive agents — meaningful with `working` and
  `asking`; `since` is the last change of `state` or `bead`, `phase_since` the last change of
  `phase`. Whoever changes the `state` vocabulary must change `cerebro--derive-from-state` with it —
  an unrecognised `state` now maps to `'unknown` and shows its raw word in yellow, not `idle`. **The
  fleet view deletes the file when it ends the session the file describes** — every path that ends
  one, because a killed agent cannot write a last transition and a file that outlives its session
  outlives its pid. There is one owner of that: `cerebro--end-session`, which removes the buffer and
  the `cerebro--sessions` entry (`cerebro--forget-session`), always the state file, and the stop flag
  only when its caller asks. Its three callers are `cerebro--supervise`'s retire (flag cleared) and
  restart branches (deletion before the launch), and `k` (`cerebro--kill-session-buffer`, flag left
  alone — `f` then `k` means stay gone). Enumerating two of the three is how the same omission came
  to be fixed twice while `k` went on leaking a state file (ah-bqi); add a fourth caller by calling
  that function, not by listing artifacts again.
- `scripts/roster` — the fleet: name, role and kind per agent, read once per buffer by
  `cerebro--fleet`.

Liveness for the interactive agents is the state file first, when one exists for a live pid
(`cerebro--derive-interactive`), and falls back to scanning system process args for `--name <Name>`
when it does not — a session started by hand, outside this fleet, has no file and still shows `up`.

**"A live pid" means the agent's own session, not merely an existing pid.**
`cerebro--session-alive-p` reads the named pid's command line and requires `--name <Name>` in it,
which every session has because `scripts/launch` passes it, **and a `--settings` path under this
consumer's root** — the third discriminator (cb-lzi), because a name is unique inside one consumer
and not on the machine. The rule is stated once, in `cerebro--session-args-p`; the state-file path
(`cerebro--session-alive-p`) and the process-scan path (`cerebro--consumer-args` then
`cerebro--name-in-args-p`) are both built from it. A bare `process-attributes` check was
what let a `done` file that outlived its session by ten hours light up green again once the OS
recycled its pid onto an unrelated daemon: pids are reused, so a number alone is not an identity.
The same check guards the claims sweep (`cerebro--live-implementer-names`), where a recycled pid
would otherwise protect a stale claim from being reclaimed.

**The shell has the same rule, in `scripts/agent-alive <Name>`** — exit 0 alive, 1 dead, 2 for a
usage error or a name that is not on the roster, so a typo can never read as "not running". It is
what `skills/plan-bead/SKILL.md` calls in both places it needs liveness: sizing the buffer from the
running implementers, and deciding whether a `planning:` label is still held. Anything in bash that
needs to know whether an agent is up calls this; a bare `kill -0` there is the pre-ah-bqi shape, and
it makes a dead planner look alive, which strands the very label the reclaim loop exists to free.
It is the bash copy of `cerebro--session-args-p` — pid, name and root — and `tests/agent-alive.sh`
mirrors the ERT cases so the two cannot drift apart again (they did, twice: `7bd5962`, `9420ff2`).

## Gotchas

- `.cerebro/` is the harness's own directory in the consumer — agent state files, stop flags and
  agent worktrees (ah-v82), **and since cb-epr the project's own declarations** (`project.conf`,
  `roster.conf`, `traps.md`). So the consumer's `.gitignore` names the
  two things the fleet writes while it runs — `.cerebro/worktrees` and `.cerebro/state` — and
  tracks the rest: the declarations, and `models.conf`, which this project commits so every clone
  runs the same models (`eb6ffdb`; a project that wants it personal ignores it). A deny-list rather
  than everything-except: the price is that a new runtime artifact has to be added to it, and that
  price was taken so models.conf could be tracked without a negation per tracked file. `.claude/` holds only what Claude
  Code itself discovers (`agents/`, `skills/`, `settings.json`) plus this repository's own
  submodule mount.
- **This repository is a consumer of itself** (cb-i3l.1). `.claude/cerebro` is a committed symlink
  back to the checkout, so every path the harness assumes — `.claude/cerebro/scripts/launch`, the
  `../cerebro/...` links the sync writes — is literally true here, and the fleet runs the *working
  tree* rather than a pinned sha. A submodule of the repository inside itself would have satisfied
  `consumer-root` with no code at all, and was rejected for a different reason: `git submodule
  update --init --recursive`, which `launch-preflight` runs, has no fixed point on a repository that
  contains itself. **One script knows about the mount**: `consumer-root`, whose
  `mount_resolves_to` is the round trip through it, exposed as `--self-mounted` and `--mount`;
  `roster` and `sync-symlinks.sh` ask it (cb-akc), and `scripts/lint` advises if the round trip is
  ever spelled anywhere else. `prune-worktrees.sh` is the documented exception and keeps its git-dir
  comparison: it asks whether the mount and the consumer are **one repository**, so that one
  `git worktree list` covers both, and that parts company with the round trip for a vendored plain
  copy at the standard mount — where the mount is an ordinary directory of the consumer's own repo. A worktree carries the same committed
  symlink, which resolves to the worktree, so an implementer reads its own branch's skills.
- `scripts/agent-alive <Name>` is the one place bash answers "is this agent up" (see above). A
  predicate, not a writer, so it is its own script rather than a mode of `scripts/agent-state`: it
  prints nothing and the exit status is the whole answer, since it runs once per agent on every
  planner pass.
- `scripts/app-paths` is the one place "which paths are this project's application" is answered
  (ah-qled.6) — the `app_paths` key, and `--classify <path>...` over changed paths. Unlike every
  other reader here it **fails when it does not know**: no declaration means exit 3 and a line on
  stderr, never a guess. A default either way was the defect — "matches nothing" gave a consumer
  empty release notes and no verifications with nothing on stderr, and "matches everything" sends
  the navigator to verify docs changes. A caller that cannot classify says so.
- `scripts/consumer-root` is the one place "where is the consumer root" is answered (ah-e0w). Every
  other script that needs it asks this one rather than deriving it itself — `consumer-root` (no
  argument) for the enclosing working tree (main checkout, or a bead worktree when this copy is the
  worktree's own submodule) and `consumer-root --shared` for the main working tree every worktree of
  the repository shares, which is where the fleet view reads state files and where the sweeps look.
  Both start from `${BASH_SOURCE[0]}`: first the validated `../../..` climb, which needs no git and
  keeps the launchers' narrowed-PATH guarantee true at the standard mount, then — only if that fails
  — asking git which working tree holds this checkout as a submodule
  (`--show-superproject-working-tree`, which answers at any mount — ah-ohc2). That order matters: the
  probe answers about whatever repository the checkout belongs to, so for a plain *copy* at the
  standard mount inside a consumer that is itself a submodule it would name the grandparent.
  `scripts/roster` asks this script for its root rather than resolving one of its own (cb-akc). So
  `.claude/cerebro/scripts` is load-bearing only for a consumer that vendors cerebro as a plain copy;
  a submodule may be mounted anywhere. To test a change, build a throwaway consumer repo rather than running
  the script here (it will refuse: there is no `.claude/` above this tree). Since cb-akc it is also
  the one place "how is this checkout mounted in it" is answered — `--self-mounted` and `--mount`.
- `scripts/sync-symlinks.sh` and `githooks/` only ever run in a **consumer** repo. `sync-symlinks.sh`
  asks `consumer-root` for the enclosing tree — a worktree syncs its own links, which is what lets a
  submodule-bump PR commit them (ah-cuc). It writes one link outside `.claude/`: the consumer's root
  `.dir-locals.el`, pointing at `templates/consumer-dir-locals.el`, which is what makes `M-x cerebro`
  available to every contributor without one of them editing their init. It is the one file the sync
  **may not merge** — Emacs reads exactly one per directory — so a consumer that already has one, or
  that has pointed that path at something of its own, keeps it and gets a line on stderr instead.
  The two git hooks ask git directly (`--show-toplevel`) rather than `consumer-root`: a hook's cwd
  is already inside the tree it fires in, so the enclosing tree is `--show-toplevel` by definition.
- `githooks/install.sh` sets `core.hooksPath`, which is repository-wide and replaces `.git/hooks`
  entirely. It refuses rather than clobbering a `core.hooksPath` already pointing elsewhere.
- **`hooks/` and `githooks/` are different mechanisms.** `githooks/` is git; `hooks/` holds Claude
  Code hook settings `scripts/launch` passes to `claude --settings` (see `hooks/README.md`). The settings
  file names no paths of its own — it runs `"$CEREBRO_SCRIPTS/agent-asking"`, and sourcing
  `scripts/agent-hooks-env <Name>` exports `CEREBRO_SCRIPTS` and `CEREBRO_AGENT_NAME` (which the
  hook subprocess inherits through `claude`) and sets `CEREBRO_HOOK_SETTINGS` for the `--settings`
  flag. Source it *and* pass the flag: doing one without the other gets hooks that silently do
  nothing, which is by design — `agent-asking` exits 0 rather than failing a question.
- **The model an agent runs on is the agent definition's `model:`, unless the consumer overrides it.**
  `scripts/launch` reads `<consumer>/.cerebro/models.conf` if it exists — `<name|role|default>
  <model|-> [effort]`, most specific key wins, `-` meaning "pass no `--model`" — and says on stderr
  which key it matched, so an unexpected model is traceable to the file nobody remembers editing. A
  `--model` on the command line still wins, since it is appended after. `models.conf.example` is the
  documented copy; the live file is consumer-side and uncommitted, which is what makes switching the
  fleet between Opus and Fable a one-line edit rather than a submodule change every consumer shares.
- `scripts/launch-preflight <role> <name>` runs before every launch. It refuses (exit 2, one line on
  stderr) if `claude` is not on `PATH`; the symlink sync it runs is consumer-only, same as
  `sync-symlinks.sh` — it does nothing beyond the `claude` check unless it is sitting inside a
  consumer's `.claude/cerebro`. Inside a consumer it also refuses if the submodule never brought that
  role's `agents/<role>.md` in, before ever syncing — a launcher used to go `up` for a moment and
  then silently `dead` when the file was missing (ah-bri). Every launcher calls it right before
  `exec claude`, so a submodule bump is usable the moment something is started rather than only after
  someone runs `sync-symlinks.sh` by hand (ah-cuc); this is what the git hooks in `githooks/` would
  otherwise be for, and why they stay optional.
- **`.claude/cerebro/scripts/` is a hard-coded path in two places that must agree**:
  `cerebro--script-directory` in `cerebro.el`, and every doc that tells someone what to type. The
  launchers themselves take no view — they are `exec claude …` and work from anywhere — so a wrong
  path here fails at `s` in the fleet view, not at the script.
- `scripts/launch <Name>` starts **one interactive session**, and is the only way one is started
  (ah-qled.5.3 removed the seven `run-*` shims that used to name it). Nothing loops, nothing polls
  a flag, nothing writes a state file: the agent writes its own state, and `cerebro--supervise`
  owns the cadence. Adding a loop back to `launch` would put two
  supervisors on one session. The one file it does touch is the symlinks, via
  `scripts/launch-preflight`, right before it execs — see above.
- Emacs backup files (`*.el~`, `*.md~`, `*.sh~`) are committed alongside the originals; ignore them
  and never edit them.
- The state directory was `.claude/implementers/` until ah-2n3.1, and its writer was
  `scripts/implementer-state`. Both names are gone: `scripts/agent-state` is the writer, and the
  rename shim was removed once a release of the consumer had carried it (ah-qled.5.3).
- **A consumer declares its own fleet in `<consumer>/.cerebro/roster.conf`** (ah-qled.5.1) — same
  `NAME  ROLE` shape as the `TABLE=` heredoc in `scripts/roster`, `#` comments and blank lines
  ignored, `KIND` still derived, and an optional third word `autostart` read by `roster --autostart`
  alone — the three default columns never change, since `launch`, `agent-state` and
  `cerebro--parse-fleet` all take the last field as the KIND; any other third word, or a fourth,
  refuses with exit 2 naming the file, line and word, and `M-x cerebro` shows that refusal rather
  than an empty fleet (cb-0r6). When it exists and is non-empty it **replaces** the built-in table
  rather than merging with it, because file order is load-bearing (first planner triages; Cerebro
  takes implementer names in file order). It is **tracked**, beside `.cerebro/project.conf`, by a
  `.gitignore` negation inside the otherwise-ignored `.cerebro/` (cb-epr): which agents exist is a
  fact every clone needs, and an ignored declaration vanishes on a fresh clone. `roster`
  asks `consumer-root` for the root (cb-akc) — the one resolver, whose git step is optional and
  whose failure is swallowed, so the launchers' narrowed-PATH guarantee (`dirname` and `bash`
  alone, `tests/launchers.sh`) still holds and is what guards it; a submodule mounted elsewhere
  (`vendor/cerebro`, ah-ohc2) is found through git when git is there. At that root a file still at
  the retired `.claude/cerebro-roster`
  with none at the new path **exits 2 naming the `mv`** rather than falling back: absence is the
  documented "run the built-in fleet" signal, and a stale path borrowing it would silently give a
  consumer nineteen names it never declared. `project-conf` and `launch-preflight` refuse the same
  way, and the reader-level refusal is the load-bearing one — `M-x cerebro` reaches `roster`
  without ever passing through a preflight. A role only the
  consumer declares needs `<consumer>/.claude/agents/<role>.md`; `scripts/launch` prefers that
  directory over the submodule's, and `launch-preflight` says which of the two causes is missing
  rather than always blaming the submodule.
- **The fleet is declared once, in `scripts/roster`.** Adding a role is one line there plus
  `agents/<role>.md` (and a skill if it has one); `launch`, `agent-state`, `cerebro.el` and the tests
  read the roster, and the model and effort come from the agent file's frontmatter. The only per-role
  facts still written by hand are the phase words in `cerebro--phases` (`scripts/agent-state` accepts
  any well-formed word since ah-qled.5.2, so the list lives in one place).

# Test driven development

Develop the emacs elisp code using test driven development, but do not stop after each phase and ask for user approval.
Instead, continue running until done and ready to commit.
