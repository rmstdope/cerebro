# cb-7dun — retrospective

- **Implementer:** Bishop
- **Date:** 2026-09-24
- **PR:** #446

## The shared checkout changed branches while the bead was being validated

**What happened.** The initial regression reproduction and first full gate ran from the shared
checkout. During that gate, `git status` showed that checkout had changed from the bead branch to
`cb-cjp7-producer-mechanics` and carried another session's `tests/launch-preflight.sh` edit. The
assigned clean worktree, `.cerebro/worktrees/cb-7dun`, still existed and was used to reproduce,
fix, and validate the bead safely.

**Why.** Not established. `git worktree list` confirmed that the shared checkout and the bead's
dedicated worktree were separate, but the session began in the shared checkout despite the latter
being available.

**Cost.** One irrelevant full-gate failure, repeated regression setup, and time spent locating and
moving to the intended worktree; no shared-checkout change was committed or pushed by this bead.

**Prevent by.** Make the bugfixer and producer workspace steps capture the prepared worktree path
before the first repository command, and run every subsequent read, edit, test, and `git` command
with that explicit path instead of relying on the session's ambient checkout.

**Seen before.** `cb-4qq` — both runs demonstrate that an ambient checkout can point outside the
bead's worktree; that run was caused by a scratch `cd`, while this run's branch change was not
established.
