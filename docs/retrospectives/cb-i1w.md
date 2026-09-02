# cb-i1w — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-02
- **PR:** #283

## The skill's `model-for` snippet is bash, and the session's tool shell is zsh

**What happened.** `implement-bead`'s *The review loop* gives the reviewer-model lookup as

```bash
provider="$(.claude/cerebro/scripts/agent-cli)" || provider=""
.claude/cerebro/scripts/model-for ${provider:+--provider "$provider"} --role reviewer
```

Run verbatim, it printed `usage: model-for [--provider <p>] [--name <n>] [--role <r>]`. The cause is
the shell: this session's Bash tool runs zsh (an earlier compound command failed with
`(eval):1: == not found`, and zsh does not word-split `${var:+--provider "$var"}`, so `model-for`
received the single argument `--provider claude` rather than two). Running the two commands
separately answered immediately: `default@claude opus medium`.
**Why.** Established — zsh's lack of word splitting on unquoted parameter expansion, against a
snippet written for bash.
**Cost.** About two minutes and one wasted tool call, plus a moment spent suspecting the worktree
rather than the shell.
**Prevent by.** `skills/implement-bead/SKILL.md`, *The review loop*: write the lookup so it does not
depend on word splitting — two calls, or an explicit `if [ -n "$provider" ]`. The same shape appears
in *Workspace*'s port block, which is not usually run here and so has not been paid for yet.
**Seen before.** None found — `grep -rn zsh docs/retrospectives/` is empty.
