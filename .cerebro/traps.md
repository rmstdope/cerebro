# Traps this project has already paid for

Read this before planning or building. Each entry is a fact, not a rule: if the bead touches one,
say so in the plan and say what will be done about it.

## An advisory step can eat the exit status that follows it

Every script under `scripts/` runs with `set -euo pipefail`. A command whose failure nobody planned
for does not merely fail — it ends the script *there*, so an `exit <n>` written below it never runs
and the caller gets `1` instead of the status the script documents.

The shape that keeps coming back is a courtesy printed just before a deliberate exit:

    print_something_advisory        # fails
    exit 2                          # never reached; the caller sees 1

It is hard to see because the output looks perfect — the message is right, the listing is complete —
and only the number is wrong. It was read as test flakiness for a whole gate run before anybody
looked at it.

Three rules, and the first is the one that matters:

- **Settle the status, then be polite.** An advisory step on a refusal path may not decide the
  refusal's status. Write `advisory || true`, or `advisory || echo "(it did not work)" >&2`.
- **`|| true` on a `{ ... }` group is a different thing.** It suspends errexit *inside* the whole
  group, so an unchecked assignment in a "cannot fail" block leaves an empty variable instead of
  aborting. `scripts/jsonl-log.sh`'s header is where that half is written down.
- **`cmd1 && cmd2` as the last statement of a loop or function is that loop's status.** A
  `while ... do [[ test ]] && printf ...; done` exits non-zero whenever the last iteration does not
  match — a bug whose visibility depends entirely on the data. Use `if ... then ... fi` in any loop
  body whose status somebody might read.

Sightings: cb-e33 (`shell: bash` is what supplies `-o pipefail` at all), cb-ccl, cb-ue0 (twice),
cb-u70, cb-c13.
