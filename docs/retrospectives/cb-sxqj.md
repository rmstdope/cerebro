# cb-sxqj — a single local gate run went red on `openpty`, green in CI

**What happened.** One ordinary `bash tests/gate` run, on a one-line `.cerebro/agents.conf`
diff, failed two `fleet-view` cases:
`session::tests::a_live_normal_screen_scrolls_back_through_its_scrollback` and
`session::tests::a_log_begun_on_the_alternate_screen_says_so`, both with
`failed to openpty: Os { code: -6, ... }`. Running `cargo test --locked -p cerebro-tui --lib
session::tests` straight afterwards passed 50/50. CI was green.

**Why.** Not established. The likely cause is pty exhaustion on the developer machine: the fleet
view hosts every live session in a pty, several producers were running, and each `session.rs`
case allocates real ptys through `portable-pty`. Unlike cb-x3u, nothing in this run was a load
check. It was the gate every producer runs.

**Cost.** One red gate, a log search and one targeted re-run (about five minutes). A producer who
reads the red at face value could also spend a fix attempt on a diff that cannot have caused it.

**Prevent by.** The gate (`tests/gate`) or `fleet-view/src/session.rs`'s test helper could tell
pty allocation failure (`openpty` errno) apart from a test failure, and name it as a host
resource fault instead of a red case.

**Seen before.** cb-x3u: the same panic, there caused by ten concurrent suite runs during a load
check. This is the second sighting, and the first in an ordinary gate run.
