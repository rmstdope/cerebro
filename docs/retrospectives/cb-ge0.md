# cb-ge0 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-27
- **PR:** #188

## A bash suite that dies before its first assertion exits 0, and the gate reads it as green

**What happened.** Increment 1's RED step was `bash tests/jsonl-log.sh` against a library that did
not exist yet. The suite died at its `source "$repo_root/scripts/jsonl-log.sh"` line with
`No such file or directory` — and `echo "exit=$?"` printed `0`. Reduced:

    printf 'set -euo pipefail\ntrap "rm -rf /tmp/nope" EXIT\nsource /nope/nope.sh\necho reached\n' > t.sh
    bash t.sh; echo "exit=$?"     # -> "No such file or directory", then exit=0

**Why.** Established, and it is the same mechanism this bead is about, one layer along. The
*implicit* errexit exit carries no explicit status, so bash takes the exit status from the last
command run in the EXIT trap — and `tests/lib/consumer.sh`'s trap ends in `rm -rf`, which succeeds.
An explicit `exit 1` is preserved, so every assertion that goes through `fail` is unaffected; only a
suite that dies *before* an assertion — a bad `source`, a failed `set -u` expansion, a missing
fixture command under errexit — reports itself green while having tested nothing.
`scripts/suite-runner` reads the exit status, so it prints `ok tests/<suite>.sh` for such a run, and
so does CI.

**Cost.** About ten minutes here, all of it spent doubting a RED that was real. Nothing was
mis-merged. The cost that has not been paid yet is the one worth naming: a suite broken this way is
indistinguishable from a passing one in the gate's output.

**Prevent by.** Making `_consumer_lib_cleanup` in `tests/lib/consumer.sh` preserve the status it was
entered with — capture `status=$?` as its first line and end with `exit "$status"` — or, if that is
judged too broad, having each suite's final `echo "<suite>: all assertions passed"` be what
`scripts/suite-runner` checks for, so a suite that never reached its last line cannot read as `ok`.
Either is a change to the test library and to the runner, which is outside a planned bead; recording
it here rather than doing it.

**Seen before.** None found for this exact symptom. It is a sibling of cb-u5e (`|| true` cannot tell
"matched nothing" from "the command never ran") and of cb-ge0 itself (`|| true` on a group suspends
errexit inside it) — the same family: a construct whose failure mode is silence.

## The `link_scripts` trap fires in fixtures that do not call `link_scripts`

**What happened.** The plan named the cb-ue0 trap precisely — a fixture that hand-places a script
must place the sourced libraries beside it — and pointed at the one fix it needed,
`tests/lib/consumer.sh`'s `link_scripts`. Two further fixtures place `scripts/agent-state` by hand
and were not on the list, so both went red only when the whole gate ran:

- `tests/agent-state.sh`'s `from-a-worktree-copy-writes-to-the-shared-checkout` case, four `ln -s`
  by hand.
- `emacs/cerebro-test.el`'s reader-contract case
  `cerebro-test/state-file-written-by-agent-state-derives-a-row`, a `dolist` over a literal list of
  four script names.

The ERT one is the one that matters: it is a *bash* trap that fires in the *elisp* suite, so neither
the plan's list of bash suites to run nor the bash half of the gate would have caught it.

**Why.** Established. `link_scripts` links the libraries unconditionally precisely so a suite cannot
forget them, but it is a convention only where it is called; two fixtures predate or bypass it.

**Cost.** Two extra gate runs, about six minutes.

**Prevent by.** A plan that adds a `source` line to a script under `scripts/` should list the
fixtures that place that script, found with `grep -rn "<script name>" tests/ emacs/` rather than
from memory — the search takes seconds and names both of the above. The durable fix is that a
fixture places scripts through `link_scripts` rather than by hand; this PR converted the
`tests/agent-state.sh` one, and the ERT fixture cannot (it is elisp and has no access to the bash
library), so that one stays a literal list somebody has to remember.

**Seen before.** docs/retrospectives/cb-ue0.md — same trap, for `root-hints.sh`, when that library
was introduced. Second sighting, and both sightings are "a new sourced library was added".
