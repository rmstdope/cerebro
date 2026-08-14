---
name: implement-bead
description: The implementation role — take one planned bead, build it under TDD, get it reviewed and merged, and finish. Use when running an implementation session in atlantis-hud.
---

# Implementing a planned bead

You take a bead somebody else planned, build exactly what the plan says, see it onto main, and
**finish**. One bead, then you are done. Several of you may run at once.

You do not loop, and you do not end yourself either. You are an interactive session, so your process
outlives your turn — which is what lets the navigator talk to you, and what means you cannot simply
stop. When the bead is closed you write `done` to your state file and say what you did; the fleet
view sees that within about five seconds, ends you, and starts a fresh session for the next bead.
Everything you learned building this one goes with you, which is the point: a new session starts
with a clean context instead of five beads of residue.

Read `beads-workflow` for the label lifecycle and CLAUDE.md's Four Eye Principle for the review
rules; this is the role on top of them.

## Standing approval, and where it comes from

The `test-driven-development` skill stops at every phase for the navigator, and says a merge is
never covered by a blanket approval. This role is the documented exception, and the authority is
**CLAUDE.md's Four Eye Principle**, which the navigator wrote for exactly this: for a planned bead,
the Copilot reviewer is the second pair of eyes, and an implementation session merges on the
conditions stated there. Where the two disagree, CLAUDE.md governs this repository.

So: RED → GREEN → REFACTOR → COMMIT without stopping, announcing each transition, and still stopping
on a genuine design question — see *When the plan is wrong*. Everything outside a planned bead
follows the TDD skill's gates as written.

## Waiting, without ending your run

A bead has two long waits in it — the Copilot review, and CI — and how you wait is the difference
between finishing a bead and abandoning one. An implementer once armed a `Monitor` against a
review, said "I'll wait now for the monitor's event", and ended its turn. The review landed two
minutes later: two comments unanswered, the bead claimed, the PR open, and nothing to wake it.

**Wait by blocking inside a tool call. Never by ending your turn.**

```bash
until <the condition>; do bd heartbeat <id>; sleep 30; done
```

Three things about that line, each of which has cost something here:

- **The heartbeat is inside the loop, not around it.** A lease is about five minutes and a CI run is
  ten, so a heartbeat before and after leaves the middle uncovered and the claim reads as abandoned.
- **It must print as it goes.** The harness kills a run whose stream has stalled for 600 seconds,
  and it has done so here. A silent loop is indistinguishable from a hang.
- **Keep each call well under ten minutes.** A `Bash` call times out — 600000ms at the most,
  120000ms by default — so pass an explicit `timeout` and, for a longer wait, call again. A
  twenty-minute review wait is three calls, not one.

`Monitor` and `Bash` with `run_in_background` both promise to re-invoke you later. Do not rely on
either here. Your process survives the end of a turn now, so this is no longer the guaranteed
disaster it was when it ran under `--print` — but nothing wakes you. A turn ended against a review
sits until the navigator happens to look and type something, with the bead claimed, the PR open and
the lease going stale the whole time. Block, and stay in the run.

## Telling the fleet view what you are doing

`.claude/implementers/<your-name>.state.json` is how you are seen and how you are replaced. Rewrite
it at every transition, in the same `Bash` call as the thing it describes:

```bash
mkdir -p .claude/implementers
cat > .claude/implementers/<your-name>.state.json <<EOF
{"state":"working","bead":"<id>","since":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","pid":$PPID}
EOF
```

`idle` before you claim, `working` the moment you do, `asking` if you put a question to the
navigator, `done` when the bead is closed and the worktree gone. `pid` is `$PPID` — your own
`claude` process — and must be captured in the call that writes the file; a stale number shows you
as dead while you are working, and the navigator will start a second implementer over the top of
you.

`done` is a request to be ended, granted within about five seconds. Write it last.

## Finishing means finishing

There is no next bead to take, and no flag for **you** to check. The `.stop` flag still means what
`orchestrator.md` says it means — the fleet view reads it when you report `done`, and decides
whether a fresh session starts in your place. That is not your business, and you must not read it:
an implementer that saw a stop flag mid-bead and wound up early would strand exactly what the
between-beads rule exists to protect.

So: when your bead is merged, closed and cleaned up, write `done`, say what you did, and stop
producing output. **Never write `done` before that point.** A bead abandoned in flight strands a
claim, a worktree and an open PR for somebody to unpick by hand, which is exactly what
one-bead-per-session is arranged to avoid.

The one exception is a bead you hand back — a missing plan section, a question only the navigator
can answer. That is a complete run too: hand it back with the block below, clean up, write `done`,
and finish.

### Asking instead of handing back

You are interactive, so the navigator can answer you. For a question that genuinely blocks the bead
you may ask rather than hand back — write `asking` to your state file first, with the bead still in
`bead`, then ask plainly and wait.

Nobody waits for ever. You do not enforce the timeout and cannot see it: if it expires, a line
starting `[cerebro]` arrives in your session telling you to give up. Treat it as the navigator
speaking — stop waiting, hand the bead back exactly as below, and finish.

Prefer handing back outright when the answer plainly needs somebody awake, or when the bead can wait
for the planner rather than the navigator. Asking is the faster path only when somebody is there.

## Picking up

**This is your first turn's work.** Nothing gates it: a running implementer is a working one, and
there is no flag to wait for. (There was a `.go` flag once; it is gone.)

If the queue is genuinely empty, **wait for one — do not report `done`.** `done` asks to be replaced,
and a fresh session would find the same empty queue and ask again, spinning sessions for as long as
the queue stays empty. Write `idle` and poll, blocking and printing as *Waiting, without ending your
run* describes:

```bash
until bd ready --label planned --exclude-label human --exclude-type epic --json \
        | grep -q '"id"'; do
  echo "queue empty, waiting"
  sleep 60
done
```

Then claim, as below. Say once that you are waiting, so the navigator knows why you look quiet.

```bash
bd dolt pull
bd ready --label planned --exclude-label human --exclude-type epic --claim --json
bd dolt push                               # so other machines see the claim
```

One bead. `--claim` takes the first ready one; take that and no other.

`human` is work already waiting on the navigator; `epic` is a split parent, which has children
rather than a plan. Claiming either means refusing it a minute later.

`bd heartbeat <id>` at every phase gate and before anything long — a full gate run, a CI watch. The
lease is short, about five minutes, and a cycle is an hour; the exact TTL is bd's and not
configurable here, so heartbeat on every boundary rather than on a timer.

Nothing planned means the planner has not got there yet, or another implementer took the last one
first. **Wait for one, as *Picking up* describes** — a blocking, printing poll, and say once that
you are waiting.

That reverses what this said when a launcher looped: idling was its job then, and finishing
immediately was free because it would start you again. It is not free now. Finishing means writing
`done`, `done` asks to be replaced, and the replacement would find the same empty queue and ask
again — a fresh session every few seconds for as long as the queue stayed empty. A blocking poll
costs one line of output a minute.

**Read the plan with `bd show <id> --json`.** The pretty renderer mangles it.

**Refuse a plan missing a mandatory section** — context, files and reuse, increments with their
tests, test plan, user-facing decisions, out of scope, validation, traps:

```bash
bd update <id> --remove-label planned --add-label human --append-notes "<the section that is missing>"
bd unclaim <id>
bd dolt push
```

All three, and this is the **hand-back block** referred to throughout. `bd update` sets no status, so
without `bd unclaim` the bead stays `in_progress` under you after you have moved on — invisible to
`bd ready` and stranded until its lease expires. Without the push, no other machine learns it was
released. If a worktree exists by then, remove it too (see *Finishing*).

## Workspace

Check there is room before starting — a build that runs out of disk fails inside the linker with a
message that reads like a code fault:

```bash
pnpm exec tsx scripts/diskPreflight.ts    # prints what it found; non-zero means do not start
```

Never check out `main` — another agent usually holds it:

```bash
git -C <repo> fetch origin main
git -C <repo> worktree add -b <id>-short-description <repo>/.claude/worktrees/<id> origin/main
cd <repo>/.claude/worktrees/<id> && pnpm install --frozen-lockfile
```

The install is not optional: a fresh worktree has no `node_modules`, so the first `pnpm run lint`
fails for a reason that has nothing to do with the bead.

Worktrees must stay under `.claude/worktrees/`. `bd` and cargo both find their configuration by
walking up, so a worktree outside the repository silently gets its own empty bead database and its
own multi-gigabyte build directory.

**Check `pwd` before any git command.** A shell keeps its directory between commands, so one `cd`
into another agent's worktree to look at something leaves every later command there — and a
`git checkout -b` then moves that agent off its own branch.

Give the session its own ports so two agents never test each other's bundle. Blocks are ten apart and
4173 is the default, so **pick one nobody is using and check before claiming it**:

```bash
lsof -i :4183 -i :4184 -i :4185     # silence means the block is free; try 4193, 4203, ... otherwise
export SMOKE_PORT_BASE=4183
export CI=1                          # so a dying server from your own last run is never reused
```

There is no registry, so the check is the whole mechanism. The configs pass `--strictPort`, so a
collision fails loudly rather than serving you somebody else's bundle — but it does stall both runs.

## Building

Follow the plan's increments in order, each opening with its named failing test. Run **`pnpm check`**
before the PR rather than assembling the steps yourself: it orders them cheap-to-dear and, crucially,
puts `build:web` between `test:smoke` and `test:pwa`, which is the difference between a passing PWA
run and twenty minutes spent "fixing" a service worker that was never broken.

The browser suites inside it take a **machine-wide lock**, so with a peer running its own gate yours
waits — quietly, and possibly for minutes. That is the lock working, not a hang. Do not go looking
for something to kill.

`test:native` is **not** in `pnpm check` and needs a Linux runner, so its first CI failure is
something to diagnose rather than something you could have caught locally.

## When the plan is wrong

A detail the plan missed is yours to decide — do it, and record the deviation in the PR body.

Anything touching **approach, scope, or what the user sees** goes back, by the same hand-back block as a missing section, worktree included. You were given a plan precisely so those decisions were made elsewhere; making
them here is the failure mode this split exists to prevent.

## The review — you get exactly one

**One Copilot review per bead. Request it the moment the PR opens, and never again.**

```bash
gh pr edit <n> --add-reviewer @copilot
```

That command runs once in the life of a PR. Not after you address the comments, not after a rebase,
not after a fix that changed more than the comment asked for. If you catch yourself weighing whether
a push is "substantial enough" to deserve another look, the answer is no — that judgement is not
yours to make any more, and the rule exists so a bead costs one review rather than an unbounded
number of them.

`requested_reviewers` reading empty a minute later means the request was fulfilled, not dropped — do
not re-run this off of that.

Then wait for it — blocking, printing, heartbeating, per *Waiting, without ending your run*:

```bash
until gh api repos/<owner>/<repo>/pulls/<n>/reviews \
        --jq '[.[] | select(.user.login | startswith("copilot"))] | length' | grep -qv '^0$'; do
  bd heartbeat <id>
  echo "waiting for the review on #<n>"
  sleep 30
done
```

Run that with an explicit `timeout` under the ten-minute ceiling and call it again if it returns
empty-handed. The twenty-minute policy below is three of these calls, not one long one.

Every review seen on this repository has been `COMMENTED`, never `APPROVED`, so do not wait for an
approval.

**Do not require that review to match your head.** It describes the PR as it stood when it opened,
and it will keep describing that after your fixes and rebases move the head — which is correct and
expected, not a reason to ask again. What you owe the review is an answer to every comment, not a
fresh review of your answers.

**Every comment gets a change or a posted reply saying why not**, and the thread resolved:

```bash
# read them
gh api repos/<owner>/<repo>/pulls/<n>/comments --jq '.[] | "\(.id)|\(.path):\(.line)|\(.body)"'
# reply
gh api repos/<owner>/<repo>/pulls/<n>/comments/<comment-id>/replies -f body='...'
# resolve — gh has no built-in for this, so it is the GraphQL mutation
gh api graphql -f query='{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>)
  {reviewThreads(first:20){nodes{id isResolved}}}}}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false) | .id'
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'
```

Take the comments seriously. On this repository they have caught a lock that could be stolen a
millisecond after being taken, a refusal message that rounded itself into a contradiction, and a
release step that could strand a version bump — but they also raise things that are wrong or do not
apply. Judge each one; a reasoned reply is a complete answer.

**No review within about twenty minutes**: leave the PR open, escalate the bead (the hand-back block above, worktree included), say so plainly, and take the next bead. Some PRs never get one. Merging anyway is not the
answer, and neither is waiting forever. Do not re-request in the hope of shaking one loose — your one
request has been spent, and a second would not arrive faster.

## Red CI

Three fix attempts. Diagnose, fix, push — and read the failure before believing it: a wall of
identical connection errors is infrastructure, not a defect.

A suspected flake gets the job re-run instead, capped at two re-runs, and only after you have
reproduced it locally once. Without that cap, "it was a flake" is an unbounded loop that ends with a
genuinely broken timing test merged.

On exhaustion, leave the PR open, escalate, move on.

## Merging

Expect `BEHIND` on most merges: with several agents, a PR that sat through one review round has
usually been overtaken. **Rebase, re-run the local gate, and wait for CI again.** It costs a full
cycle each time and that is the accepted price — a green gate on a stale tree is evidence about a
tree that will never exist, and two agents changing the same function compatibly is exactly what
this catches.

```bash
gh pr merge <n> --squash --delete-branch
```

**Never `--auto`.** On this repository the ruleset requires checks but no review, so auto-merge fires
on green checks alone: it does not wait for the reviewer and it races any fix you push afterwards.
PR #142 merged that way four minutes before its review arrived, and the fixes that review prompted
had to ship as a second PR.

`--delete-branch` often aborts with `'main' is already used by worktree` — the merge has already
happened by then. Check `git ls-remote --heads origin <branch>` and delete it explicitly if it
survived.

## Finishing, then going again

```bash
bd close <id> --reason "Delivered in PR #NN"
git -C <repo> worktree remove --force .claude/worktrees/<id>
git -C <repo> worktree prune
bd dolt push
```

`--force`, because `worktree remove` refuses a tree holding untracked files and would otherwise abort
at the very end of a session — leaving the worktree, its branch and its build artifacts behind. The
two commands are separate rather than chained for the same reason: a failure in the first should not
skip the second.

**Do this on every exit, not only this one.** A bead handed back, a review that never came, a CI
budget spent — each of those leaves a worktree too, and nothing else cleans them up.

### Close the parent too, when you were the last child

A bead you closed may be a child of an epic, and the epic is nothing but its children: once the last
one is closed there is no work left under it, but nothing closes it on its own. Two epics sat open
here with 2/2 children closed for exactly that reason. So this belongs with the `bd close` above and
**before** the `bd dolt push` that ends the block — a parent closed after the push is a close no
other machine sees:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .parent // empty'
bd children <parent> --json | jq -r '.[].status'            # includes closed children by default
bd close <parent> --reason "All children closed; last was <id>, delivered in PR #NN"
```

An empty first line means there is no parent and you are done. `bd show --json` returns an array, so
index it as one — but guard the shape as `plan-bead` and `user-feedback` already do, because
indexing the wrong one fails with `Cannot index array with string "parent"` and reads like a missing
parent rather than a broken command.

Close the parent only when **every** child reads `closed`, and then repeat the lookup on *its*
parent — a child of a child leaves two levels to settle, and each is the same three commands. If the
walk runs after you have already pushed, push again; it costs nothing and the alternative is a
family that looks half-closed everywhere but here.

Two things this is not:

- **Not `bd epic close-eligible`.** That sweeps every eligible epic in the database, including
  families no session of yours ever touched. Walk up from your own bead, the way `bd reclaim --id`
  names one bead rather than reaping every stale lease.
- **Not a judgement about whether the epic is finished.** All children closed is the whole test. An
  epic that still has work left in it has that work as an open child, or it has a scope the navigator
  changed — and a scope change is theirs, not yours. If the children are all closed but the parent
  plainly is not done, leave it open, `--append-notes` why, and say so on the way out.

Say what you merged and anything the navigator should know — a deviation, a trap the plan missed, a
bead you handed back.

**Then finish.** Do not look for another bead, and do not stay alive in case one appears. Your
launcher re-reads its flags the moment you exit and starts a fresh session if there is more to do;
that session begins with a clean context, which is worth more than anything you could have carried
into it.

## Traps this repository has already paid for

- **The PWA suite after the smoke suite.** Smoke rebuilds `apps/web/dist` with the service worker
  disabled, so `test:pwa` straight afterwards fails with page timeouts and no worker. `pnpm check`
  orders `build:web` before `test:pwa` for exactly this reason. Rebuild; do not "fix" the worker.
- **A leftover preview server.** Without `CI=1`, Playwright reuses an existing server — including
  your own dying one from the previous run — and tests the bundle it is serving. That produced a
  "65 passed" and a "40 passed" run of a 138-test suite before anyone noticed.
- **`pnpm run test:smoke -- --project=web`** forwards the `--`, which Playwright reads as a
  positional filter: it matches no spec after building and serving, and looks exactly like a hang.
- **WebKit's driver** answers `""` for text it considers clipped, so a Chromium assertion can pass
  while the native shell shows nothing. `native` is the job that tells you.
- **A stale lease is not an abandoned agent** unless it is genuinely stale — see `beads-workflow`
  before reclaiming anything.
