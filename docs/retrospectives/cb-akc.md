# cb-akc — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-24
- **PR:** #120

## A predicate the plan said was equivalent was not, and only the full gate said so

**What happened.** The plan replaced `prune-worktrees.sh`'s `submodule_is_the_consumer` — a
`git rev-parse --git-common-dir` comparison — with `consumer-root --self-mounted`, stating that the
two "agree in every layout that exists". Its increment 4 was "refactor under green:
`bash tests/prune-worktrees.sh` before and after", and that suite *was* green after the change.
`bash tests/gate` then went red on `tests/project-sweeps.sh`, whose output showed every worktree
reported twice — the exact double-walk the predicate exists to prevent.

**Why.** The two mechanisms answer different questions. `--self-mounted` asks whether
`.claude/cerebro` resolves back to the checkout root; the janitor needs to know whether the mount
and the consumer are *one git repository*, so that one `git worktree list` covers both. They agree
for a real submodule (two repos) and for the self-mount (one repo), and part company for the third
supported layout — a vendored plain **copy** at the standard mount, where `.claude/cerebro` is an
ordinary directory of the consumer's own repository. `tests/project-sweeps.sh` builds its consumer
with exactly that shape; `tests/prune-worktrees.sh` does not, which is why the named suite passed.

**Cost.** One full gate cycle (~5 min) plus about 20 minutes reading the fixture to establish which
predicate was right. No CI cycle: the gate caught it before the PR opened.

**Prevent by.** When a plan replaces a predicate with one it calls equivalent, its increment should
name **every** suite that exercises the predicate, not the one suite named after the file. Here
`grep -rl submodule_is_the_consumer tests/` would have named `tests/project-sweeps.sh` alongside
`tests/prune-worktrees.sh` in about a second, and the plan's *Files to change* section already
listed the call site it came from. A "refactor under green" increment that names one suite is an
assertion about coverage that costs one grep to check.

**Seen before.** None found.

## A bead that merged mid-run added a fixture with the shape my own plan's trap named

**What happened.** The PR came back `CONFLICTING DIRTY` before CI. Rebasing onto main brought in
cb-0r6, and the rebased gate went red on a *new* ERT test, `fleet-signals-when-roster-refuses`,
which copies `scripts/roster` alone into a throwaway consumer. `roster` asks `consumer-root` for its
root since this bead, so with no sibling the fixture found no consumer file, rendered the built-in
fleet and refused nothing.

**Why.** The plan's *Known traps* named this exactly — "every fixture links or copies scripts one by
one; anything a script now `exec`s must be beside it in every fixture that runs the script" — and
enumerated the fixtures that needed the new line. That enumeration was correct when the plan was
written. cb-0r6 merged during this run and added a fixture of the same shape, which no list written
beforehand could contain.

**Cost.** One rebase, one extra gate cycle, about 15 minutes. It did not reach CI, because the
`CONFLICTING DIRTY` check sent the run to a local rebase before the CI wait.

**Prevent by.** For a change to what a shared script `exec`s, re-run the enumerating grep
(`grep -rn 'scripts/roster' tests/ emacs/`) **after the rebase**, not only at the start — the plan's
list is a snapshot of main at planning time, and a refactor of a widely-linked script is exactly the
kind that races other beads. Worth adding to `implement-bead`'s *Merging* section as a line: after
an update or rebase, re-check any enumeration the plan handed you.

**Seen before.** None found.
