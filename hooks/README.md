# hooks/

Claude Code hook settings `scripts/launch` passes to `claude --settings`. Not git hooks — those are
`githooks/`, and they are a different mechanism entirely.

## `question-state.settings.json`

Keeps an interactive agent's state file honest across a question to the navigator: `asking` for
exactly as long as the question tool is open, and back to what it was doing the moment an answer (or
a cancellation) lands. It runs `scripts/agent-asking`, whose header says why this is a hook and not
another paragraph in an agent file — the short version is that Psylocke had been told three ways and
still asked under `working` and still left `asking` behind after the answer, because those two
writes sit either side of the one moment where attention is on the human.

**The whole fleet gets it**, from the two lines in `scripts/launch` — the interactive roles and the
implementers alike. The problem is the fleet's, not Psylocke's: she is only where it was noticed.
Nothing in the hook knows a role, so an implementer stuck on a question mid-review gets the same
honest row.

```bash
. "$here/agent-hooks-env" "$name"               # exports CEREBRO_AGENT_NAME and CEREBRO_SCRIPTS
exec claude ... --settings "$CEREBRO_HOOK_SETTINGS" ...
```

`launch` is the only place a session starts, so it is the only place this is wired — the same reason
`BEADS_ACTOR`, `launch-preflight` and the model live there once rather than six times. The name it
passes is the one `roster --entry` resolved, which is what the state file is called after and not
necessarily what the navigator typed.

The variables are read by the hook at hook time, from the environment `claude` inherited from
`launch`. Without them `agent-asking` exits 0 and does nothing, so the settings file is inert in an
ordinary session and the hooks cannot break a question that has nothing to do with the fleet.

`--settings` adds to the consumer's own settings rather than replacing them, so a repository that
configures its own hooks keeps them.

The agent files still describe the same transitions themselves, and should: the hook covers the
question tool, and an agent asks in prose sometimes too. Two copies of a rule that is this cheap to
write is the right number.

What the hook deliberately does **not** do: invent a state file that does not exist yet (a question
asked before the agent's first `agent-state` call is invisible to it), invent a bead or a phase, or
touch a file that is not at `asking` when `end` runs without a sidecar. Each of those would need a
guess, and a wrong state file is worse than a late one.

A session that dies between `begin` and `end` leaves its sidecar behind, describing a bead the next
session has nothing to do with. `begin` removes any sidecar it finds when the file already says
`asking` — the one path that would otherwise carry it forward — so a crash can only ever cost the
no-sidecar restore (`asking` → `working`, bead and phase read from the file itself), never a restore
of somebody else's bead.

## `copilot/cerebro-question-state.json`

The same behaviour for GitHub Copilot, in Copilot's own hook schema — `preToolUse`, `postToolUse`
and `postToolUseFailure`, each matching its `ask_user` tool, each running the same
`"$CEREBRO_SCRIPTS/agent-asking"`. **`scripts/agent-asking` is shared and unchanged**: it reads
`CEREBRO_AGENT_NAME` out of its own environment, which cb-d59.1 measured surviving `exec copilot`,
and knows nothing about providers. Do not give it a provider branch.

**Copilot has no `--settings`.** It discovers hooks from `.github/hooks/*.json` **in the
repository**, so this file cannot be handed to it on the command line the way the Claude Code
settings file is: `scripts/sync-symlinks.sh` links it into the consumer's `.github/hooks/`, and
`scripts/agent-cli --hooks` is the one place the source and destination paths are written down.

The link is written in **every** consumer, whatever `agent_cli` declares — the rule cb-d59.4 took
for agents and skills, so switching a fleet to Copilot stays one line in `.cerebro/project.conf`.
The accepted cost: a Claude-Code-only project carries a `.github/hooks/` file it never uses, and
the hook fires for *any* `copilot` run in that repository. That is harmless — `agent-asking` exits 0
doing nothing when `CEREBRO_AGENT_NAME` is unset.

Two things to know before changing it:

- **The two schemas are different files and different shapes.** Copilot's entry names the script in
  `bash`; Claude Code's names it in `command` and carries a `timeout`. Copying one file's shape onto
  the other produces a hook that is silently never run. A `matcher` matches the payload's internal
  `toolName`, never the name a transcript renders.
- **Whether Copilot follows a *symlinked* hook file is unmeasured.** cb-d59.1 measured it following
  a relative symlink for an agent file (M4) and a skill directory (M5); its hook probe (M6) wrote a
  real file. `cb-d59.6` measures this one. Until then: if a Copilot fleet never shows `asking`, the
  symlink is the first suspect, and replacing the link with a copy of the file at the same path is
  the fix.
