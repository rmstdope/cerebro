# cb-d59.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-26
- **PR:** #172

## The plan required editing a file that was never committed

**What happened.** The plan's *Files to change*, increment 12 and *Validation* all name
`docs/ui/cb-d59-parity.html` — "the committed copy" of the flag mapping — and make a one-sentence
edit to it half of the PR's required two-path diff (`git diff --name-only` "must print exactly"
two paths). `ls docs/ui/` and `find docs -iname '*d59*'` both come back empty of any `cb-d59-*`
file; it exists at no commit on `main`. The PR therefore ships one path where the plan's
acceptance criterion demands two, and the document's `## Summary` table had to be rebuilt from
`scripts/launch:194-204` rather than diffed row-for-row against the artefact it was meant to
supersede.

**Why.** cb-d59's design says the mockups it was decided against are "scratch, not committed — the
committed copy is `docs/ui/cb-d59-parity.html`". The planner appears to have intended to promote a
`.cerebro/scratch/` mockup into `docs/ui/` and not done so; `.cerebro/scratch/` is gitignored
(root `CLAUDE.md`, *Gotchas*), so a file that lives only there is invisible to every later session
and to every clone. Not established beyond that — I did not ask the planner.

**Cost.** About fifteen minutes: the failed grep, confirming across `docs/`, reading cb-d59's
design to find the table's actual source, and writing the deviation up three times (document, PR
body, this file). No CI cycle and no rebase.

**Prevent by.** A plan's *Validation* section should cite a file only after the plan has confirmed
it is tracked — a `git ls-files <path>` rather than a memory of having drawn it. More specifically,
where `plan-bead` has a planner write a mockup under `.cerebro/scratch/` and then refer to it from
a bead, the step that promotes it into a tracked path needs to be part of the bead that ships it,
because a scratch path is gitignored and a later reference to it cannot fail loudly.

**Seen before.** None found — `grep -rl "does not exist\|never committed" docs/retrospectives/`
matched only cb-dul and cb-s7i, both about something else.

## Probing an interactive TUI CLI needs a real pty, and `script(1)` will not give you one

**What happened.** M3 and M11 needed a `copilot` session that stays up, which meant starting one
from a `Bash` tool call and inspecting it from another. Three shapes were tried before one worked.
`nohup copilot -i "…" &` ran the prompt and exited, leaving a transcript that looks exactly like a
successful `-p` run — a silent degradation, not an error. `nohup script -q /dev/null copilot …`,
the obvious way to fake a tty, failed with `script: tcgetattr/ioctl: Operation not supported on
socket`, because macOS `script(1)` wants its *own* stdin to be a tty and a `nohup` job's is not;
feeding it a fifo did not help. Only `pty.fork()` from Python worked — and even then the TUI
rendered its header and nothing else until `TIOCSWINSZ` set a window size.

**Why.** Established. `copilot` detects a non-tty stdin and falls back to single-shot mode; macOS
`script(1)` calls `tcgetattr` on stdin unconditionally.

**Cost.** Roughly twenty-five minutes and three dead-end probe runs. No CI cycle.

**Prevent by.** Any later bead in the cb-d59 family that has to observe a live agent session — and
cb-d59.3's liveness work almost certainly does — should start it with `pty.fork()` plus a
`TIOCSWINSZ` window size, and treat "the session ran the prompt and exited" as the signature of a
missing tty rather than of a crash. This finding is recorded in `docs/providers/copilot.md` M11 as
well, which is where an implementer of that bead will be reading.

**Seen before.** None found.
