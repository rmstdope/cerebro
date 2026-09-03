# cb-21g — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-03
- **PR:** #299

## The doc-comment-stealing insert happened three more times, one day after it was written up

**What happened.** Every one of this bead's three review rounds raised the same defect
cb-44b recorded yesterday: a textual insert anchored on an item's `fn`/`pub fn` line
takes the doc comment — and any attribute — that belonged to it.

1. `dispatch_write` inserted before `fn dispatch` (`fleet-view/src/main.rs`) took both
   `dispatch`'s doc comment **and its `#[allow(clippy::too_many_arguments)]`**, leaving the
   nine-argument function undocumented and unallowed while the three-argument one carried
   the allow. Cold read, finding 2.
2. `value_mut` inserted before `pub fn value` (`fleet-view/src/app.rs`) took `value`'s doc
   line, so `value_mut` carried two docs describing two functions. Delta round, finding A.
3. Removing the old `apply_pending_priority` **method** from between
   `finish_work_refresh`'s doc comment and `finish_work_refresh` left that doc stacked on
   `begin_write`. Same round, same finding — and this is the variant cb-44b does not cover:
   it was a *deletion*, not an insertion.

All three compile, `cargo test --workspace --all-targets --locked` is green and
`bash tests/gate` is green: nothing mechanical sees any of it. The review sub-agent caught
all three.

**Why.** cb-44b's prevention — "anchor on the blank line before the target item, never on
its `fn` line" — is correct and I did not follow it, because it lives in a retrospective
nobody reads before starting a bead. The third case shows the rule is also incomplete:
removing an item from between a doc comment and the item below it re-parents that doc, so
the trap is about the *gap* between a `///` block and its item, not about inserts.

**Cost.** Three of the six cold-read findings and both delta-round findings, plus one CI
cycle for the doc-only fix — call it fifteen minutes and two review rounds. Cheap here
because the reviewer caught it; the cost if it merges is documentation that lies, and in
case 1 a lint suppression silently moved onto the wrong function.

**Prevent by.** This is the second bead in two days, and five occurrences in total, so the
prevention wants to stop being prose. The class is now well enough defined to check
mechanically: a `///` block must be adjacent to the item it documents, and no item that had
a doc comment or attribute before an edit may lose it. `cargo doc` is not in the gate and
would not catch cases 2 and 3 anyway (both items still have *a* doc). A clippy lint
(`clippy::missing_docs_in_private_items` is the wrong shape; `#[warn(missing_docs)]` on the
crate would catch cases 1 and 3, not 2) or a small suite comparing each item's doc block
against `git diff` is the navigator's decision, not mine. Until then, cb-44b's rule needs
the deletion half added to it: **after removing any item, read the lines above and below the
hole.**

**Seen before.** `docs/retrospectives/cb-44b.md` — Storm, yesterday, PR #297, the identical
defect twice in the same two files. That one recorded "Seen before: none found".
