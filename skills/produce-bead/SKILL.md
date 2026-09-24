---
name: produce-bead
description: Produce one UX-agreed bead end to end: decide the build and tests, implement it with TDD, review it, validate it, and deliver it.
---

# Producing a bead

Load `beads-workflow` and the consumer's root `CLAUDE.md`. You take one UX-agreed bead already
claimed for you; `bugfix` beads stay with the bugfixer.

1. Confirm the prompt's bead is `in_progress` and assigned to you; with no bead in the prompt, run
   `end-pass` and stop. Work only in the prepared worktree. Write `working --bead <id> --phase
   design` at once, before reading anything else (*State file*, below).
2. Read its acceptance and mockup. A bead carrying `ux:none` instead of `ux:agreed` has no mockup
   and no agreed experience under the five headings: the navigator said at filing that nothing a
   person sees changes, so design from the description and the acceptance line it was filed with. If the build turns out to touch anything a person sees, hand it to UX
   (`producer-park … ux`, below) rather than deciding the shape yourself.
   The agreed experience is fixed. Decide the architecture, files,
   increments, test plan, validation, and any non-UX details. Read `.cerebro/traps.md` at the
   consumer root if it exists: a trap is a fact a plan cannot be written correctly without, so
   name every trap the bead touches and what the plan does about it; a missing file is ordinary.
   Write those decisions to the bead's `design` field under the eight headings of *The plan*,
   below, then add `planned`. A missing `design` field
   or `planned` label is the normal producer input, never a reason to return it for build design.
   A bead carrying `verification:failed` **and** `planned` is rework: the navigator saw the build
   fail against a design that was judged right. Read the dated failure note, amend the existing
   `design` in place rather than writing a new one, and keep `planned`.
   If the experience cannot be built as written because a genuine UX or scope decision is still
   needed, hand it on only through
   `.cerebro/cerebro/scripts/producer-park <name> <id> <ux|scope> "<what must be decided>"`.
   `ux` is for something the agreed experience does not settle (a state, a word, what closes it):
   it goes straight back to the UX stage, with your question as the note. `scope` is for whether
   the work itself is right: it goes to the navigator's queue. Both release your claim and push.
   A missing build plan or an implementation detail is never a reason to hand on: decide it in
   this plan. End the pass after a genuine decision is handed on.
3. Design each test with the increment it proves. Work RED -> GREEN -> REFACTOR, beginning every
   increment with its failing test. Use `build`, `gate`, `review`, `ci`, `rebase`, and `merge` as
   the phase changes; heartbeat before long work.
4. Run the declared gate. Obtain and address one independent, full review of the complete diff and
   bead. Decide whether the review changes warrant another review, and choose its scope; do not
   loop on minor, self-contained answers. Rerun required checks, write *The retrospective* if one
   is due, deliver by this consumer's configured merge convention, close and push the bead, and
   run `end-pass` last.

## The plan

Written to the bead with `bd update <id> --design-file <file>`, and read back with
`bd show <id> --json` (the pretty renderer mangles tables). Every heading below is present,
spelled exactly, as a `##` heading at the top level of the `design` field; where one does not
apply, write **"None."** and say why. The verifier briefs the navigator from *User-facing
decisions*, and the review sub-agent reads the diff against it, so a plan without them leaves
both reading nothing.

    ## Context
    ## Files to change, and what to reuse
    ## Increments
    ## The test plan
    ## User-facing decisions
    ## Out of scope
    ## Validation
    ## Known traps

1. **Context**: why the work exists and what changes when it lands.
2. **Files to change, and what to reuse**: concrete paths, and the existing functions and patterns
   to build on. It also carries the design of the code: the public surface of anything new, in the
   project's language; where state lives, who owns it and what invalidates it; which layer each
   piece belongs in when the work crosses the project's layers, and why.
3. **Increments**: small, ordered, each naming the failing test that opens it.
4. **The test plan**: each kind of test the project runs, with names and what each pins, and which
   suites must run.
5. **User-facing decisions**, with two `###` subsections, both always present:
   - `### Agreed with the navigator`: a pointer, never a summary, since a paraphrase drifts: one
     line naming the `acceptance` field, the mockup path, and every string a person reads, quoted
     verbatim from the acceptance.
   - `### Decided by me`: every detail you decided inside the agreed shape (wording the acceptance
     leaves open, sizes, an empty or error state it does not name), one line each, the value as it
     ships and why. The navigator can overrule any line here; nobody else decides any of it.

   "None." under both for a bead with no user-facing surface, `ux:none` included.
6. **Out of scope**: what a reader might assume is included and is not.
7. **Validation**: the exact commands, and any human check, that prove the acceptance.
8. **Known traps**: the entries of `.cerebro/traps.md` this bead touches, with what the plan does
   about each, or "None.".

## The retrospective

Only you saw the run. **When the review is answered and CI is green, before you merge**, ask: did
anything happen that I did not expect? Worth recording: a failure nothing prepared you for; green
locally and red in CI; a tool not behaving as documented; a rule you could not follow; time lost
to something avoidable. Not worth it: a normal bead, a RED that was meant to be red, an answered
finding, anything already written in `docs/retrospectives/`. If nothing qualifies, **write no
file** and say so in your closing message: *"retrospective: nothing to record."*

One file per bead, `docs/retrospectives/<bead id>.md`, never appended to another bead's; two
findings are two sections of your one file. It lives under `docs/` because `.cerebro/state/` is
gitignored, and it rides on the bead's own pull request:

```bash
grep -rl "<a word from your symptom>" docs/retrospectives/ 2>/dev/null || echo "nothing like it yet"
mkdir -p docs/retrospectives
[ -f docs/retrospectives/README.md ] || \
  cp .cerebro/cerebro/templates/retrospectives-README.md docs/retrospectives/README.md
git add docs/retrospectives/
git commit -m "docs(<bead id>): retrospective — <the one-line symptom>"
git push
```

The grep comes first so *Seen before* is real. Stage the directory, not just your file, or the
README copy is lost with the worktree. The README is the format: **What happened**, **Why** (or
"not established"), **Cost**, **Prevent by** (a file, a section, a step or a check; "be careful"
is not a prevention), **Seen before**. Be specific enough to act on. **Record; do not fix**:
changing the rules, the skills or CI is the navigator's, and Forge reads these files to propose
it. A retrospective is a commit after the review, so it needs CI on the new head; decide whether
its scope warrants a follow-up review before merging, as with any post-review change.

Never take another bead, alter agreed UX, or skip a failing test, review, or required check. Ask
the navigator only for a genuine UX, scope, or approach decision; otherwise decide and record it.

## State file

`.cerebro/state/<your-name>.state.json` is how you are seen and how you are replaced.

<!-- state-contract:begin -->

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

**Every question to the navigator is three actions.** Write `asking`, ask, then write `working` as
the very first thing you do with the answer, before any `bd`, `git` or reply. Typing `bd` or `git`
straight after an answer means you skipped the third: stop and write it.

**The hook does not excuse you.** `hooks/session-state.settings.json` and `scripts/agent-asking`,
from `scripts/launch`, flip the file to `asking` during a question tool call and back on answer or
cancellation. It misses a prose question, a wait on a port or a "say when", and cannot tell `idle`
from `working`. Write `asking` for a prose question too: one under `working` looks wedged, and the
stuck clock ends wedged sessions.

**You cannot see your own state file.** Read it at the start of a pass and before ending one. If it
is wrong, fix it with `agent-state` first and say so in one line ("my state file still said `asking`;
corrected").

<!-- state-contract:end -->

Every write names your bead and pid:
`.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase <phase> --pid $PPID`.
The phases, in order, are `design`, `build`, `gate`, `review`, `ci`, `rebase` and `merge`; a
question is `asking` with the same bead and phase. `merge` covers the retrospective, the merge,
the close and the cleanup; a retrospective that warrants a follow-up review goes back through
`review` and `ci` first. Delivered, parked or handed back:
`.cerebro/cerebro/scripts/end-pass <name> --pid $PPID`, last.
