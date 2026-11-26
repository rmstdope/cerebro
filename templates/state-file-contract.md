Write it at every transition, in the same `Bash` call as the thing it describes, only through
`.cerebro/cerebro/scripts/agent-state`, never by hand. There are four state words and no others:

- `working` — everything you are doing.
- `asking` — blocked on the navigator; nothing moves until they answer.
- `idle` — live, nothing in hand, waiting to be spoken to.
- `waiting` — pass over, turn ended. About half a minute later the fleet view ends the session,
  keeps its buffer as the pass's record, and starts a fresh one on your role's own trigger.

The table below says which to write when. A wrong one misleads: a session shown with nothing in
flight may be `k`-ed, and one shown `asking` looks blocked on the navigator.

`working` and `asking` take `--phase`, with your role's words from that table. The script keeps
`since` across a phase-only change and stamps `phase_since`: another reason never to write by hand.

`--pid` is `$PPID`, whichever agent CLI runs you, captured in the call that writes the file. A stale
pid shows you dead; the navigator starts a second session over you.

**A question through the question tool needs no write of your own.** `hooks/session-state.settings.json`
(Copilot: `hooks/copilot/`) runs `scripts/agent-asking` around it: the file goes to `asking` with
your bead and phase as the question opens, and back to what it was when it is answered or
cancelled. Writing `asking` and `working` around it yourself only repeats the hook.

**Any other question is three actions.** The hook sees only the question tool, so a question asked
in prose, a wait on a port or a "say when", and a question that must show a phase other than the
one you are in (a navigator's gate) are yours: write `asking`, ask, then write `working` as the
very first thing you do with the answer, before any `bd`, `git` or reply. Typing `bd` or `git`
straight after such an answer means you skipped the third: stop and write it. A question under
`working` looks wedged, and the stuck clock ends wedged sessions. A row in your role's table that
names `asking` for a question means exactly these questions.

**You cannot see your own state file.** Read it at the start of a pass and before ending one. If it
is wrong, fix it with `agent-state` first and say so in one line ("my state file still said `asking`;
corrected").
