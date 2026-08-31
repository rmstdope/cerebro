# cb-4z6.2 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-31
- **PR:** #217

## The procedure I was rewriting was unfollowable, and I only found out by following it

**What happened.** This bead rewrote `skills/implement-bead/SKILL.md`'s review section, and the
plan said plainly that I would be the first implementer to use the new flow, on this very PR. I
wrote the section, opened the PR, and then followed my own new text — and it had two holes the
review found rather than I did. It told me to `gh pr comment <n> --body-file <the review>` without
ever saying to write the review to a file, and it required every finding to be answered "by a
change or a posted reply" while having deleted the reply commands with nothing in their place: the
findings now arrive in-session, so there is no thread to reply to and the text never said where a
reply goes. It also called `scripts/model-for --role reviewer` without `--provider`, which
`scripts/launch` passes — on a consumer declaring `agent_cli copilot` that silently answers
differently from the launcher, the one defect `model-for`'s header says it exists to prevent.

**Why.** Established. Prose that describes a procedure reads as complete while you are writing it,
because you are holding the steps in your head as you write them; the gaps are exactly the steps
that were in your head and not on the page. Running the procedure is what separates the two, and I
ran it *after* the section was final rather than while writing it.

**Cost.** Small — one extra commit and one CI cycle, because the review caught all three. It would
not have been small unattended: the `--provider` omission is a wrong model on a Copilot consumer,
silently, with the launcher and the skill disagreeing about the same config file.

**Prevent by.** When a bead's diff changes the procedure the implementer is itself running, execute
the new text on the bead's own PR *before* the review, from the file as written, doing exactly what
it says and nothing it does not — and treat every step you complete from memory rather than from
the page as a hole in the page. The plan for this bead did anticipate the situation (its *Traps*
section says "you will be the first implementer to use this flow, on this very PR") but asked only
that I read the skill as I rewrote it; reading is what missed these, and running is what found
them.

**Seen before.** None found.
