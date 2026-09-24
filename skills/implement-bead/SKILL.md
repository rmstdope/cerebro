---
name: implement-bead
description: The implementation role — take one planned bead, build it under TDD, get it reviewed and merged, and finish. Use when running an implementation session.
---

# Implementing a planned bead

You take one bead somebody else planned, build exactly what the plan says, see it onto main, and
**finish**. Several of you may run at once.

`bugfix`-labelled beads are out of scope for this role: they route to the bugfixer flow and are
not built through the planned-bead implementer queue.

You do not loop, and you do not end yourself: you are an interactive session, and your process
outlives your turn. Never kill your own process, shell or terminal. When the bead is closed, run
`end-pass` (*Ending a pass*) and say what you did; the fleet view ends you about half a minute later
and starts a fresh session under your name for the next planned bead.

Read `beads-workflow` and the consumer's root `CLAUDE.md`; this is the role on top of them.

## Review and delivery

For a planned bead, obtain and address one independent, full review of the complete diff and bead.
Decide whether the review changes warrant another review and its scope; minor, self-contained
answers do not require a review loop. Unresolved findings or a review that cannot complete go to
the navigator.

So: RED → GREEN → REFACTOR → COMMIT without stopping, announcing each transition, and still stopping
on a genuine design question (*When the plan is wrong*). The approval covers a planned bead only;
other work stops for the navigator at each phase.

## Waiting, without ending your run

A bead has two kinds of wait, waited on differently.

- **CI, and everything else outside this session.** Nothing tells you it finished, so **block
  inside a tool call**, polling a condition a shell can test.
- **A `reviewer` sub-agent you spawned.** Its result is delivered, so do not sleep on it — see
  *Waiting for a sub-agent*.

**For the first kind: wait by blocking inside a tool call. Never by ending your turn.**

```bash
until <the condition>; do bd heartbeat <id>; sleep 30; done
```

- **The heartbeat goes inside the loop.** A lease is about five minutes and a CI run about ten.
- **It prints as it goes.** The harness kills a stream stalled for 600 seconds.
- **Each call stays well under ten minutes**, with an explicit `timeout`; a longer wait is several
  calls.

Do not rely on `Monitor` or `Bash` with `run_in_background`: nothing wakes you, and a turn ended
against CI sits until somebody types.

### Waiting for a sub-agent

**Do not sleep on the review.** Its completion is not a condition a shell can test, and a fixed
sleep wastes minutes every round. Heartbeat, spawn, and take the findings when they arrive.

Letting the turn end meanwhile is fine; **ending your pass is not**. Your state stays
`working --phase review`, and you never write `waiting` with a review outstanding.

It is trusted where `Monitor` is not because `reviewer` sub-agents have been observed to report
back, even after the parent's turn ended. One that never arrives is visible: the row sits in
`review`, the fleet view keeps a live session's bead, and the row goes red as stuck.

A cold read can outlast a lease; heartbeat on both sides. An expired lease under a live session is
not reclaimed — no licence to let one go cold elsewhere.

## Telling the fleet view what you are doing

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

| Where in this skill | Call |
|---|---|
| *Picking up*, no bead named in the prompt that started you | `.cerebro/cerebro/scripts/end-pass <name> --pid $PPID` |
| *Picking up*, once the bead you were given is confirmed yours | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID` |
| *Building*, before the fast gate | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase gate --pid $PPID` |
| *The review loop*, before spawning the review sub-agent | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID` |
| *The review loop*, once every finding is answered | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID` |
| *Red CI*, after each fix-and-push | decide whether its scope warrants `--phase review`; then `--phase ci` again |
| *The retrospective* opening line onward | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase merge --pid $PPID` |
| *The retrospective*, if you committed one | decide whether its scope warrants `--phase review`; then `--phase ci`, then `--phase merge` again |
| *Merging*, when a `strict` protection asks for a catch-up: GitHub → CI | `.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID`, then `... --phase ci ...` |
| *Asking instead of handing back* | `.cerebro/cerebro/scripts/agent-state <name> asking --bead <id> --phase <current> --pid $PPID`; on resuming, `working` with the same bead and phase |
| *Finishing, then going again*, after `bd close`, and the hand-back block | `.cerebro/cerebro/scripts/end-pass <name> --pid $PPID` |

`waiting` asks to be ended and is granted within about half a minute, so run `end-pass` last; there
is no wake to ask for.

## Ending a pass

The `.stop` flag is the fleet view's to read when you report `waiting`, never yours: winding up early
mid-bead strands the bead. **Never touch another implementer's state file or stop flag.**

**A pass is ended in one place**, and `waiting` is what it writes for you:

```bash
.cerebro/cerebro/scripts/end-pass <name> --pid $PPID
```

Run it last — after the bead is merged and closed and the retrospective is written — then say what
you did and stop producing output. **Never earlier**: a bead abandoned in flight strands its claim,
worktree and PR. A hand-back is a complete run too, and ends the same way.

## Picking up

**This is your first turn's work.** Nothing gates it.

**You do not pick your bead, and you do not claim it.** The fleet view claimed it before your
session started, and the prompt names it: *Your bead is `<id>`; it is already claimed for you.*
Confirm it is yours, then write your state:

```bash
bd dolt pull
bd show <id> --json          # assignee must be your own name, status must be in_progress
.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase build --pid $PPID
bd dolt push
```

**Never run `bd ready`, never pass `--claim`, never take a different bead, and never take a bead
another agent holds: `in_progress` with an assignee is authoritative.** Which bead a builder takes is
the fleet view's decision (`scripts/assignable-beads`).

**If it is not yours** — another assignee, not `in_progress`, or no such bead — hand it back with the
hand-back block below, the `--add-label human` form, name what you found, and end the pass.

**If the prompt names no bead**, say "no bead was given, ending the pass" in one line, run `end-pass`,
and stop producing output.

`bd heartbeat <id>` at every phase gate and before anything long. The lease is about five minutes,
and its TTL is not configurable here.

**Read the plan with `bd show <id> --json`.** The pretty renderer mangles it.

**Redirect an unplanned UX-agreed bead before validating a plan.** When its labels contain
`ux:agreed` and not `planned`, it is combined-producer work, not a malformed legacy input: load
`produce-bead` and continue there. The producer writes the missing build plan and implements the
bead; do not use the hand-back block.

**Refuse a plan missing a mandatory section** — context, files and reuse, increments with their
tests, test plan, user-facing decisions, out of scope, validation, traps:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<the section that is missing>" \
  --set-metadata paused_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
bd unclaim <id>
bd dolt push
```

All three: this is the **hand-back block** referred to throughout. Why each command matters is in
`beads-workflow`, *The lifecycle a bead moves through*.

**One variation.** A bead carrying `verification:failed` that you hand back because there is
**nothing left to implement** — the surface is already there, or another bead carries it — drops the
`human`:

```bash
bd update <id> --remove-label planned --append-notes "<why there is nothing to build>"
bd unclaim <id>
bd dolt push
```

An open bead with `verification:failed` and neither `planned` nor `plan:revise` is what
`scripts/second-look-beads` matches, so it gets the verifier's second look; `human` would park it
before a person with nothing to decide.

**Never add `plan:revise` in either case.** Only the verifier sets it, as the navigator's answer at
the verdict. After either block, run `end-pass` last.

### A reopened bead

Recognise it from `bd show <id> --json`: a `verification:failed` label, notes beginning
"Verification failed", a reopened history. Before the plan, read what shipped and the failure notes:

```bash
git log origin/main --grep "(<id>):" -F --oneline    # the original PR(s)
```

Build from the plan as amended. **Your scope is the gap the navigator found, not a rebuild.** Where
it is testable, your first failing test reproduces what they saw.

Close it as usual: `verification:failed` stays through the close by design, and the parent walk is
unchanged, because the verifier already reopened the chain.

## Workspace

**Your tree was made before your session started**: `disk-preflight` with the plan's workload, then
`scripts/prepare-worktree` (fetch the default branch, branch, init the `.cerebro/cerebro` submodule,
run the project's `install`) at `<repo>/.cerebro/worktrees/<id>`. Never check out `main`; go to
your tree:

```bash
cd <repo>/.cerebro/worktrees/<id>
git branch --show-current          # <id>, or <id>-2 and onward when that name was taken
git status --porcelain
git log --oneline "origin/$(.cerebro/cerebro/scripts/default-branch)..HEAD"
```

**If either of the last two shows anything, the tree is an earlier attempt at this bead**; read it
before you build. If the tree is missing, hand back, naming that. **Never create, move or remove a
worktree yourself.**

A fresh tree has no prewarmed build: if a suite needs one, run what
`.cerebro/cerebro/scripts/project-conf prewarm` prints, inside the tree.

Worktrees stay under `.cerebro/worktrees/`: `bd` and most build tools find their configuration by
walking up.

### A bead whose diff is inside `.cerebro/cerebro`

Work in `<tree>/.cerebro/cerebro`; its submodule git dir is private to your tree:

```bash
cat <tree>/.cerebro/cerebro/.git    # gitdir: …/.git/worktrees/<id>/modules/.cerebro/cerebro
cat <repo>/.cerebro/cerebro/.git    # gitdir: …/.git/modules/.cerebro/cerebro
```

**It arrives detached at the pinned sha**, so fetch and branch from cerebro's main, or the PR is
based behind it:

```bash
git -C <tree>/.cerebro/cerebro fetch origin
git -C <tree>/.cerebro/cerebro checkout -b <id>-short-description origin/main
```

**Never `git -C .cerebro/cerebro worktree add`**: it registers the tree in the submodule, not the
consumer, and a relative path lands it inside the submodule. **Never clone cerebro to a sibling
directory**: the classifier refuses it. `bd` works here because the tree is inside the consumer.

**Two PRs**: cerebro's, then, once merged, a `chore: bump cerebro` commit from the same consumer tree.

**Check `pwd` before any git command.** A `cd` into another agent's worktree followed by
`git checkout -b` moves that agent off its branch.

**Give each session its own block of ports.** With no `port_base` the wrapper is a no-op, so it is
always safe:

```bash
.cerebro/cerebro/scripts/smoke-port -- <the project's browser-suite command>
```

It takes a free block, holds it for exactly as long as your command runs, releases it however the
command ends, and exports the variable the suites read. **Wrap every browser-suite run, not just the
first.**

**Do not set `CI` by hand.** Project tooling reads it as "a runner with the machine to itself". A
browser config using `CI` to mean "never reuse a server I did not start" is fixed to say that
outright.

## Building

Write `gate` (state table) before you first run the fast gate. Follow the plan's increments in
order, each opening with its named failing test.

**Before the PR, classify what you changed, then run the fast gate:**

```bash
git diff --name-only -z origin/main...HEAD |
  xargs -0 .cerebro/cerebro/scripts/build-workload --classify
```

If a planned `non-rust` workload classifies as `rust`, or classification fails, rerun the preflight
with `--workload rust` and use the private-target gate. Otherwise use the plan's shared-target fast
gate; keep every existing gate leg. The command is the project's:

```bash
.cerebro/cerebro/scripts/project-conf gate_fast     # the fast gate, and what to run
.cerebro/cerebro/scripts/project-conf gate_full     # everything the project has
```

A detected, undeclared gate is announced on stderr; read it. With no gate at all, launch preflight
refuses.

### A changed shared-root declaration is gated in a clone

`project-conf` and `agents-conf` read `.cerebro/project.conf` and `.cerebro/agents.conf` from the
shared checkout, so when your diff changes either, a read from this worktree sees main and is not
evidence. Commit the increments, then run the plan's exact clone, submodule, install or prewarm, and
fast-gate commands in a throwaway clone of the committed branch. Never dirty main to make a worktree
check pass, and never report a worktree shared-root read as validation. Run a check the plan labels
post-merge only after the merge. Use the clone only for a declaration read through
`consumer-root --shared`; `roster.conf` needs none, as `roster` reads the enclosing worktree.

The fast gate is deliberately not everything; CI gates the merge. The full gate is yours to run by
choice when you suspect a regression the fast gate skips — slower, and possibly serialized.

A suite in neither gate may run in CI only when the diff touches its paths
(`.cerebro/cerebro/scripts/app-paths`); a red job there is the gate doing its job.

## When the plan is wrong

A detail the plan missed is yours to decide; record the deviation in the PR body.

**A helper the plan cites for what it decides is read before it is built on.** Read its body before
the first increment that depends on it. If it does not accept what the plan says and the intent is
unambiguous, use what does and record the deviation; if not, hand back. Run or read a helper or label
before writing a sentence about it in the PR body.

**A current-source claim the plan relies on is checked before its increment begins** — a quoted
`Currently:` region, the old side of a diff, a line-number or body claim, or prose describing
current behaviour. Open it in the current worktree before the dependent failing test, against
merged source, not a sibling's design. Still true: proceed. Already supplied by `main`: skip that
increment without duplicating code or tests, cite the evidence in the PR body, continue. Moved,
intent unambiguous: use the current shape and record it. Affects or obscures approach, scope or
audience-visible intent: hand back.

Anything touching **approach, scope, or what the user sees** needs the navigator. In the combined
producer flow, use `producer-park` only for a genuine UX or scope decision; the legacy hand-back
block remains for a malformed planned legacy bead.

### Asking instead of handing back

For a question that genuinely blocks the bead you may ask: write `asking` with the bead and the
current phase, ask plainly, and wait. No clock ends the question; the session, its claim and its
worktree sit until somebody answers. Prefer handing back when the answer needs somebody awake or the
bead can wait for a planner. Handing back is always correct.

## The review loop

**Review the implementation being merged, and obtain the review yourself.** Nothing is requested from
GitHub or waited for. Once the gate is green and the PR is open, spawn a `reviewer` sub-agent and
wait per *Waiting for a sub-agent*. Address its findings, then decide whether the resulting change
needs a follow-up review.

```bash
.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase review --pid $PPID
.cerebro/cerebro/scripts/agents-conf --role reviewer
```

**Ask for no provider; let `agents-conf` resolve it.** It probes the `reviewer` role, then
`default`. A `hit` line is `hit<TAB><key><TAB><tool><TAB><model><TAB><effort>`; an empty model or
effort means the CLI's own default. `miss<TAB>no-file` or `miss<TAB>no-line` also means the CLI's
default. `refused<TAB><sentence>` is a broken declaration: say the sentence and spawn on the CLI's
default. The tool column is read and ignored, since the sub-agent runs in this session's CLI. Say
which key matched and which model you review on.

Before each invocation, read and retain `reviewed_head` from `gh pr view <n> --json headRefOid`. A
tool failure, an empty response, or one with neither findings nor an explicit no-findings verdict is
unusable: retry that head up to three attempts, heartbeating between them. After three, leave the PR
open, record the attempts in the bead's notes, hand back, and end the pass. Post a usable review in
full with its `reviewed_head` in the heading, and answer every finding.

**The first round is a cold read**: the whole diff, the plan and the checklist, never your
reasoning. Follow-up review is the producer's decision: use a delta for a focused change or another
full read when the change is broader.

### Getting the review

Spawn a sub-agent of type **`reviewer`** on the resolved model; both layouts ship one.

**A cold read gets three things, and only these:**

- the diff — `gh pr diff <n>`,
- the bead's plan — `bd show <id> --json`,
- `.cerebro/cerebro/agents/reviewer.md`, to read as its checklist.

**A follow-up review**, when the changes warrant one, gets five things:

- **the two shas** — the previous `reviewed_head` and the head now — so it takes
  `git diff <reviewed_head>..<head>` **itself**, which makes a misdescribed delta detectable;
- the findings that round raised and the answers you posted, **as claims to check against the code**.

**Never give it your reasoning**, in either round.

**Choose the follow-up scope from the change.** A small answer to a finding can skip it; a focused
fix can use a delta, while a broader change gets another full read.

`agents/reviewer.md` tells the sub-agent which of it applies; do not repeat that. Heartbeat before the
spawn and when the findings land, and do not sleep (*Waiting for a sub-agent*).

### Posting it

**In full, as a PR comment, before the merge**, and appended to the bead's notes. The numbered list
is the findings, most important first, each naming the file and the case; with none, the italic line
alone:

```markdown
**Review (cold read, `reviewed_head`: `<sha>`)** — this pull request was reviewed before merge under
the producer's review practice, by an agent given the diff and the bead's plan, and not the
implementer's reasoning.

1. <finding, naming the file and the case>
```

A follow-up review names its scope and what it measured from:

```markdown
**Review (delta since `<previous reviewed_head>`, now `<sha>`)** — the findings of the round before
this one, checked against the code, and the diff since the head it reviewed.
```

```markdown
*No findings.*
```

Write the sub-agent's output to a file first, so the same bytes go to both places:

```bash
gh pr comment <n> --body-file /tmp/review-<id>.md
bd update <id> --append-notes "$(cat /tmp/review-<id>.md)"
bd dolt push
```

### Answering it, and going on

**Every finding gets a change or a posted reply** naming it by number and saying why not:

```bash
gh pr comment <n> --body 'Finding 3 — not changing this, because ...'
```

One comment may answer several. Judge each — a finding can be wrong — and a reasoned reply is a
complete answer. A finding about **approach, scope or what the audience sees** is a hand-back.

Once every finding is answered, write `ci` (state table) and wait for CI per *Waiting, without ending
your run* — after *Merging*'s merge-state check if anything was pushed since the PR opened. After a
*Red CI* fix, decide whether its scope warrants a review before CI.

A review a person or a bot leaves on the PR is answered like any comment; it is not what the approval
rests on.

## Red CI

**Three fix attempts and two bare re-runs, for the whole bead** — two budgets, neither refilling. A
pushed fix spends a fix attempt; a re-run of the same head spends a re-run. Read the failure before
believing it: a wall of identical connection errors is infrastructure.

Re-run a suspected flake only after reproducing it locally once, in the one suite, for that spec.

After every fix, decide whether its scope warrants another review. On exhaustion, leave the PR
open, hand back, and end the pass.

## The retrospective

Write `merge` (state table) on entering; it covers the retrospective, the merge, the close and
cleanup. A retrospective added after review needs CI on the current head; decide whether its scope
warrants a follow-up review before merging.

**When the review is answered and CI is green, before you merge**, ask: *did anything happen that I
did not expect?* This is not optional; only you saw the run. It goes before the merge because the
file is tracked and travels in the bead's own PR.

### What is worth recording

**Worth it**: a failure nothing prepared you for; green locally, red in CI; a tool not behaving as
documented; a rule you could not follow; time lost to something avoidable.

**Not worth it**: a normal bead, a RED failure, an answered finding, anything already written here.

If nothing qualifies, **write no file** and say so in your closing message: *"retrospective: nothing
to record."*

### Where it goes

`docs/retrospectives/<bead id>.md`. **One file per bead**: never append to or rewrite another
bead's; two findings are two sections of your one file. It lives under `docs/` because
`.cerebro/state/` is gitignored. It costs a CI cycle, hence the high bar:

```bash
mkdir -p docs/retrospectives          # the first finding in a fresh checkout creates it
[ -f docs/retrospectives/README.md ] || \
  cp .cerebro/cerebro/templates/retrospectives-README.md docs/retrospectives/README.md
git add docs/retrospectives/          # the README too, on the run that creates it
git commit -m "docs(<bead id>): retrospective — <the one-line symptom>"
git push
# wait for CI; if its scope warrants follow-up review, obtain it, address findings and rerun CI
# merge only when the producer decides no follow-up is needed and the current head is green
```

**Stage the directory, not just your file**, or the README copy is lost with the worktree.

### The format

The README that fence copies is the format: **What happened**, **Why** (or "not established"),
**Cost**, **Prevent by** (a file, a section, a step or a check), **Seen before**.

### Writing it

**Grep the directory first**, so *Seen before* is real:

```bash
grep -rl "<a word from your symptom>" docs/retrospectives/ 2>/dev/null || echo "nothing like it yet"
```

Be specific enough to act on: name the file, command, job or section. **Record; do not fix** —
changing the rules, the skill or CI is the navigator's.

## Merging

Expect `BEHIND`. **Whether a `BEHIND` branch may merge is the repository's answer:**

```bash
gh api "repos/<owner>/<repo>/branches/$(.cerebro/cerebro/scripts/default-branch)/protection" \
  --jq '.required_status_checks.strict'      # true: catch up first. false: BEHIND may merge.
```

- **`false`** — a `MERGEABLE BEHIND` head with green checks **merges as it stands**. Do not catch it
  up.
- **`true`** — catch up first, as below.
- **A failed protection call** is read as `true`.

The project's configuration owns this; `false` knowingly risks a semantic conflict git merges cleanly.

When it says `true`, catch up **on GitHub, and wait for CI again — no local re-gate**:

```bash
.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase rebase --pid $PPID
gh api -X PUT "repos/<owner>/<repo>/pulls/<n>/update-branch"
until [ "$(gh pr view <n> --json mergeStateStatus -q .mergeStateStatus)" != "BEHIND" ]; do
  sleep 10
done
.cerebro/cerebro/scripts/agent-state <name> working --bead <id> --phase ci --pid $PPID
# wait for CI on the new head
```

`update-branch` merges server-side (fine under squash) and returns 202 before the commit appears,
hence the poll. A **422** is a real conflict — rebase locally:

```bash
git fetch origin main && git rebase origin/main   # resolve conflicts
git push --force-with-lease
# back to --phase ci, and wait for CI
```

**Before waiting on CI after any push that could have raced main**, check the head can merge at all:

```bash
want="$(git ls-remote --heads origin "$(git rev-parse --abbrev-ref HEAD)" | cut -f1)"
until state="$(gh pr view <n> --json mergeable,mergeStateStatus,headRefOid \
                 -q '"\(.mergeable) \(.mergeStateStatus) \(.headRefOid)"')" \
      && [ "${state##* }" = "$want" ] \
      && [ "${state%% *}" != "UNKNOWN" ] && [ "$(echo "$state" | cut -d' ' -f2)" != "UNKNOWN" ]; do
  sleep 5
done
state="${state% *}"      # drop the sha again: the bullets below read the two words
echo "$state"
```

After a push both fields read `UNKNOWN` briefly, or show the **previous head's** verdict, so the
poll waits for your tip and two known fields. Then:

- `CONFLICTING DIRTY` — **do not enter the CI wait.** Rebase locally (`--phase rebase`),
  `git push --force-with-lease`, and check again.
- `MERGEABLE BEHIND` — merge it, unless protection is `strict`; then `update-branch` and check again.
- anything else (`MERGEABLE CLEAN`, `MERGEABLE BLOCKED`, `MERGEABLE UNSTABLE`) — `--phase ci`, and
  wait per *Waiting, without ending your run*.

If an update or rebase leaves an empty diff against main, close the PR unmerged.

Immediately before merging, require all three together: a full review has covered the bead's
implementation, the producer has decided whether any later change needs follow-up review,
mergeability is not behind or conflicting, and required checks for the current head are green.

```bash
gh pr merge <n> --squash --delete-branch
```

**Never `--auto`.** Auto-merge fires on green checks alone, so it races any fix you push afterwards
and can merge before the review is obtained.

`--delete-branch` often aborts with `'main' is already used by worktree` after the merge has
happened. Check `git ls-remote --heads origin <branch>` and delete it explicitly if it survived.

## Finishing, then going again

```bash
bd close <id> --reason "Delivered in PR #NN"
bd dolt push
.cerebro/cerebro/scripts/end-pass <name> --pid $PPID
```

The fleet view removes your tree only when nothing in it can be lost, so `git status --porcelain`
must print nothing before `end-pass`, on every exit.

### Close the parent too, when you were the last child

With `bd close` and **before** the `bd dolt push`:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'            # includes closed children by default
bd close <parent> --reason "All children closed; last was <id>, delivered in PR #NN"
```

An empty first line means no parent. Close the parent only when **every** child reads `closed`,
then repeat one level up. If the walk ran after the push, push again. Why the guard, and why not
`bd epic close-eligible`: `beads-workflow`, *Dependencies and breakdown*. A parent that plainly is
not done stays open with `--append-notes` saying why; its scope is the navigator's.

Say what you merged and anything the navigator should know, then **finish**: no second bead, no
staying alive in case one appears.

## Traps this fleet has already paid for

- **Suites clobbering each other's build** fail in the wrong order for no defect; run the gate, and
  do not "fix" the leftover.
- **A leftover preview server** is tested by a runner that reuses servers; run through `smoke-port`
  and set reuse to `false`.
- **`--` forwarded into a test runner** filters out every spec and looks like a hang.
- **A stale lease is not an abandoned agent** unless genuinely stale — `beads-workflow`, *Traps*.
- **A merge verdict about the wrong head** — see *Merging*.
- **Accessible names are a shared namespace**: grep the suite for every name you add; a selector
  ratchet does not catch an overlap.
- **Rust documentation and attributes belong to the whole item boundary**, not its signature:
  insert or remove an item with one `apply_patch` hunk that includes its leading `///` block,
  outer attributes and declaration. Never anchor a textual edit on a `fn`/`struct`/`impl` line
  alone. When Rust source changes, run the `item_adjacency` integration target; it compares
  existing items with their merge-base metadata and catches silent reparenting.

Read `<consumer>/.cerebro/traps.md` if it exists and say what to do about any trap the bead touches;
absent is ordinary.
