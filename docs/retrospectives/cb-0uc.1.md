# cb-0uc.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-15
- **PR:** #392

## The plan's marker-block paste truncated every carrier

**What happened.** I pasted the plan's `sync_block` awk function (increment 2) into a zsh `Bash`
call with a `for f in $=SC` loop, and it cut all eleven carriers off after the begin marker. The
diff was 5532 lines deleted. Both sync checkers then reported `unmarked:` for every file. I had
already committed before I looked, so I reset to `origin/main` and redid the paste with a small
Python replacement. That worked the first time.
**Why.** Not established. Run alone on a fixture, the same awk (macOS `awk version 20200816`)
gives the right output, so the fault is probably in how the loop called it, not in the awk.
**Cost.** About ten minutes, and one hard reset of a local branch that had not been pushed.
**Prevent by.** The cb-0uc siblings' plans reuse this paste. They should run `git diff --stat` and
the sync checker *before* committing, as increment 2 already says but my run skipped. A fleet-wide
fix would be a `--write` mode on `scripts/state-contract-sync` and `scripts/four-eye-sync`, so no
plan has to carry a hand-rolled paste. That is the navigator's to decide.
**Seen before.** None found.
