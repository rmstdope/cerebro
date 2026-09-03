# cb-44b — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-03
- **PR:** #297

## Inserting a Rust function above an existing one silently stole its doc comment

**What happened.** Both new functions this bead adds were placed with a textual
insert immediately before an existing item — `refresh_flagged` before
`fn log_exits` (`fleet-view/src/main.rs`) and `flag_shows_for` before
`fn state_label` (`fleet-view/src/ui.rs`), each anchored on the `fn` line
itself. Rust attaches a `///` block to the *next* item, so in both cases the
neighbour's docstring landed on the new function and the neighbour was left
undocumented. Four functions ended up carrying wrong documentation. It compiles,
`cargo test --workspace --all-targets --locked` is green, and `cargo doc` is not
in the gate, so nothing mechanical saw it; the review sub-agent caught all of it
in the cold read (findings 1 and 2).
**Why.** The anchor was the `fn` line, which is not the start of the item as far
as documentation is concerned — the `///` block above it is. Anchoring on the
docstring's first line, or on the blank line before it, would have been correct.
**Cost.** One delta review round and one CI cycle, about five minutes.
**Prevent by.** When adding a function to a Rust file by text insertion, anchor
on the *blank line* before the target item, never on its `fn`/`struct`/`impl`
line, and read the three lines above the insertion point afterwards. The same
trap exists for `#[test]`, `#[derive]` and any other attribute.
**Seen before.** None found — `grep -rn "stole\|attaches to the next item"
docs/retrospectives/` is empty.
