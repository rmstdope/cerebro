# cb-ahs5

## The supervision-lease test failed under gate load, a fourth time

**What happened.** The first `bash tests/gate` failed only
`main_tests::a_released_lease_is_bindable_by_a_successor` (`fleet-view/src/main.rs`); this bead
changes no fleet-view code. It passed 3/3 alone, the full gate rerun was green, and CI was green.
The error text was not kept: the run's output was tailed to eight lines.
**Why.** Not established; same shape as the earlier sightings.
**Cost.** One red full gate and a second full gate, about ten minutes.
**Prevent by.** A bead for `fleet-view/src/main.rs`
`main_tests::a_released_lease_is_bindable_by_a_successor`; four sightings and still none on the
board (`bd search` finds nothing).
**Seen before.** cb-z330, ah-ickz (same test), cb-abs.1 and cb-kcs.5.3.
