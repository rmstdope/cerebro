# cb-rdv — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-26
- **PR:** #158

## `main` carried a tracked symlink with no source, and nothing was red

**What happened.** The plan required running `.claude/cerebro/scripts/sync-symlinks.sh` in the
worktree to write the new skill's link. It printed an extra line I did not expect:

```
Removed stale skill link: …/.claude/skills/release-notes (its source is gone from the mount)
```

`.claude/skills/release-notes` is a **tracked** symlink pointing at `../cerebro/skills/release-notes`,
and that directory was removed by cb-7v2 (`d7a76fa`, merged in #151) without the link being removed
with it. It had been dangling on `main` through three merges. `bash tests/gate` is green with it
there, and so was CI on every PR since — `tests/sync-symlinks.sh` builds its own throwaway consumer
and syncs it, so it never looks at the links this repository has committed, and
`tests/launch-preflight.sh`'s self-consumer case checks that the links it needs resolve rather than
that every committed link does.

**Why.** Established. This repository is a consumer of itself, so `.claude/skills/*` are tracked
files whose correctness depends on `skills/*` — and nothing checks that pairing. Deleting a skill
is therefore a two-file change that looks like a one-file change, and the second file is in a
directory a normal `sync-symlinks.sh` run silently repairs, so whoever next runs the sync picks the
repair up as an unrelated diff.

**Cost.** Small here — about ten minutes deciding whether an unrelated tracked deletion belonged in
this bead's commit, and one paragraph of the PR body explaining it. The real cost was paid earlier
and invisibly: three merges shipped a broken tracked link, and any consumer that vendors this
repository as a plain copy got a dangling `.claude/skills/release-notes` with it.

**Prevent by.** `emacs/cerebro-test.el`'s *Reader contracts* section is the wrong home, but the
check itself is one line of bash and belongs in `tests/sync-symlinks.sh`: every symlink tracked
under this repository's own `.claude/skills` and `.claude/agents` resolves to an existing path.
That is behaviour over code (the sync's own output), not a grep over prose, so it fits this
repository's *Development practices*. Alternatively `scripts/sync-symlinks.sh` could exit non-zero
when it removes a stale link it did not expect to remove — but the test is the cheaper of the two.
(Recording only; the change is the navigator's.)

**Seen before.** None found. `docs/retrospectives/cb-epr.md` is the only other file mentioning
symlinks, and it is about `consumer-root --shared` resolving to the main checkout during a gate run,
not about tracked links going stale.
