# cb-mqa — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-01
- **PR:** #259

## The plan named a `source` spelling `tests/lib/place-scripts` cannot see, and said it was the one it derives

**What happened.** The plan instructed, twice and emphatically, to write the new library's source
line as `source "$(dirname "${BASH_SOURCE[0]}")/block-sync.sh"` — "never through a variable" —
because "`tests/lib/place-scripts` derives a script's libraries from exactly that line (cb-u70)".
That is the opposite of true. `place-scripts`' `sourced_by` awk is
`/^[[:space:]]*(source|\.)[[:space:]]+"\$[A-Za-z_][A-Za-z_0-9]*\/[^"]+"/` — it matches only
`source "$var/lib"`, which is the form every other library-sourcing script in `scripts/` uses. I
followed the plan, and `bash tests/lib/place-scripts --copy /tmp/psx four-eye-sync` then placed
`four-eye-sync` alone, with no `block-sync.sh` beside it: a fixture that would die at the source
line, which is the exact failure cb-u70 built `place-scripts` to prevent. The review sub-agent
caught it and read the regex; I had not.

**Why.** Established. The plan asserted a fact about a helper's body without opening it, and the
assertion was confident enough — a named script, a named bead, "exactly that line" — that it read
as verified. `skills/implement-bead/SKILL.md`, *When the plan is wrong*, already says a helper the
plan cites for what it decides is read before it is built on. I did not apply that rule here,
because the citation was about a *test fixture's* behaviour rather than about a predicate my code
would call, and it did not read to me as a claim that could be wrong.

**Cost.** One review round and one CI cycle, about twenty minutes. It was latent rather than red —
no fixture links these two scripts today — so a gate run could never have caught it.

**Prevent by.** *When the plan is wrong*'s helper rule should say that a plan's claim about a
**test fixture's** behaviour is a helper claim like any other: `place-scripts`, `consumer.sh`,
`suite-runner` decide how a suite is built, and a plan that describes what one of them accepts is
making a claim to open and read, not a build instruction to follow. As written the rule reads as
being about production predicates only, which is how I read past it.

**Seen before.** None found for this helper. `docs/retrospectives/` has no other entry about
`place-scripts`.

## `git checkout -- <file>` during the plan's own validation step destroyed an uncommitted increment

**What happened.** The plan's *Validation* section prescribes proving the checker fires on the real
repository:

```bash
perl -0pi -e 's/.../.../' agents/verifier.md
scripts/state-contract-sync ; echo "expect 1: $?"
git checkout -- agents/verifier.md
scripts/state-contract-sync ; echo "expect 0: $?"
```

I ran it at the end of increment 3 with that increment's carrier edits still uncommitted. The
`git checkout --` reverted `agents/verifier.md` to `HEAD`, which was increment 2 — so it discarded
the whole of the largest carrier edit, not just the one-word perl change. The second check printed
`unmarked: agents/verifier.md` instead of the expected exit 0, which is how I noticed; the edit had
to be redone from scratch.

**Why.** Established, and it is inherent to the recipe: `git checkout -- <path>` restores from the
index, and it cannot distinguish the deliberate one-word corruption from every other uncommitted
change in that file. The recipe is only safe on a clean tree.

**Cost.** About five minutes — the edit was scripted, so redoing it was cheap. It would not have
been if the edit had been by hand.

**Prevent by.** A plan whose validation step ends in `git checkout -- <path>` should say the step
runs on a clean tree, after the increment that produced the change is committed. Better still, the
recipe should use `git stash push -- <path>` / `git stash pop`, or copy the file aside and move it
back, neither of which is destructive of uncommitted work.

**Seen before.** None found — no other retrospective mentions `git checkout --`.
