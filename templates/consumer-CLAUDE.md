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

Nothing merges unreviewed and nothing merges red.

For a change built by an agent, an automated reviewer counts as the second pair of eyes when all of
these hold: exactly one review is requested as the pull request opens; every comment it leaves is
answered, by a change or by a posted reply saying why not; and every check is green.

Everything else needs a person.

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

> *Not prose — files. The fleet reads these rather than guessing, and each is tracked so that every
> clone has it — by a `.gitignore` negation inside the otherwise-ignored `.cerebro/`:*
>
> ```gitignore
> .cerebro/*
> !.cerebro/project.conf
> !.cerebro/roster.conf
> !.cerebro/traps.md
> ```
>
> *`.cerebro/*` and not `.cerebro/`: a negation only works when the parent directory itself is not
> ignored. These lived under `.claude/` with a `cerebro-` prefix until cb-epr; a file left at the old
> path makes `project-conf`, `roster` and `launch-preflight` refuse, naming the `mv`.*

- `.cerebro/project.conf` — how the project installs itself, what its fast and full gates are
  called, which paths are the application, where retrospectives live.
- `.cerebro/roster.conf` — which agents this project runs, and in what order. Absent means the
  built-in fleet. An optional third word, `autostart`, makes the fleet view start that agent as it
  comes up (cb-0r6).
- `.cerebro/traps.md` — the traps this project has already paid for, read by planners and
  implementers before they start. Absent means the project has paid for nothing yet, which is where
  every project starts.
