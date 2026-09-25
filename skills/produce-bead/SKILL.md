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
   **A bead that already has a `design` is a producer's returned plan, never redesigned from
   nothing**, whether or not `planned` is still on it (every park removes `planned`; a crash does
   not). Read what shipped first, `git log "origin/$(.cerebro/cerebro/scripts/default-branch)" -F
   --grep "(<id>):"`, so an increment main already carries is skipped rather than redone. Then: with `verification:failed` it is rework
   (the navigator saw the build fail against a design judged right; read the dated failure note and
   amend the design in place); otherwise it was unparked or its session died (read the notes, a
   `## Navigator's answer` heading first, and the worktree's own log, then continue from the
   design, amending what the answer changes). Add `planned` back if it is missing.
   If the experience cannot be built as written because a genuine UX or scope decision is still
   needed, hand it on only through
   `.cerebro/cerebro/scripts/producer-park <name> <id> <ux|scope> "<what must be decided>"`.
   `ux` is for something the agreed experience does not settle (a state, a word, what closes it):
   it goes straight back to the UX stage, with your question as the note. `scope` is for whether
   the work itself is right: it goes to the navigator's queue. Both release your claim and push.
   A missing build plan or an implementation detail is never a reason to hand on: decide it in
   this plan. End the pass after a genuine decision is handed on.
3. Design each test with the increment it proves. Work RED -> GREEN -> REFACTOR in your worktree
   (*Workspace*), beginning every increment with its failing test. Use `build`, `gate`, `review`,
   `ci`, `rebase`, and `merge` as the phase changes; heartbeat before long work.
4. Run the fast gate (*Building*), open the pull request, obtain and address one independent, full
   review of the complete diff and bead (*The review loop*), wait for CI (*Waiting, without ending
   your run*; *Red CI*), write *The retrospective* if one is due, merge through the pull request
   and never otherwise (*Merging*), close the bead and its parent when you were the last child
   (*Finishing*), and run `end-pass` last. A bead you cannot finish goes back through *Handing
   back*.

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
7. **Validation**: the exact commands, and any human check, that prove the acceptance, opening
   with the workload the preflight needs: `disk-preflight --workload rust` or
   `disk-preflight --workload non-rust` (`scripts/assign-bead` reads that line; without it every
   bead preflights as Rust).
8. **Known traps**: the entries of `.cerebro/traps.md` this bead touches, with what the plan does
   about each, or "None.".

## Workspace

**Your tree was made before your session started** by `scripts/prepare-worktree` at
`<repo>/.cerebro/worktrees/<id>`: fetched, branched, submodule initialised, the project's `install`
run. Never check out `main`; go to your tree and read what is there before you build:

```bash
cd <repo>/.cerebro/worktrees/<id>
git branch --show-current          # <id>, or <id>-2 and onward when that name was taken
git status --porcelain
git log --oneline "origin/$(.cerebro/cerebro/scripts/default-branch)..HEAD"
```

Anything in the last two is an earlier attempt at this bead. If the tree is missing, hand back
naming that. **Never create, move or remove a worktree yourself.** A fresh tree has no prewarmed
build: if a suite needs one, run what `.cerebro/cerebro/scripts/project-conf prewarm` prints,
inside the tree. **Check `pwd` before every git command**: a `cd` into another agent's worktree
followed by `git checkout -b` moves that agent off its branch.

**A bead whose diff is inside `.cerebro/cerebro`** is worked in `<tree>/.cerebro/cerebro`, which
arrives detached at the pinned sha: `git -C <tree>/.cerebro/cerebro fetch origin` and branch from
`origin/main` there, or the PR is based behind it. Never `git -C .cerebro/cerebro worktree add`,
never clone cerebro beside the consumer. Two PRs: cerebro's, then a `chore: bump cerebro` commit
from the same consumer tree once it merged.

**Give each session its own block of ports** for anything that serves: wrap every browser-suite
run in `.cerebro/cerebro/scripts/smoke-port -- <command>`, which takes a free block for exactly as
long as the command runs and exports the variable the suites read; with no `port_base` declared it
is a no-op. Do not set `CI` by hand.

## Building

Write `gate` before you first run the fast gate. **Before the PR, classify what you changed, then
run the gate the project declares**, every leg of it:

```bash
git diff --name-only -z "origin/$(.cerebro/cerebro/scripts/default-branch)...HEAD" |
  xargs -0 .cerebro/cerebro/scripts/build-workload --classify
.cerebro/cerebro/scripts/project-conf gate_fast     # the fast gate: what to run before the PR
.cerebro/cerebro/scripts/project-conf gate_full     # everything the project has
```

The plan's *Validation* names the workload (`disk-preflight --workload rust` or `non-rust`); the
fleet view ran that preflight before your tree was made. If the classification says `rust` where
the plan said `non-rust`, run `.cerebro/cerebro/scripts/disk-preflight --workload rust` yourself
before the gate, since the Rust build tree is what fills a disk. A detected, undeclared gate is
announced on stderr; read it. With no gate at all the launcher would have refused you, so an empty
answer is a fault to report, never a licence to improvise one.

**Then run the plan's *Validation***, every command under that heading, and record its result in
the PR body: the gate proves the tests, the validation proves the acceptance, and the verifier
later runs the same commands. A validation that cannot pass is a plan that was wrong; amend the
plan and say so, or hand back if the amendment is a decision you may not take.

Then open the pull request under `beads-workflow` *Branch, commit and PR conventions*: the branch
`<id>-short-description`, the subject `feat(<id>): …`, the body naming the bead, the validation
result, and any deviation from the plan.

**A changed shared-root declaration is gated in a clone.** When the diff touches the consumer's
`install`, `prewarm`, gate or `.cerebro/project.conf` lines, run the clone, submodule, install and
fast-gate commands in a throwaway clone of the committed branch before the PR: your prepared tree
proves nothing about a fresh checkout.

## Waiting, without ending your run

Two kinds of wait, waited on differently.

- **CI, and everything else outside this session.** Nothing tells you it finished, so **block
  inside a tool call**, polling a condition a shell can test, heartbeating inside the loop, printing
  as it goes, each call well under ten minutes with an explicit timeout:

  ```bash
  until <the condition>; do bd heartbeat <id>; sleep 30; done
  ```

  Never by ending your turn, and never by a background task: nothing wakes you, and a turn ended
  against CI sits until somebody types.
- **The `reviewer` sub-agent you spawned.** Its result is delivered, so do not sleep on it. Letting
  the turn end meanwhile is fine; ending your pass is not: your state stays `working --phase
  review`, and you never write `waiting` with a review outstanding.

## The review loop

**Obtain the review yourself; nothing is requested from GitHub or waited for there.** Once the gate
is green and the PR is open, write `review`, resolve the model, and spawn a sub-agent of type
`reviewer`:

```bash
.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID
.cerebro/cerebro/scripts/agents-conf --role reviewer      # hit<TAB><key><TAB><tool><TAB><model><TAB><effort>
```

A `miss` or an empty model means the CLI's default; `refused<TAB><sentence>` is a broken
declaration, say the sentence and spawn on the default. Say which key matched and which model you
review on. Before each invocation read and keep `reviewed_head` from `gh pr view <n> --json
headRefOid`.

**A cold read gets three things, and only these**: the diff (`gh pr diff <n>`), the bead
(`bd show <id> --json`, the plan included), and `.cerebro/cerebro/agents/reviewer.md` as its
checklist. **Never your reasoning.** `reviewer.md` tells the sub-agent which of it applies.

**A follow-up review**, only when your answers warrant one, gets the two shas (the previous
`reviewed_head` and the head now, so it takes the diff itself), the findings that round raised and
the answers you posted, as claims to check against the code. Choose its scope from the change: a
small answer to a finding needs none, a focused fix a delta, a broader change another full read.

**Post it in full, as a PR comment, before the merge**, and append it to the bead's notes, from
one file so the same bytes go to both places:

```markdown
**Review (cold read, `reviewed_head`: `<sha>`)** — reviewed before merge under the producer's
review practice, by an agent given the diff and the bead, and not the producer's reasoning.

1. <finding, naming the file and the case>
```

```bash
gh pr comment <n> --body-file /tmp/review-<id>.md
bd update <id> --append-notes "$(cat /tmp/review-<id>.md)"
bd dolt push
```

*No findings.* is a complete review. **Every finding gets a change or a posted reply** naming it by
number and saying why not; a finding can be wrong, and a reasoned reply is an answer. A finding
about approach, scope or what the audience sees is a hand-back. A tool failure, an empty response,
or one with neither findings nor an explicit no-findings verdict is unusable: retry that head up
to three times, heartbeating between; after three, leave the PR open, record the attempts in the
notes, hand back with `human`, and end the pass.

Once every finding is answered, write `ci` and wait per *Waiting, without ending your run*, after
*Merging*'s mergeability check if anything was pushed since the PR opened.

## Red CI

**Three fix attempts and two bare re-runs, for the whole bead.** A pushed fix spends a fix attempt;
a re-run of the same head spends a re-run. Read the failure before believing it; re-run a suspected
flake only after reproducing it locally once, in the one suite. After every fix, decide whether its
scope warrants another review. On exhaustion, leave the PR open, hand back with `human`, and end
the pass.

## Merging

**Only through the pull request, and only `gh pr merge`.** Never `git push` to the default branch,
never `--auto` (it fires on green checks alone and races the review). Expect `BEHIND`; whether a
`BEHIND` head may merge is the repository's answer, and a failed call reads as `true`:

```bash
gh api "repos/<owner>/<repo>/branches/$(.cerebro/cerebro/scripts/default-branch)/protection" \
  --jq '.required_status_checks.strict'      # false: BEHIND may merge. true: catch up first.
```

Catch up on GitHub, then wait for CI again with no local re-gate: write `rebase`, run
`gh api -X PUT "repos/<owner>/<repo>/pulls/<n>/update-branch"`, poll `mergeStateStatus` until it is
not `BEHIND`, write `ci`. A `422` is a real conflict: fetch and rebase onto `origin/<default branch>` (the branch
`scripts/default-branch` prints), resolve, `git push --force-with-lease`, back to `ci`.

**Before waiting on CI after any push that could have raced main**, poll `gh pr view <n> --json
mergeable,mergeStateStatus,headRefOid` until the head is yours and neither field is `UNKNOWN`.
`CONFLICTING DIRTY`: rebase, never the CI wait. `MERGEABLE BEHIND`: merge unless `strict`, then
`update-branch`. Anything else: `ci`, and wait. An update or rebase that leaves an empty diff
against main is a PR to close unmerged, and a bead to close as delivered by whoever delivered it.

Immediately before merging, all four together: a full review covered this bead's diff, you decided
whether any later change needed a follow-up review, the head is neither behind under `strict` nor
conflicting, and every required check on the current head is green. Then:

```bash
gh pr merge <n> --squash --delete-branch
```

`--delete-branch` often aborts after the merge has happened; check `git ls-remote --heads origin
<branch>` and delete it explicitly if it survived.

## Handing back

A bead you cannot finish goes back to the board, never to another producer by your hand. **The
hand-back block**, three commands and never a chain:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<what stopped it, and what would unblock it>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) --if-assignee <name>
bd unclaim <id> --if-assignee <name>
bd dolt push
```

`--if-assignee <name>` on both: the block only ever releases your own claim. Why each command
matters is `beads-workflow`, *The lifecycle a bead moves through*. It is the exit for: a bead with
no tree; a review that could not be obtained three times; a red CI budget spent; a finding about
approach, scope or the audience you may not decide. **A bead that is not yours** (another
assignee, or not `in_progress`) is not handed back at all: say so in one line, touch nothing, and
end the pass.

**Asking instead of handing back.** For a question that genuinely blocks the bead you may ask
the navigator: write `asking` with the bead and the current phase, ask plainly, and wait. No clock
ends the question; the session, its claim and its worktree sit until somebody answers. Prefer a
hand-back when the answer needs somebody awake or the bead can wait; handing back is always
correct. A genuine
UX or scope question is not a hand-back but `producer-park` (step 2). **One variation**: a bead
carrying `verification:failed` that you hand back because there is **nothing left to implement**
(the surface is already there, or another bead carries it) drops the `human` and the `paused_at`
and adds `second-look`, the one label that makes it the verifier's: `scripts/second-look-beads`
lists it, every builder and UX queue refuses it, and Psylocke removes it when she records a
verdict. Nobody but this hand-back sets it:

```bash
bd update <id> --remove-label planned --add-label second-look --append-notes "<why there is nothing to build>" \
  --if-assignee <name>
bd unclaim <id> --if-assignee <name>
bd dolt push
```

Leave the PR open on a hand-back; its being unmerged is the point. A hand-back is a complete pass
and ends the same way, `end-pass` last.

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
it. A retrospective is a commit after the review, so it always needs CI on the new head (write
`ci`, wait per *Waiting, without ending your run*); whether it also warrants a follow-up review is
your call, as with any post-review change, and a `docs/`-only commit rarely does.

## Finishing

```bash
bd close <id> --reason "Delivered in PR #NN"
bd dolt push
.cerebro/cerebro/scripts/end-pass <name> --pid $PPID
```

`git status --porcelain` prints nothing before `end-pass`, on every exit: the fleet view removes
your tree only when nothing in it can be lost. **Close the parent too, when you were the last
child**, with `bd close` and before the push:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'            # closed children are included by default
bd close <parent> --reason "All children closed; last was <id>, delivered in PR #NN"
```

An empty first line means no parent. Close the parent only when **every** child reads `closed`,
then repeat one level up; if the walk ran after the push, push again. A parent that plainly is not done stays open with `--append-notes`
saying why; its scope is the navigator's. Say what you merged and anything the navigator should
know, then finish: no second bead, no staying alive in case one appears.

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
the close and the cleanup; a retrospective goes back through `ci` first, and through `review`
too when it warrants one. Delivered, parked or handed back:
`.cerebro/cerebro/scripts/end-pass <name> --pid $PPID`, last.
