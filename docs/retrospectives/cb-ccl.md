# cb-ccl — retrospective

- **Implementer:** Rogue
- **Date:** 2026-08-26
- **PR:** #163

## A "cannot fail" log block appended an empty line when its `jq` was missing

**What happened.** `scripts/launch-refused` writes its `errors.jsonl` line inside
`{ ... } || true`, the idiom the plan named and pointed at (`scripts/agent-state:208-245`,
"deliberately last, and deliberately unable to fail"). The suite's no-`jq` case — a stub `jq`
first on `PATH` that exits 127 — failed: the script wrote a blank line to `errors.jsonl` instead
of writing nothing. `set -euo pipefail` is set at the top of the file, so `line="$(jq ...)"`
looked as though it would abort the block; it does not. **Errexit is suspended for every command
inside a compound command that is the left-hand side of an AND-OR list**, which `{ ... } || true`
is by construction. `line` stayed empty, and the `printf` after it ran.

**Why.** Established, and reproduced in isolation. The `|| true` that makes the block unable to
fail is the same thing that makes `set -e` unable to stop it — the two properties are one
mechanism, and only one of them is written down.

**Cost.** About ten minutes, no CI cycle: the suite caught it before the push, which is the loop
working. The check now reads
`if line="$(jq ...)" && [[ -n "$line" ]]; then printf ... ; fi`.

**Prevent by.** `scripts/agent-state`'s own transitions-log block has the identical shape and the
identical unchecked assignment (`line="$(jq -c -n ...)"` then `printf '%s\n' "$line" >>`), so a
machine without `jq`, or one where it fails, appends a blank line to `transitions.jsonl` on every
state write — which `scripts/fleet-history` then has to parse. Nothing has hit it because `jq` is
present everywhere the fleet runs; it is latent, not theoretical. Two changes would close the
class: check the assignment in `agent-state` the way `launch-refused` now does, and state the rule
beside the idiom, in that script's header where the next copier will read it — **`|| true` on a
group turns `set -e` off inside the group, so every step in a "cannot fail" block checks itself.**
Both are outside a planned bead, so they are recorded here rather than done.

**Seen before.** `docs/retrospectives/cb-u5e.md` — the same family, one layer along: there
`|| true` could not tell "matched nothing" from "the grep never ran", and a broken rule reported
`ok`. Here `|| true` cannot tell "wrote nothing" from "wrote a blank line". Both are `|| true`
converting a failure into a plausible-looking success in a block written to be unable to fail.
