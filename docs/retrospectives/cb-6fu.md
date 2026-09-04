# cb-6fu — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #315

## The plan prescribed a shape that would have stripped nothing, convincingly

**What happened.** The plan's *Increments* section wrote the launcher's half as reading the strip's
removed names off its stdout, and the *Files to change* section described the function as one that
both unsets and prints. Implemented literally — `while IFS= read -r name; do ... done < <(cerebro_strip_cargo_env "$root")`
— the launcher printed `launch: cleared 17 CARGO_* variables from the environment cargo left behind.`
and then handed `CARGO_MANIFEST_DIR=/x` straight to the stub `claude`. A process substitution is a
subshell, so every `unset` took effect in a process that exited on the next line. Every assertion in
the new library suite passed at that point, because each one calls the function inside a subshell it
had already accepted; only `tests/launchers.sh`'s first new case, which asserts on what actually
reached the session, caught it.

**Why.** Established. `unset` takes effect in the shell that runs it, and both `$(...)` and
`< <(...)` are subshells. A function whose *effect* is on the caller's shell cannot report through
stdout to that same caller — the two are mutually exclusive — and neither the plan nor the library's
own interface said so. Fixed by leaving what was removed in two arrays
(`cerebro_cargo_stripped_injected`, `cerebro_cargo_stripped_config`) and sending the printed lines to
`/dev/null` at the one call site.

**Cost.** About fifteen minutes: one full `tests/launchers.sh` run against the broken shape, a
standalone debug fixture to see the variable arrive at the stub, and the redesign.

**Prevent by.** When a plan specifies a bash helper that **mutates the caller's shell** — `unset`,
`export`, `cd`, an assignment to a caller's variable — its *Files to change* section should say how
the caller learns what it did, and it may not be stdout. The general rule is now in
`scripts/cargo-env.sh`'s header and in `.cerebro/traps.md`'s new entry, with a suite case pinning it
(`cargo_env: what was removed is readable without a subshell, and the removal is the caller's`); a
future planner citing either will get it right.

**Seen before.** `docs/retrospectives/cb-547.md` — the same class, a different mechanism: a trap
inherited into a command-substitution subshell behaving differently from the plan's account of it.
Both are "a subshell is not the caller", and this is its second sighting in a bash helper's contract.
