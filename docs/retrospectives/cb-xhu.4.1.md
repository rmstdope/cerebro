# cb-xhu.4.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-04
- **PR:** #327

## A fixture-sized suite cannot see an argument list that is too long

**What happened.** `scripts/fleet-health` handed the two logs to `jq` as `--arg dec "$dec_raw"
--arg tr "$tr_raw"`. All nineteen assertions in `tests/fleet-health.sh` were green against
fixtures of a few lines each. Run against this machine's real logs — the plan's own hand-validation
step — it died: `scripts/fleet-health: line 205: /usr/bin/jq: Argument list too long`, then the
script's own loud-failure line. Four decision generations here are about twenty megabytes, and
`ARG_MAX` on macOS is a quarter of that. The fix is `--rawfile dec <(cat …)`: the same bytes, as a
file rather than as argv.

**Why.** A suite whose fixtures are hand-written log lines can assert every rule about *what* the
logs mean and nothing at all about *how big* they get. Nothing in the plan or in this suite's shape
would ever have produced a twenty-megabyte fixture, and nothing should — the cost of one is real
and the assertion it would buy is about the operating system rather than about the code.

**Cost.** Small, and only because the plan's *Validation* section said to run the finished script
against the real logs by hand. Ten minutes. Had that step not been there, the script would have
been merged green and failed the first time an orchestrator ran it, which is the case it exists for.

**Prevent by.** A bash script that reads this fleet's own `.cerebro/state/*.jsonl` passes them to
`jq` with `--rawfile`/`--slurpfile`, never `--arg`. `scripts/fleet-history` already does the
equivalent (`cat "${logs[@]}" | jq -s -R`), which is why it has never hit this; `scripts/fleet-health`
did not, because it needs two log streams and one obvious way to pass two is two `--arg`s. More
generally: a plan for a script over live, unbounded files should keep its "run it against the real
thing" step, and this one did.

**Seen before.** None found — `grep -rl "Argument list too long" docs/retrospectives/` matched
nothing.
