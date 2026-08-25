---
name: release-notes
description: Write the release notes for a release — collect the beads that shipped in it, drop everything the audience could never see, and say what changed in terms of what they can now do. Use when a release has been cut and needs notes, or when asked what went out in one.
---

# Writing release notes

You turn a range of merged work into a short page a person who does not read code can act on. The
audience is whoever uses what this project builds, not the fleet that built it: they want to know
what they can now do that they could not, and what has stopped going wrong.

**First, read this project's word for them**, and use that word — not "user" — throughout the notes:

```bash
.claude/cerebro/scripts/project-conf audience_noun user   # "user" when the project declares none
```

Here it is **player**, and the rest of this skill is written with that word in it: read every
"player" below as whatever the key gave you. Form the plural by adding *s* and the possessive by
adding *'s* — `players`, `player's`; `operators`, `operator's`. **A noun with an irregular plural is
the one case that needs a hand**, and there is no second key for it: write the plural yourself and
carry on.

This is the one skill that names the audience concretely, and deliberately. Every other role here
says "the audience", because it is instructing an agent; these notes are the navigator's public
output, and *"name the areas the way a player would say where they were"* does work that *"the way
the audience would say"* loses.

**Everything technical is noise here.** No bead ids, no PR numbers, no file or module names, no
"refactored", "migrated", "wasm", "submodule". If a sentence would only make sense to somebody who
has read the repository, it does not belong on the page.

## The range

Two most recent tags, newest first:

```bash
git fetch --tags origin
git tag --sort=-creatordate | head -2      # e.g. v0.7.0 then v0.6.0
```

The notes cover `<previous>..<latest>`. If the navigator names a different pair, use theirs — and if
the latest tag is not the release they meant, ask rather than guessing; a release cut minutes ago and
one cut last week look identical from here.

## The beads that shipped

Every commit in the range carries its bead id in the subject — `feat(ah-3bl): …`, `fix(ah-p31): …` —
so the range gives you the ids, and `bd` gives you what they were for:

```bash
git log --format='%s' v0.6.0..v0.7.0 \
  | grep -oE '\(([a-z]+-[a-z0-9.]+)\)' | tr -d '()' | sort -u
```

A bead usually has several commits and sometimes none of its own — a bead delivered inside another
bead's PR leaves no subject of its own, and is picked up below when you read what actually changed.

## Dropping what a player cannot see

**A bead belongs in the notes only if it changed the application.** The test is the one Psylocke
uses, and it is about paths rather than judgement:

```bash
git show --stat --format= <sha>     # for each commit of the bead
```

**Application-touching iff some changed path is one of the project's application paths**, which
`.claude/cerebro/scripts/app-paths --classify <the changed paths>` answers with `application` or
`invisible`. **A non-zero exit means it could not classify** — the project declares no `app_paths` —
and that is said out loud in the notes rather than silently dropping the bead, since a project with
no declaration would otherwise produce empty notes and no sign of why. Everything it calls invisible
— `.claude/`, `docs/`, `scripts/`, `tests/`, `.github/`, config — is the fleet talking to itself. A new
agent, a rewritten skill, a CI fix and a test-only change are all invisible to a player, however much
work they were.

Two corroborations, both cheap:

- a bead already carrying `verification:not-needed` was ruled out by Psylocke on this same test —
  **unless the project declares `verification none`** (`.claude/cerebro/scripts/project-conf
  verification`), where every merged bead carries that label and it says nothing about paths;
- a bead carrying `verification:passed` has been watched working by the navigator, which is the
  strongest evidence it is worth a line.

Then drop one more class by reading rather than by path: **work that is invisible in practice**. A
fix to a feature that never shipped, a change behind a flag nobody can turn on, a correction to
something released in this same range — the player never experienced the problem, so telling them it
is fixed describes a bug they never had.

If dropping leaves nothing, say so plainly. A release that moved only the harness is a real thing and
the honest note is one sentence: *this release contains no changes a player will notice.*

## What each surviving bead actually did

Read three things, in this order, and stop when you can say what changed for the player:

- the bead's **description** — what was wrong or missing, usually in the reporter's own terms;
- its **acceptance criteria** — what had to be true afterwards, which is the outcome stated for you;
- the plan's **User-facing decisions**, in `design` — where the navigator settled how it would look
  and behave, and therefore what a player will actually meet.

```bash
bd show <id> --json | jq -r '.[0] | .title, .description, .acceptance_criteria, .design'
```

`bd show --json` answers with an **array**, even for one id — `.title` on it fails with "Cannot
index array with string", which is a confusing way to learn this.

**A bead from a GitHub issue is worth extra care.** Its `external_ref` is a `gh-<n>`, which means a
real person hit it and wrote it up — they are likely to read these notes looking for their own
report, and they will recognise a description of the thing they saw. Read the thread if the bead is
thin.

## Writing it

**Group by the part of the app, not by the kind of change.** A player thinks "what is different
about the map", not "what was a bug and what was a feature" — so a fix to the map belongs beside a
new map feature, and the reader meets everything about one surface at once.

```markdown
What's new for you in Atlantis HUD (<version>)
=============================================

## Map

- Right-click a hex to instantly jump the map to it, without changing what you have selected
- Province borders are bolder and easier to see at any zoom level

## Writing orders

- You can now import orders straight into the app instead of retyping them
- Cleaner spacing in the orders editor, with errors marked more clearly
```

**The areas come from the work, not from a fixed list.** Name them the way a player would say where
they were when they met it. What v0.7.0 wanted: Map, Layout, Writing orders, Turn history, Fleet
movement, Saving and exporting (desktop). A release about something else will want other names.

Order the areas by how much of the release lands in each, with two exceptions: what most players
touch daily goes near the top whatever its size, and anything that applies to only one platform goes
last with the platform in the heading.

**Rules that keep it readable:**

- **One line per item, no more.** No bold lead-in, no second sentence explaining the first. If a line
  needs a caveat to be true, the caveat is part of the line or the item is two items.
- **Address them directly.** "You can now plan sea routes…", "Right-click a hex to…". Not "the
  application supports" and not "we have added".
- **Describe the outcome, not the work.** "The hex you've selected is now much easier to spot, with a
  clear glowing ring" — not "added a double ring and pulse animation to the selection overlay".
- **A fix names the symptom they had.** "Fixed a bug where units from a previous turn could
  incorrectly still appear as if they were current" — they remember that happening. "Fixed a
  stale-state bug" tells them nothing.
- **Their words, not the codebase's.** Hexes, units, orders, turns, provinces and factions are the
  game's language and belong. Name a thing on screen the way the screen names it. Components,
  stores, crates and bundles never appear.
- **No counts of work**, no bead ids, no PR numbers, no version numbers of dependencies.
- **Nothing conditional.** If you cannot tell whether something is user-visible, ask the navigator
  rather than hedging — "may improve performance in some cases" tells a reader nothing and costs
  their trust.

**Err towards including a capability.** Something stored for later use, or a foundation a player
will meet next release, is worth a line if it can be said in their terms — "older reports are kept
properly for later reference" is useful; the increment of a feature that shipped complete in the
same release is not.

## Before you hand it over

Read it once as somebody who has never seen this repository, and cut every line that only makes
sense with it open. Then check the two failure modes that survive that reading:

- **A line nobody can act on.** If a reader cannot tell whether it affects them, it needs the "when
  it helps" half or it needs cutting.
- **A fix with no symptom.** Every entry under *Fixed* should name something a player could have
  noticed. If you cannot state the symptom, the change was probably invisible and belongs in neither
  section.

Then give it to the navigator. Where the notes go — the GitHub release body, a file, both — is
theirs to say, and `gh release edit <tag> --notes-file <file>` is the usual answer once they have
read it.
