# cb-eguq — retrospective

- **Implementer:** Bishop
- **Date:** 2026-10-20
- **PR:** #495

## The local gate was red twice in fleet-keys.sh and fleet-view-restart.sh, green in CI

**What happened.** With the fix in place, `bash tests/gate` on macOS failed twice:
- `fleet-view-restart.sh`: "after 90s: the view starting Rogue on the first ready bead". No decision was logged and the header stayed read-only.
- `fleet-keys.sh`: "timed out waiting for: the stub agent to start".

Both suites passed alone. Six concurrent copies of `fleet-view-restart.sh` failed five times. An instrumented run showed all six views computing the same lease endpoint, 127.0.0.1:24570, from six different consumer roots.

**Why.** `scripts/fleet-supervisor`'s `endpoint_for` XORs `cksum("A:<root>")` with `cksum("B:<root>")`. `cksum` is a CRC, which is affine over XOR, so for two strings of equal length the XOR of their sums cancels the root out. The port is a function of the root's length alone. Every fleet-view system suite whose `mktemp` consumer root has the same length contends for one lease in a parallel gate run. The loser stays read-only until the winner exits. The same arithmetic made two real checkouts of equal path length collide. Filed as cb-7jmm. With the second sum changed locally (not committed), the full gate was green.

**Cost.** About forty minutes: two full gate runs, three parallel-run experiments and one instrumented build. It also nearly read as this bead's fix being wrong.

**Prevent by.** cb-7jmm, a hash in `scripts/fleet-supervisor` that depends on the root's bytes, with a suite that asserts two equal-length roots get different ports. Until it lands, a producer whose local gate is red in a fleet-view system suite should check `fleet-supervisor --endpoint-for` on two equal-length roots before suspecting their own change.

**Seen before.** cb-eguq's own description: R15 flaking 4 times in ~12 local runs, with "read-only, then supervising" on screen, is this collision seen from the other side. No retrospective file found.
