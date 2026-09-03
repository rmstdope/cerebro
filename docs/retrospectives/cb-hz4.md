# cb-hz4 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-09-03
- **PR:** #309

## The `model-for` snippet failed the same way it failed for cb-i1w

**What happened.** `implement-bead`'s *The review loop* gives the reviewer-model lookup as
`.claude/cerebro/scripts/model-for ${provider:+--provider "$provider"} --role reviewer`. Run as
written it printed `usage: model-for [--provider <p>] ...` and exited non-zero; run as two separate
commands it answered `default@claude opus medium` at once. This session's Bash tool is zsh, which
does not word-split an unquoted parameter expansion, so `model-for` was handed the single argument
`--provider claude`.
**Why.** Established, and established once already: `docs/retrospectives/cb-i1w.md` records the
identical failure with the identical diagnosis. The snippet is unchanged since.
**Cost.** About a minute here — small, and that is the point: it is the second sighting of a defect
that will greet every implementer on this machine at the same line of the same file.
**Prevent by.** `skills/implement-bead/SKILL.md`, *The review loop*: write the lookup without
relying on word splitting — two calls, or an explicit `if [ -n "$provider" ]`. cb-i1w said the same
and nothing changed, which is what makes this worth filing rather than shrugging at. *Workspace*'s
port block has the same shape and has still not been paid for.
**Seen before.** cb-i1w — same snippet, same shell, same diagnosis.
