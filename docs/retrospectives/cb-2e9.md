# cb-2e9 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #319

## A mutation experiment left a stale test binary that read as a real regression

**What happened.** To check that a review finding was genuinely fixed, I mutated one line
(`fleet-view/src/main.rs:574`, back to `lifecycle::NUDGE_MESSAGE`), ran
`cargo test --workspace --all-targets --locked <one test>` to watch it fail, then restored the file
with `cp /tmp/main.rs.bak fleet-view/src/main.rs` and confirmed the restore with `grep`. The very
next `bash tests/gate` was RED on that same test, and three consecutive re-runs failed identically,
each printing the *pre-mutation* behaviour — the implementer's nudge line reaching an interactive
session — while the source on disk was demonstrably correct. `touch fleet-view/src/main.rs
fleet-view/src/lifecycle.rs` and a re-run were green, and the whole gate has been green since.

**Why.** Not established. The source was verified correct by `grep` before the failing runs, and the
only difference between red and green was touching the files, so a stale cargo fingerprint after the
`cp` restore is the obvious candidate — but I did not prove it, and `cp` should have set a fresh
mtime.

**Cost.** About ten minutes, and one commit (`69efbcc`, docs-only) was pushed on the strength of a
`tail -3 && git commit` chain that ran even though the gate printed `gate: RED` — so the red was
briefly on a pushed head. No wrong code reached main.

**Prevent by.** Two things. First, when a mutation experiment restores a file, `touch` the restored
file before the next build rather than trusting the copy — or make the mutation with `git stash` /
`git checkout --` instead of `cp`, which git keeps consistent with its own index. Second, and more
generally: `bash tests/gate 2>&1 | tail -N && git commit && git push` does **not** stop on a red
gate, because the exit status belongs to `tail`. `skills/implement-bead/SKILL.md`'s *Building*
section names the gate but not this shape; a gate run whose result gates a commit must be its own
command, with the commit run only after reading the word `green`.

**Seen before.** None found — `grep -rl mutation docs/retrospectives/` matched nothing. The nearest
relative is `.cerebro/traps.md`'s "An advisory step can eat the exit status that follows it", which
is the same class of mistake (a pipeline's status is the last command's) from the other direction.
