# cb-5uqs — retrospective

- **Implementer:** Storm
- **Date:** 2026-11-26
- **PR:** #593

## A review replayed on today's bead is handed the findings of the first review

**What happened.** To compare reviewer models, 20 merged pull requests were reviewed again at the
head the first review read, with the bead taken from `bd show --json`. One replay's review said the
head was the attempt the bead's plan had rejected. Five of the 20 beads had their `design` or
`acceptance_criteria` rewritten after the first review, to answer it, so those replays were given
the answers.
**Why.** A bead's fields are edited in place while its pull request is under review, and `bd show`
gives only the latest. `bd history <id> --json` gives every earlier version with its commit date.
**Cost.** Five replays discarded and run again, about $1.40, and a comparison that would have
flattered the cheaper model had one review not mentioned the plan.
**Prevent by.** Any replay or measurement over merged beads reads each bead from
`bd history <id> --json` as of the original run's start, never from `bd show`.
**Seen before.** none found.
