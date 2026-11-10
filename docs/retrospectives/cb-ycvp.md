# cb-ycvp: retrospective

## A temp-dir leak check under an isolated `TMPDIR` passed on a suite that leaks

**What happened.** The plan proved "tests/launchers.sh leaves nothing behind" with
`t=$(mktemp -d); TMPDIR="$t" bash tests/launchers.sh; ls -A "$t"`. Run against the unfixed suite
for RED, it printed nothing: a false GREEN on code known to leak two directories per run. The
second attempt scanned the real temp dir for `tmp.*` directories newer than a marker that matched
the suite's fixture shapes. It still reported two "leaks" after the fix: two other sessions were
running `tests/launchers.sh` at the same time, and their fixtures matched.

**Why.** On macOS, BSD `mktemp -d` with no template ignores `TMPDIR` and uses the per-user
confstr dir (`/var/folders/...`). GNU `mktemp` on CI honours `TMPDIR`, so the same check would be
meaningful on Linux and vacuous on a developer's Mac. The shared temp dir is also shared with every
other session's gate, so nothing in it can be attributed to one run by shape or timestamp.

**Cost.** Two wrong validations and a plan amended twice, about 15 minutes. Without the RED run
first, the false GREEN would have shipped as the bead's validation.

**Prevent by.** A check that "a run leaves no temp files" logs what the run itself creates: a
`mktemp` shim first on PATH that calls `/usr/bin/mktemp` and appends each path to a log, then
`[ -e ]` on each logged path after the run. A candidate line for `.cerebro/traps.md`: "`TMPDIR`
does not redirect a bare `mktemp -d` on macOS."

**Seen before.** No. The load-induced gate timeouts in this run are already recorded in cb-92g0,
cb-kmxs and cb-yq4c.
