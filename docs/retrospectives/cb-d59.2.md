# cb-d59.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #173

## A new line on stderr turned an existing suite red in a file the plan said gained only one case

**What happened.** The plan's Q4 chose that an absent `agent_cli` prints
`agent-cli: no agent_cli declared; running on claude` on every call, and said
`tests/launch-preflight.sh` gains exactly one case. It gained two edits: the
`unreachable origin stays quiet` case asserts `[[ -z "$out" ]]` over the *whole* of stderr, so the
new line failed it — with a message about staleness, which is not what broke.

**Why.** Established. A suite that asserts on all of stderr is a suite that any new advisory line
breaks, wherever in the script it comes from. `tests/launch-preflight.sh:238` is the only such
assertion in that file, and nothing named it.

**Cost.** About five minutes: one red gate run and one fixture line (`agent_cli claude` for that
consumer, so the case stays about staleness).

**Prevent by.** When a plan decides a script will print a new line on stderr on an ordinary path,
its *Known traps* should carry the result of
`grep -rn '\-z "\$out"\|\-z "\$err"' tests/` — the suites that assert on the whole of a stream, and
so must be told about the line before it exists.

**Seen before.** None found.
