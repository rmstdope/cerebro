# cb-1or.1 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-26
- **PR:** #159

## `bd show <id> --json` on a large plan comes back truncated, and `cat`ting the saved copy truncates again

**What happened.** *Picking up* says to read the plan with `bd show <id> --json`. This plan rendered
to 31KB, which is over the host's inline limit, so the tool result was a 2KB preview plus a path to
a persisted file. `cat`ting that file produced a second 2KB preview and a second persisted path —
the same truncation, one file further along. Reading it took `sed -n '1,160p'`, `sed -n '160,340p'`
and `sed -n '340,600p'` against the persisted path.
**Why.** Established: any tool output above the host's inline limit is saved to a file and previewed,
and `cat` is itself a tool call subject to the same limit. Plans in this repository routinely run
past it — this one carried a 12-item elisp change list, a 14-item test plan and nine traps.
**Cost.** Two wasted tool calls and about four minutes at the very start of the bead, before any
code was read.
**Prevent by.** `skills/implement-bead/SKILL.md`, *Picking up*, beside "**Read the plan with
`bd show <id> --json`.** The pretty renderer mangles it." — add that a large plan comes back as a
preview and a saved path, and that the saved file is read in ranges (`sed -n '1,160p' <path>`),
never with `cat`.
**Seen before.** None found — `grep -rl "bd show" docs/retrospectives/` and
`grep -rl "truncat\|persisted" docs/retrospectives/` both came back empty.
