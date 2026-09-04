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
and look at. It draws the fleet and the bead panel from the same contracts `M-x cerebro`
reads. Which of the two views may act on a checkout is the project's own declaration
(`fleet_supervisor`); this repository declares `tui`, so `cerebro-tui` is the view that operates
this fleet and `M-x cerebro` reads.

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

<!-- four-eye:begin -->

Nothing merges unreviewed and nothing merges red.

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself** — given the diff and the bead, never the implementer's own reasoning — and it
counts when all of these hold: the review **chain** covers the implementation being merged, its
first round reading the whole change cold and each later round the delta since the round before it;
every round is posted in full on the pull request, saying which of the two it was; every finding from every usable round is answered, by a change or
by a posted reply saying why not; and every check is green. Failed or unusable attempts may be retried,
but three unusable attempts for one head require the navigator. That is the whole standing approval,
and it covers a planned bead only.

Updates after rebase and/or conflict resolution does not need to trigger an additional review.

Documentation only does not need reviews — `docs/`, `README.md` and the like. **A change under
`agents/` or `skills/` is never documentation**: those files are what the fleet reads, so a word
changed there changes how every consumer behaves, and they are reviewed like any other behaviour.
`scripts/app-paths --classify` settles the question when it is not obvious; anything it calls
`application` needs a review.

**A commit that only answers findings does not start the review over.** The first round is a cold
read of the whole change. Every round after it is given the two shas, so it can take the delta
itself, together with the findings it raised and the answers posted — which it treats as **claims to
check against the code**, never as an account to accept. It asks two questions: were the findings
addressed, and does the delta introduce anything new. A round that returns nothing blocking ends the
review.

Which round a commit buys is decided by what the commit does, not by how big it is:

- **answers findings, or only makes a red check green** — a delta round;
- **a rebase, a conflict resolution or an `update-branch`** — no round at all;
- **documentation only**, by the paragraph above — no round at all;
- **anything else** — new behaviour, a different approach, work the reviewer has not seen — a fresh
  cold read, as is the first round after a hand-back.

<!-- four-eye:end -->

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

- `.cerebro/project.conf` — this project's name, default branch, audience, **which fleet view may
  supervise** (`fleet_supervisor emacs|tui`, absent means `emacs` — see *fleet-view/* below and
  `scripts/fleet-supervisor`), which paths are
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

What the fleet's own logs say is stuck — starts per name, passes that held no bead, what is
running now and what has been disarmed, over `decisions*.jsonl` and `transitions*.jsonl`. It reads
and reports; it writes, starts and stops nothing, and exits 0 always:

```bash
scripts/fleet-health                       # the four-section report, last 24h
scripts/fleet-health --since 7d --json     # the same facts as one object, for cerebro-tui
```

Sync symlinks into a consumer repo (run from that repo, not this one):

```bash
.claude/cerebro/scripts/sync-symlinks.sh
```

## The agent fleet these files describe

Seven roles, each an agent definition in `agents/`; most are backed by a skill in `skills/`. A role is
not a session count — **`planner` is held by two agents, Xavier and Beast** (`scripts/roster --role
planner`), which is the one place a name and a role stop being interchangeable:

- **Xavier** and **Beast** (`planner`, Opus/high) — load `plan-bead`. Turn unplanned beads into
  plans a Sonnet agent could build unattended. Decide architecture themselves, and the detail inside an interaction the human ("the navigator") has
  already agreed — recorded in the plan's *Decided by me* — while the shape of every new interaction
  goes to them. Keep a buffer of planned beads ahead of the
  builders, sized from the roster's implementers minus any told to finish (`planner_buffer_multiple`
  each — absent means one each — and never fewer than two) and refilled one bead per pass, with no wake interval to wait out — the rule itself lives in `scripts/planner-buffer`,
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
  own** — and is itself started by the fleet view for one thing, an unranked bead (cb-5lx.2), and
  typed a line by it for two: that same unranked bead, and, since cb-7nx, a two-hourly reminder to
  run the two sweeps that need a judgement no decision table makes. The
  worktree, claims and epics sweeps it used to run on a timer now run from the fleet view itself
  (`ah-4ao`; see `docs/cerebro-jobs.md` for the decision and `docs/cerebro-sweeps.md` for what each
  sweep looks for and the guards it runs under); what is left for a Cerebro session is the claims
  sweep, the beads parked on the navigator, and the worktrees the watcher declined, each of which
  needs a judgement no table makes,
  handing a release
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

- **Wait by blocking inside a tool call, never by ending a turn** — with one measured exception,
  below. `Monitor` and background `Bash` promise a re-invocation that nothing delivers; this
  stranded a claimed bead, an open PR and unanswered review comments. Implementers are interactive
  now, so an ended turn no longer kills the process — it just sits there until a human types
  something, which is not better. The exception is **a `reviewer` sub-agent the session spawned
  itself**, whose result *is* delivered and has been every time in this repository, including to a
  parent whose turn had ended: that one is waited for by being told, never by a fixed `sleep`, which
  cost cb-sxf ten of its twenty-two minutes. Ending a *turn* there is not ending a *pass* — the
  state file stays `working --phase review`, and `waiting` with a review outstanding is still the
  stranding this bullet is about.
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
  `hooks/session-state.settings.json` + `scripts/agent-asking`, wired into the whole fleet by the
  two lines `scripts/launch` gives every session (`agent-hooks-env`, `--settings`), flip the file
  for the lifetime of a question tool call, because telling an agent three ways did not make it so.
  The agent files still describe the transitions and must keep doing so — the hook covers the
  question tool, not a question asked in prose, and knows nothing about `idle` versus `working`.
  **That same settings file carries two more hooks since cb-ykz.1**: a `Stop` hook and a
  `UserPromptSubmit` hook running `scripts/agent-turn`, which stamps `turn_ended` into the state
  file when a session's turn ends and clears it when one begins — and every `scripts/agent-state`
  write clears it too, an agent writing its own state being a session still running turns. Both
  readers parse the field and carry it on the row, and since cb-ykz.2 both **derive "stuck"** from
  it — a `working` row whose turn ended more than `cerebro-stuck-ceiling` /
  `STUCK_CEILING_SECONDS` (1800, a literal pair) ago. Acting on one is cb-ykz.3; today it is drawn
  and recorded and no more. A fleet declaring `agent_cli copilot` gets no
  `turn_ended` at all: no measured Copilot event corresponds to `Stop`, and a guessed one would be
  a hook that silently never fires.
- **Nothing merges unreviewed, red, or stale.** The implementer's standing approval to merge without
  asking comes from the consumer repo's CLAUDE.md ("Four Eye Principle") and applies only to a
  planned bead.
- **A session is started only for work nobody is already coming for.** Since cb-cz7 the planner
  and implementer conditions subtract the live
  sessions of their own role that name no bead (`triggers::in_flight`, `cerebro--in-flight`) from
  the work they read, and a headroom of zero starts nobody and shows `→ 0 free` on the row. Both
  views answer `tests/lib/start-headroom.cases`, and each carries its own half of the within-tick
  rule (`triggers::no_headroom`, `cerebro--no-headroom-p`): a start made in one pass of the start
  loop is subtracted from the headroom the next row is judged against, since the fleet read that
  would show it up is five seconds away. The spacing in the bullet below stays, staggering the
  boots a real queue does justify.
- **A role more than one agent holds is started one at a time.** The planners answer the same buffer
  rule off the same panel, so a tick where it is true is true for both, and the view started Xavier and
  Beast in one breath. They then race for one candidate over the startup window the planner bullet
  above describes — launch to that `planning:` label reaching the remote, about a minute on this
  fleet — and not over research time. The implementers are the same shape since cb-1or.1: a queue that
  fills is a condition true for every standby builder on one tick.
  `cerebro-role-start-spacing` holds the second for 30s; it counts
  peers only, so a role is never held by its own restart.
- **Agents never decide the shape of what a user sees** — a new surface, a key or gesture, what a
  control does — and **only the planner** decides the detail inside a shape the navigator has
  already agreed, writing every one of them into the plan's *Decided by me* where the navigator can
  overrule it. No agent takes work off another (except the documented crashed-agent recovery), and
  none acts outside a planned bead.
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
**Sweeps** section: the claims and epics sweeps `docs/cerebro-sweeps.md` specifies, run every ten
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

Since cb-ykz.2 a **stuck** row says so: a `working` row whose recorded turn-end is older than
`cerebro-stuck-ceiling` (1800 seconds) draws a red `✗` in place of its glyph and `stuck 8h49` —
how long the turn has been over — where its elapsed pair would be, keeping its state, phase and
bead untouched, and one `stuck` line per occurrence goes into `decisions.jsonl` (gated on
supervision, like the nudge; the drawing is gated on nothing, since looking at a fleet is not
supervising it). **Since cb-ykz.3 supervision acts on it**: a stuck row is asked, once, to carry
on — one line typed into the session, `resume` in the log and a `resume` arm on
`cerebro--supervise-action`, with the stop flag making no difference. The typed line itself clears
`turn_ended` (`scripts/agent-turn`), so the row is un-stuck on the very next tick; the escalation
is therefore built on the state file not having moved rather than on a second clock
(`cerebro--resumed`, which is **not** cleared when the row stops being stuck — that is the trap).
If the row is stuck again with its `(since . phase_since)` pair unmoved, an interactive role's
session is ended, or retired under a stop flag, which says *no further pass*; an implementer's is
left alone — it holds a claim, a worktree and possibly an open pull request, and `sweep-stalled`
already offers the unclaim at sixty minutes.

It writes three of its own beside them. **`.cerebro/state/errors.jsonl`** is the short one and the
one to be pointed at: a line per thing that went wrong — `{event, ts, context, message}`, where
`context` names the part of the view it came from (`autostart`, `roster`, `launch`, `sweep`,
`supervise <Name>`). Every path that used to demote an error to a message goes through
`cerebro--with-logged-errors` or `cerebro--report-error`, which say the same words in the echo area
*and* keep them, because the echo area is painted over by the next render and a fleet that failed to
start half an hour ago has no other trace. It is a separate file from the one below for the
one reason that matters: the navigator is sent to it by opening it, which a hundred thousand
evaluations a day would make useless. An error is written at every verbosity but `none` — `none`
means nothing at all, which is what the suite binds.

**`.cerebro/state/decisions.jsonl`** is the record of what the view actually did: a line per
decision — start (with the trigger that fired), end, retire, nudge, stuck, disarm (`k` and the
standby disarm, which said nothing at all until cb-yv9), resume, sweep run, sweep line
typed (`sweep-tell`), abnormal exit. Since cb-xhu.2 that is *all* it holds, and it therefore keeps
months: it was 99.7% evaluation lines and rotated a start or an exit away within four days, which
is exactly the window cb-nc8 needed and did not have.

**`.cerebro/state/evaluations.jsonl`** is the loud one that left it: at `cerebro-log-verbosity`
`evaluations` (the default), a line per trigger evaluation per tick carrying what the trigger read
and whether `cerebro--unless-unchanged` is what held it. That is the only
observable trace of a decision *not* to start, which is otherwise indistinguishable from a bug.
`changes` logs an evaluation only when its answer differs from that agent's last; `decisions` logs
none. All three files rotate on `cerebro-log-max-bytes` × `cerebro-log-generations` — one policy, since
a healthy fleet never fills the error log at all. The pure half is `cerebro--log-line`,
`cerebro--log-event-p`, `cerebro--log-evaluation-p`, `cerebro--log-rotate-p` and
`cerebro--log-basename` (which of the three files an event belongs in); the writer is silent and
unable to fail, for the reason `scripts/agent-state` gives about its own log — and the error writer
more so, being the one path that runs when something has already gone wrong.

Two data sources it depends on, both under `.cerebro/state/` in the consumer repo:

- `<name>.state.json` — `{state: "idle"|"working"|"asking"|"waiting", phase, bead, since,
  phase_since, pid, turn_ended}`, written by **the agent itself** at each transition through
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
  also disarms it, the way retiring a role does — armed is what promises a retry. Arming follows the
  same rule in both views (cb-op0): every successful launch arms, and a retire, a `k`, a stop flag
  on a waiting role and a tick on which somebody else has or is taking the checkout disarm — a
  tick on which this view merely could not tell who supervises changes nothing, because a
  recoverable condition may not have a permanent consequence (cb-nc8) — see
  `docs/ui/cb-op0-arming.html` §6.
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

## fleet-view/ — the standalone terminal view

`.claude/cerebro/scripts/cerebro-tui` opens `cerebro-tui`, a Rust/Ratatui program that draws the
same fleet and the same six work queues as `M-x cerebro`. **Since cb-kcs.1 what it may do at all is
a consequence of what the project declares rather than of what the program can do.** Since cb-kcs.3 it acts unattended on
the sessions it hosts where a project declares it the supervisor: it ends one whose pass is over
after `END_GRACE_SECONDS`, retires one under a stop flag and clears the flag with it, deletes the
state file of every session it ends, and types one line into a session whose question nobody
answered — an implementer past `ANSWER_TIMEOUT_SECONDS`, and since cb-2e9 an interactive role past
`INTERACTIVE_ANSWER_TIMEOUT_SECONDS` (`cerebro-interactive-answer-timeout`, twice the
implementer's), each in its own words. Held to `tests/lib/supervise.cases`, which
`cerebro--supervise-action` answers too. On that clock an interactive role is nudged and never
retired: a nudge asks the agent to finish, where a retire ends its session under it. (A stop flag on
an idle one still retires it — that is the flag's arm, not the clock's.)
Since cb-kcs.4.1 it also **starts** sessions on its own: the roster's `autostart`/`standby`
declaration is honoured as the view comes up, and the board-backed triggers for the planner,
implementer, verifier and orchestrator roles bring a blue `standby` row back — held back by a
per-role wake floor, the unchanged-work fingerprint, role-start spacing and, since cb-cz7, the
**start headroom**: available work minus the live sessions of that role that name no bead yet, so
one planned bead starts exactly one builder and four still staff four. A row held by it reads
`→ 0 free`, and a start made inside one tick reduces the headroom the next row in the same loop is
judged against — the fleet read that would show the first one up is five seconds away.
`tests/lib/start-headroom.cases` is the table both views answer, for `supervise.cases`' reason. Every successful
launch arms, whoever asked for it — `s`, an autostart and a trigger alike — and a retire, a `k`
(at every row state, not only standby), a give-up and a tick on which somebody else has or is
taking the checkout all disarm; a pass that merely ends does not, which is the whole point of the
set (cb-op0), and neither does a tick on which this view could not tell who supervises — a
declaration it could not read is an outage, not a handover (cb-nc8).
`docs/ui/cb-op0-arming.html` §6 is where that whole rule is written down, for both views. Since
cb-kcs.4.2 a start that keeps failing backs off on `0/30s/2m/10m` — the row counts the wait down
in place of its condition — and is abandoned after five consecutive starts
that produced no pass, which disarms the name and leaves `s` as the only way back; a launcher
refusal is parked from the first failure, where a silent crash is retried. Since cb-kcs.4.3 the
three roles whose work arrives from outside the fleet start too, off a `gh` reader on its own
cadence and an hourly floor each. Since cb-kcs.4.4 all of it is written down, in the same three
append-only files `M-x cerebro` writes: `decisions.jsonl` — a line per start (with the trigger that
fired), end, retire, nudge, resume, stuck, arm, disarm, exit and give-up, and since cb-xhu.2 nothing else, which is why it
keeps months; `evaluations.jsonl` — at the verbosity this view compiles in, a
line per trigger evaluation per armed row per tick carrying what the trigger read and which guard
held it; and `errors.jsonl`, one line per outage rather than per failed read, naming the pane or
the name it came from. One policy rotates all three; the writer is silent and unable to fail; and a
read-only view writes none of them, since it decides nothing.

Since cb-ykz.2 its Fleet rows carry the same **stuck** signal `M-x cerebro` does, off the same
rule (`lifecycle::stuck_for`) and the same 1800-second ceiling: a red `✗` glyph, and `stuck 8h49`
in red. Which cell carries the text is the one divergence, and it is the pane's own shape: in the
wide layout it replaces the FOR column's elapsed pair, and **below `WIDE_COLUMNS` — which is the
ordinary split layout, where the Fleet pane is a fixed 40 cells — the BEAD cell carries it**
instead, standing aside as it already does for a standby label and a dead row's verdict, with
`columns` sizing that column from the same `bead_cell` so the text is never cut. The STATE cell is
untouched in both. One `stuck` line per occurrence goes into `decisions.jsonl`, gated on
supervision like the nudge. Since cb-ykz.3 it also **acts**, off the same rule and the same
memory `M-x cerebro` keeps: one `resume` line typed into the session, then — if it is stuck again
with its `(since, phase_since)` pair unmoved — the interactive role's session ended, or retired
under a stop flag, and an implementer's left to `sweep-stalled`. A stuck row this view hosts
therefore writes two lines per occurrence, `stuck` and `resume`: the observation and what was done
about it.

Since cb-kcs.5.1 it runs **the six sweeps** as well, on their own ten-minute cadence and their own
in-flight slot, and draws what they found as the Work pane's **first** section — `Sweeps {n}`, one
truncated line per finding, a gold line for a stranded P0, and the failed script named beside the
header in red when one did not answer (`sweep-claims failed`), because three of the six `git fetch`
and a stale section that reads like a current one is what Emacs's own silence costs. The chain
stops at the first script that did not answer, which is what lets the header name exactly one. Under
Work the arrow and page keys move a **cursor over the findings** while there are any and scroll the
pane when there are none (widened to bead rows by cb-kcs.5.4, below) — and `x`, from any focus, shows the exact `bd` and runs
it only on `y`, followed by `bd dolt push` on the same keystroke — since cb-21g both of those run
on the **write worker** rather than on the drawing thread, so the keystroke returns at once and the
header's sentence arrives when the write answers. That was **the one write in this
crate that does not pass `--readonly`** until cb-kcs.5.4 added the priority keys beside it; it lives
in `lifecycle::run_finding` beside every other
write and spawns through `readers::CommandRunner` like every other command
(cb-i1w), and it is deliberately **outside the lease**: the board is shared, so a view that may start
nothing may still close a delivered bead. `tests/lib/sweep-findings.json` is the table both
implementations answer — every finding, every label and every command — for `supervise.cases`'
reason: both views go on sweeping after the cutover, so one decision has two implementations in two
languages. The header now renders **whichever** `Prompt` is up, through the enum's own `text`
(cb-4cn): matching one variant by name is how cb-kcs.4.1's disarm confirmation came to be built and
never drawn.

Since cb-kcs.5.2 it runs the supervisor's last two unattended jobs as well. It keeps one
`prune-worktrees.sh --watch` child alive beside itself on a five-second clock while it may act,
kills it when it may not — a drain is a handover, and the pruner is a writer — and says
`Worktree pruning stopped: <cause>` in **red** in the header's notice slot when the child will not
start or has died, once and then again every ten minutes while it stays broken (Emacs swallows all
of this, and the cost is worktrees quietly not being pruned). And it types the triage line into an
idle orchestrator this view hosts when unranked beads are waiting for a ranking — the same bytes
Cerebro already reads — saying `Cerebro was asked to rank 3 unranked beads.` in gold beside the
nudge's own line, and repeating the same set every ten minutes while Cerebro stays idle. The line
is typed, recorded and throttled **only when it went into a session this view hosts**, which is a
deliberate divergence from `cerebro--triage-tell`: that one records and logs even when no buffer
took the string, so its throttle then holds for a line that never left the building.
`tests/lib/triage.cases` is the table both implementations answer, for `supervise.cases`' reason —
both views go on triaging until the declaration moves.

Since cb-7nx a **second** line goes into an idle orchestrator on the same mechanism: every two hours
(`cerebro-sweep-interval` / `SWEEP_INTERVAL_SECONDS`, both 7200) it is asked to run the claims sweep
and the worktrees the pruner declined, the two that need a judgement no table makes — an orchestrator
has no cadence of its own, so without it Cerebro sweeps once at startup and never again.
`tests/lib/sweep-tell.cases` is its own table, answered by both implementations, and it is separate
from `triage.cases` for the reason its header gives: triage's trigger is a condition that stays true,
so a busy Cerebro needs no queue, while a two-hour mark is an **edge** that passes — one falling
mid-pass is queued and typed at the first idle tick after it, at most one at a time, so six hours of
work is followed by one sweep. The clock resets when the line is typed rather than when a sweep
completes (the navigator's choice: the alternative needs a new signal from the agent back to the
view), and it is dropped entirely for a name this view holds no session for, which is what keeps a
restarted Cerebro from being told to sweep seconds after its own startup sweep. The event is
`sweep-tell` in both writers, `sweep` being the `x`-on-a-finding decision. `triggers::cadence` is
deliberately untouched: an orchestrator gets no wake trigger, since a two-hour *cadence* would have
the view starting Opus sessions round the clock. The pruner writes **no** decision event:
starting and stopping a watcher is not a fleet decision, and its failures reach `errors.jsonl`
under the context `prune` and nowhere else. Its surface was approved over three interview rounds
on 2026-09-02 and arrives, like cb-kcs.2's, in a docs-only pull request of its own — so no path
for it is written here, for the reason the paragraph above gives.

Since cb-kcs.5.4 it carries the last two things the Emacs bead panel had and it did not, and both
are the navigator's own hands rather than the supervisor's. **The priority keys** — `0`-`4`, `+`
(more urgent, so the *number* goes down), `-` and `u` — write a bead's priority to the shared board
with no confirmation and `bd dolt push` on the same keystroke, saying what they did in the header
(`cb-x: P1 → P0`, `cb-x is already P0`, `cb-x: back to P1`, and the push failure in the same line).
Since cb-21g the write itself runs on the **write worker**: the keystroke leaves a dim provisional
line (`cb-x: P1 → P0…`) that no other keystroke clears, the row shows the priority it was asked to
have until a board read that began after the write settled lands, and the sentence above arrives
when the write answers — a refused one in red, and in `errors.jsonl` under the context `write`.
`u` is one step, spent only by using it, surviving a refresh and overwritten by the next change.
They are the second write in this crate that does not pass `--readonly`, beside `x`, and the one key
set in this view that is **not** "from any focus": Work focus only, because a
digit is far more ordinary than `x` and from Fleet focus `3` would silently rerank a bead in a pane
nobody was looking at. And **the History section**, last in the Work pane — the `M-x cerebro`
order — one line per agent running something right now, gold when it has run past twice its own
median (`Psylocke asking 537m - long, median 2m`), on its own five-minute reader; a state nothing
has finished in has no median and is never called long. A failed run keeps the rows it had and says
`History 4  fleet-history failed` in red, and a *first* failure draws no section at all, which is
the ordinary state of a machine that has never run the fleet. Both are **outside the supervision
lease**, exactly as `x` is, and both hint clauses are shown on a read-only view where `s`/`f`/`k`
are not.

With it the Work **cursor** widened from findings to findings, bead rows and `+N more` rows —
never a header, a blank, `(none)` or a History row, so a grey row always means a key will do
something here — and it is on the first selectable row from the first frame. `Enter` on a `+N more`
row opens that one section (`all 23 shown — Enter`) and closes it again, which is the only way a
bead in the P4 backlog can be reranked at all; an open section survives the thirty-second refresh
and `g`. That widening is what moved the whole Work document into `app::work_body`: it now owns
every drawn line — headers, bead rows, notices, `+N more`, History and all — and `ui::work_document`
renders one arm per variant and computes no structure of its own, so the row the cursor is on and
the row that is drawn cannot come from two pieces of arithmetic. `sorted_by_priority`,
`sorted_by_recency`, `paused_age`, `SectionKind` and `WORK_ROWS_PER_SECTION` live in `app.rs` for
that reason.

**Exactly one view supervises, and `.cerebro/project.conf` says which** (`fleet_supervisor
emacs|tui`, absent means `emacs`, so every consumer that predates the key is untouched).
`scripts/fleet-supervisor` is the one place either implementation reads it, and the one place the
lease's address is computed — a port derived from the *shared* root, so every worktree of a
checkout contends for one lease. An invalid value is fail-closed and loud: exit 2, the sentence on
stderr, the raw word on stdout, and **both views go read-only** rather than one of them assuming
the default.

**The lease is a bound loopback listener and nothing else.** No pid file, no timestamp, no
heartbeat, no lease duration, no stale-entry sweep: the kernel closes a listener when its holder
dies, so a crashed owner releases immediately and nobody has to decide it had crashed. Every
timeout scheme has a window in which a live owner looks dead; this one has none.
`.cerebro/state/supervisor.json` beside it is **diagnosis only** — it names who to put on the
header or the mode line, and a missing, malformed or foreign record on a bound port is a visible
lock error, never permission to take over. `tests/lib/supervisor.cases` is the transition table
both implementations answer, because Emacs and Ratatui disagreeing about ownership is a fleet with
two supervisors or with none.

A view that does not own the checkout starts, nudges, arms, triages and prunes nothing — the
**session lifecycle** is what the lease gates. The bead panel's own keys are deliberately outside
it: `x` on a sweep finding and the priority keys write to the shared board rather than to this
checkout's sessions, they are the navigator's own act and each asks first, and a board `bd` runs
the same from any machine whether or not this Emacs supervises anything. A view whose
declaration moved *while it hosts sessions* **drains** — it keeps the lease so the new owner cannot
start duplicates, keeps those sessions usable, and releases when the last one ends. Emacs shows
this in its mode line (`Cerebro[read-only: Ratatui supervises]`); the TUI shows it in its header
line and nowhere else, which is the navigator's choice: ownership takes neither a row nor a Tab
stop from Fleet and Work.

**The family is complete.** `cb-kcs.1` brought ownership, `.2` the PTYs, `.3` retirement, `.4` the
triggers and `.5` the sweeps, the pruner, the triage line and the cutover itself. This repository
declares `fleet_supervisor tui`; `M-x cerebro` is read-only here and stays supported, and rolling
back is one line (`docs/cerebro-supervision.md`).

One screen, **three** independently bordered, independently scrolling widgets since cb-kcs.2.1:
Fleet, Work and Session, each with its own title, focus and scroll offset rather than one shared
document. At `SPLIT_COLUMNS` (100) or wider the screen is a fixed `LEFT_COLUMN` (40) holding Fleet
over Work, with Session taking every remaining cell beside them; below that width all three stack.
`Tab` cycles Fleet → Work → Session and `Shift-Tab` reverses it, and since cb-5kk `F1`/`F2`/`F3`
jump straight to those three panes from any focus (held back from a focused live session like the
tabs; `F4` and above still reach the agent) — the focused one draws a
bright-blue thick-line border and a bold title. From a focused **live** session both are held back
from the child and run that same cycle (cb-3v5), so `Tab` is the one key back to Fleet and
`Shift-Tab` the one key to Work. Since cb-lor **arriving at the Fleet pane by any of those keys —
`Tab`, `Shift-Tab` or `F1` — drops a bead pinned in the Session pane** by `Enter` on a Work row
(cb-41r), so that pane goes back to drawing the selected agent, at its top; `F2` and `F3` leave a
pinned bead alone, and `Enter` on the same Work row re-opens it. `↑`/`↓`/`PgUp`/`PgDn` move only the focused widget:
under Work and Session that is its own scroll offset, and **under Fleet it is the selection**, which
the pane then scrolls to follow. Since cb-d31 **`Enter` under Fleet focus is `Tab` twice in one
key**: it moves focus straight to the selected agent's Session pane, and only while that pane is
holding something — a live child, one starting, a retained pass or a refused launch. An empty pane
refuses in gold (`Rogue has no session`) and leaves the focus where it was, so walking the roster
with `↓` never throws the navigator into an empty pane; nothing selected is silent. It moves focus
and nothing else, so it is **outside the supervision lease** exactly as `x` and the priority keys
are, and it behaves identically on a read-only view. `g` refreshes both readers regardless of focus,
`q`/`Esc`/`Ctrl-C` quits. A pane whose content outgrows its inner height reserves its last row for a dim
`Rows n–m of total` cue.

**The selection is a name, never an index** (`App::selected`, `App::selected_index`): the roster can
shrink under the navigator, and an index would silently come to mean a different agent. A selected
agent that leaves the roster moves the selection to the row at its old index, clamped, and says so
in the header in gold until the next keystroke (`App::notice`) — and only ever on a **successful**
fleet read, so a five-second `ps` hiccup can never reselect anybody. The fleet body is not one line
per row (a heading, plus a diagnostic line per invalid row), so `model::row_document_line` is the
one place a row index becomes a document line and the renderer calls it rather than keeping a
second copy.

Session can hold a real child since cb-kcs.2.2: `scripts/launch <Name>` in a pty (`portable-pty`),
its screen drawn from a `vt100::Parser` this crate owns — which is why a killed child's screen is
still drawable — and every key of a focused live session forwarded to it, with `Tab` and
`Shift-Tab` both held back as the two ways out — `Tab` to Fleet, `Shift-Tab` to
Work. A pass that ends is kept as a scrollable transcript of at most ten thousand
lines, until that agent starts again. **Nothing a navigator can press starts one**: `SessionHost::spawn`
is reached by test code alone, and `s`/`f`/`k` are cb-kcs.2.3's, so the pane still says why there is
no session in it and the header hint still names no key that does not exist. The rule that pays for
all of it is that `SessionHost::sync` materialises the child's screen into a `SessionView` **before**
the frame: `App` holds no pty, no thread and no child, and `ui::draw` stays pure over `App` while a
reader thread writes into a parser continuously. That reader thread drains the master
unconditionally, focused or not — a pipe nobody drains is a deadlock — and `Session`'s `Drop` kills
its child, because a pane the navigator can no longer see must not leave an agent running against a
bead nobody is watching. The surface the navigator approved for the
whole `cb-kcs.2` family is the split console, interviewed over three rounds on 2026-09-01. It
refines `docs/ui/cb-kcs-supervisor.html`, which the epic's own interview approved, and supersedes
`docs/ui/cb-42k-independent-widgets.html` and the original single-document
`docs/ui/cb-vyp-read-only-view.html`. **Its own mockup file arrives with its own docs-only pull
request rather than with any of the three children**, so this paragraph deliberately names no path
for it: a pointer that resolves on one merge order and not the other is worse than none, and
nothing checks a path written in prose the way `scripts/tracked-links` checks a link.

The crate is split the way `cerebro.el` is, and for the same reason:

- `sweeps.rs` — pure throughout: what the six sweeps decide (`Sweep::judge`), the seven `Finding`
  shapes, the Sweeps line, the exact argv and the header's question. The Rust copy of
  `cerebro--sweeps` and its neighbours, held to `tests/lib/sweep-findings.json` the way `model.rs`
  is held to its own table. The four thresholds are `const`s here and defcustoms there, exactly as
  `lifecycle::END_GRACE_SECONDS` is.
- `pruner.rs` — the `prune-worktrees.sh --watch` child and its one pure decision
  (`prune_action`), its own module for `session.rs`'s reason: it owns a child process with a
  lifetime longer than any call. Its `Drop` kills the child, and the `Pruner` is constructed
  **before** the `TerminalGuard` so it drops after it. Both pipes are `Stdio::null()` — a pipe
  nobody drains is a deadlock — and `Child::try_wait` is what keeps a dead watcher from being a
  zombie that reads as live for ever.
- `model.rs` — pure parsing and derivation (roster, state files, the marker sentence, the process
  tree, `partition_beads` — which since cb-hzl skips an epic only while it HAS a direct child,
  answered from the ids the one board read already holds, so a childless epic partitions like any
  other bead; `scripts/work-beads`, whose list is scoped to one status, asks `bd children` instead). It is the Rust copy of the elisp rules, held to the same
  `tests/lib/session-args.cases` table as every other reader of the marker sentence.
- `supervisor.rs` — ownership: the pure `reconcile_supervision`, held to
  `tests/lib/supervisor.cases` the way `model.rs` is held to its own table, and `SupervisorLease`,
  the bound listener that IS the lock. One test starts a real Emacs, takes the lease from under it
  and kills it, which is why CI installs Emacs in the Rust job.
- `readers.rs` — every file and subprocess: `scripts/roster`, `ps -axo pid=,ppid=,args=`, and one
  `bd --readonly -C <shared root> list --status open,in_progress,blocked,deferred,closed --json
  --brief`. Each child has a wall-clock bound - five seconds, or `BD_TIMEOUT`'s thirty for the two `bd` reads,
  which wait behind the fleet's Dolt traffic - is killed **and reaped** on it, and has
  both pipes drained on their own threads before anything waits — a child that fills a pipe while
  the parent waits is a deadlock no timeout can see. `read_fleet` and `read_work` are the two
  aggregate reads, and **a failure is never an empty answer**: `Ok(vec![])` would draw a fleet in
  which every agent is dead, and `Ok(WorkBuckets::default())` a board with nothing on it. Since
  cb-x3u the spawning itself is behind `CommandRunner`: production passes `RealCommands`, which is
  the only implementation that starts a process, and a test about parsing passes
  `readers::testing::FakeCommands`, which answers from a table and records the argv. Spawning is
  proved once, in `fleet-view/tests/command_runner.rs`, against **tracked** fixture scripts under
  `fleet-view/tests/fixtures/` — a file no test writes cannot be `ETXTBSY`, which is what four
  patches in this module had been working around. Since
  cb-kcs.4.3 `read_gh` is a third reader — three `gh` calls on their own ten-minute cadence, each
  bounded at thirty seconds because these are network calls — and it is what starts the roles whose
  work arrives from outside the fleet. Its pane is never drawn: its four content states are exactly
  what tells a trigger "no answer yet" (no suffix) from "the last request failed" (`gh?` on Moira's
  and Cypher's rows, and their hourly floor alone).
- `log.rs` — the three JSONL files, split the same way: the pure half (`Event::basename`,
  `log_event_p`, `log_evaluation_p`, `log_rotate_p`, `log_line`, `log_file`, `reader_context`) and
  one impure `Logger` that owns them. It is the ONLY thing in the crate that writes any of them, its
  root is a constructor parameter and never resolved — a logger that found its own root would make
  every test append to the navigator's live log — and it starts disabled, so a view that comes up
  read-only has written nothing by its first frame.
- `app.rs` — the display state, the two independent cadences (fleet every 5s, work every 30s) and
  one worker thread per pane. The panes are independent all the way down: one in-flight slot each,
  one clock each, one `Pane<T>` state machine each. A global busy bit would let the five-second
  fleet read starve the thirty-second work read, and a busy fleet would swallow the retry a
  navigator pressed `g` for. Since cb-21g the two board **writes** have a worker of their own — the
  eighth — for the reason the seven readers have theirs: a `bd dolt push` is a network call bounded
  at thirty seconds, and running it on the drawing thread froze the screen, keys and all, for as
  long as the remote took. **One** worker and one write at a time, deliberately: writes to the
  shared board must run in the order the navigator pressed them, and a pool would let `3` overtake
  `0` on the same bead. The UI thread decides (`lifecycle::priority_action`), records
  (`App::begin_write`) and looks (`App::finish_write`); it starts nothing. A write the worker
  never received is answered by `WriteAnswer::undeliverable`, and one it received and can no
  longer answer — its thread gone — by `App::abandon_outstanding_writes`, because `Worker::poll`
  answers `None` for "nothing yet" and for "never" alike and only the second is news
  (`Worker::is_dead`).
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
- **`scripts/plan-candidates` is the one place "which beads may a planner take at all" is answered**
  (cb-391). It is `work-beads --status open` plus five label rules — not `planned`, not `human`, not
  held by a `planning` label in either spelling, `verification:failed` only with `plan:revise`,
  never `verdict:stale` — and a sort by priority then id. It takes no arguments: one question, and
  its name is the question. It owns **no epic logic of its own**, because `work-beads` has owned
  that since cb-hzl, and a second copy of that rule is what it exists to end. It exists because
  those rules lived only in `skills/plan-bead/SKILL.md`, as two hand-written `jq` blocks, and they
  drifted from cb-hzl inside a day of it merging: the fleet view started a planner for a childless
  epic that the planner's own `--exclude-type epic` then excluded, so the planner reported nothing
  to plan and was woken again by the same bead. Priority stays at the two call sites, because
  *which* candidate and in what order is policy the skill explains at length. `tests/plan-candidates.sh`
  is its suite.
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
- **`scripts/four-eye-sync` is the one place "do this repository's copies of the merge-review rule
  agree" is answered** (cb-m7u). The Four Eye Principle is the implementer's whole standing approval
  to merge, and it used to be written out twice — the *Four Eye Principle* section above, and
  `templates/consumer-CLAUDE.md` — with nothing checking that the two agreed. They had already
  drifted: the closing sentence above, *"That is the whole standing approval, and it covers a
  planned bead only"*, had never been in the template. The rule now lives once, in
  `templates/four-eye-principle.md`, and each carrier wraps its copy in `<!-- four-eye:begin -->` /
  `<!-- four-eye:end -->`; the blank lines inside those markers are load-bearing, because CommonMark
  ends an HTML block at a blank line and a marker followed straight by prose swallows the paragraph.
  Findings on stdout, exit 1, in `tracked-links`'s house format — `drifted:`, `unmarked:`,
  `missing:` — with `tests/four-eye-sync.sh` as its suite. The carrier list is a decision, literal
  in the script: a **consumer's** own `CLAUDE.md` is theirs to edit and is never read. What the
  block *says* is deliberately not asserted, for the reason *Development practices* gives about
  grepping prose. Like `tracked-links` and `marker-readers` it is a gate predicate and must never
  join `launch-preflight`'s hot path: a check that refuses there is a fleet that cannot start. Its
  marker parsing now lives in `scripts/block-sync.sh`, shared with `scripts/state-contract-sync`
  (cb-mqa); its own output, exit codes and suite are unchanged, and `tests/four-eye-sync.sh` passing
  unedited is what proved that extraction behaviour-preserving.
- **`scripts/state-contract-sync` is the one place "do this repository's copies of the state-file
  contract agree" is answered** (cb-mqa). The contract — how to call `scripts/agent-state`, what the
  four state words mean, what `--pid $PPID` is, the question sandwich, the hook behind `asking` —
  was written out in seven role documents, and it drifted in the direction that makes an agent write
  a wrong state: one sentence was corrected in `agents/implementer.md` and re-corrected across five
  more files the same day (`5c12795`, `1f09133`), and `agents/verifier.md` still told Psylocke to
  write `idle` at the end of a pass directly under the bullet forbidding it. It now lives once, in
  `templates/state-file-contract.md`, and each carrier wraps its copy in
  `<!-- state-contract:begin -->` / `<!-- state-contract:end -->`; the blank lines inside those
  markers are load-bearing, for the same CommonMark reason. Findings on stdout, exit 1, in
  `tracked-links`'s house format, with `tests/state-contract-sync.sh` as its suite. The carrier list
  is a decision, literal in the script: the seven documents a session actually **loads**.
  `agents/implementer.md` and `agents/planner.md` are deliberately not on it — both are thin role
  files that defer to their skill, and both sessions load that skill, so a copy there would be read
  twice per session and kept in step for nothing; each points at its skill's section instead. What
  the block *says* is deliberately not asserted. Like `four-eye-sync` it is a gate predicate and
  must never join `launch-preflight`'s hot path.
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
- **`scripts/portable-snippets` is the one place "does a skill or agent snippet only word-split
  under bash" is answered** (cb-7ft). An agent pastes the snippets in `skills/` and `agents/` into
  whatever shell its tool provides, and an alternate-value expansion means two different things
  across them: bash splits an unquoted one into several arguments, zsh does not word-split a
  parameter expansion at all, so the command receives a flag glued to its value and answers with its
  usage line. Two implementers hit that at the same line of the same file and wrote the same
  prevention (cb-i1w, cb-hz4) while the snippet stayed byte-identical, which is the second sighting
  a check is earned on. Findings on stdout, exit 1, in `tracked-links`' house format —
  `unportable: <path>:<line>` — with `tests/portable-snippets.sh` as its suite. It scans `skills/`
  and `agents/` and nothing else, for `tracked-links`' reason: those are the two directories the
  sync links into a consumer's discovery paths, and a wider pathspec would make the suite read
  `docs/`, `README.md`, `LICENSE` or `models.conf.example` and quietly break `scripts/ci-needed`'s
  skip list. Only the alternate-value form is matched, never the default-value one — `"${BD_TIMEOUT:-30}"`
  is portable and quoted, and flagging it would push authors toward uglier code for no defect. It is
  **not itself scanned**, living in `scripts/`, the way `marker-readers` is not itself a reader of
  the marker sentence — which is what lets its header spell the construct out where a skill may not.
  Like its siblings it is a gate predicate and must never join `launch-preflight`'s hot path.
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
- **`scripts/cargo-env.sh` is the one place bash answers which variables cargo put in this
  process's environment** (cb-6fu) — `cerebro_cargo_injected_name_p`,
  `cerebro_cargo_config_env_names`, `cerebro_cargo_protected_name_p` and `cerebro_strip_cargo_env`,
  sourced never executed, builtins alone for the narrowed PATH, in the shape of
  `scripts/session-marker.sh` and `scripts/root-hints.sh` beside it. Its one caller is
  `scripts/launch`, its suite is `tests/cargo-env.sh`, and the launch path's own cases are in
  `tests/launchers.sh`. It exists because `scripts/cerebro-tui` execs `cargo run`, so the fleet view
  is a **child of cargo** and hands its environment to every session it spawns — cargo's eighteen
  injected variables plus every key of the `[env]` table in the **consumer's** `.cargo/config.toml`.
  In atlantis-hud that meant `TS_RS_EXPORT_DIR` pointing at the navigator's shared checkout, so
  every agent's `cargo test` wrote its generated bindings there with no cwd mistake required
  (ah-79ca, ah-16pb). It is a **denylist and deliberately not the prefix `CARGO_*`**: `CARGO_HOME`
  and `CARGO_TARGET_DIR` are the navigator's own settings, and clearing the second costs a full
  rebuild per session. `PATH`, `HOME`, `CEREBRO_*`, `BEADS_*` and the shell's own bookkeeping names
  are protected against an `[env]` table that names them. **`unset` takes effect in the shell that
  runs it**, so `cerebro_strip_cargo_env` reports through two arrays as well as stdout: a caller
  reading its printed lines through `$(...)` or `< <(...)` strips nothing at all and prints a
  convincing list of what it did not do.
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
  Since cb-xhu.1 it is **also the one place a write to the fleet's live logs is refused**.
  `CEREBRO_PROTECTED_STATE_DIR` names a directory nothing may append into; a write at or under it
  returns non-zero, writes nothing, and records `<suite>\t<path>` in
  `$CEREBRO_PROTECTED_STATE_REPORT` when one is named. `scripts/suite-runner` is the only thing
  that sets either — it resolves `consumer-root --shared` once per run, names each suite in
  `CEREBRO_SUITE_NAME`, and turns any recorded attempt into a red run naming the suite and the path
  (an explicitly empty value is *guard off*, which is why it tests `${VAR+set}`). Production never
  sets it, so no launcher, session or fleet-view child changes behaviour at all.
  `scripts/agent-state` skips its whole log block, rotation included, when its own log is protected:
  the `mv` is outside the library, so a suite that reached the shared root would rotate the
  navigator's live log. **It is a refusal at the writer and not a before/after snapshot of the
  files**, because the live fleet appends to `decisions.jsonl` every five seconds and to
  `transitions.jsonl` on every transition while an implementer's gate runs in a worktree, so a
  size comparison would be red on essentially every local run. The guard covers the two bash-written
  `*.jsonl` logs only — a suite that wrote a `<name>.state.json` into the live directory would still
  not be caught, deliberately, since that write is `agent-state`'s primary job and no suite has ever
  done it. cb-xhu.1: 249 of the 437 lines of this checkout's `errors.jsonl` were one fixture, in the
  file the navigator is sent to by name.
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
  otherwise be for, and why they stay optional. Since cb-4qq a **dirty** checkout is refused only
  when the incoming commits change a file that has uncommitted changes — `git merge --ff-only` keeps
  every other local edit, and refusing on all of them closed a loop where each merged bead left the
  shared checkout one commit behind and one edited file then refused every launch of every name —
  and a merge or submodule update that cannot be done is a **refusal** (exit 2, naming the paths)
  rather than a bare exit 1 the fleet view reads as a crash.
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
