# cb-t51j.3 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-11-21
- **PR:** #555

## `set -u` did not stop a sweep whose policy failed to load: the sweep printed `[]`

**What happened.** The plan's *Known traps* said a `sweep-*.sh` that cannot source
`candidate-label-policy.sh` would stop under `set -u` the moment it read an unset label word.
Copilot's review asked for a structured error instead. A test for that case (delete the
consumer's policy, run `--json`) got exit 0 and `[]`. The first use of the word is
`done < <(jq --arg human "$human_label" …)`, so `-u` killed only the process substitution. The
loop read nothing, and the sweep reported an empty board, which is the "failed read is never an
empty answer" fault, with exit status 0. Moving the `source` into an `if ! source …` guard then
broke every suite fixture, because `tests/lib/place-scripts` only finds a sourced library when
`source "$x/lib"` starts the line.

**Why.** Established. A process substitution is a subshell, so `set -u` aborting there exits the
subshell, not the script. The `place-scripts` awk matches `^[[:space:]]*(source|\.)` only.

**Cost.** One review round and two extra commits. Nothing reached main. Without Copilot's comment
this would have shipped.

**Prevent by.** A *Known traps* entry, under "An advisory step can eat the exit status": `set -u`
does not guard a variable whose first expansion is inside `<(…)`, `$(…)` or a pipeline stage.
Check it explicitly (`[[ -n "${x:-}" ]] || refuse`) right after the line that should set it. The
`place-scripts` header could also say that only a line-initial `source` is recognised.

**Seen before.** cb-6fu (a process substitution's `unset` took effect in a subshell that exited at
once). Same cause, different symptom.
