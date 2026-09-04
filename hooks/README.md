# hooks/

Claude Code hook settings `scripts/launch` passes to `claude --settings`. Not git hooks — those are
`githooks/`, and they are a different mechanism entirely.

## `session-state.settings.json`

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

### The turn-end hooks (cb-ykz.1)

The same file also carries a `Stop` hook and a `UserPromptSubmit` hook, both running
`scripts/agent-turn`. `Stop` — Claude has finished responding — stamps `turn_ended` into the state
file; `UserPromptSubmit` — a prompt submitted, before the model sees it — clears it again. So does
every `scripts/agent-state` write, an agent writing its own state being a session that is still
running turns. Neither entry carries a `matcher`: neither event supports one.

It exists because a session that writes `working` and then ends its turn without writing `waiting`
sits as `working` for hours, and nothing could tell that row from one doing real work. **Nothing
reads the field yet** — deriving "stuck" is cb-ykz.2 and acting on one is cb-ykz.3.

Two things about `agent-turn` differ from `agent-asking` beside it, and both are load-bearing:

- **It never writes to stdout.** Claude Code adds a `UserPromptSubmit` hook's stdout to the model's
  context on exit 0, so one stray `echo` is a sentence prepended to every prompt of every agent in
  every consumer.
- **It never exits non-zero**, not even for an unknown mode — which prints its usage on stderr and
  exits 0. Exit 2 on `UserPromptSubmit` erases the navigator's prompt; exit 2 on `Stop` refuses to
  let the session stop. `agent-asking`'s usage-error exit 2 would do one or the other here.

`SubagentStop` is deliberately not wired: a review sub-agent finishing is not its parent's turn
ending, and stamping there would clear the very signal cb-ykz.2 is being built on.

**Copilot has no equivalent, and gets none.** `docs/providers/copilot.md`'s measured event list
(M6) holds nothing that corresponds to `Stop` — `sessionEnd` fires when the whole session finishes
— so `hooks/copilot/cerebro-question-state.json` is untouched and keeps its name. A guessed event
name would be a hook that silently never fires, which is the failure this README already warns
about for matchers. The cost, plainly: a fleet declaring `agent_cli copilot` never gets
`turn_ended`, so when cb-ykz.2 lands no Copilot session will ever be marked stuck.

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
- **A hook file is loaded only in a folder Copilot trusts.** `~/.copilot/config.json`'s
  `trustedFolders` gates repo-level hooks entirely: in an untrusted directory the file is simply
  never read, and nothing says so. That is the first suspect when a Copilot fleet never shows
  `asking` — not the schema, and not the link. Measured in `docs/providers/copilot.md`, M6b.
- **A relative symlink is fine.** The link `scripts/sync-symlinks.sh` writes into `.github/hooks/`
  is followed and the hook fires (M6b), the same as for an agent file (M4) and a skill directory
  (M5). It need not be a copy.
