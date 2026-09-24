---
name: project-definition
description: "Define a blank repository by interview — what the software is, where it runs, what it is built with, what using it is like — and leave it ready to work: the declarations under .cerebro/, the root CLAUDE.md, the bead board with its Dolt remote, and the opening epics filed and ranked. Use when a repository holds nothing but a README and the harness and the navigator wants to start a project. Invoked by hand as /project-definition; never loaded by a fleet role."
---

# Defining a project

You interview the navigator and leave the declarations, `CLAUDE.md`, a board with a remote and
ranked epics. Run once per repository via `/project-definition`; no role loads you; no state file.
Beads you file carry no plan. Bead commands: `beads-workflow`.

## Announce yourself, and check the repository is blank

First message: **"I am the project-definition session."** Both checks run before any question:

```bash
root="$(.cerebro/cerebro/scripts/consumer-root)"
cd "$root"
# The board: does one exist, and is it empty?
bd list --status open --json 2>/dev/null | jq -r 'length'      # nothing printed: no board yet
# The tree: tracked files that are neither the harness nor a README/LICENSE.
git ls-files \
  | grep -v -E '^(\.claude/|\.cerebro/|\.beads/|\.gitignore$|\.gitmodules$|CLAUDE\.md$|README[^/]*$|LICENSE[^/]*$)' \
  | wc -l
```

`consumer-root` answers the tree the session started in. If `.cerebro/cerebro` does not resolve,
refuse (never do the setup):

> cerebro is not mounted at .cerebro/cerebro — do steps 1 and 2 of its README first, then run
> /project-definition again.

**Open beads — refuse.** Say this (count, first three) and write nothing:

> This project already has work on its board — N open beads, the first three: `<id>` <title>,
> `<id>` <title>, `<id>` <title>. Project definition is for a blank repository; new work goes on
> that board as a bead, and a planner session plans it. Stopping here; nothing was written.

**Other tracked files** — read every file found (over fifty: list by directory, read
ten), then ask:

> The tree already holds code: <the files>. I have read it. Do you want me to define the project
> around what is here, or stop?

Options *"Continue, treating this code as given"* and *"Stop"*. *Stop*: write nothing, say so.
*Continue*: ask about stack and layout in the past tense; never propose replacing it.

**Otherwise — go on**, saying:

> The board has no open beads and the tree holds only <the files>, so this is a blank project.

## The interview: five topics, each pinned before the next

- In order. **Never accept the first answer**; follow up until you can write the read-back.
- Each ends with a short read-back via the question tool, *"Right"* / *"Not quite"* (correction in
  Other); only *"Right"* closes it. A correction to an earlier topic re-reads it.
- Question tool, up to four independent questions per batch, one at a time when dependent;
  propose answers.

### 1. What is it?

> What kind of software is this — a CLI, a service, a library, a desktop or mobile app, a web app, a
> harness, something else? One sentence on who uses it and for what.

Keep the navigator's own word for *"something else"*. Follow up: who uses it for what; single- or
multi-user; who else reads output.

### 2. Where does it run?

> How is it deployed, and to what — a host you rent, a container platform, a static bundle, an app
> store, a package registry, or nowhere because it is a library?

Follow up: environments; where data lives; who deploys, how often; what "down" means.

### 3. What is it built with?

> Which stacks are on the table? And which have you already ruled out, and why — the ruled-out ones
> matter as much, because a planner will otherwise propose them.

Ask the ruled-out stacks **explicitly**. Follow up: language, framework, database, package manager,
test runner. Then:

- **The gate** — one command, or a fast and a slow one: `gate_fast`, `gate_full`.
- **Install** — the command that makes a fresh clone's gate runnable: `install`. *"nothing"* is
  written as an absence with a reason.

> And which agent CLI should the fleet's sessions run on — Claude Code or GitHub Copilot?

`.cerebro/agents.conf` holds each agent's tool, model and effort; copy `agents.conf.example` to share it; absent means Claude
Code defaults.

### 4. What is using it like, and what does it look and feel like?

> Walk me through the first minute for each kind of user. What do they see first, what is the one
> thing they came to do, and what does done look like?

Follow up: day-one empty state; auth; how a mistake looks and is undone. Then:

> And what should it look and feel like? Visual style, and any reference you have in mind. Which
> platform's conventions it should follow — native, web, terminal. What it must do for people who
> cannot use it the ordinary way. And three words it has to feel like.

The three words are the navigator's to choose, not yours; they go into the root `CLAUDE.md`.

### 5. The declaration

Read back the whole `.cerebro/project.conf` as a fenced block, ask *"Anything wrong?"*, show the
derivation:

| Key | Where it comes from |
|---|---|
| `project_name` | topic 1 |
| `default_branch` | `git symbolic-ref --short HEAD`, or `main` on an unborn branch |
| `audience_noun` | topic 1 — the word for the people who use it, proposed from their answer (*setter*, *user*, *operator*) |
| `app_paths` | topic 3 — a regex over the paths the audience could see, proposed from the layout the stack implies |
| `gate_fast`, `gate_full` | topic 3; the same command when the project has one |
| `install` | topic 3; omitted with a comment when there is nothing to install |
| `verification none` | when topic 1 said library, harness or build tool — nothing in it can be verified by looking |

**Write every absent key as a comment saying why.**

## What gets written, and in what order

**Nothing is written before topic 5's *"Right"*.** Then in order, each shown as a diff or listing
before the next:

**1. `.cerebro/project.conf`** — topic 5's block, comments included.

**2. `CLAUDE.md`** from `.cerebro/cerebro/templates/consumer-instructions.md`: `## The project` becomes
read-backs 1, 2 and 4 as three paragraphs (drop the italic note and placeholder); one line in
`## Development practices` names the gate; keep every other template section verbatim,
the producer-review guidance especially. An existing `CLAUDE.md` is **merged**:
append absent template sections, write `## The project`, keep the rest, say which happened.

**3. `.cerebro/roster.conf`** — propose the built-in `TABLE=` from `.cerebro/cerebro/scripts/roster`
with `autostart` on `orchestrator`, `verifier`, `user-feedback` and `producer` rows,
none on `reviewer` or `architect`, as a fenced table:

> This is the fleet I will declare. Keep it, or say what to change — names, roles, fewer
> producers, which ones start on their own.

*"Keep it"* / *"Change it"* (changes in Other); repeat until *"Keep it"*. Header:

```
# The fleet this project runs. This file replaces the built-in table rather than merging with it,
# so what is left out is as much a decision as what is here.
#
# Order is load-bearing, not display: the interactive roles come first, and the orchestrator takes
# the next unused producer name in file order.
#
# A third word, `autostart', starts that agent with the fleet view; omitted means it is started by
# hand with `s'. Any other third word refuses, so a typo cannot read as "no".
#
# NAME          ROLE            [autostart]
```

**4. `.cerebro/traps.md`** — exactly this:

```markdown
# Traps

The facts this project has already paid for, read by producers before they start.
One entry per trap: what happened, what it cost, and what to do about it. Empty until the first one.
```

**5. `.gitignore`** — append these, with the comment, unless all three lines are already there:

```gitignore
# Cerebro writes these while the fleet runs; the declarations beside them are tracked.
.cerebro/worktrees
.cerebro/state
.cerebro/scratch
```

**6. The board.** Skip if a board exists. Propose a two- or three-letter lowercase prefix: first letter plus next consonant, else
the first two letters (Crux → `cx`, Ledger → `lg`):

> Bead ids will look like `cx-a1b`. Keep `cx`, or type another prefix.

The remote is `origin`; without one, ask and file nothing until it exists:

> The board needs a Dolt remote, and the repository has no `origin`. Give me the URL of the
> repository's remote and I will add it as `origin` and use it for the board; or stop.

```bash
bd init --prefix <prefix> --quiet
bd dolt remote add origin "$(git remote get-url origin)"
```

Before `bd init`, say it writes `.beads/` and appends to `.gitignore`; read the `.gitignore` diff
after.

**7. The beads**, then **8. `bd dolt push` and the commit** — below.

## The epics

After the declaration, open with:

> What has to exist before anyone can use this at all? Name the opening arcs, one line each; I will
> propose the children each obviously carries and you strike or add.

Per epic:

- **Read-back** — what it is, what "done" means; closed by *"Right"*.
- **Children** — three to six obvious ones, one line each, nameable without design. *"Strike or
  add?"*: drop struck, append added.
- **Rank** — options `P0` to `P4`, recommendation first marked `(Recommended)`, a reason in each
  description. **Children take the parent's priority.**

Epic:

```bash
bd create "<title>" --type epic -p <rank> --body-file <file>
```

body: read-back, done, out of scope. Child:

```bash
bd create "<title>" --type <feature|task> --parent <epic-id> -p <rank> --body-file <file>
```

body: what it is and why. `bd dep add <child> <sibling>` only where the navigator said so. Titles
follow `beads-workflow`: the effect, not the area; no *fix*/*improve*/*add support for*; ~70 chars.

Then ask once:

> Does any epic have to be built before another can start?

and run `bd dep add <later-epic> <earlier-epic>` for each pair named.

## The commit, and what is left to the navigator

One commit, and no push:

```bash
bd dolt push
git add .cerebro/project.conf .cerebro/roster.conf .cerebro/traps.md CLAUDE.md .gitignore .beads
git add .claude/skills .claude/agents          # the links the sync wrote, if untracked
git commit -m "chore: define the project"
```

`.beads` adds what `bd init` tracked. On the *Continue* path add exactly these paths, **never**
`git add -A`.

Last message, nothing more: files written, one per line; beads as id, title, priority, children
indented two spaces under their epic; the commit sha; then:

> Next, in this order:
>
> ```bash
> git push origin <default_branch>
> .cerebro/cerebro/scripts/cerebro-tui  # then press s on a planner's row
> ```

No project summary.

## What this session never does

- **Never writes a `design` or the `planned` label.**
- **Never claims a bead.**
- **Never sets a priority the navigator did not choose.** Anything they declined to rank is P4.
- **Never pushes git.**
- **Never runs `git add -A`.**
- **Never deletes or overwrites a file it found.**
- **Never writes `.cerebro/agents.conf`.**

## Known traps

- **`bd show --json` returns an array**: `bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .title'`.
- **`bd create` defaults to P2**: pass `-p` on every one.
- **`bd init` appends to `.gitignore`.**
