# cb-yq4c — the web console's browser suite joins CI and the gate

## The supervision-lease test failed under gate load, a fifth time

**What happened.** `bash tests/gate` went red on
`main_tests::a_released_lease_is_bindable_by_a_successor` (`fleet-view/src/main.rs`) with
`ReadOnly(LockError("cannot locate the supervision lease"))`. This bead changes no Rust. The test
passed 3/3 alone and the whole `cargo test` passed on rerun.

**Why.** Not established; it fails only under the gate's parallel load.

**Cost.** One extra Rust run (about two minutes) and a paragraph in the PR explaining a red
gate that was not this bead's.

**Prevent by.** A bead for that test, as cb-z330 and cb-ahs5 already ask. The board still has
none: `bd search "released_lease"` finds nothing.

**Seen before.** cb-z330, cb-ahs5 (which counts four sightings before this one).

## A `project.conf` declaration cannot be exercised from the worktree that adds it

**What happened.** The bead declares `port_base` and `port_env` so that `scripts/smoke-port`
reserves the browser suite's ports. In the worktree, `smoke-port` answered "this project declares
no port_base" and ran the suite on the fixed ports. Vite then reused a foreign server already
listening on 5199 (another project's dev server), and 45 of 49 cases failed.

**Why.** Established. `project-conf` resolves `consumer-root --shared`, which is the main
checkout, so a declaration takes effect only once it merges. The suite reused the server because
`reuseExistingServer` was on whenever `CI` was unset.

**Cost.** One full red suite run, about five minutes of diagnosis, and a local validation that
had to set `CEREBRO_PORT_BASE` by hand. CI is unaffected, because there the checkout is the
shared root.

**Prevent by.** A line in `skills/produce-bead`'s *Building* saying that a bead which adds a
`project.conf` key validates with the value passed by hand, because the worktree reads the main
checkout's file. cb-epr hit the same thing.

**Seen before.** cb-epr.

## The browser suite had a race nobody had seen, because nothing ran it

**What happened.** The first enforced runs failed "a kill asks first" about once in fifty. The
helper `controlled()` returned before `/api/control` had answered, so `k` was refused as
read-only.

**Why.** Established. The suite had never run repeatedly or under load. Fixed in this bead: the
helper now waits for the supervision pill.

**Cost.** One stress run of the full suite, four repetitions.

**Prevent by.** When a suite first joins CI, run it `--repeat-each` locally before enforcing it.
This bead did; the note is for the next suite promoted the same way.

**Seen before.** Nothing like it yet.
