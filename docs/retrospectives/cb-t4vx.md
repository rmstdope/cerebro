# cb-t4vx

## A review fix skipped the static gate predicates because the local gate could not go green

**What happened.** On a loaded machine (load ≈13 on 18 cores, an endpoint-security agent scanning
every spawn), `bash tests/gate` went red twice. Every pty suite (`fleet-*`, mine included) timed
out together on "Loading work...", and each one passed when run alone. Since the full gate could
not tell a real failure from load, the follow-up commit answering the review was checked by running
only `tests/fleet-priority.sh`. That commit added `tail … | grep -q` to the suite, and CI's
`tests/pipefail-pipelines.sh` refused it (`quiet grep may exit before its writer drains`).

**Why.** Established. Once the parallel gate is known to be red for load, nothing in the
producer's routine names a cheaper gate to run after a fix. The static predicates (`pipefail-pipelines`,
`portable-snippets`, `tracked-links`, …) take seconds and are unaffected by load, but they were
left to CI.

**Cost.** One red CI round and one of the bead's three fix attempts.

**Prevent by.** `skills/produce-bead`, *Building*, or `tests/gate`: a fast leg that runs the
gate-predicate suites (CLAUDE.md, *Where each rule lives*, "gate predicates") on their own, run
after every post-review fix whatever the state of the pty suites.

**Seen before.** The load half: docs/retrospectives/cb-gkhx.md (the gate failing locally at load
10–16). The skipped predicate after a fix: none found (`grep -rl "pipefail-pipelines" docs/retrospectives/`).
