# cb-kcs.2.3 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-01
- **PR:** #266

## Adding a refusal to an existing key turned three passing tests into hangs, not failures

**What happened.** This bead makes `q` refuse to quit while a session is hosted. Three cb-kcs.2.2
cases drive `run` with a live child and end with `q` — `a_focused_live_session_receives_every_key_but_shift_tab`,
`a_paste_reaches_the_child_as_one_block` and `a_hosted_session_is_counted_for_supervision`. Their
event source polls `false` once its keys are spent, and `run` loops `while !app.quit`, so a refused
quit is an infinite loop. `cargo test --workspace --all-targets --locked` printed no failure and no
progress: it simply never returned, twice for over nine minutes, and the harness moved it to the
background rather than reporting anything. Diagnosing it needed `--test-threads=1` and a log tailed
from outside the run to see which case was last to start.
**Why.** Established. An event source that ends by *polling false for ever* only terminates because
some key in the case reaches a branch that sets `app.quit`. A bead that makes an existing key stop
doing that converts every such case from a test into a spin, and a spin is invisible to the runner.
**Cost.** About 35 minutes across three diagnosis cycles, most of it waiting on runs that were never
going to finish.
**Prevent by.** A plan that adds a REFUSAL to a key an existing test drives the loop with should
name those cases in its *Existing cases that must be updated* list — this plan named six such cases
and none of these three. Concretely for the next session in this crate (`cb-kcs.3` adds retirement
to the same loop): before changing what any key does in `route_key`, `grep -n "Char('<key>')"
fleet-view/src/main.rs` and read every case that drives `run` with it. The event sources now carry
a `stop_when_empty` mode that ends the loop when the keys are spent, which is what a case asserting
a refusal needs; prefer it over adding a key whose only job is to escape.
**Seen before.** cb-dul — a gate run that stalled for 19 minutes and never finished, also diagnosed
only by finding which suite was last to start. Different mechanism, same signature: no output is
the hardest failure in this repository to read.

## The `main.rs` test fixture's ownership worker races the keystroke it is meant to test

**What happened.** The plan's increment 8 asked for the lifecycle cases to drive `run` through
`QueuedEvents`. `run` polls the ownership worker *before* it reads a key, and `main_tests`'s
`supervision()` fixture points at a directory with no `fleet-supervisor` in it, so the worker
answers with a lock error and `app.set_supervision` replaces `Supervising` with read-only. Whether
that lands before or after the keystroke is decided by how fast a thread ran. `f_is_a_toggle` failed
with the second `f` refused as read-only, having passed its first half in the same run.
**Why.** Established — the failing case's notice was
`This view is read-only; it starts and stops nothing` for an app constructed as `Supervising`.
**Cost.** About 15 minutes, and a deviation from the plan recorded in the PR body: the
mode-dependent cases call `route_key` directly, and only the quit cases (which the mode has no part
in) drive the whole loop.
**Prevent by.** `main_tests::supervision()` is a fixture for cases about the terminal and the event
source, where ownership must not be what decides them — its own doc says so. A plan asking for a
loop-driven case whose assertion depends on `SupervisionMode` needs to say which fixture holds the
mode still, or ask for the function under test to be called directly. `route_key` is the same code
the loop calls and takes the mode as `&mut App`, so it is the deterministic seam.
**Seen before.** cb-qrm and cb-u70 both record a suite that failed once and passed on every re-run;
this is the same class arriving before the merge rather than after it, because the race is inside
one process rather than between two.
