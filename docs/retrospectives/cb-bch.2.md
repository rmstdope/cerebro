# cb-bch.2 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-08
- **PR:** #341

## The same `grep -q` SIGPIPE, a third time, and this time in a suite nobody had touched

**What happened.** CI went red on `tests/fleet-health.sh` with
`tests/fleet-health.sh: line 220: printf: write error: Broken pipe` and
`FAIL: the report does not name the roles it did not count`. Nothing in this bead's diff touches
bash — it is a Rust and `CLAUDE.md` change — and `main` itself was red at the same assertion, on
the cb-bch.1 merge (`be12596`, run 34263805431). Five local runs of the suite were green.

**Why.** Established, and already written down twice. The assertion was
`printf '%s\n' "$(run "$tmp")" | grep -q '…' || fail`. `grep -q` exits at its first match and
closes the pipe, `printf` then dies of EPIPE, and `set -o pipefail` propagates it — so **the
assertion fails precisely because what it looked for was found early enough**. It is a race the
reader wins only on a loaded runner, which is why it is green on this machine and on macOS.

**Cost.** One CI cycle, one question to the navigator and about 25 minutes, plus the delta review
round the fix bought. Cheap this time only because cb-ue0 had already written the mechanism down
in exactly these words, so the diagnosis took one `sed -n`.

**Prevent by.** This is the **third** sighting of one defect class in this repository, and the
first two were both fixed by hand, one suite at a time — cb-ue0 removed 58 of them from
`tests/launchers.sh` alone, and every other suite was left as it was. The pattern is
mechanically greppable (`| grep -q`, `| head -n`, or any writer piped into a reader that exits
early) and the safe shape is already the house style here: a here-string, or a file argument.
`scripts/portable-snippets` is the precedent for turning a twice-paid shell trap into a gate
predicate over a named directory, and this class has now been paid for three times. Whether that
check is worth writing is the navigator's, not an implementer's; recording it is what this file
is for.

**Seen before.** cb-ue0 (`tests/launchers.sh:528`, 58 occurrences in one suite, two CI cycles and
about 45 minutes), and cb-u70, which cites that same line while recording the neighbouring
"an advisory step eats the exit status" trap. `.cerebro/traps.md` records the advisory-step half
of that family and says nothing about this half.

## A plan can promise a test its own fixture cannot support

**What happened.** The plan named `mouse_capture_is_entered_and_left_with_the_other_modes`,
"asserts through the existing `Recorder` fixture that `leave` attempts every step". `Recorder` is
a fake `TerminalModes` that substitutes for `CrosstermTerminal` entirely, so it can never see
crossterm commands — the doc comment above `first_error` says exactly that, three lines up from
where the plan was reading. The test as specified would have asserted `["enter", "leave"]` and
nothing about mouse capture at all.

**Why.** Established. The plan cited the fixture correctly and the file's own comment contradicts
what it asked of it. What the test was *for* is genuinely testable, and by the other half of the
same plan sentence: `first_error`'s array grown from four steps to five, with a case naming the
mouse step.

**Cost.** About five minutes — the vacuous test was written, read back, and deleted before it ran.

**Prevent by.** `implement-bead`'s *When the plan is wrong* already says a helper the plan cites
for what it decides is read before it is built on. This is that rule applied to a *fixture* rather
than to a predicate, and the section's wording is about "a predicate, a filter, a query". A
fixture named as the vehicle for an assertion is the same kind of claim and could be named there.

**Seen before.** None found for a fixture specifically; the helper form of it is what that section
of the skill already exists for.
