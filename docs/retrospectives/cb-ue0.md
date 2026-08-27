# cb-ue0 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #180

## `main` was already red when the bead was claimed, and the suite died with no FAIL line

**What happened.** `tests/launchers.sh` died partway through with no `FAIL:` message and no
assertion named — the suite simply stopped and the runner reported it failed. Twenty minutes went
into looking for what this bead had broken. It had broken nothing: stashing every local change
reproduced the identical death, and `gh run list --branch main` showed `main`'s own CI failing the
same way at `4caab75`, a direct push titled "Fixes for copilot introduction." that removed the
`model:`/`effort:` frontmatter from all seven `agents/*.md` while the suite still asserted it.

**Why.** Established, and two causes stacked.

The red `main` is one: the change was correct — those are Claude Code's words and the fleet now runs
on Copilot — but it went in outside the fleet, so no gate ran on it and no bead carried the matching
suite change. Every implementer started after it inherits a red baseline.

The silent death is the other, and is what made it expensive.
`x="$(… | grep -n … | head -1 | cut -d: -f1)"` under `set -euo pipefail` fails the whole assignment
when the `grep` matches nothing, and `set -e` then kills the suite **before** the `fail` call that
would have named the assertion. A suite whose assertions are `… || fail "…"` still dies mutely
whenever the *value* it is about to assert on is computed by a pipeline that can legitimately match
nothing — which is exactly the shape of "assert this argument is absent".

**Cost.** About 40 minutes of misattributed debugging, plus a navigator interruption to get approval
to fold the repair into this bead's PR (granted). No CI cycles: it never got that far.

**Prevent by.** Two specific things.

For the baseline: `implement-bead`'s *Workspace* section has the implementer run `disk-preflight`
before starting but nothing that establishes whether `main` is green. One `gh run list --branch main
--limit 1 --json conclusion` beside it would turn a 40-minute misattribution into a sentence, and
would tell the implementer to ask before building on red rather than after. That is a change to the
skill, so it is the navigator's to make, not mine.

For the silent death: any assignment in a suite whose right-hand side is a pipeline containing
`grep` needs `|| true`, because a no-match is data here rather than an error. The ones in
`tests/launchers.sh` are guarded now; nothing checks the rest, and a grep of the suites for
`="$(` followed by `grep` would find them.

**Seen before.** `cb-ccl.md` and `cb-e33.md` both record `set -euo pipefail` behaving other than
expected — errexit suspended inside `{ … } || true`, and `shell: bash` being what supplies
`-o pipefail` at all. Same family, third sighting: **`set -e`/`pipefail` in this repository's bash
keeps costing time by failing somewhere other than where the author was looking.**

## Removing a fork exposed a SIGPIPE race that had been hiding behind it

**What happened.** After the review was answered, a commit that changed **one word inside a comment**
turned CI red. `tests/launch-preflight.sh` failed on
`unreachable: expected no output - offline is not staleness - got: …/agent-cli: line 197: printf:
write error: Broken pipe`. Five local runs of that suite never reproduced it, before or after the
fix.

**Why.** Established from the code and the CI log. `scripts/launch-preflight` read
`agent-cli --layouts` through a process substitution and `break`ed on the matching row. The break
closes the read end while `agent-cli` is still writing the remaining rows, so its `printf` takes
SIGPIPE and bash reports the write error on stderr — and that one case asserts on the *whole* of
stderr, so the line is a failed assertion rather than noise.

The race predates this bead entirely. What this bead did was delete the `consumer-root` fork that
`launch-preflight` used to perform before the loop; without those ~20ms the parent now reaches the
`break` before the child has finished writing. **An optimisation that removes latency is a change to
timing, and timing was load-bearing for something nobody had written down.**

**Cost.** One CI cycle and about 15 minutes. The comment-only commit is what made the cause
findable — had it ridden in with the real change it would have read as a defect in the hint contract.

**Prevent by.** In a bash reader loop fed by `< <(cmd)`, drain every row and keep the first match
with a guard, rather than `break`ing — `scripts/sync-symlinks.sh` already does this for the same
`--layouts` rows and never had the problem. Worth stating wherever the fleet's bash conventions
live, because the failure appears in the *writer*, names a line number in an unrelated script, and
is invisible on macOS.

**Seen before.** None found — no retrospective mentions `Broken pipe` or SIGPIPE.
