# cb-i6yf — retrospective

## fleet-board.sh failed in CI with a message that contradicts itself

**What happened.** PR #551 touched only `tests/fleet-role-triggers.sh`. Its first CI run went red in `tests/fleet-board.sh`: `FAIL: cb-merged is drawn under 'Merged, unverified 1', not 'Merged, unverified 1'`. Three runs of that suite alone, locally, were green, and so was one bare re-run of the CI job.

**Why.** `expect_in` (tests/fleet-board.sh:170) reads the live pty screen file twice: once in `in_section` for the test, and again in `section_of` to build the message. The view rewrites that file as it draws, so the first read can see a half-drawn screen and fail while the second sees the finished one. The message then names the right section as the one it failed to find. Why the first read saw something else (a partial write, or a frame where the bead was under another header) is not established.

**Cost.** One bare re-run of a ~2.5-minute CI job, and the time spent reading a failure message whose expected and actual values are the same text.

**Prevent by.** `tests/fleet-board.sh` `expect_in`: copy the screen once and answer both the test and the message from that one copy, so a failure shows the frame that actually failed. Likely the same for any `on_screen`/`section_of` caller that fails using a second read.

**Seen before.** cb-8dha and cb-kmxs record pty suites, fleet-board among them, going red under local load and green in CI. This is the reverse, red in CI, and the first record of the self-contradicting message.

## The estimated saving was half the real one

**What happened.** The bead estimated that removing the baseline run would save 20-25s of the suite's 108s. Run back to back locally on a warm binary, origin/main's suite took 100s and this PR's took 88s, a 12s saving. In CI the PR ran in 108s, inside the 96-114s main's last six runs spread over.

**Why.** Not established. The baseline's waits (arming, the gh read, the evaluation window) probably ended sooner than their ceilings, and CI's run-to-run spread (±9s) is wider than the cut.

**Cost.** None to the build. A reader could take the bead's figure as the expected CI drop.

**Prevent by.** A Testing bead that promises seconds should cite a timed before/after of the one suite (a `git show origin/main:<suite>` copy run next to the edited one), not a reading of its waits. CI's spread for this suite is too wide to show a cut under ~15s.

**Seen before.** Nothing like it yet.
