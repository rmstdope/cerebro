# Traps this project has already paid for

Read this before planning or building. Each entry is a fact, not a rule: if the bead touches one,
say so in the plan and say what will be done about it.

## An advisory step can eat the exit status that follows it

Every script under `scripts/` runs with `set -euo pipefail`. A command whose failure nobody planned
for does not merely fail — it ends the script *there*, so an `exit <n>` written below it never runs
and the caller gets `1` instead of the status the script documents.

The shape that keeps coming back is a courtesy printed just before a deliberate exit:

    print_something_advisory        # fails
    exit 2                          # never reached; the caller sees 1

It is hard to see because the output looks perfect — the message is right, the listing is complete —
and only the number is wrong. It was read as test flakiness for a whole gate run before anybody
looked at it.

Three rules, and the first is the one that matters:

- **Settle the status, then be polite.** An advisory step on a refusal path may not decide the
  refusal's status. Write `advisory || true`, or `advisory || echo "(it did not work)" >&2`.
- **`|| true` on a `{ ... }` group is a different thing.** It suspends errexit *inside* the whole
  group, so an unchecked assignment in a "cannot fail" block leaves an empty variable instead of
  aborting. `scripts/jsonl-log.sh`'s header is where that half is written down.
- **`cmd1 && cmd2` as the last statement of a loop or function is that loop's status.** A
  `while ... do [[ test ]] && printf ...; done` exits non-zero whenever the last iteration does not
  match — a bug whose visibility depends entirely on the data. Use `if ... then ... fi` in any loop
  body whose status somebody might read.

Sightings: cb-e33 (`shell: bash` is what supplies `-o pipefail` at all), cb-ccl, cb-ue0 (twice),
cb-u70, cb-c13.

## A port a probe just released is not a port you can bind

`fleet-view/src/probe.rs`'s `free_endpoint` binds loopback port 0, reads the port back and closes
the listener. The address it answers was free a moment ago and is *not* reserved: anything on the
machine may take it in the window before the caller binds it, and on a busy CI runner something
does. A single-shot re-bind of that address is a test that fails a few runs in a hundred, on a head
whose diff may be nothing but Markdown, and it reads as a fault in the change rather than in the
test.

So every bind of a `free_endpoint` address is retried within `probe::POLL_BOUND`, asking for a new
address each attempt, and only `AddrInUse` is retried — any other bind error is answered at once
rather than being spent against the bound. The same rule already applies to anything that takes a
supervision lease: the lease's bind *is* the lock, so a caller cannot be handed a listener to avoid
the race, and both implementations retry on their own tick instead.

Sightings: cb-gln (a prose-only pull request reddened by `AddrInUse` in the `Rust tests` job),
cb-3da (the fix).

## A process started under `cargo run` hands cargo's environment to everything it starts

Cargo gives its child eighteen variables — `CARGO`, `CARGO_MANIFEST_DIR`, the whole `CARGO_PKG_*`
family — **plus every key of the `[env]` table in whatever `.cargo/config.toml` cargo discovered
from its working directory**, and rustup's proxy adds `RUSTUP_TOOLCHAIN`, which outranks the
`rust-toolchain.toml` in any worktree. The fleet view spawns sessions with its own environment, so
a view running under `cargo run` gives every agent the lot.

A `[env]` entry written without `force = true` **loses to an inherited value**, in every worktree.
So in atlantis-hud every agent's `cargo test` once wrote its generated TypeScript bindings into the
navigator's shared checkout, with no `cd` mistake required, and `export_bindings_stay_inside_this_workspace`
went red in any session carrying the variable.

Dealt with by never running the view as cargo's child: `scripts/cerebro-tui` runs `cargo build`
and execs the binary itself (ah-4n2r). That replaced a denylist in `scripts/launch` which had to be
fixed each time another variable leaked (cb-6fu, then ah-3kge). **Nothing strips the environment
any more**, so anything that starts the view, or a session, from inside `cargo run` brings the
leak straight back.

Sightings: cb-6fu, and ah-79ca / ah-16pb / ah-3kge / ah-4n2r in atlantis-hud.

