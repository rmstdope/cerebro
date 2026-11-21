# cb-wklg

## A gate run on an uncommitted tree skipped the item-adjacency guard

**What happened.** `bash tests/gate` was green before my first commit. After the commit (and a
second one answering the review), a plain `cargo test --workspace --all-targets --locked` went red
in `fleet-view/tests/item_adjacency.rs`, `current_rust_diff_keeps_metadata_with_its_existing_items`:
I had added `#[allow(clippy::too_many_arguments)]` to the existing `fn start_given`, and the guard
refuses changed attributes on an existing item. CI would have gone red on the PR's first head; the
fix was dropping the attribute (seven parameters is within clippy's limit anyway).

**Why.** The guard diffs `git merge-base origin/main HEAD ... HEAD`, the committed range only. The
skill has the producer run the fast gate *before* opening the PR, and nothing says to commit first,
so a gate run on a working tree with nothing committed sees an empty range and passes the guard
vacuously. The tests that read the tree (every other Rust test) saw the change; this one did not.

**Cost.** A red CI round avoided only by chance (a full re-run after the review commit); one extra
commit.

**Prevent by.** Either `produce-bead` *Building* says to commit the increments before running
`gate_fast`, or `current_rust_diff_keeps_metadata_with_its_existing_items` also compares the working
tree (`git diff <base> --name-only` without `...HEAD`) so it cannot pass on an uncommitted change.

**Seen before.** No: grepped `docs/retrospectives/` for `item_adjacency` and `uncommitted`; the
`uncommitted` hits (cb-5yr.1, cb-drjb, cb-hwpj, cb-mqa) are about lost edits, not a skipped guard.
