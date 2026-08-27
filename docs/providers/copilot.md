# GitHub Copilot CLI, as measured

Measured on 2026-08-26, `copilot --version` **GitHub Copilot CLI 1.0.80**, on macOS 26.6.2
(25G83, arm64), against the navigator's own Copilot subscription.

Every section below is a command that was run and the output it produced. Anything that could
not be measured says so and says why; nothing here is inferred from documentation. Where an
output is quoted it is quoted verbatim, minus terminal escape sequences.

The reference this replaces — `docs/ui/cb-d59-parity.html`, named by cb-d59.1's plan as the
doc-derived mapping to be superseded — **does not exist in this repository**. cb-d59's design
records it as "the committed copy", but it was never committed: `docs/ui/` holds no `cb-d59-*`
file. The `## Summary` table below is therefore built row-for-row from the flags
`scripts/launch` actually passes (`scripts/launch:194-204`), which is what that table mapped.

## Summary

| what `scripts/launch` passes today | Copilot equivalent | measured? | note |
|---|---|---|---|
| `claude` | `copilot` | yes (M1) | already installed globally via npm; a Node loader that forks a native child |
| `--agent <role>` | `--agent <role>` | yes (M4) | reads `.github/agents/<role>.agent.md`; relative symlink followed |
| `--name <Name>` | `-n, --name <name>` | yes (M3) | same spelling; a real argv token; also sets the terminal title and is a `--resume` key |
| `--remote-control <Name>` | **none** | yes (M12) | `--remote`/`--remote-export` is GitHub web/mobile control of a session, a different thing. Decision 7 already accepts this loss |
| `--model <id>` | `--model <id>` | yes (M8) | ids are Copilot's; an unknown id is a hard error, not a fallback. **Decided (cb-d59.6):** passed only from `.cerebro/models.conf`; the agent files' `model:` is Claude Code's word and is dropped |
| `--effort <level>` | `--effort, --reasoning-effort <level>` | yes (M7) | choices are `none,minimal,low,medium,high,xhigh,max` — but acceptance is **per model**, and the non-interactive default model rejects every level. **Decided (cb-d59.6):** passed only when a `.cerebro/models.conf` row names one, and then verbatim |
| `--append-system-prompt <marker>` | **none** | yes (M12) | no equivalent flag. The marker rides inside `-i`, and is measured reaching argv verbatim through `scripts/launch` (M13) |
| `--settings <path>` | `.github/hooks/*.json` (no flag) | yes (M6, M6b) | hooks are discovered from the repository, not passed on the command line. A relative symlink is followed; an untrusted folder is not read at all |
| `--permission-mode auto` | `--allow-all-tools` | yes (M9) | documented as required for non-interactive mode. **Decided (cb-d59.6):** `--allow-all-tools`, last in the arm, not the wider `--allow-all` |
| trailing bare prompt | **refused** — use `-i <prompt>` | yes (M3) | `copilot --allow-all-tools 'reply ok'` → `error: too many arguments. Expected 0 arguments but got 1.` |
| (root `CLAUDE.md` read as instructions) | same | yes (M10) | loaded as custom instructions, not read as a file |

## M1 Install and version

### Command

```
which copilot
copilot --version
ls -l /opt/homebrew/bin/copilot
npm ls -g --depth=0 | grep -i copilot
sw_vers
```

### Output

```
/opt/homebrew/bin/copilot
GitHub Copilot CLI 1.0.80.
Run 'copilot update' to check for updates.
lrwxr-xr-x@ 1 henrikku admin 49 Aug 26 22:09 /opt/homebrew/bin/copilot -> ../lib/node_modules/@github/copilot/npm-loader.js
├── @github/copilot@1.0.80
ProductName:	macOS
ProductVersion:	26.6.2
BuildVersion:	25G83
```

### Conclusion

The CLI was **already installed** on this machine as a global npm package (`@github/copilot@1.0.80`),
in Homebrew's node prefix. This bead therefore installed nothing and changed the navigator's
machine in no way, and the `npm install -g @github/copilot` the plan describes was not run.

The uninstall route, recorded here beside the install for whoever needs it later, is
`npm uninstall -g @github/copilot`. **It was not run**, and must not be: the navigator's own
installation predates this bead. The plan's increment 12 says to ask before uninstalling; there
is nothing this bead installed to remove.

Note for M3: `/opt/homebrew/bin/copilot` is a **Node loader script**, not the binary.

## M2 Authentication

### Command

```
copilot -p 'reply with the single word ok' --allow-all-tools
```

### Output

```
ok

Changes    +0 -0
Requests   0.33 Premium (2s)
Tokens     ↑ 18.7k (18.7k written) • ↓ 37 (30 reasoning)
Resume     copilot --resume=fce0b098-4e66-4d8b-889e-254806d4d6c7
```

### Conclusion

The CLI was **already logged in**. `copilot login` was never run and the navigator was never
asked to run it — the plan's increment 2, and the question it prescribes, did not arise. No
token was read, written or quoted anywhere in this bead.

## M3 The argv identity

The measurement cb-d59.3 stands on. Three shapes were run.

### Command

A session in the shape cb-d59.3 will use, started under a real pty (`pty.fork()` from Python,
because `script(1)` on macOS refuses a non-tty stdin — see M11), then inspected from another
shell:

```
copilot --name Cyclops --allow-all-tools \
  -i "This session is Cyclops of the cerebro fleet rooted at <root>/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it."

ps -o pid=,ppid=,args= -p <pid>
ps -o args= -p <pid> | wc -c
pgrep -P <pid>
```

and, separately, the marker as a bare trailing argument:

```
copilot --allow-all-tools 'reply ok'
```

### Output

The process the launcher would record (the direct child of the shell, i.e. what `exec` produces):

```
51714 51712 node /opt/homebrew/bin/copilot --name Cyclops --allow-all-tools -i This session is Cyclops of the cerebro fleet rooted at /Users/henrikku/repos/cerebro/.cerebro/worktrees/cb-d59.1/probe/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.
```

byte length `287`, nothing truncated.

Its one descendant, the native binary the loader forks (both pids stay alive):

```
51716 51714 /opt/homebrew/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot --name Cyclops --allow-all-tools -i This session is Cyclops of the cerebro fleet rooted at /Users/henrikku/repos/cerebro/.cerebro/worktrees/cb-d59.1/probe/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.
```

byte length `353`, nothing truncated. The grandchild count is zero.

For comparison, this fleet's own Claude Code session, measured the same way:

```
ps -o args= -p $PPID | wc -c   →   2881
```

The bare trailing argument:

```
error: too many arguments. Expected 0 arguments but got 1.
```

### Conclusion

Answering the plan's five questions:

- **Does `--name Cyclops` appear verbatim in the recorded process's command line?** Yes, in both
  the recorded pid's and its child's.
- **Does the whole marker sentence appear verbatim in that same command line?** Yes, in both, as
  the argument to `-i` — a separate argv token, so it survives `ps -o args=` intact.
- **Byte length, and truncation?** 287 bytes for the parent, 353 for the native child; nothing
  truncated. A Claude Code session in this fleet measures 2881 bytes intact, so there is ample
  headroom and Copilot's line is an order of magnitude shorter.
- **Does `copilot` re-exec or fork into a child whose command line differs?** It **forks a child**
  (it does not re-exec: both processes live). The child is a different executable path
  (`…/@github/copilot-darwin-arm64/copilot` rather than `node …/npm-loader.js`) but carries
  **every flag and the whole marker verbatim**. Both are quoted above.
- **Does the same hold with the marker as a bare trailing argument?** **No — there is no bare
  trailing argument.** `copilot` refuses one outright (`error: too many arguments`). The prompt
  must be given as `-i <prompt>` (interactive) or `-p <prompt>` (non-interactive), and the marker
  rides inside that string.

**Decision 4 survives, with a change of mechanism.** The marker does reach argv verbatim and is
usable as the whole liveness rule; but it cannot be appended as a trailing token the way
`scripts/launch` does today, and there is no `--append-system-prompt` (M12). On Copilot the
marker sentence and the "You are `<Name>`…" prompt have to be **one `-i` string**.

## M4 `--agent`, and symlinks

### Command

In a throwaway `probe/` directory, reached the way cb-d59.4 will:

```
mkdir -p .github/agents real
cp <cerebro>/agents/architect.md real/architect.md
ln -s ../../real/architect.md .github/agents/architect.agent.md
copilot --agent architect -p 'name the role you were given, in one word' --allow-all-tools
```

`real/architect.md` carries this repository's own frontmatter unchanged:

```
---
name: architect
description: Forge, the technical-debt session. …
model: opus
effort: xhigh
---
```

### Output

```
Warning: Custom agent "architect" specifies model "opus" which is not available; using "claude-haiku-4.5" instead
Forge.
```

### Conclusion

- **A relative symlink is followed.** The agent loaded through `.github/agents/architect.agent.md
  -> ../../real/architect.md`, which is the exact shape `sync-symlinks.sh:26` writes.
- **`--agent architect` resolves from the filename `architect.agent.md`**, as decision 6 assumes.
- **The extra frontmatter keys do not break the load.** `model: opus` produces a **warning on
  stderr and a silent substitution** to `claude-haiku-4.5` — not an error. `effort: xhigh`
  produced no warning at all; whether it was honoured or ignored was **not measured** (there is
  no observable difference in a one-word reply), and given M7 it is very likely ignored.
- The control run with a regular file was **not performed**, and did not need to be: it exists in
  the plan to tell a symlink failure apart from a frontmatter failure, and neither failed.

## M5 Skills

### Command

A skill reached by a relative symlink to a **directory**, the way `sync-symlinks.sh` links skills:

```
mkdir -p .github/skills realskills/probeskill
cat > realskills/probeskill/SKILL.md   # name: probeskill, description: …, body says to reply PROBE-SKILL-LOADED-7788
ln -sfn ../../realskills/probeskill .github/skills/probeskill
copilot skill list
copilot -p 'run the probeskill skill and reply with what it tells you to reply' --allow-all-tools
```

### Output

```
Project skills:
  probeskill - A probe skill. Use when asked to run the probe.

Builtin skills:
  customize-cloud-agent - …
  github-pr-media - …
```

```
● skill(probeskill)

PROBE-SKILL-LOADED-7788
```

### Conclusion

A **symlinked directory** under `.github/skills/` is discovered and invoked. `copilot skill list`
is a cheap, non-billing way to prove discovery without starting a session, which is worth knowing
for cb-d59.4's own validation.

**Not measured:** invocation by the slash form `/probeskill`, which needs an interactive session
and a keystroke. The skill was invoked by the model through a `skill(...)` tool call instead,
which is how a fleet agent would reach it anyway.

## M6 Hooks, and the hook environment

The measurement cb-d59.5 stands on. Hooks live in `.github/hooks/*.json` (confirmed by
`copilot help config`: "`hooks`: inline hook definitions, keyed by event name (same schema as
.github/hooks/*.json)").

### Command

`.github/hooks/probe.json`, with **no** matcher so every tool is caught, each hook writing the
*values* of the two variables:

```json
{"version":1,"hooks":{
 "preToolUse":[{"type":"command","bash":"printf '%s\\n' \"pre tool=[$(cat)] name=[$CEREBRO_AGENT_NAME] scripts=[$CEREBRO_SCRIPTS]\" >> /tmp/cb-d59-hook.log"}],
 "postToolUse":[{"type":"command","bash":"echo post-ok >> /tmp/cb-d59-hook.log"}],
 "postToolUseFailure":[{"type":"command","bash":"echo post-fail >> /tmp/cb-d59-hook.log"}],
 "sessionStart":[{"type":"command","bash":"echo session-start >> /tmp/cb-d59-hook.log"}],
 "sessionEnd":[{"type":"command","bash":"echo \"session-end payload=[$(cat)]\" >> /tmp/cb-d59-hook.log"}]}}
```

run three ways:

```
CEREBRO_AGENT_NAME=Cyclops CEREBRO_SCRIPTS=/tmp/x copilot -p 'run the shell command: echo hello-from-shell' --allow-all-tools
# and, under a pty, an interactive session told to use ask_user, answered once with Enter and once with Esc:
CEREBRO_AGENT_NAME=Cyclops CEREBRO_SCRIPTS=/tmp/x copilot --name AskProbe --allow-all-tools -i "Use the ask_user tool right now to ask me which colour I prefer, offering red and blue."
```

### Output

Shell tool, non-interactive:

```
session-start
pre tool=[{"sessionId":"b73cd965-…","timestamp":1787776779113,"cwd":"…/probe","toolName":"bash","toolArgs":"{\"command\":\"echo hello-from-shell\",\"description\":\"Run echo command to output text\"}"}] name=[Cyclops] scripts=[/tmp/x]
post-ok
session-end payload=[{"sessionId":"b73cd965-…","timestamp":1787776781157,"cwd":"…/probe","reason":"complete"}]
```

`ask_user`, interactive, answered with Enter:

```
session-start
pre tool=[{"sessionId":"3346722d-…","timestamp":1787776807587,"cwd":"…/probe","toolName":"ask_user","toolArgs":"{\"question\":\"Which colour do you prefer?\",\"choices\":[\"Red\",\"Blue\"]}"}] name=[Cyclops] scripts=[/tmp/x]
post-ok
```

`ask_user`, interactive, dismissed with Esc:

```
session-start
pre tool=[{"sessionId":"5812fabe-…","toolName":"ask_user","toolArgs":"{\"question\":\"Which colour do you prefer?\",\"choices\":[\"red\",\"blue\"]}"}] name=[Cyclops] scripts=[/tmp/x]
post-ok
session-end payload=[{"sessionId":"3346722d-…","timestamp":1787776917332,"cwd":"…/probe","reason":"user_exit"}]
```

An earlier run with `"matcher":"shell"` on the same tool logged **nothing**, while the same run
with no matcher logged `toolName":"bash"`.

### Conclusion

- **`preToolUse` fires when the session asks a question, and `ask_user` is the matching tool
  name.** Confirmed by the `toolName` in the payload, and independently by the CLI's own
  `--no-ask-user` flag ("Disable the ask_user tool").
- **The exported variables reach the hook subprocess.** `name=[Cyclops] scripts=[/tmp/x]` —
  neither bracket is empty, in every run. **cb-d59.5's mechanism holds**: `agent-hooks-env` can
  export `CEREBRO_AGENT_NAME` and `CEREBRO_SCRIPTS` before `exec copilot` and
  `scripts/agent-asking` will see both.
- **The matcher matches the internal tool name, not the displayed one.** The shell tool renders
  as `(shell)` in the transcript but its `toolName` is `bash`, and a `"matcher":"shell"` hook
  never fired. Anyone writing a Copilot hook file must match on the payload's `toolName`.
- **`postToolUse` fires on an answered question. `postToolUseFailure` was never observed** — a
  question dismissed with Esc still produced `post-ok`. So, as in Claude Code, **one arm is
  enough** to flip the state back; the two events were not shown to be disjoint. Whether some
  other cancellation route (Ctrl-C mid-question, session kill) produces `postToolUseFailure` was
  not measured.
- **`sessionStart` and `sessionEnd` both fire, and `sessionEnd`'s payload carries `reason`** —
  `"complete"` for a finished `-p` run, `"user_exit"` for an interactive session ended with
  Ctrl-C. Claude Code has no equivalent. Recorded under *What this changes*; **no bead filed.**
- The hook subprocess is fed the event payload on **stdin** as JSON (that is what `$(cat)`
  captured), which is also how Claude Code hooks receive theirs.

## M7 `--effort`

### Command

```
for e in low medium high xhigh max bogus; do copilot --effort $e -p 'reply ok' --allow-all-tools -s; done
copilot --model gpt-5-mini --effort high  -p 'reply ok' --allow-all-tools -s
copilot --model gpt-5-mini --effort xhigh -p 'reply ok' --allow-all-tools -s
copilot -p 'reply with just the model id you are running as, if you know it' --allow-all-tools -s
```

### Output

```
Error: Model "claude-haiku-4.5" does not support reasoning effort configuration (requested: "low").
Error: Model "claude-haiku-4.5" does not support reasoning effort configuration (requested: "medium").
Error: Model "claude-haiku-4.5" does not support reasoning effort configuration (requested: "high").
Error: Model "claude-haiku-4.5" does not support reasoning effort configuration (requested: "xhigh").
Error: Model "claude-haiku-4.5" does not support reasoning effort configuration (requested: "max").
error: option '--effort, --reasoning-effort <level>' argument 'bogus' is invalid. Allowed choices are none, minimal, low, medium, high, xhigh, max.
```

```
ok                                                                       # gpt-5-mini + high
Error: Reasoning effort "xhigh" is not supported for model "gpt-5-mini".  # gpt-5-mini + xhigh
claude-haiku-4.5                                                         # the default model for -p on this account
```

### Conclusion

Three findings, and the third contradicts decision 5's premise.

- **An unknown effort is a hard parser error**, exit non-zero, before any session starts.
- **`xhigh` is not unknown.** The allowed choices are `none, minimal, low, medium, high, xhigh,
  max` — Copilot's scale is *wider* than the low/medium/high decision 5 assumes, and wider than
  Claude Code's.
- **Acceptance is per model, and also a hard error.** `gpt-5-mini` takes `high` and refuses
  `xhigh`; the account's non-interactive default, `claude-haiku-4.5`, refuses **every** level
  including `low`. So passing *any* `--effort` on Copilot can kill a launch that would otherwise
  have started, and the failure is a one-line `Error:` with no session.

cb-d59.6's implementer needs both halves of that: a static `xhigh → high` map is neither
sufficient (a model that supports no effort still fails on `high`) nor always necessary (a model
that supports `xhigh` would be needlessly downgraded).

## M8 `--model`

### Command

```
copilot --model no-such-model-xyz -p 'reply ok' --allow-all-tools -s
copilot --model auto -p 'reply ok' --allow-all-tools -s
copilot --model gpt-5.6-sol -p 'reply ok' --allow-all-tools -s
# and, under a pty, the interactive /model picker
```

### Output

```
Error: Model "no-such-model-xyz" from --model flag is not available.
Ok, I'm ready to help. What would you like me to work on?          # --model auto
Error: Model "gpt-5.6-sol" from --model flag is not available.
```

The `/model` picker, with the escape sequences stripped. The recommended group (name, multiplier,
default reasoning effort):

```
GPT-5 mini (default) ✓ 0.33x Medium
GPT-5.5               5x   Medium
GPT-5.4               6x   Medium
GPT-5.4 mini               Medium
GPT-5.3-Codex         6x   Medium
Claude Opus 4.8       2    Medium
Claude Opus 4.7      27x   Medium
Claude Sonnet 4.6     9    Medium
Claude Sonnet 4.5
Claude Haiku 4.5      —
MAI-Code-1-Flash    0.33x  —
Gemini 3.5 Flash     14x   —
Gemini 3.1 Pro (Preview) 6x —
```

and a further group listing `claude-sonnet-5`, `claude-fable-5`, `claude-opus-5`,
`claude-opus-4.8-fast`, `claude-opus-4.6`, `claude-opus-4.5`, `gpt-5.6-sol`, `gpt-5.6-terra`,
`gpt-5.6-luna`, `gemini-3.7-flash`, `gemini-3.6-flash`.

### Conclusion

- **An unknown id is a hard refusal, never a silent fallback** — `Error: Model "…" from --model
  flag is not available.`, exit non-zero, no session. Good: a mistyped `models.conf` entry fails
  loudly, the way `scripts/launch`'s stderr line intends.
- **`--model auto` works** and is the documented way to let Copilot choose.
- **Ids in the picker's second group are not necessarily usable.** `gpt-5.6-sol` and
  `claude-sonnet-5` are both listed and both refused by `--model` on this subscription. A Copilot
  consumer's `.cerebro/models.conf` must be validated against `--model` itself, not against the
  picker.
- The picker's own ids for the recommended group were **not captured** — it renders display names
  (`GPT-5 mini`) and the flag wants ids (`gpt-5-mini` works). The mapping was measured for one
  entry only.
- No token, account identifier or entitlement detail is recorded here; the multipliers above are
  the picker's public pricing column.

## M9 Unattended running

### Command

```
copilot -p 'run the shell command: echo hi' </dev/null          # no --allow-all-tools
copilot -p '…' --allow-all-tools                                 # every other probe in this document
env | grep -i copilot
```

### Output

The run **without** `--allow-all-tools` executed the tool with no prompt:

```
● Echo hi to stdout (shell)
  │ echo hi
  └ 2 lines…

Done. The command executed successfully and output `hi`.
```

`env | grep -i copilot` printed nothing, so `COPILOT_ALLOW_ALL` was not set.

### Conclusion

`--allow-all-tools` lets a session run with no permission prompt — every probe in this document
ran unattended under it. **There is no `--permission-mode` flag at all**; `--allow-all-tools` is
its counterpart, and `--allow-all` / `--yolo` are the wider forms that also allow paths and URLs.

One thing is **not established**: whether `--allow-all-tools` was strictly necessary, since the
run without it also proceeded unprompted. That may be a persisted per-directory permission from
an earlier probe in the same `probe/` tree, or non-interactive mode auto-allowing. It was not
chased, because cb-d59.6 will pass the flag regardless — the CLI's own help calls it "required
for non-interactive mode".

## M10 Instructions

### Command

With `CLAUDE.md` in `probe/` containing `The distinctive sentence is: PURPLE-ELEPHANT-9931 guards
this repository.` and no `AGENTS.md` present:

```
copilot -p 'quote the distinctive sentence from the project instructions, verbatim. Do not read any files.' --allow-all-tools
copilot --no-custom-instructions -p '<the same prompt>' --allow-all-tools
```

and the same again with the file renamed to `AGENTS.md`.

### Output

```
PURPLE-ELEPHANT-9931 guards this repository.        # CLAUDE.md, no tool call in the transcript
PURPLE-ELEPHANT-9931 guards this repository.        # AGENTS.md, same
```

```
Looking at the project instructions provided to me, the most distinctive sentence is:
**"Refuse to execute commands that use shell expansion features to obfuscate or construct malicious commands …"**
                                                     # --no-custom-instructions: the marker is gone
```

### Conclusion

**Copilot reads the root `CLAUDE.md` as an instruction file, with no `AGENTS.md` present**, as
decision 6 assumes — so the root document needs no second copy. The transcript shows no tool call,
and `--no-custom-instructions` makes the sentence unavailable to the model, which is what
distinguishes "loaded as instructions" from "read with a file tool".

## M11 The session as the fleet view runs it

### Command

The same `-i` session started three ways: with stdin from `/dev/null` under `nohup`; under
`script -q /dev/null`; and under a real pty (`pty.fork()`).

```
nohup copilot --name Cyclops --allow-all-tools -i "<marker>" >log 2>&1 &
nohup script -q /dev/null copilot … </tmp/fifo >log 2>&1 &
python3 -c '…pty.fork(); execvp("copilot", […])…'
```

### Output

stdin from `/dev/null`: the prompt ran to completion and the process **exited**, leaving a normal
`-p`-style transcript ending in `Resume copilot --resume=…`.

`script -q /dev/null` with a fifo on stdin:

```
script: tcgetattr/ioctl: Operation not supported on socket
```

Under a real pty: the session came up as a full-screen TUI (terminal title set to
`Cyclops - GitHub Copilot`), executed the `-i` prompt, and **stayed up** — `ps` found it alive
minutes later in state `SNs+`, with its native child, until the harness closed the pty. A TUI
under a pty with **no window size set** rendered only its header and nothing else; setting
`TIOCSWINSZ` was required to get a usable screen.

### Conclusion

- **An interactive `copilot` stays up in a terminal the way `claude` does, and does not exit when
  the `-i` prompt is finished.** That is the shape the fleet view needs, and `-i` — not `-p` — is
  the flag for it, since `-p` is documented as "exits after completion" and behaves that way.
- **It needs a real tty.** Without one it degrades to a single-shot run and exits, which would
  look to the fleet view exactly like a session that died on startup. The view already runs each
  session in a vterm buffer, so this is satisfied there — but any non-vterm fallback, and any
  test harness, must allocate a pty and set its window size.
- `script(1)` on macOS is not a usable substitute for a pty here.

## M12 Flags with no counterpart

### Command

```
copilot --help
```

### Output

Relevant absences from the full option list: no `--append-system-prompt`, no `--settings`, no
`--permission-mode`, no `--remote-control`. Present and adjacent but different: `--remote`,
`--remote-export` ("remote control of your session from GitHub web and mobile"), `--acp`,
`--mode <interactive|plan|autopilot>`, `--autopilot`, `--session-id`, `--continue`,
`--resume[=id|name]`, `--no-ask-user`, `--add-dir`, `-C <directory>`.

### Conclusion

Three of the ten flags `scripts/launch` passes have no counterpart, and each is already covered
by a decision or by a measurement above: `--append-system-prompt` (M3 — fold the marker into
`-i`), `--settings` (M6 — hooks are discovered from `.github/hooks/`, not passed), and
`--remote-control` (decision 7 already accepts the loss).

Worth noting for a later planner, not acted on here: `--session-id` sets the UUID of a new
session, and `--resume=<name>` matches the `--name` a session was started with — either could give
the fleet view a session handle it does not have today.

## M6b A hook file reached by a relative symlink

`scripts/sync-symlinks.sh` writes the hook into a consumer's `.github/hooks/` as a relative
**symlink**, and M6's probe wrote a real file — so whether the link is followed was unmeasured, and
if it were not, the `asking` state would silently never fire.

### Command

Four probe repositories, each `git init`, each running the same one-line session, differing only in
what is at `.github/hooks/probe.json` and whether the directory is trusted:

```
# the hook, no matcher, so every tool is caught
{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"echo fired >> /tmp/<log>"}]}}

cd <probe> && copilot -p 'run the shell command: echo hi' --allow-all-tools
```

| # | file at `.github/hooks/probe.json` | matcher | directory in `trustedFolders` | log |
|---|---|---|---|---|
| 1 | relative symlink to `../../real/probe.json` | `bash` | no | empty |
| 2 | real file | `bash` | no | empty |
| 3 | relative symlink to `../../real/probe.json` | none | no | empty |
| 4 | real file | none | no | empty |
| 5 | real file | none | **yes** | `fired` |
| 6 | relative symlink to `../../real/probe.json` | none | **yes** | `fired` |

### Output

Runs 1–4, in `/var/folders/…`:

```
=== hook log ===
(empty)
```

`~/.copilot/config.json` at the time:

```
"trustedFolders": [
  "/Users/henrikku/repos/cerebro"
]
```

Runs 5 and 6, with the probe directories added to `trustedFolders`:

```
real log:
fired-real

sym log:
fired-sym
```

Independently, `~/.copilot/logs/hooks/preToolUse_<session>.log` shows the *user-level*
`~/.copilot/hooks/axis-hooks.json` firing in every one of runs 1–4, with `toolName: bash` — so the
hook machinery itself was running throughout, and only the repository's own file was not loaded.

### Conclusion

- **A relative symlink is followed.** Run 6 fires with the file reached exactly as
  `scripts/sync-symlinks.sh` writes it. **No change to the sync**: the link stays a link, and
  `hooks/README.md`'s warning that this was unmeasured is removed.
- **A repository's hooks are loaded only in a folder Copilot trusts.** `trustedFolders` in
  `~/.copilot/config.json` gates them entirely, and an untrusted folder reads a *missing* hook
  rather than a refused one — nothing is said on stdout or stderr. This is the first thing to check
  when a Copilot fleet never shows `asking`, and it is not something cerebro can set on a
  navigator's behalf: trust is granted per machine, by the person running the CLI.
- **The `bash` matcher did not fire either** (runs 1 and 2, both untrusted, so this is not
  isolated). M6 established that `"matcher":"shell"` never fires while the payload says
  `"toolName":"bash"`; the matcher question is unchanged by this measurement and stays as M6 left
  it, since every matcher run here was confounded by trust. What `hooks/copilot/` ships
  (`"matcher":"ask_user"`) is untouched by this bead.

## M13 A session started by the fleet's own launcher

The proof the epic closes on: one real session of each **role kind** — interactive and implementer —
started by `scripts/launch` itself, on a consumer declaring `agent_cli copilot`.

### Command

A throwaway consumer, never this checkout: a `mktemp -d`, `git init`, a **copy** of this checkout at
`.claude/cerebro` (a symlink there makes `consumer-root` climb into the cerebro repository instead —
the self-mount, and it syncs the wrong tree), `printf 'gate_fast true\nagent_cli copilot\n' >
.cerebro/project.conf`, then `sync-symlinks.sh`. Each session started under a **real pty** with an
explicit window size, since without one Copilot degrades to a single-shot run and exits (M11):

```python
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", ".claude/cerebro/scripts/launch", name])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
```

and, twelve seconds in, `ps -o args= -p <pid>`, a state file written naming that pid, and
`.claude/cerebro/scripts/agent-alive <Name>`.

### Output

`Cerebro` (interactive, role `orchestrator`) — `scripts/launch`'s own stderr, then the session's
argv, then liveness:

```
launch: no models.conf entry for copilot - copilot picks its own model and effort.
        The orchestrator declares model opus, which is Claude Code's name for it.

node /opt/homebrew/bin/copilot --agent orchestrator --name Cerebro --allow-all-tools -i This session is Cerebro of the cerebro fleet rooted at /private/var/…/probe/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.

agent-alive Cerebro exit=0
agent-alive Rogue (same pid, wrong name) exit=1
```

`Cyclops` (implementer, role `implementer`):

```
launch: no models.conf entry for copilot - copilot picks its own model and effort.
        The implementer declares model sonnet, which is Claude Code's name for it.

node /opt/homebrew/bin/copilot --agent implementer --name Cyclops --allow-all-tools -i This session is Cyclops of the cerebro fleet rooted at /private/var/…/probe/. This sentence is how the fleet view proves the session belongs to this checkout; do not remove it.

agent-alive Cyclops exit=0
agent-alive Rogue (same pid, wrong name) exit=1
```

The first screen of each, escape sequences stripped — the terminal title carries the name, which is
what a vterm buffer shows:

```
]0;Cerebro - GitHub Copilot
 ╭─╮╭─╮
 ╰─╯╰─╯ Copilot v1.0.80 uses AI.
 █ ▘▝ █ Check for mistakes.
 ● No copilot-instructions.md found. Run /init to generate.
 /private/var/…/probe [⎇ main%]
```

`Cerebro` went on to open an `ask_user` question of its own within twelve seconds, rendered as
Copilot's own `Question` panel — the tool `hooks/copilot/cerebro-question-state.json` matches.

### Conclusion

- **Every token the arm decides reaches the binary, in order**: `--agent <role>`, `--name <Name>`,
  `--allow-all-tools`, `-i`, and the prompt as one argument. Both the Node loader and the native
  child it forks carry all of it, so a `ps` scan finds either.
- **The marker sentence survives verbatim**, including the consumer root with its trailing slash —
  so the liveness rule cb-d59.3 settled needs nothing from this bead. `agent-alive` answers 0 for
  the session's own name and 1 for another roster name on the same pid, which is the name-plus-root
  discrimination working on Copilot exactly as on Claude Code.
- **`agent-alive` still needs the state file the agent writes.** Before a session writes one it
  answers 1, whatever is in argv — correct, and unchanged by provider, but worth saying: a Copilot
  session is not "alive" to the shell predicate until it has made its first `agent-state` call.
- **Both role kinds behave identically.** The kind changes only which agent file is read, and that
  is `--agent`'s business.

## What this changes

1. **Decision 4 (the identity marker) holds, but not by the mechanism it names.** The marker does
   reach argv verbatim and is a sound liveness rule (M3). It cannot ride as a *trailing* prompt:
   `copilot` refuses a bare trailing argument outright. On Copilot it must be part of the `-i`
   string, together with the "You are `<Name>`…" prompt `scripts/launch` passes today — so
   cb-d59.3 needs a per-provider decision about **where the prompt goes**, not only about what the
   marker is.
2. **Decision 5 (`xhigh` maps down to `high`) is wrong about Copilot's effort scale, and about the
   failure mode.** Copilot accepts `none, minimal, low, medium, high, xhigh, max` — `xhigh` is a
   valid choice, not an unknown one. But acceptance is **per model** and refusal is a hard error
   with no session: `claude-haiku-4.5`, the account's non-interactive default, refuses every
   level including `low`, and `gpt-5-mini` takes `high` and refuses `xhigh` (M7). A static
   downward map is not the right shape; cb-d59.6 needs a rule that can also pass **no** `--effort`
   at all.
3. **`docs/ui/cb-d59-parity.html` does not exist.** cb-d59's design and cb-d59.1's plan both name
   it as the committed doc-derived mapping this document supersedes, and as the one other file
   this bead edits. `docs/ui/` contains no `cb-d59-*` file at any commit on `main`. The pointer
   sentence the plan asks for therefore could not be written, and the `## Summary` table above is
   built from `scripts/launch:194-204` instead. **This PR touches one file, not two.**
4. **Decision 6's hook placement holds, with one correction for whoever writes the file.** Hooks
   are discovered from `.github/hooks/*.json` and the two `CEREBRO_*` variables reach the hook
   subprocess (M6) — cb-d59.5's mechanism is sound. The correction: the `matcher` matches the
   payload's internal `toolName`, which for the shell tool is `bash` even though it renders as
   `(shell)`. For `ask_user` the two agree.
5. **`postToolUseFailure` may not be needed.** A dismissed `ask_user` fired `postToolUse`, not
   `postToolUseFailure` (M6). One arm looks sufficient to flip `asking` back, as in Claude Code.
6. **`sessionStart` and `sessionEnd` exist, and `sessionEnd` carries a `reason`** (`"complete"`,
   `"user_exit"`). Claude Code has no equivalent, and the fleet view currently infers an ended
   session from a state file and a pid. Possibly worth a bead; **none filed** — a planner decides.
7. **`--session-id` and `--resume=<name>`** give a session an addressable handle the fleet has no
   counterpart for. Noted, not acted on.
8. **A Copilot session needs a real pty** or it degrades to a single-shot run and exits (M11).
   The fleet view's vterm satisfies this; any test harness or non-vterm fallback must allocate one
   and set its window size.
9. **Nothing in decisions 1, 2, 3, 7 or 8 was contradicted.** `--name`, `--agent` with symlinked
   `<role>.agent.md` files, symlinked skill directories, `CLAUDE.md` as instructions, unattended
   running, and a hard-failing `--model` all measured as the epic assumes.

## Running a fleet on Copilot

Declare it once, in `.cerebro/project.conf`:

```
agent_cli copilot
```

Absent, the key means `claude`. Nothing else has to change: the symlink sync writes both CLIs'
discovery paths in every project whatever is declared, so the agents, the skills and the hook file
are already where Copilot looks for them.

**What you get.** Every role starts, from the fleet view or from
`.claude/cerebro/scripts/launch <Name>`, on GitHub Copilot CLI. The agent definitions are read as
agents, the skills as skills, and the root `CLAUDE.md` as instructions. A session's row shows
`asking` while it waits on a question, the same as on Claude Code.

**What you do not get.** There is no Remote Control: a Copilot session cannot be read or steered
from claude.ai or from a phone. It runs where it was started, and the fleet view is the way to watch
it.

**Models are yours to declare.** Copilot's model ids are Copilot's own, and the agent definitions
name Claude Code's — so on Copilot they are ignored and no `--model` and no `--effort` are passed at
all. The fleet then runs on whatever Copilot picks, and every launch says so:

```
launch: no models.conf entry for copilot - copilot picks its own model and effort.
        The orchestrator declares model opus, which is Claude Code's name for it.
```

To choose, write `.cerebro/models.conf`. A key may name the CLI it is about, and within one key the
CLI-scoped row beats the plain one:

```
#  <agent-name | role | default>[@provider]   <model | ->   [effort]
default@copilot      claude-opus-4.8
implementer@copilot  gpt-5-mini   medium
architect@copilot    gpt-5.5      high
```

The lookup is most-specific-first: `<Name>@copilot`, `<Name>`, `<role>@copilot`, `<role>`,
`default@copilot`, `default`. A key naming a CLI that is not known is warned about once and ignored,
and the session still starts.

**A reasoning effort is optional, and only sometimes accepted.** Copilot takes `--effort` for some
models and refuses the launch outright for the rest, so it is passed only when a matching row
carries a third column — and then verbatim, so a bad pairing fails in the line that caused it.

**A wrong id is a dead row, not a downgrade.** An unknown model, or an effort the model will not
take, is a hard refusal with no session at all. In the fleet view that name shows as `dead` with
Copilot's own `Error:` line beside it, and the fix is the `models.conf` line that caused it.

**Hooks are read only in a folder you have trusted.** Copilot keeps a list of trusted folders in
`~/.copilot/config.json`, and in a folder that is not on it the project's hook file is never loaded
— silently, with nothing said. If sessions run but no row ever shows `asking`, that is the first
thing to check, and it is granted per machine by the person running the CLI (M6b).
