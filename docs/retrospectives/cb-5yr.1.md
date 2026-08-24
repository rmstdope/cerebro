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

---

*Second run — the bead was reopened by a failed verification and rebuilt. Below is that run's
retrospective; nothing above it was changed.*

- **Implementer:** Storm
- **Date:** 2026-08-24
- **PR:** #131

## Every ERT case for the root rule fed it a root the real producer never returns

**What happened.** cb-5yr shipped with `cerebro--session-alive-p` returning nil for *every*
interactive agent, so the fleet view showed `up` for roles whose state file said `waiting`, ended
none of them, and restarted none — the whole mechanism inert, and cb-5yr.2 and cb-5yr.3 unverifiable
behind it. The cause was one string comparison in `cerebro--root-in-args-p` against a root spelled
`~/repos/cerebro/`, which matches no command line. Four green ERT cases covered that function and
every one of them passed it an absolute root (`/Users/x/repos/cerebro/`) — a shape its only real
caller, `cerebro--repo-root`, does not produce for a checkout under the home directory.
**Why.** The pure/impure split in `cerebro.el` is what makes the view testable, and the tests only
exercise the pure half by design. The consequence is that no test anywhere pins the *shape* of what
an impure reader returns, so a pure function tested exhaustively against invented inputs can still
be wrong about every real one. `locate-dominating-file` abbreviating its result is invisible to
every other caller, because they all expand it on the way to a file name.
**Cost.** A failed verification, a bead reopened at P0, two dependent children blocked from
verification, and a second full implementation cycle — the navigator's verification time plus about
forty minutes here.
**Prevent by.** Where a pure function's argument comes from one named impure reader, one ERT case
should feed it that reader's real output shape and say so — for this one, a root as
`locate-dominating-file` returns it. `emacs/README.md`'s test section is where that belongs, next to
the pure/impure rule it qualifies. The general form: a value that is a *display* spelling
(abbreviated paths, relative paths, formatted times) must be normalised at the point it is compared
as a string, not assumed absolute.
**Seen before.** None found.

## `docs/retrospectives/` has no shape for a bead built twice

**What happened.** `docs/retrospectives/cb-5yr.1.md` already existed, written by the first run.
`skills/implement-bead` says one file per bead, one retrospective per file, and never rewrite one —
which has no arm for a reopened bead whose second run also has a finding.
**Why.** The convention was written when a bead was built once. A failed verification makes that
untrue, and the two rules ("the bead's own id as the file name, and nothing else" and "never
rewrite one") cannot both hold for a second run.
**Cost.** A few minutes' hesitation; no rework.
**Prevent by.** `skills/implement-bead`, *The retrospective* → *Where it goes*, saying what a second
run does. Appending a delimited section under a rule saying the earlier text is never touched is
what this file now does, and is the smallest change; the navigator may prefer `<bead id>.2.md`.
**Seen before.** None found.
