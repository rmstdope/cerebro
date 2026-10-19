# cb-gyw0

## tests/fleet-view-restart.sh is red locally on a loaded machine and green in CI

**What happened:** The gate passed on the first run. Its second run, after a web-console-only
change, went red in `tests/fleet-view-restart.sh`: "after 90s: the view starting Rogue on the first
ready bead, cb-b1". Run alone it was red twice more. The view logged no evaluation, no decision and
no error, and launched nothing. Disk was fine and none of the stray `cerebro-tui` processes were
this session's. The load average was 68, and another worktree (cb-n53p) was running the same suite
at the same moment. CI ran the same head green on ubuntu-latest.

**Why:** Not established. The diff could not reach the suite: it builds only `cerebro-tui`, which
does not depend on `cerebro-web`. The most likely cause is that the view's first trigger tick did
not finish inside the 90 s bound under that load. The view writes nothing before it decides, so the
failure output cannot tell a slow view from a stuck one.

**Cost:** Three suite runs (about five minutes) and the time spent ruling out disk, orphans and the
diff before trusting CI.

**Prevent by:** In `tests/fleet-view-restart.sh`, have the failure dump print what the view drew
(its pty screen) and the load average. A red run would then show whether the view was supervising
and how far it got.

**Seen before:** No.
