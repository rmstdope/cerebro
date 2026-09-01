# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Cerebro is an **AI harness**, not an application: agent definitions, skills, docs, a sync script, and
an Emacs fleet viewer. It is consumed by other repositories as a git submodule at `.claude/cerebro`,
whose `scripts/sync-symlinks.sh` symlinks the skills and agents into the consumer's discovery paths,
and `scripts/cerebro` opens the fleet view (`M-x cerebro`, in a fresh Emacs) for everyone working in
that repository.

Almost nothing here executes in this repository. The agents and skills describe a workflow that runs
in a *consumer* repo, and the launchers in `scripts/` only make sense from a consumer root, where
this repo is mounted at `.claude/cerebro`. So a change here is generally not testable by running it
in this tree.

The one exception, since the `cb-vyp` family, is `fleet-view/` — a Rust workspace whose
`cerebro-tui` binary **does** run here, and is the one thing in this repository a person can start
and look at. It is a **reader**: it draws the fleet and the bead panel from the same contracts
`M-x cerebro` reads and writes nothing at all. Emacs remains the sole supervisor.

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

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself** — given the diff and the bead, never the implementer's own reasoning — and it
counts when all of these hold: at least one usable review covers the exact head being merged; it is
posted in full on the pull request; every finding from every usable round is answered, by a change or
by a posted reply saying why not; and every check is green. Failed or unusable attempts may be retried,
but three unusable attempts for one head require the navigator. That is the whole standing approval,
and it covers a planned bead only.

No review is asked of GitHub, and none is waited for. A review a person or a bot leaves on the
pull request anyway is read and answered like any other comment; it is not what the approval
rests on.

Everything else needs the navigator — a change nobody planned, a red or missing check, a finding
about approach, scope or what the audience sees, a finding answered by neither a change nor a
reply, a review sub-agent that could not be spawned or returned nothing usable, and any pull
request that came from outside the fleet, which is Cypher's to review and the navigator's to
merge.

## Work tracking

Planned work is tracked in **beads** (`bd`), with the prefix `cb`; `skills/beads-workflow` carries
the commands. GitHub issues are the external inbox only. Every bead is created unranked at P4 and
ranked later with the navigator; a bead is planned in one session and implemented in another.

The board syncs through the Dolt remote rather than through git — a clone gets the code, `bd`
gets the work. That is deliberate, not an omission (cb-4yo): no `.beads/*.jsonl` snapshot is
tracked, and the root `.gitignore` keeps a stray `bd export` out of every commit. Reading the
board means asking `bd`, never browsing git.

**A fresh clone runs `bd bootstrap`**, which reads `sync.remote` from `.beads/config.yaml` and
clones the board from `refs/dolt/data` on the git remote; after that it is `bd dolt pull` and
`bd dolt push`. There is no `bd sync` — this file said there was until somebody installed bd and
found out, which cost an afternoon of "the board is empty". `bd bootstrap` refuses if a database
already exists, so a `bd list` run before the bootstrap leaves an empty `cb` that has to be moved
aside first.

## Development practices

- Work is delivered in small increments that stand on their own.
- Code is written test-first. That is not a style preference here: the suites are the only thing
  that can tell a change to this harness from a change that quietly breaks every consumer, since
  almost nothing in this repository executes in this repository. `fleet-view/` is held to the same
  rule by `cargo test`, and more strictly: it is the one part that *does* run here, so a test that
  fails is a screen a navigator would have seen.
- **Tests assert behaviour, and nothing else is checked mechanically.** A test here exercises the
  code this repository ships — the elisp in `emacs/` and the bash in `scripts/`. Prose and
  configuration are not code: an agent file, a skill file, a declaration file gets no test, because
  a suite that greps prose fails on the day somebody changes their mind rather than on the day
  something breaks (cb-194 — one line added to the roster turned the gate red in three places).
  These decisions were guarded by an advisory `scripts/lint` for a while, and that is gone too: over
  its whole life it fired on no tree and in no CI run, while a quarter of the commits in that period
  edited it. **So the invariants in this file are kept by reading it, not by a grep.** Anything
  that matters enough to guard mechanically is worth restating as behaviour, in a suite, over code —
  and a class of defect earns a check the *second* time it happens, not the first.
- A change to a role's agent file or skill changes how the fleet behaves in every consumer. Say so
  in the bead, and keep the invariants above consistent with each other.
- Prefer the simple design; say so when you decline a more general one.

## Where the project declares its facts

Not prose — files, each tracked so that every clone has it.

- `.cerebro/project.conf` — this project's name, default branch, audience, which paths are
  the application, which agent CLI its sessions run on (`agent_cli`, answered by
  `scripts/agent-cli` — `claude` or, since cb-d59.6, `copilot`, both runnable rather than one
  planned; absent means `claude`), and the gate. Both gates name `tests/gate`, which runs exactly what
  `.github/workflows/ci.yml` runs (cb-i3l.2). Since the `cb-vyp` family it also declares the Rust
  build — `rust_paths` (what `scripts/build-workload --classify` calls a Cargo workload),
  `install`, `prewarm`, `disk_floor_gb`, `reclaim_dirs` and `cargo_reclaim_packages` — and one
  launch target, `launch_tui` → `.claude/cerebro/scripts/cerebro-tui`, which is the one thing here
  a navigator can start and look at. `verification none` is gone with it: a merged bead that
  touched the fleet view is verified by running it.
- `.cerebro/roster.conf` — which agents this project runs, and in what order. Absent means the
  built-in fleet. An optional third word, one of two: `autostart` makes the fleet view start that
  agent as it comes up (cb-0r6), `standby` **arms** it without starting it (cb-98u) — its row reads
  `standby` and its role's own trigger is what starts it. `standby` on an implementer row arms it
  the same way (cb-1or.2); its trigger is a planned, unclaimed bead.
- `.cerebro/traps.md` — the traps this project has already paid for, read by planners and
  implementers before they start. Absent means it has paid for none yet, which is where every
  project starts.

## Commands

The whole gate, which is what an implementer runs before it opens a pull request and what CI runs
on it (cb-i3l.2) — byte-compile, ERT, every `tests/*.sh`, and the locked Cargo tests:

```bash
bash tests/gate
```

Its four parts, for when only one of them is the question. The Emacs package (ERT):

```bash
emacs --batch -L emacs -l cerebro-test -f ert-run-tests-batch-and-exit    # all tests
emacs --batch -L emacs -l cerebro-test \
  --eval '(ert-run-tests-batch-and-exit "cerebro-test/elapsed-minutes-hours-days")'   # one test (name or regexp)
```

And the scripts, in plain bash (no framework; each file exits non-zero at its first failed
assertion), run from this repository's root:

```bash
bash scripts/suite-runner tests             # all of them, each named as it starts
bash tests/launchers.sh                     # one suite
```

And the Rust workspace (`fleet-view/`, the `cerebro-tui` binary), from this repository's root:

```bash
cargo test --workspace --all-targets --locked          # model, readers, app, renderer, binary
cargo test --workspace --locked work_reader            # one test, or a substring of one
```

`--locked` everywhere, including in `scripts/cerebro-tui`: a gate that re-resolved a dependency
would run something no gate has ever seen. `--all-targets` because a test-only compile error
otherwise hides behind a green `cargo build`. `/target` is gitignored, and a Rust change needs
`scripts/disk-preflight --workload rust` before it starts — several worktrees each keep a build
tree, and running out of disk announces itself as a linker fault rather than as a full disk.

`scripts/suite-runner` names each suite before it runs it and replays a failing suite's output, so a
stalled suite is identifiable by name; both `tests/gate` and CI call it, which is what keeps the one
loop from being written twice (cb-8cn). Suites run **in parallel, one per processor** by default
(`--jobs N` to change it, `--jobs 1` for one at a time — the same output either way); on the
navigator's ten-core machine that took the bash half of the gate from 185s to 83s (cb-x05). Results
therefore arrive in completion order, and each failing suite's output is replayed after every suite
has ended rather than inline. What makes it safe is that every suite builds its fixtures under its
own `$work_dir` — a new suite that reaches outside it breaks the whole gate, not just itself.

Every run also keeps each suite's full output — passing and failing alike — under
`.cerebro/state/suite-logs/<YYYYmmdd>-<HHMMSS>-<pid>/<suite>.log`, the last three runs, pruned at
the start of a run; `--log-dir DIR` moves the root, and a red run names its directory on stderr
(cb-kf8) — written relative to the caller's working directory, reported as an absolute path
(cb-wxr), since the line outlives the directory it was printed from. A run never prunes its own
directory, whatever else is in the root (cb-1h8): the names sort lexically and two runs inside one
second are ordered by pid as a string, so a run that sorted first used to delete the directory it
was writing into and fail every suite with a missing log. The path is already
gitignored, here and in every consumer. Before it, the only record of
a red gate was terminal scrollback, and the re-run an implementer does first is what destroyed it.

Every suite sources `tests/lib/consumer.sh` for `fail`/`pass`, `git_q`, its work directory and the
two throwaway-consumer shapes (`consumer_new`, `consumer_with_submodule`); `tests/lib/` is a
directory precisely so the gate's `tests/*.sh` glob never runs it as a suite (cb-dul). A suite keeps
its own assertions and any fixture that is not a consumer — a worktree fabricator, a corpus
directory. The library installs the one EXIT trap, so a suite adds to it with
`cleanup_add` rather than writing a `trap` that would silently replace it, and does its own killing
in a `suite_cleanup` the trap calls first. `tests/consumer-lib.sh` is the library's own suite.

Every suite's last line is `suite_passed`, and that is not decoration: a suite that dies partway
through under `set -euo pipefail` can reach the EXIT trap with `$?` already 0 and be reported
green, so the trap refuses to exit 0 unless the suite reached its end or failed an assertion. A
new suite that forgets the line is red, which is the safe direction.

A rule whose grep or awk fails is itself an advisory naming the rule and the step, never an `ok`
line — `|| true` could not tell a no-match from a grep that never ran (cb-u5e).

CI (`.github/workflows/ci.yml`) runs all of it: ERT on Emacs 28.2 and 30.1, every `tests/*.sh` on
ubuntu-latest, and `cargo test --workspace --all-targets --locked`. A suite that only passes on
macOS is a red PR, and so is a Rust test that only passes on the developer's own `bd`.

A pull request that touches only `docs/` (except `docs/agent-workflow.md`, which a suite reads),
`README.md`, `LICENSE` or `models.conf.example` runs none of that: `scripts/ci-needed` is the one
place that list lives, with the reason beside each entry, and the three required checks report
*skipped*, which GitHub counts as green (cb-ypx). The predicate answers on stdout, in
`$GITHUB_OUTPUT`'s own `run=true|false` shape, so the workflow appends it unread and a crashed
predicate is a red step rather than a skipped one. Anything else runs the whole matrix, and a push
to `main` always does. **Nothing checks that list against what the suites actually open** — a new
suite that starts reading a path on it makes a green pull request that should have been red, so a
suite that reads `docs/`, `README.md`, `LICENSE` or `models.conf.example` must edit
`scripts/ci-needed` in the same pull request. The two ERT jobs are literal, not a matrix, because a skipped matrix job never expands into
the per-version check names branch protection requires.

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
  builders, sized from the roster's implementers minus any told to finish (one each, never fewer
  than two) and refilled one bead per pass, with no wake interval to wait out — the rule itself lives in `scripts/planner-buffer`,
  which the skill calls and `cerebro-test/the-trigger-counts-what-planner-buffer-counts` holds the
  fleet view to. They divide
  the work through the `planning:<name>` label alone, and a whole split family through a
  `planner:<name>` label on its parent — taken before research and pushed at once (after the
  state file names the bead, which is what makes an abandoned label safe to tell apart from a held
  one), freed again by whichever planner finds it held by nobody. The buffer counts `planned` beads
  and never held ones: a bead being planned is not claimable, and counting it put both
  planners to sleep over a two-bead queue (ah-2p.1).
- **Cerebro** (`orchestrator`, Opus/medium) — stops implementers on request by writing their stop
  flag; it cannot start one, since that means starting a session. Ranks the P4 backlog with the
  navigator (the triage pass that was the first planner's until cb-5lx.1). **Starts nothing on its
  own** — and is itself started by the fleet view, or typed a line by it, for one thing: an unranked
  bead (cb-5lx.2). The
  worktree, claims and epics sweeps it used to run on a timer now run from the fleet view itself
  (`ah-4ao`; see `docs/cerebro-jobs.md`); what is left for a Cerebro session is handing a release
  request to the project's own release skill, diagnosing a stuck implementer, and anything needing a forced reassignment.
- **implementer** (Sonnet) — loads `implement-bead`. One bead per session: claim, build test-first in
  its own git worktree, PR, spawn a `reviewer` sub-agent and answer what it finds, merge, close, end
  its pass with `waiting`.
  Interactive, so it cannot end itself — the Emacs fleet view ends it and starts a fresh session when
  a planned bead exists, which is what keeps a session's context one bead deep.
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
  PRs **as a session** — those are reviewed at merge time by a sub-agent loading `agents/reviewer.md`
  in its second mode, which is the one part of Cypher every fleet change now passes through.
- **Forge** (`architect`, Opus/xhigh) — loads no separate skill either; its whole job lives
  in `agents/architect.md`. One sweep per session: reads what merged since its watermark (daily) or
  the whole codebase (weekly), and files a `Refactoring:` bead at P4 for each smell that names a cost
  already being paid, never a fix. Watermark kept in bd memory, and it is the only gate: woken hourly
  by the fleet view, every session reads every commit and retrospective added since it, and an empty
  range costs a `git log` and a line. Ends its own turn when the sweep is
  reported — the one role here that does not loop, because it holds no claim, lease or PR to strand.

`skills/project-definition` is the one skill no role loads. The navigator invokes it by hand as
`/project-definition`, once, in a consumer that holds nothing but a README and the harness: it
interviews them about the software as a whole, writes the declarations, the root `CLAUDE.md` and the
board with its Dolt remote, and files the opening epics and their obvious children. Everything it
files is unplanned, because a planner plans against code that by then exists.

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
  carries `idle`/`working`/`asking`/`waiting`; every agent in the fleet writes it, and
  `cerebro.el` acts on it. Since ah-u3i it also carries `phase` (an implementer's `build`/`gate`/`review`/`ci`/`rebase`/
  `merge`, or a role word for the interactive agents since ah-2n3.2, or null) and `phase_since`; `standby` is
  the one state no file ever carries, being derived from what this Emacs armed and has not seen die
  abnormally since (cb-5yr, cb-eat) — a refused launch is `dead` with its last line on the row,
  never `standby`, and since cb-ccl that line comes from the launcher's own `errors.jsonl` entry
  (`scripts/launch-refused`) when vterm has not drawn it yet; a name that died silently
  `cerebro-give-up-after` times running is `dead` too, and only `s` brings it back —
  supervision (`cerebro--supervise-action`) reads `state` alone, never `phase`, so a typo in the
  phase vocabulary can only mislabel a column, never break the supervision loop. An unrecognised `state`
  string shows its raw word in yellow rather than reading as `idle`, which used to mean "fine" when
  it meant "an error". **`waiting` is every agent's end-of-pass state** (ah-hiib.3, cb-5yr,
  cb-1or.1), meaning *this pass is over and my turn has ended* — an implementer's bead merged and
  closed, one handed back, or nothing to claim. The fleet view ends that session half a minute later
  (`cerebro-end-grace`), keeps its buffer as the record of the pass, and starts a fresh one on the
  agent's own trigger (`cerebro--trigger`) — for an implementer, a planned, unclaimed bead — so a
  session's context is one pass deep the way an implementer's is one bead deep.
  `cerebro-wake-intervals` survives it as the minimum gap between two *starts* of one role. A stop
  flag on a waiting agent ends it and disarms it. **`done`, the implementer's older spelling of it,
  is retired (cb-1or.2)**: `scripts/agent-state` refuses it like any unknown word, and a live file
  that carries it anyway maps to `'unknown` and is never acted on. **`asking` has a hook behind it**:
  `hooks/question-state.settings.json` + `scripts/agent-asking`, wired into the whole fleet by the
  two lines `scripts/launch` gives every session (`agent-hooks-env`, `--settings`), flip the file
  for the lifetime of a question tool call, because telling an agent three ways did not make it so.
  The agent files still describe the transitions and must keep doing so — the hook covers the
  question tool, not a question asked in prose, and knows nothing about `idle` versus `working`.
- **Nothing merges unreviewed, red, or stale.** The implementer's standing approval to merge without
  asking comes from the consumer repo's CLAUDE.md ("Four Eye Principle") and applies only to a
  planned bead.
- **A role more than one agent holds is started one at a time.** The planners answer the same buffer
  rule off the same panel, so a tick where it is true is true for both, and the view started Xavier and
  Beast in one breath. They then race for one candidate over the startup window the planner bullet
  above describes — launch to that `planning:` label reaching the remote, about a minute on this
  fleet — and not over research time. The implementers are the same shape since cb-1or.1: a queue that
  fills is a condition true for every standby builder on one tick.
  `cerebro-role-start-spacing` holds the second for 30s; it counts
  peers only, so a role is never held by its own restart.
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
  PR; the navigator merges. Implementers are unaffected — their path is a `reviewer` sub-agent they
  spawn for themselves plus the standing approval in the consumer's CLAUDE.md.
- **Forge files, never fixes.** If you are editing the project's application paths
  (`scripts/app-paths`), you have taken the wrong job — and so is editing `emacs/`, cerebro's own
  source rather than any consumer's application. A
  finding that cannot name a cost already being paid — a repeated fix, a change that touched several
  files, a retrospective, a misread module — is not filed at all.

## emacs/cerebro.el

`M-x cerebro` lists the fleet (`scripts/cerebro` opens it from a terminal) — every agent on
`scripts/roster`, the interactive roles first, then the implementers — with state,
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
`cerebro--finding-command`, `cerebro--findings-from-snapshot`, `cerebro--triage-action`,
`cerebro--triage-message`) and a small set of **impure readers**
at the bottom (`cerebro--fleet`, `cerebro--roster`, `cerebro--read-state-file`,
`cerebro--system-processes`, `cerebro--owned`, `cerebro--gather-sweeps`, `cerebro--fleet-snapshot`). The tests only exercise the pure half, passing state in as plain data. Keep
new logic on the pure side or it becomes untestable. The one qualification: **each impure reader
has one ERT case that runs it for real and feeds its output to the pure function that consumes
it** (the "Reader contracts" section of `emacs/cerebro-test.el`). A pure function tested
exhaustively against invented inputs can still be wrong about every real one — cb-5yr shipped with
the liveness rule comparing an abbreviated `~/…` root against absolute command lines, four green
cases and all of them fed absolute roots (cb-os4). So a value that is a *display* spelling — an
abbreviated path, a relative path, a formatted time — is normalised by the reader that produces it
(`cerebro--repo-root` through `cerebro--canonical-root`), never assumed canonical by a comparator,
and a new reader is not done until its contract case exists.

It writes two of its own beside them. **`.cerebro/state/errors.jsonl`** is the short one and the
one to be pointed at: a line per thing that went wrong — `{event, ts, context, message}`, where
`context` names the part of the view it came from (`autostart`, `roster`, `launch`, `sweep`,
`supervise <Name>`). Every path that used to demote an error to a message goes through
`cerebro--with-logged-errors` or `cerebro--report-error`, which say the same words in the echo area
*and* keep them, because the echo area is painted over by the next render and a fleet that failed to
start half an hour ago has no other trace. It is a separate file from the one below for the
one reason that matters: the navigator is sent to it by opening it, which a hundred thousand
evaluations a day would make useless. An error is written at every verbosity but `none` — `none`
means nothing at all, which is what the suite binds.

**`.cerebro/state/decisions.jsonl`** is the loud one: a line per decision —
start (with the trigger that fired), end, retire, nudge, sweep run, abnormal exit — and, at
`cerebro-log-verbosity` `evaluations` (the default), a line per trigger evaluation per tick carrying
what the trigger read and whether `cerebro--unless-unchanged` is what held it. That last is the only
observable trace of a decision *not* to start, which is otherwise indistinguishable from a bug.
`changes` logs an evaluation only when its answer differs from that agent's last; `decisions` logs
none. Both files rotate on `cerebro-log-max-bytes` × `cerebro-log-generations` — one policy, since
a healthy fleet never fills the error log at all. The pure half is `cerebro--log-line`,
`cerebro--log-event-p`, `cerebro--log-evaluation-p`, `cerebro--log-rotate-p` and
`cerebro--log-basename` (which of the two files an event belongs in); the writer is silent and
unable to fail, for the reason `scripts/agent-state` gives about its own log — and the error writer
more so, being the one path that runs when something has already gone wrong.

Two data sources it depends on, both under `.cerebro/state/` in the consumer repo:

- `<name>.state.json` — `{state: "idle"|"working"|"asking"|"waiting", phase, bead, since,
  phase_since, pid}`, written by **the agent itself** at each transition through
  `scripts/agent-state` (never by hand — see that script's header). Every implementer writes one, and since ah-2n3.2 so does each of
  the interactive agents; `waiting` is written by every kind since cb-1or.1. The launcher used to write the file and no longer does: it
  `exec`s a session and cannot see it claim a bead. `phase` is one of `build`/`gate`/`review`/`ci`/
  `rebase`/`merge` for an implementer, or a role word (`plan`, `prepare`/`verify`, `sweep`,
  `sweep`/`release`/`triage`, `daily`/`weekly`) for the interactive agents — meaningful with `working` and
  `asking`; `since` is the last change of `state` or `bead`, `phase_since` the last change of
  `phase`. Whoever changes the `state` vocabulary must change `cerebro--derive-from-state` with it —
  an unrecognised `state` now maps to `'unknown` and shows its raw word in yellow, not `idle`. **The
  fleet view deletes the file when it ends the session the file describes** — every path that ends
  one, because a killed agent cannot write a last transition and a file that outlives its session
  outlives its pid. There is one owner of that: `cerebro--end-session`, which removes the buffer and
  the `cerebro--sessions` entry (`cerebro--forget-session`), always the state file, and the stop flag
  only when its caller asks. Its two callers are `cerebro--supervise`'s retire branch (flag cleared)
  and `k` (`cerebro--kill-session-buffer`, flag left
  alone — `f` then `k` means stay gone). Enumerating one of the two is how the same omission came
  to be fixed twice while `k` went on leaking a state file (ah-bqi); add a third caller by calling
  that function, not by listing artifacts again. A session that ends by *itself* reaches none of
  those, so since cb-hzs `cerebro--launch` deletes the file before it spawns: one present then is
  always a previous session's, since a name with a live session is refused. Retiring an implementer
  also disarms it, the way retiring a role does — armed is what promises a retry.
- `scripts/roster` — the fleet: name, role and kind per agent, read once per buffer by
  `cerebro--fleet`.

Liveness for the interactive agents is the state file first, when one exists for a live pid
(`cerebro--derive-interactive`), and falls back to scanning system process args for cerebro's own
marker sentence when it does not — a session started by the fleet outside this Emacs has no file
and still shows `up`; one typed by hand carries no marker and reads dead (cb-d59.3).
The same scan, kept as (pid ppid . args) triples (`cerebro--system-processes`), counts how many sessions of
one name this consumer has (`cerebro--session-pids`), and a count above one shows as ` ×N` on the
row, with `s`, `k` and `f` naming the pids rather than acting on an ambiguity (cb-63m). **A session
is a process tree rather than a process** (cb-3ks): a CLI whose launcher is a shim spawning the real
binary as its own child passes the marker down, so both processes carry it, and
`cerebro--drop-wrappers` collapses each tree to the one pid the state file names — the leaf, since
an agent writes `--pid $PPID` from inside itself. Claude Code is one process per session, a tree of
one, and is unaffected; a genuine second session sits in its own tree and is still counted.

**"A live pid" means the agent's own session, not merely an existing pid.**
`cerebro--session-alive-p` reads the named pid's command line and requires cerebro's own marker
sentence in it — `This session is <Name> of the cerebro fleet rooted at <root>/.`, which
`scripts/launch` puts at the head of every session's prompt, the one argv slot every agent CLI
accepts (cb-d59.3). Two needles are cut from it: the name, and **the root** — the third
discriminator (cb-lzi), because a name is unique inside one consumer and not on the machine. No
provider's flag spelling is evidence any more; `--name` is still passed and proves nothing. The
needle is built by `cerebro--marker-needle`, which matches each space as an optional
backslash-and-space: on GNU/Linux `process-attributes` escape-quotes the whitespace inside a single
argv entry, and the marker is one argument, so the same session reads `This\ session\ is\ …`
there and `This session is …` on macOS. The
sentence is byte-identical to the one that used to ride on `--append-system-prompt` (ah-ybsr), so
the rule still recognises a session the previous launcher started and merge day is not a flag day.
The rule is stated once, in `cerebro--session-args-p`; the state-file path
(`cerebro--session-alive-p`) and the process-scan path (`cerebro--consumer-processes` then
`cerebro--name-in-args-p`) are both built from it. A bare `process-attributes` check was
what let a `done` file that outlived its session by ten hours light up green again once the OS
recycled its pid onto an unrelated daemon: pids are reused, so a number alone is not an identity.
The same check guards the claims sweep (`cerebro--live-implementer-names`), where a recycled pid
would otherwise protect a stale claim from being reclaimed.

**The shell has the same rule, in `scripts/agent-alive <Name>`** — exit 0 alive, 1 dead, 2 for a
usage error or a name that is not on the roster, so a typo can never read as "not running". It is
what `skills/plan-bead/SKILL.md` calls in the one place it needs liveness: deciding whether a
`planning:` label is still held (the buffer stopped counting sessions in cb-1or.3). Anything in bash that
needs to know whether an agent is up calls this; a bare `kill -0` there is the pre-ah-bqi shape, and
it makes a dead planner look alive, which strands the very label the reclaim loop exists to free.
It is the bash copy of `cerebro--session-args-p` — pid, and the marker's two halves — and both are held to one
case table, `tests/lib/session-args.cases`, so a case added on either side fails the other until
both answer it (they drifted twice before the table existed: `7bd5962`, `9420ff2`). Since cb-akt
that table holds **every** reader of the marker sentence, not only the two predicates:
`tests/fleet-cost.sh` runs the same rows against `scripts/fleet-cost`'s SQL prefilter and its two
jq captures, and its rows carry the store's shape — the marker as the *first sentence of a whole
seed prompt* — with `\n` as their one escape. `tests/lib/session-args.sh` is the one bash reader of
the table, sourced by both bash subscribers; elisp keeps its own parser because it cannot source
one, the same qualification `cerebro--log-line` carries against `scripts/jsonl-log.sh`. A fourth
reader subscribes rather than inventing plausible spellings — the third one did not, anchored its
root capture at the end of the message, and reported a silent zero for a fleet that had spent ten
thousand credits that week (cb-d89). Since cb-9su that subscription is checked mechanically rather
than trusted: `scripts/marker-readers` fails the gate on any file that spells the sentence without
declaring itself.

## fleet-view/ — the standalone read-only view

`.claude/cerebro/scripts/cerebro-tui` opens `cerebro-tui`, a Rust/Ratatui program that draws the
same fleet and the same six work queues as `M-x cerebro` **and touches nothing**. It runs no
launcher, writes no state file, no stop flag and no bead, and evaluates no trigger. Both views may
read the same consumer at the same time; the supervision half has not moved and is not planned to
move here (`docs/fleet-view-alternatives.md`).

One screen, two independently bordered, independently scrolling widgets: Fleet above Work, each
with its own title, focus and scroll offset rather than one shared document. Fleet takes its
natural height up to half the area below the header; Work takes the rest. `Tab`/`Shift-Tab` toggle
which widget is focused - the focused one draws a bright-blue thick-line border and a bold title;
`↑`/`↓`/`PgUp`/`PgDn` move only it, stopping at its own boundary rather than transferring focus.
`g` refreshes both panes regardless of focus, `q`/`Esc`/`Ctrl-C` quits. A pane whose content
outgrows its inner height reserves its last row for a dim `Rows n–m of total` cue. There is no
selection, no detail window and no lifecycle key, deliberately — the approved surface is
`docs/ui/cb-42k-independent-widgets.html`, which superseded the original single-document
`docs/ui/cb-vyp-read-only-view.html`.

The crate is split the way `cerebro.el` is, and for the same reason:

- `model.rs` — pure parsing and derivation (roster, state files, the marker sentence, the process
  tree, `partition_beads`). It is the Rust copy of the elisp rules, held to the same
  `tests/lib/session-args.cases` table as every other reader of the marker sentence.
- `readers.rs` — every file and subprocess: `scripts/roster`, `ps -axo pid=,ppid=,args=`, and one
  `bd --readonly -C <shared root> list --status open,in_progress,blocked,deferred,closed --json
  --brief`. Each child has a five-second wall-clock bound, is killed **and reaped** on it, and has
  both pipes drained on their own threads before anything waits — a child that fills a pipe while
  the parent waits is a deadlock no timeout can see. `read_fleet` and `read_work` are the two
  aggregate reads, and **a failure is never an empty answer**: `Ok(vec![])` would draw a fleet in
  which every agent is dead, and `Ok(WorkBuckets::default())` a board with nothing on it.
- `app.rs` — the display state, the two independent cadences (fleet every 5s, work every 30s) and
  one worker thread per pane. The panes are independent all the way down: one in-flight slot each,
  one clock each, one `Pane<T>` state machine each. A global busy bit would let the five-second
  fleet read starve the thirty-second work read, and a busy fleet would swallow the retry a
  navigator pressed `g` for.
- `ui.rs` — pure over `App` plus an injected `DateTime<Utc>`. It never reads a file, runs a
  program or asks the clock, which is what makes its `TestBackend` cases assertions about the
  screen rather than about the machine. Widths are **terminal cells** (`unicode-width`), never
  bytes or `char`s.
- `main.rs` — the terminal, the event loop and nothing else. Raw mode and the alternate screen are
  entered under an RAII guard, because `?`, an early return and a panic all skip a cleanup call
  and none of them skips a drop.

Two rules a change here must keep. **A failed refresh never destroys a snapshot still worth
reading**: a first failure is `Unavailable`, a later one is `Stale` carrying the original
`read_at`, and a success clears the error with the value. And **the two panes fail apart**: `bd`
being unreadable says nothing about the fleet. The header is the one place they meet — while
either pane is retrying it says `refreshing...`, otherwise it carries the newest failure's time,
and the key hint stays `g retry` until both panes are fresh.

## Gotchas

- `.cerebro/` is the harness's own directory in the consumer — agent state files, stop flags and
  agent worktrees (ah-v82), **and since cb-epr the project's own declarations** (`project.conf`,
  `roster.conf`, `traps.md`). So the consumer's `.gitignore` names the
  three things the fleet writes while it runs — `.cerebro/worktrees`, `.cerebro/state` and
  `.cerebro/scratch`, the planners' drafts (cb-27g) — and
  tracks the rest: the declarations, and `models.conf`, which this project commits so every clone
  runs the same models (`eb6ffdb`; a project that wants it personal ignores it). A deny-list rather
  than everything-except: the price is that a new runtime artifact has to be added to it, and that
  price was taken so models.conf could be tracked without a negation per tracked file. `.claude/` holds only what Claude
  Code itself discovers (`agents/`, `skills/`, `settings.json`) plus this repository's own
  submodule mount. Since cb-d59.4 `.github/agents/<role>.agent.md` and `.github/skills/<name>` hold
  the same links under the names GitHub Copilot discovers, written by the same sync — **both
  layouts, always, whatever `agent_cli` declares**, so switching provider is one line in
  `.cerebro/project.conf` and nothing else. They are tracked here, and produced by running the
  script rather than written by hand.
- **This repository is a consumer of itself** (cb-i3l.1). `.claude/cerebro` is a committed symlink
  back to the checkout, so every path the harness assumes — `.claude/cerebro/scripts/launch`, the
  `../cerebro/...` links the sync writes — is literally true here, and the fleet runs the *working
  tree* rather than a pinned sha. A submodule of the repository inside itself would have satisfied
  `consumer-root` with no code at all, and was rejected for a different reason: `git submodule
  update --init --recursive`, which `launch-preflight` runs, has no fixed point on a repository that
  contains itself. **One function knows about the mount**: `cerebro_mount_resolves_to` in
  `scripts/root-hints.sh`, which `consumer-root` sources and exposes as `--self-mounted` and
  `--mount`; `roster` and `sync-symlinks.sh` ask it (cb-akc), and nothing else spells the round
  trip. Since cb-ue0 the same round trip is what authenticates a root hint, which is why it moved
  out of `consumer-root` into a library the hint readers can source without forking it.
  `prune-worktrees.sh` is the documented exception and keeps its git-dir
  comparison: it asks whether the mount and the consumer are **one repository**, so that one
  `git worktree list` covers both, and that parts company with the round trip for a vendored plain
  copy at the standard mount — where the mount is an ordinary directory of the consumer's own repo. A worktree carries the same committed
  symlink, which resolves to the worktree, so an implementer reads its own branch's skills.
- `scripts/agent-alive <Name>` is the one place bash answers "is this agent up" (see above). A
  predicate, not a writer, so it is its own script rather than a mode of `scripts/agent-state`: it
  prints nothing and the exit status is the whole answer, since it runs once per agent on every
  planner pass.
- `scripts/end-pass <Name> --pid <pid>` is the one place a pass is ended (cb-3tk). It is a
  **caller** of `scripts/agent-state`, not a second writer — it runs
  `agent-state <name> waiting --pid <pid>` as its last command, so the two cannot drift and a
  refusal from the writer is its own exit status. Its whole argument list is a name and a pid:
  there is no state word and no number for prose to get wrong, which is what six different
  spellings of the same call in six role documents had been, and what left every Forge sweep for
  two days unable to end its pass. `--wake-in` and `wake_at` went with it — the field was written
  and read by nothing, and cadence is `cerebro-wake-interval`/`cerebro-wake-intervals`, which have
  never read the state file.
- `scripts/planner-buffer` is the one place the planner buffer rule is answered for the shell —
  the excluded labels, the floor, the planned count and the wanted number. The elisp trigger keeps a
  pure copy of the predicate (`cerebro-parked-labels`, `cerebro-planner-buffer-floor`,
  `cerebro--planner-want`) because it runs every five seconds and may not spawn a process; the ERT
  contract test is what keeps the copy honest. It counts an implementer told to finish as not
  running — it takes no further bead — which is one of the two drifts the split had already caused.
  Since cb-1or.3 it counts the roster's implementers rather than running sessions — a builder
  between beads has no session (cb-1or.1) — so `agent-alive` is no longer part of the rule.
- `scripts/app-paths` is the one place "which paths are this project's application" is answered
  (ah-qled.6) — the `app_paths` key, and `--classify <path>...` over changed paths. Unlike every
  other reader here it **fails when it does not know**: no declaration means exit 3 and a line on
  stderr, never a guess. A default either way was the defect — "matches nothing" gave a consumer
  empty release notes and no verifications with nothing on stderr, and "matches everything" sends
  the navigator to verify docs changes. A caller that cannot classify says so.
- `scripts/tracked-links` is the one place "are this repository's tracked links whole" is answered
  (cb-8rz). This repository is a consumer of itself, so the links the sync writes are tracked files
  here, and a broken one shipped through three merges with a green gate (cb-7v2, `d7a76fa`). It
  answers both directions — a tracked link under `.claude/` or `.github/` that no longer resolves,
  and a skill, agent or provider hook the mount ships that no layout has a tracked link for — with
  findings on stdout, exit 1, and `tests/tracked-links.sh` as its suite. It scans **only** those two
  directories, deliberately: a wider pathspec would make the suite read `docs/`, `README.md`,
  `LICENSE` or `models.conf.example` and quietly break `scripts/ci-needed`'s skip list, which needs
  no edit as it stands. It never checks **where** a link points — `.github/copilot-instructions.md`
  and `.claude/cerebro` are tracked links the sync does not write. It is a gate predicate and must
  never join `launch-preflight`'s hot path: a check that refuses there is a fleet that cannot start.
- **`scripts/session-marker.sh` is the one place bash spells the marker sentence** (cb-9su) —
  `cerebro_marker_sentence`, `cerebro_marker_name_needle`, `cerebro_marker_root_needle` and
  `cerebro_marker_infix`, sourced never executed, builtins alone for the narrowed PATH, in the shape
  of `scripts/root-hints.sh` beside it. Its two callers are the writer (`scripts/launch`) and a
  reader (`scripts/agent-alive`), which is what took four hand-tuned parsers of one sentence down to
  three: those two can no longer disagree at all. Three properties are load-bearing and each was
  already paid for — the name needle ends at the space after `rooted at ` (so `Cyclops` never
  matches `Cyclopsly`), the root needle carries exactly one trailing slash (so `/repos/x` never
  matches `/repos/x-hud`), and the sentence carries no apostrophe (`launch`'s bash-3.2 convention,
  and `tests/fleet-cost.sh` interpolates the field into a `sqlite3` string literal). `emacs/cerebro.el`
  and `scripts/fleet-cost`'s SQL/jq stay copies for the reasons above; what changed is that a copy
  can no longer exist *undeclared*. `tests/session-marker.sh` pins the four functions against
  literals on purpose — a test that re-derived the sentence from the library would prove nothing.
- **`scripts/marker-readers` is the one place "is every reader of the session marker a subscriber"
  is answered** (cb-9su). `tests/lib/session-args.cases` is a test fixture, so it only ever caught
  drift between readers that opt in; a reader that never subscribed was not red but silently wrong,
  and cb-akt's was a **zero**, which reads as a fleet that has never run rather than as a failure.
  This scans `scripts`, `emacs`, `tests`, `hooks` and `githooks` — those five and no others, for
  `scripts/tracked-links`'s reason: a wider pathspec would make the suite read `docs/`, `README.md`,
  `LICENSE` or `models.conf.example` and quietly break `scripts/ci-needed`'s skip list, which needs
  no edit as it stands. `--cached --others --exclude-standard`, so a new reader written but not yet
  `git add`ed is caught at exactly the moment the check exists for. Findings on stdout, exit 1,
  in `tracked-links`'s house format — `unsubscribed:`, `stale:`, `unpinned:` — with
  `tests/marker-readers.sh` as its suite. **It is not itself a reader**: it sources
  `scripts/session-marker.sh` and greps for `cerebro_marker_infix`, which is the rule rather than a
  way round it. Like `tracked-links` it is a gate predicate and must never join
  `launch-preflight`'s hot path: a check that refuses there is a fleet that cannot start.
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
  Since cb-ue0 it also answers all three at once: `consumer-root --hints` prints the enclosing root,
  the shared root (empty when git cannot say) and the mount, on three lines, so one fork can do what
  three used to.
- **`scripts/jsonl-log.sh` is the one place bash appends a line to an append-only JSONL log**
  (cb-ge0) — `cerebro_jsonl_append <path> <line>`, builtins only for the narrowed PATH, refusing a
  line that is empty or does not begin with `{` rather than trusting its caller to have checked one.
  Its two callers are `scripts/agent-state` (`transitions.jsonl`) and `scripts/launch-refused`
  (`errors.jsonl`), and both append from inside a `{ ... } || true` group, which is the whole reason
  the library exists: **`|| true` on a group turns errexit off inside the group**, so a
  `line="$(jq ...)"` in a "cannot fail" block does not abort it when `jq` fails — it leaves `line`
  empty and appends a blank line. That sentence had been learned twice from scratch, once per bead,
  because it lived in a comment in one copy of the idiom; it lives in the library's header now.
  `emacs/cerebro.el`'s own writer (`cerebro--log-line`) is a third implementation in a different
  language rather than a copy that was missed — elisp cannot source a bash library, and shelling out
  would be a fork per evaluation in a loop that runs every five seconds.
- **`scripts/root-hints.sh` is the root-hint contract**, and the one place the mount round trip
  lives (cb-ue0). `scripts/launch` resolves `consumer-root --hints` once per session start and
  exports `CEREBRO_CONSUMER_ROOT`, `CEREBRO_CONSUMER_SHARED_ROOT` and `CEREBRO_CONSUMER_MOUNT`;
  `project-conf`, `default-branch`, `sync-symlinks.sh`, `launch-preflight`, `roster` and
  `agent-alive` source the library and prefer the hint, which took a launch from **16**
  `consumer-root` forks to **one**. A hint is **never trusted, always validated**: an environment
  variable is inherited, and `consumer-root` deliberately answers about the checkout its own
  `${BASH_SOURCE[0]}` lives in, so a hint from a parent in the main checkout must not answer for a
  copy inside a bead worktree. `cerebro_hinted_root` therefore checks `<hinted root>/<hinted mount>`
  physically resolves to the caller's own checkout — which cannot be true of two checkouts at once —
  and returns non-zero otherwise, so every caller keeps its original fork as the fallback and
  behaves exactly as it did before when the hint is absent or foreign. **A fixture that hand-places
  `scripts/consumer-root` must place `scripts/root-hints.sh` beside it**, or it dies at the source
  line; `link_scripts` in `tests/lib/consumer.sh` does this for every consumer it builds.
- `scripts/sync-symlinks.sh` and `githooks/` only ever run in a **consumer** repo. `sync-symlinks.sh`
  asks `consumer-root` for the enclosing tree — a worktree syncs its own links, which is what lets a
  submodule-bump PR commit them (ah-cuc). It writes into every discovery path
  `scripts/agent-cli --layouts` names — `.claude/` and, since cb-d59.4, `.github/` — and mirrors a
  project's own definitions from `.claude/` into the others, one way only. cb-pq4's actual rule is
  intact: the consumer **root** is the project's alone, the `.dir-locals.el` it used to install is
  gone, and the one thing it does there is remove a link to the retired template, out loud.
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
  `hooks/copilot/` holds the same behaviour in GitHub Copilot's schema. Copilot has no `--settings`
  and discovers its hooks from the consumer's `.github/hooks/`, so `scripts/sync-symlinks.sh` links
  it there — in every consumer, whatever `agent_cli` declares, the same rule the layouts follow —
  and `scripts/agent-cli --hooks` is the one place those two paths are written down.
- **The model an agent runs on is the agent definition's `model:`, unless the consumer overrides it —
  and on any CLI but Claude Code the definition does not answer at all.**
  `scripts/launch` reads `<consumer>/.cerebro/models.conf` if it exists — `<name|role|default>[@provider]
  <model|-> [effort]`, most specific key wins, `-` meaning "pass no `--model`" — and says on stderr
  which key it matched, so an unexpected model is traceable to the file nobody remembers editing. A
  `--model` on the command line still wins, since it is appended after. `models.conf.example` is the
  documented copy; the live file is consumer-side and uncommitted, which is what makes switching the
  fleet between Opus and Fable a one-line edit rather than a submodule change every consumer shares.
  Since cb-d59.6 a key may carry `@<provider>`, and the six probed keys are most-specific-first with
  the provider-scoped key beating the plain one within each: `<Name>@<p>`, `<Name>`, `<role>@<p>`,
  `<role>`, `default@<p>`, `default`. A key naming a CLI cerebro does not know is warned about
  **once** and ignored — which is why the file is read in one pass into parallel arrays and then
  probed, rather than re-read per key. The agent files' `model:` and `effort:` are **Claude Code's
  words** (`scripts/agent-cli --agent-file-models`), so on any other provider they are dropped: a
  Copilot fleet with no `models.conf` passes no `--model` and no `--effort` at all, runs on the
  CLI's own defaults, and says so on stderr rather than looking deliberate.
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
  ignored, `KIND` still derived, and an optional third word — `autostart`, read by
  `roster --autostart`, or `standby`, read by `roster --standby` (cb-98u) — the three default
  columns never change, since `launch`, `agent-state` and
  `cerebro--parse-fleet` all take the last field as the KIND; any other third word, or a fourth,
  refuses with exit 2 naming the file, line and word, and `M-x cerebro` shows that refusal rather
  than an empty fleet (cb-0r6). When it exists and is non-empty it **replaces** the built-in table
  rather than merging with it, because file order is load-bearing (Cerebro takes implementer names
  in file order). It is **tracked**, beside `.cerebro/project.conf`, by a
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
