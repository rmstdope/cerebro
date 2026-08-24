# cb-x05 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-24
- **PR:** #138

## A planned test case passed before the code path it was written for existed

**What happened.** The plan's increment 4 specified a fixture suite `f-killed.sh` containing
`kill -9 $$`, to prove that a suite leaving no result behind is reported as a failure rather than a
pass. Written as specified, the case went green on its first run — no RED. `kill -9 $$` kills the
`bash "$t"` child only, so `run_one` survives it, reads a perfectly ordinary exit status of 137 and
writes the `.rc` file. The missing-result branch — `cat` of an absent `.rc`, the whole point of the
increment — was never reached, and the case would have shipped proving nothing.
**Why.** Established. The plan reasoned about `$$` as though the suite and the job running it were
one process. The reproduction that does reach the branch is `kill -9 $PPID`, which kills the
`run_one` background subshell before it can write a result; confirmed by hand, and the runner then
prints no `ok`/`FAIL` line for that suite at all, only the replay header and `FAILED:`.
**Cost.** About five minutes, and only because the missing RED was noticed. Nothing was lost.
**Prevent by.** `skills/implement-bead`'s *Building* says each increment opens with its named
failing test; it does not say what to do when the named test passes immediately. It should: a
planned test that goes green before its implementation exists is not an increment already done, it
is a test aimed at the wrong thing, and the branch it claims to cover must be reached by hand
before the increment is called finished.
**Seen before.** None found — `grep -rl` over `docs/retrospectives/` for this shape returned
nothing.
