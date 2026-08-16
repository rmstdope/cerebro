---
name: release-notes
description: Write the release notes for a release — collect the beads that shipped in it, drop everything a player could never see, and say what changed in terms of what they can now do. Use when a release has been cut in atlantis-hud and needs notes, or when asked what went out in one.
---

# Writing release notes

You turn a range of merged work into a short page a person who does not read code can act on. The
audience is a player of the game, not the fleet that built it: they want to know what they can now
do that they could not, and what has stopped going wrong.

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

**Application-touching iff some changed path matches `^(packages|crates|apps)/`.** Everything else —
`.claude/`, `docs/`, `scripts/`, `tests/`, `.github/`, config — is the fleet talking to itself. A new
agent, a rewritten skill, a CI fix and a test-only change are all invisible to a player, however much
work they were.

Two corroborations, both cheap:

- a bead already carrying `verification:not-needed` was ruled out by Psylocke on this same test;
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

```markdown
# <version> — <date>

<One sentence, only if the release has a theme worth naming. Skip it rather than inventing one.>

## New

- **<What they can now do>.** <One sentence on when it helps.>

## Fixed

- **<What was going wrong, as they would have experienced it>.** <What happens now instead.>

## Changed

- **<What behaves differently>.** <Why, if it is not obvious — a change without a reason reads as
  something taken away.>
```

Only the sections that have entries. Most releases have two.

**Rules that keep it readable:**

- **One line each**, bolded lead, plain sentence after. A player scanning for whether to update reads
  the bold and stops.
- **Describe the outcome, not the work.** "The map now centres where you right-click" — not "added a
  right-click handler to the map canvas".
- **Say what they experienced, for fixes.** "Units from an earlier turn no longer appear as if they
  were still there" beats "fixed a stale-state bug in the unit list": the first is a thing they
  remember happening.
- **Their words, not the codebase's.** Hexes, units, orders, turns, factions are the game's language
  and belong. Panes, dialogs and panels are borderline — name the thing on screen the way the screen
  names it. Components, stores, crates and bundles never appear.
- **Order by what they will notice**, not by bead id or merge order. The thing most players will meet
  first goes first.
- **No counts of work.** "Twelve beads shipped" measures the fleet, not the release.
- **Nothing conditional.** If you cannot tell whether something is user-visible, ask the navigator
  rather than hedging on the page — "may improve performance in some cases" tells a reader nothing
  and costs their trust.

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
