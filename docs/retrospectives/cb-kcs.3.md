# cb-kcs.3 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #268

## A scripted insertion anchored on an item lands *inside* that item's doc comment

**What happened.** Three of this bead's new items were added with a Python edit of the shape
`s.replace("pub fn set_notice(...) {", new_function + "pub fn set_notice(...) {")` — anchoring on
the signature of the item to insert before. In Rust the doc comment sits *above* the signature, so
each insertion landed between an existing `///` block and the item it documented: `supervise` took
`run`'s doc comment and its `#[allow(clippy::too_many_arguments)]`, `enum Deliberate` took
`SessionHost`'s, and `set_exits` took `set_notice`'s. Three occurrences of one habit in one bead.
`cargo test --workspace --all-targets --locked` is completely silent about it — the code compiles,
every test passes, and the only cost is that four items are now documented as something else. The
review sub-agent found all three; without it they would have merged.

**Why.** Anchoring on a signature is the obvious way to say "put this before that function", and it
is wrong for any language where an item's documentation precedes it — Rust, Elisp docstrings being
the exception since they sit inside. Nothing in the toolchain checks that a `///` block is attached
to what it describes.

**Cost.** One review round and about ten minutes of edits; no CI cycle, since it was caught before
the first CI wait.

**Prevent by.** Anchor a scripted insertion on the **blank line above** the target's doc comment, or
on the end of the preceding item — never on the target's own signature — and after any such edit
read the three lines above each inserted item before running anything. `implement-bead`'s *Traps
this fleet has already paid for* is where this belongs if it is seen a second time; one sighting is
not yet a check.

**Seen before.** None found — `grep -rl "doc comment" docs/retrospectives/` is empty.
