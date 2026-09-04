# cb-4qq — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #317

## A scratch `cd` silently moved every later edit out of the worktree

**What happened.** To check a git claim from a review finding I ran
`d=$(mktemp -d); cd $d && git init -q ...` in a `Bash` call. The harness then reported
`Shell cwd was reset to /Users/henrikku/repos/cerebro` — the **main checkout**, not the bead's
worktree the session had been working in since `prepare-worktree`. The next two edit scripts
(`python3 - <<'PY'` against `tests/launch-preflight.sh` and `scripts/launch-preflight`) therefore
opened the shared checkout's copies. They happened to be harmless: both began with `assert old in s`,
the main checkout did not carry the branch's text, and both aborted having written nothing. The
mistake surfaced only because a `grep -n globby` afterwards found nothing at all.

**Why.** The shell's directory does not persist across a call that leaves it somewhere the harness
will not keep, and the reset target is the session's original root rather than wherever the session
was last working. `implement-bead`'s *Workspace* section warns about the opposite case — a `cd` into
another agent's worktree that then persists — so the rule as written ("check `pwd` before any git
command") reads as being about a directory that *sticks*, not one that is taken away.

**Cost.** About five minutes, and only that because the edits were assertion-guarded. Unguarded
`sed -i` or a heredoc `cat >` would have written into the shared checkout mid-bead, which is the
tree every other agent launches from.

**Prevent by.** Making every file-touching call in a bead's worktree independent of the ambient
cwd — an absolute path, or `cd <worktree> && ...` in the same call — rather than relying on the
directory a previous call left behind. A scratch repository for checking a git question belongs
under `$(mktemp -d)` with `git -C` and no `cd` at all, which is the rule
`tests/lib/consumer.sh` already binds its own fixtures to ("no function ever `cd`s the caller").

**Seen before.** None found — `docs/retrospectives/cb-kf8.md` and `cb-kcs.5.1.md` mention a cwd, but
both are about a *script's* cwd-relative default, not about a session's own directory moving.
