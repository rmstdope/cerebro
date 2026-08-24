# cb-5yr.1 — retrospective

- **Implementer:** Rogue
- **Date:** 2026-08-24
- **PR:** #127

## `git stash pop` in a worktree popped another session's stash

**What happened.** I ran `git stash -q` before checking out `origin/main`'s copy of a file to
compare byte-compile warnings, then `git stash pop` to undo it. My own tree was clean, so `stash -q`
created nothing — and `pop` took `stash@{0}`, which belonged to another session
(`On main: uncommitted on main before catching up`). It landed as five conflicted files in my
worktree, three of them mine (`CLAUDE.md`, `emacs/cerebro.el`, `emacs/cerebro-test.el`) and two not
(`agents/verifier.md`, `emacs/README.md`).
**Why.** The stash stack belongs to the **repository**, not the working tree. Every worktree of a
repository shares one, so a stash pushed in the main checkout is `stash@{0}` in a bead worktree too.
A `stash` that stashes nothing is silent, so `pop` reached straight past it to somebody else's.
**Cost.** About ten minutes, and it could have been much worse: `git reset --hard` is blocked here,
and recovering meant `git checkout HEAD -- <the five paths>` instead. Everything of mine was already
committed, which is the only reason nothing was lost. The other session's stash entry survived
(`pop` keeps it on conflict) — had it applied cleanly, that session's work would have been dropped
from the stack and left in my worktree.
**Prevent by.** `skills/implement-bead`, *Workspace*, saying plainly: **never `git stash` in a bead
worktree** — the stash stack is the repository's, shared with every other agent's worktree and with
the navigator's own checkout. To read another commit's version of a file, `git show <ref>:<path>`,
which needs no clean tree at all and is what I should have used.
**Seen before.** None found.

## A test passed on Emacs 30.2 locally and failed in CI on 28.2

**What happened.** `cerebro-test/start-due-survives-a-launcher-that-cannot-start` asserts that
`cerebro--start-due` demotes a launcher error so the other roles still start. Green locally and on
`ERT (Emacs 30.1)` in CI; red on `ERT (Emacs 28.2)`, with the error escaping the
`with-demoted-errors` it was supposed to be swallowed by.
**Why.** `with-demoted-errors` expands to `condition-case-unless-debug`, which **re-signals** while
`debug-on-error` is non-nil, and ERT's batch runner binds it on so a failure carries a backtrace.
Whether it is bound at the point the test body runs differs between the two Emacsen. Confirmed
locally: `(let ((debug-on-error t)) (ert-run-tests-batch-and-exit "start-due-survives"))` reproduces
it on 30.2 exactly.
**Cost.** One CI cycle, about seven minutes.
**Prevent by.** Any ERT test that asserts a `with-demoted-errors` branch swallows an error must bind
`debug-on-error` to nil, which is also what makes it assert the production path — nothing in the
fleet view ever runs with debugging on. Worth a line in `emacs/README.md`'s test section, and worth
running the one-liner above over a new demoted-error test before pushing: the gate's single local
Emacs cannot see this class on its own.
**Seen before.** None found.
