# cb-q6yb — retrospective

- **Implementer:** an interactive Claude Code session, at the navigator's request
- **Date:** 2026-10-07
- **PR:** rmstdope/cerebro#474

## The acceptance field went unread until the review

**What happened.** I planned and built from the bead's description, *Outcome* and *Where*, and
never read `acceptance_criteria`. The first build shared the label *words*. The acceptance asks
for the label *transitions* to be declared once and applied from there, and the review sub-agent
caught that as its blocking finding.
**Why.** `bd show` (the pretty view) puts the acceptance below a long description, and I stopped
reading at *Evidence*. `produce-bead` reads the bead with `bd show <id> --json`, which an
interactive session does not follow.
**Cost.** A second build round of named transitions, two snippets and four new suite cases, plus a
second review pass. About an hour.
**Prevent by.** A session that builds a bead outside the fleet reads `acceptance_criteria` from
`bd show <id> --json` before planning, as `produce-bead` already says for producers.
**Seen before.** Not in `docs/retrospectives/`.

## A mutation check restored a file from the index and erased a staged edit's successor

**What happened.** To confirm the new suite catches a broken writer, I mutated
`scripts/producer-park` and undid it with `git checkout scripts/producer-park`. That restores the
*index* copy. The index held an earlier staged version, so the later, unstaged `route_flags_for`
edit to that file was silently lost. A second mutation then ran against the stale file and "passed"
for the wrong reason. I noticed only because the diff stat of the next step looked wrong.
**Why.** `git add -A` before review left an index that was older than the working tree, and
`git checkout <path>` reverts to the index, not to HEAD and not to "before my mutation".
**Cost.** Re-applying the edit by hand and re-running both mutations, about fifteen minutes.
The result was nearly a false green.
**Prevent by.** Undo a mutation from a copy taken just before it (`cp f f.bak … cp f.bak f`, then
`cmp`), never with `git checkout`, whenever the working tree holds unstaged edits.
**Seen before.** Not in `docs/retrospectives/`.
