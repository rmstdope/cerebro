# CLAUDE.md — a starting point

This is a **template**, not a policy. Copy it to the root of a project that uses cerebro, then edit
every section until it describes what your project actually does. It is written as a working default
so the fleet runs on day one; it is **expected to be edited**, and a section you leave untouched is
one you have chosen by default rather than one that was decided for you.

Everything below is here because some part of cerebro reads it or assumes it. Each section says what
the fleet does with it, so you can tell an edit from a deletion.

## The project

> *The fleet's agents read this to know what they are building. Replace it.*

One paragraph: what this application is, who uses it, and what "working" means for it.

## Four Eye Principle

*Read by `skills/implement-bead` and `skills/plan-bead` — by this exact heading. An implementer's
standing approval to merge without asking comes from here, and from nowhere else. Delete this
section and every implementer stops merging.*

<!-- four-eye:begin -->

Nothing merges unreviewed and nothing merges red.

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself** — given the diff and the bead, never the implementer's own reasoning — and it
counts when all of these hold: at least one usable review covers the implementation being merged; it is
posted in full on the pull request; every finding from every usable round is answered, by a change or
by a posted reply saying why not; and every check is green. Failed or unusable attempts may be retried,
but three unusable attempts for one head require the navigator. That is the whole standing approval,
and it covers a planned bead only.

Updates after rebase and/or conflict resolution does not need to trigger an additional review.

Documentation only does not need reviews — `docs/`, `README.md` and the like. **A change under
`agents/` or `skills/` is never documentation**: those files are what the fleet reads, so a word
changed there changes how every consumer behaves, and they are reviewed like any other behaviour.
`scripts/app-paths --classify` settles the question when it is not obvious; anything it calls
`application` needs a review.

<!-- four-eye:end -->

No review is asked of the code-hosting platform, and none is waited for. A review a person or a bot
leaves on the pull request anyway is read and answered like any other comment; it is not what the
approval rests on.

Everything else needs a person — a change nobody planned, a red or missing check, a finding about
approach, scope or what the audience sees, a finding answered by neither a change nor a reply, and a
review sub-agent that could not be spawned or returned nothing usable.

## Work tracking

> *The fleet tracks planned work in beads (`bd`), not in issues. `skills/beads-workflow` carries the
> commands; this section is where a project says anything that differs.*

Planned work is tracked in beads. An external issue tracker, if there is one, is the inbox for
outside requests and bug reports only. Every bead is created unranked and ranked later with a human;
a bead is planned in one session and implemented in another.

## Development practices

> *Read by planners and implementers when deciding how much to build at once and how to test it.*

- Work is delivered in small increments that stand on their own.
- Code is written test-first.
- Prefer the simple design; say so when you decline a more general one.

## Where the project declares its facts

> *Not prose — files. The fleet reads these rather than guessing, and each is tracked so that
> every clone has it. `.cerebro/` also holds what the fleet writes while it runs, which is what
> the consumer's `.gitignore` keeps out:*
>
> ```gitignore
> .cerebro/worktrees
> .cerebro/state
> .cerebro/scratch
> ```
>
> *`worktrees/` is where implementers build; `state/` holds the agents' state files and stop
> flags; `scratch/` holds the planners' drafts and rejected mockup variants. `.cerebro/models.conf`
> is the project's choice — commit it to share the fleet's models, or add it here to keep it
> personal. These declarations lived under `.claude/` with a `cerebro-` prefix until cb-epr; a file
> left at the old path makes `project-conf`, `roster` and `launch-preflight` refuse, naming the
> `mv`.*

- `.cerebro/project.conf` — how the project installs itself, what its fast and full gates are
  called, which paths are the application, where retrospectives live, — with
  `verification none` — that nothing in it can be verified by looking, and **which fleet view may
  supervise** (`fleet_supervisor emacs|tui`; absent means `emacs`, and only the declared one starts,
  nudges or prunes anything — the other reads beside it).
- `.cerebro/roster.conf` — which agents this project runs, and in what order. Absent means the
  built-in fleet. An optional third word, one of two: `autostart` makes the fleet view start that
  agent as it comes up (cb-0r6), `standby` **arms** it without starting it (cb-98u) — its row reads
  `standby` and its role's own trigger is what starts it. `standby` on an implementer row arms it
  the same way (cb-1or.2); its trigger is a planned, unclaimed bead.
- `.cerebro/traps.md` — the traps this project has already paid for, read by planners and
  implementers before they start. Absent means the project has paid for nothing yet, which is where
  every project starts.
