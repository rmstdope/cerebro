Write it at every transition, in the same `Bash` call as the thing it describes, through
`.claude/cerebro/scripts/agent-state` — never by hand, and never with a state word of your own
invention. There are four, and no others: `idle`, `working`, `asking`, `waiting`.

- `working` covers everything you are actually doing.
- `asking` says you are blocked on the navigator and nothing is moving until they answer.
- `idle` says a live session with nothing in hand, waiting to be spoken to.
- `waiting` says *this pass is over and my turn has ended*. The fleet view ends the session about
  half a minute later, keeps its buffer as the record of the pass, and starts a fresh one on your
  role's own trigger.

The table below is where you find which of them you write, and when. Work done under the wrong one
is invisible or misleading: a session shown with nothing in flight is one the navigator may `k`, and
one shown as `asking` is one they think is blocked on them.

`working` and `asking` also take `--phase`, naming what the work or the wait actually is; the words
your role uses are in that same table. The script keeps `since` across a phase-only change and
stamps `phase_since` on one — which is another reason never to write the file by hand.

`--pid` is `$PPID` — your own session's process, whichever agent CLI it runs on — and it must be
captured in the call that writes the file. A stale number shows you as dead while you are working,
and the navigator will start a second session over the top of you.

**Every question to the navigator is three actions, not one.** Write `asking`, ask, and then — as
the very first thing you do with the answer, before any `bd`, `git` or reply — write `working`
again. If you find yourself typing `bd` or `git` straight after an answer, you have skipped the
third: stop, write the state, then carry on. That is the most common way this goes wrong, because
the answer feels like the end of the exchange while the file still says you are blocked.

**There is a hook behind that, and it does not excuse you.** `hooks/question-state.settings.json`
and `scripts/agent-asking`, which `scripts/launch` gives every session, flip the file to `asking`
for the lifetime of a question tool call and back again on the answer or a cancellation. Keep
writing the states anyway: the hook knows about the question tool and nothing else, so a question
put in prose, a wait on a port or a "say when" is invisible to it, and it cannot tell `idle` from
`working`. Two writes that agree cost nothing; a missing one costs the navigator an hour of not
knowing you were waiting.

**A `[cerebro]` line means nobody answered, and it is not optional.** A question nobody answers
holds your whole role: nothing else you would have done this pass happens while you sit in
`asking`. So the fleet view holds a clock on that state, and when it expires it types one line
into your session beginning `[cerebro]`. You do not enforce that timeout and cannot see it.
Treat the line as the navigator speaking: stop waiting, record the question and everything you
found where your own instructions say an unanswered question goes, write `working` again, and
end the pass. Do not ask again, and do not wait a second time. Where your own instructions say
nothing about an unanswered question, say in one line what you asked and that nobody answered,
and end the pass.

**You cannot see your own state file**, so read it rather than trusting your memory of it — once at
the start of a pass and once before you end it. If it does not describe what you are doing at that
moment, fix it with `agent-state` before anything else, and say so in one line ("my state file still
said `asking`; corrected").
