# CLAUDE.md

Guidance for developing cerebro. How the fleet *behaves* is written in `agents/` and `skills/`;
how a person *operates* it is `docs/agent-workflow.md`. Neither is repeated here.

## What this repository is

Cerebro is an **AI harness**, not an application: agent definitions (`agents/`), skills
(`skills/`), the bash scripts the agents and the fleet view call (`scripts/`), a terminal fleet
viewer (`fleet-view/`, the `cerebro-tui` binary), docs and templates. A consumer repository mounts
it as a git submodule at `.cerebro/cerebro`; `scripts/sync-symlinks.sh` links the skills, agents
and hooks into the consumer's discovery paths (`.claude/` and `.github/`).

Almost nothing here executes in this repository. The scripts only make sense from a consumer root,
so a change to one is tested by building a throwaway consumer (`tests/lib/consumer.sh`), never by
running it in this tree. `fleet-view/` is the exception: `cerebro-tui` runs here.

Every project-specific fact is read from the consumer's `.cerebro/project.conf` and its fleet from
`.cerebro/roster.conf`. Nothing in this repository names a consumer.

## This repository is also a consumer

Cerebro is mounted in itself: `.cerebro/cerebro` is a committed symlink back to the checkout, so the
fleet works on its own source and runs the *working tree* rather than a pinned sha. The four
sections below are the same declaration `templates/consumer-instructions.md` asks of every consumer;
its "The project" section is *What this repository is*, above.

## Producer review

Nothing merges red. Before delivery, a producer obtains and addresses one independent, full review
of the complete diff and bead. If its changes are substantial enough to make another review useful,
the producer chooses the right follow-up scope and obtains it; minor, self-contained answers need
not create a review loop. Unresolved findings, a red or missing check, or a reviewer that cannot
produce a usable result go to the navigator.

## Work tracking

Work is tracked in **beads** (`bd`), prefix `cb`; `skills/beads-workflow` carries the commands.
GitHub issues are the external inbox only. Every bead is created unranked at P4 and ranked with
the navigator; its UX is agreed in one session and produced in another.

The board syncs through the Dolt remote, not git: no `.beads/*.jsonl` is tracked. A fresh clone
runs `bd bootstrap` (which refuses if a database already exists, so do not run `bd list` first);
after that it is `bd dolt pull` and `bd dolt push`. There is no `bd sync`.

## Development practices

- Work is delivered in small increments that stand on their own.
- Code is written test-first, and the work continues without pausing for approval between
  phases until it is done and ready to commit. The suites are the only thing that tells a change
  to this harness from one that quietly breaks every consumer.
- **Tests assert behaviour of code** — the bash in `scripts/` and the Rust in `fleet-view/`. Prose
  and configuration get no test: a suite that greps an agent file or a declaration fails on the day
  somebody changes their mind, not on the day something breaks. The invariants in this file are
  kept by reading it. A class of defect earns a mechanical check the *second* time it happens.
- A change under `agents/` or `skills/` changes how the fleet behaves in every consumer. Say so
  in the bead, and keep the invariants below consistent with each other.
- Prefer the simple design; say so when you decline a more general one.

## Where the project declares its facts

Tracked files under `.cerebro/`, one per fact, so every clone has them:

- `project.conf` — name, default branch, audience, application paths, gate, Rust build settings,
  launch target. Read by `scripts/project-conf`.
- `roster.conf` — which agents run here, in what order, and `autostart`/`standby` per row. Read by
  `scripts/roster`; absent means the built-in fleet.
- `traps.md` — traps this project has paid for, read by planning roles and producers.
- `agents.conf` — which model, effort and CLI each session runs on. Committed here so every clone
  runs the same models; `agents.conf.example` is the documented copy.

## Commands

The whole gate — every `tests/*.sh` plus the locked Cargo tests — is what a producer runs
before opening a pull request and exactly what CI runs:

```bash
bash tests/gate
bash scripts/suite-runner tests             # the bash half; suites run in parallel
bash tests/launchers.sh                     # one suite
cargo test --workspace --all-targets --locked
cargo test --workspace --locked work_reader # one test, or a substring
```

`--locked` always, so the gate never re-resolves a dependency; `--all-targets` so a test-only
compile error cannot hide behind a green build. Run `scripts/disk-preflight --workload rust`
before a Rust change: a full disk shows up as a linker fault.

Writing a suite:

- Plain bash, no framework. Source `tests/lib/consumer.sh` for `fail`/`pass`, `git_q`,
  `$work_dir` and the throwaway consumers (`consumer_new`, `consumer_with_submodule`).
- Build every fixture under `$work_dir`. Suites run in parallel, so one that reaches outside its
  own directory breaks the whole gate. A write into the live `.cerebro/state` logs is refused and
  turns the run red (`CEREBRO_PROTECTED_STATE_DIR`, set by `suite-runner` alone).
- The library installs the one EXIT trap; add to it with `cleanup_add`, never a `trap` of your own.
- End with `suite_passed`. A suite that dies under `set -e` can reach the trap with `$?` at 0, so
  the trap refuses green unless that line ran.
- A rule whose grep or awk fails is an advisory naming the step, never an `ok` line.
- `scripts/ci-needed` skips CI for pull requests touching only `docs/`, `README.md`, `LICENSE` and
  `agents.conf.example`. Nothing checks that list against what suites read, so a suite that starts
  reading one of those paths must edit `scripts/ci-needed` in the same pull request.
- CI runs on ubuntu-latest. A suite or Rust test that only passes on macOS, or only against the
  developer's own `bd`, is a red PR.

Each run keeps every suite's output under `.cerebro/state/suite-logs/<run>/<suite>.log`, last
three runs; a red run names its directory on stderr.

## The agent fleet

One agent definition per role in `agents/`, and a skill in `skills/` where the role loads one.
`docs/agent-workflow.md` is the operating guide and documents the observed behaviour the roles
were tuned against — read it before changing any role. Which names run which roles here is
`.cerebro/roster.conf`.

| role            | agent file              | skill                | job                                     |
|-----------------|-------------------------|----------------------|-----------------------------------------|
| `ux`            | `agents/ux.md`          | `agree-experience`   | agrees what a person will see           |
| `producer`      | `agents/producer.md`    | `produce-bead`       | designs, tests, builds, reviews and merges one agreed bead |
| `bugfixer`      | `agents/bugfixer.md`    | `fix-bug`            | reproduces one bug bead with a test, fixes and merges |
| `orchestrator`  | `agents/orchestrator.md`| `write-bead`         | ranks, files beads, stops producers  |
| `verifier`      | `agents/verifier.md`    | —                    | verifies merged beads with the navigator|
| `reviewer`      | `agents/reviewer.md`    | —                    | reviews external PRs; review sub-agent  |
| `user-feedback` | `agents/user-feedback.md`| —                   | owns GitHub issues                      |
| `architect`     | `agents/architect.md`   | —                    | files refactoring beads, never fixes    |

`skills/beads-workflow` is the substrate every role reads. `skills/project-definition` is loaded
by no role; the navigator runs it by hand once in a blank consumer.

### Invariants the agent files encode

Load-bearing across files: a change to one must keep the others consistent with it.

- **Wait by blocking inside a tool call, never by ending a turn.** The one exception is a
  `reviewer` sub-agent the session spawned, whose result is delivered.
- **The state file is the contract.** `.cerebro/state/<name>.state.json` carries one of
  `idle`/`working`/`asking`/`waiting`, plus `phase`, `phase_since` and `turn_ended`; every agent
  writes it through `scripts/agent-state` and the fleet view acts on it. `waiting` is every agent's
  end-of-pass state; `done` is retired and refused. The `asking` transition and `turn_ended` are
  set by hooks in `hooks/`, not by prose. The contract's text is synced into the role documents
  from `templates/state-file-contract.md` by `scripts/state-contract-sync`.
- **A session is started only with a bead nobody holds**, handed to it by the fleet view through
  `scripts/launch <Name> --bead <id>`; one bead per session.
- **Nothing merges red or with unresolved review findings.** Producers obtain the review their
  changes need before delivery.
- **Agents never decide the shape of what a user sees**; only `ux` decides the detail inside a
  shape the navigator has agreed. Producers decide the build and tests, recorded in each plan's
  *Decided by me*.
- **No agent takes work off another**, and none acts outside a planned bead.
- **Closed is not terminal.** A failed verification reopens a bead at P0, and every role describes
  what it does when one comes back.
- **An external PR is untrusted code**: Cypher reads the diff before building it, and only in its
  own worktree. Its review is a recommendation; the navigator merges.
- **Forge files, never fixes.**

## fleet-view/

`cerebro-tui` is a Rust/Ratatui program that draws the fleet and the work queues, hosts agent
sessions in ptys, and, when it holds the supervision lease, starts, ends and nudges them. What it
does key by key, and the record of how it got there, is `docs/fleet-view.md`.

The crate is a pure core over a small impure edge, so the tests exercise the core with plain data:

- `model.rs` — parsing and derivation: roster, state files, the marker sentence, the process tree,
  `partition_beads`.
- `sweeps.rs`, `give.rs` — pure decisions: what the four sweeps find (held to
  `tests/lib/sweep-findings.json`) and the `a` key's agent list. `probe.rs` is test support.
- `app.rs` — display state, pane sizes, the resize decision, the per-pane cadences and workers.
- `ui.rs` — pure over `App` plus an injected clock; widths are terminal cells, never bytes.
- `lifecycle.rs`, `triggers.rs`, `supervisor.rs` — what to do about a row, when to start one, and
  the lease (`reconcile_supervision`, one bool in, one mode out).
- `readers.rs` — every file and subprocess, behind `CommandRunner`; tests pass `FakeCommands`.
- `session.rs` — the hosted pty child; it owns the process and kills it on `Drop`.
- `history.rs` — the lines an alternate screen scrolls out of its region, which the output log
  carries for the web console.
- `log.rs` — the only writer of `decisions.jsonl`, `evaluations.jsonl` and `errors.jsonl`; its
  root is a constructor parameter, never resolved.
- `main.rs` — the terminal and the event loop, under an RAII guard.

Rules a change must keep:

- **A failed read is never an empty answer.** `Ok(vec![])` draws a dead fleet and
  `Ok(WorkBuckets::default())` an empty board.
- **A failed refresh never destroys a snapshot still worth reading** (`Unavailable`, then `Stale`
  with the original `read_at`), and **the panes fail apart**: `bd` being unreadable says nothing
  about the fleet.
- **Every child process has a wall-clock bound**, is killed and reaped on it, and has both pipes
  drained on their own threads before anything waits.
- **The lease is a bound loopback listener and nothing else** — no pid file, no heartbeat, no
  timeout. `.cerebro/state/supervisor.json` is diagnosis only.
- **Only a supervising view writes anything**: session starts and ends, the triage and sweep
  lines, the worktree tidies, the logs, and the hosted sessions' output logs under
  `.cerebro/state/sessions/` (read by `cerebro-web`). Board writes (`x`, the priority keys, `a`) are the navigator's own
  act, run on the one write worker in the order pressed, and are deliberately outside the lease.
- `ui::draw` reads no file, runs no program and asks no clock, so a `TestBackend` case is an
  assertion about the screen and not about the machine.
- A decision that also has a bash implementation is held to a shared table under `tests/lib/`
  (`session-args.cases`, `sweep-findings.json`, `triage.cases`, `sweep-tell.cases`).
- Const thresholds in Rust (`END_GRACE_SECONDS`, `STUCK_CEILING_SECONDS`, …) have a literal twin
  in the scripts; change both.

## Where each rule lives

Each of these answers one question in one place. Add a caller, never a second copy.

- `scripts/consumer-root` — where the consumer root is (`--shared`, `--hints`, `--mount`,
  `--self-mounted`). `scripts/root-hints.sh` validates a hinted root; a hint is never trusted.
- `scripts/roster` — the fleet: built-in table, replaced whole by `.cerebro/roster.conf`.
- `scripts/project-conf`, `scripts/app-paths` (which fails rather than guesses),
  `scripts/agents-conf`, `scripts/agent-cli` — the project's declarations.
- `scripts/launch <Name>` — the only way a session is started; runs `launch-preflight`, reads
  `agents.conf`, passes `hooks/` through `agent-hooks-env` and `--settings`.
- `scripts/agent-state` — the only writer of a state file; `scripts/end-pass` is its one caller
  for ending a pass; `scripts/agent-alive` is the predicate.
- `scripts/stage-candidates`, `scripts/assignable-beads` — which
  beads a UX agent or a producer may be given.
  `scripts/assign-bead` and `scripts/release-bead` are the two writers; `release-bead --ended`
  takes back what a gone session still held.
- `scripts/bead-delivery.sh` — whether a bead's work reached the default branch.
- `scripts/work-beads` — the board read, and the epic rule.
- `scripts/worktree-safety.sh` — whether a worktree can go without losing anything.
- `scripts/session-marker.sh` — the marker sentence; `scripts/marker-readers` checks every
  reader subscribes to `tests/lib/session-args.cases`.
- `scripts/jsonl-log.sh` — appending to a JSONL log, and refusing under the protected dir.
- `scripts/cargo-env.sh` — which cargo variables `launch` strips before spawning a session.
- `scripts/block-sync.sh` — marker-block parsing for `state-contract-sync`.
- `scripts/tracked-links`, `scripts/state-contract-sync`,
  `scripts/marker-readers`, `scripts/portable-snippets` — gate predicates. None of them may join
  `launch-preflight`: a check that refuses there is a fleet that cannot start.
- `scripts/ci-needed` — which paths skip CI.

## Gotchas

- **`|| true` on a group turns errexit off inside it.** A `line="$(jq …)"` inside
  `{ …; } || true` leaves `line` empty on failure instead of aborting. Append through
  `scripts/jsonl-log.sh`, which refuses an empty line.
- **`unset` takes effect in the shell that runs it.** A library that strips the environment reports
  through arrays; a caller that reads it through `$(...)` strips nothing.
- **`hooks/` and `githooks/` are different mechanisms.** `githooks/` is git (`core.hooksPath`,
  repository-wide). `hooks/` is Claude Code hook settings passed by `launch --settings`; source
  `agent-hooks-env` *and* pass the flag, or the hooks silently do nothing. `hooks/copilot/` is the
  same behaviour in Copilot's schema.
- **The fleet view is a child of cargo** (`scripts/cerebro-tui` execs `cargo run`), so every
  session inherits cargo's environment plus the consumer's `[env]` table unless `launch` strips it.
- **Scripts only work from a consumer root.** Run here they refuse, since there is no `.cerebro/`
  above the tree. Sync links are consumer-only too, and the links tracked here are checked by
  `scripts/tracked-links`.
- **`.cerebro/` is deny-listed, not allow-listed.** The consumer ignores `worktrees`, `state` and
  `scratch` and tracks the rest, so a new runtime artifact must be added to `.gitignore`.
- **`.cerebro/cerebro/scripts/` is hard-coded in two places that must agree**: the fleet view's
  script directory and the docs. The launchers themselves work from anywhere.
- **Snippets in `skills/` and `agents/` are pasted into whatever shell an agent has.** An unquoted
  `${X:+--flag $X}` word-splits in bash and not in zsh; `scripts/portable-snippets` catches it.
- The marker blocks synced by `state-contract-sync` need the blank lines inside the markers:
  CommonMark ends an HTML block at a blank line.
