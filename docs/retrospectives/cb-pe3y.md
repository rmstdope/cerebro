# cb-pe3y — retrospectives

## `tests/web-console.sh` was refused its second Start: "Forge is running outside this view"

**What happened.** `bash tests/gate` went red on `start again: the view refused it`; the API answer
was `{"done":false,"text":"Forge is running outside this view"}`, after the suite's own Kill had
passed. The diff since the previous green gate was a default value, a comment and one sentence of
`scripts/producer-brief`'s output. Run alone straight after, the suite was green (load average
about 20 to 55); the next full gate and CI were green too.

**Why.** Not established. The screen showed the row still `● Forge working` beside a pane saying
`Forge was killed by signal 1`, so the Start was likely asked before the view had seen the killed
session's state go.

**Cost.** One suite re-run and one more full gate, a few minutes.

**Prevent by.** `tests/web-console.sh`, before "start again": wait until the view's own answer or
row shows Forge not alive, not only until the Kill was accepted.

**Seen before.** Not with this message. `docs/retrospectives/cb-8484.md` is another load-bound
red in the fleet-view suites.

## A hung-pull wall-clock case went red under load again

**What happened.** `tests/ux-brief.sh` failed with `a hung pull is cut off at its bound, took 11s`
at load average 228, on a refactor that moved the bounded wait into `scripts/brief-lib.sh`. It
passed on re-run, on the branch and on main.

**Why.** The case asserts elapsed seconds, as cb-6bgn recorded.

**Cost.** Two extra runs of the suite to compare with main, about a minute and a half.

**Prevent by.** `tests/ux-brief.sh`'s hung-pull case: take the shape `tests/producer-brief.sh`
uses, a stub that writes a marker only if it was allowed to finish, and drop the `-lt 10` check.

**Seen before.** `docs/retrospectives/cb-6bgn.md`.

## The review packet is too large to paste into the sub-agent's prompt

**What happened.** `produce-bead` says to paste `scripts/review-packet`'s output whole into the
prompt. It was 58 KB; retyping it into a tool call is not possible without cost and the risk of
altering it, so the prompt gave the file's path and said to read all of it.

**Why.** The agent tool takes the prompt as text the producer writes out; it has no way to attach a
command's output.

**Cost.** No time; a rule not followed as written.

**Prevent by.** `skills/produce-bead/SKILL.md`, *The review loop*: have the packet written to a
file and the prompt name it, unedited, instead of "paste its output whole".

**Seen before.** Not in `docs/retrospectives/`.
