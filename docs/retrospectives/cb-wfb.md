# cb-wfb — a positional list grew a bucket, and every hand-written fixture lied

`cerebro--partition-beads` returns its buckets as a plain list, and its consumers
index that list by position. This bead inserted a sixth bucket, `paused`, ahead
of `merged`. Every consumer that reads `(nth 4 beads)` therefore changed meaning
silently — and one of them, `cerebro--trigger-context`, was missed. The verifier's
standby trigger spent the whole of this bead counting beads parked for the
navigator as merged-unverified work: Psylocke would have been started by the very
section this bead adds, and never by merged work at all.

The gate was green throughout. Three tests cover `cerebro--trigger-context`, and
all three build `cerebro--beads` as a hand-written five-element list. A fixture
that restates the shape under test cannot notice the shape changing; it only
notices the *indices* changing, which is the half that was already correct. Two
further tests were red for the same underlying reason and were fixed as "stale
expectations" without anyone asking what else indexed the same list.

What found it was a review of the diff, not the suite.

**The finding:** a positional structure with several readers needs at least one
test per reader that builds the structure through its real producer. The new
`cerebro-test/trigger-context-reads-the-buckets-partition-beads-writes` does
exactly that, and is the only fixture in that area a seventh bucket cannot fool.
The remaining hand-written five-element fixtures in `emacs/cerebro-test.el` were
updated to six, but they retain the weakness described here.

This is the same class as the reader-contract rule the root `CLAUDE.md` already
states for the impure readers — a pure function tested exhaustively against
invented inputs can still be wrong about every real one. It applies to a data
shape passed between two pure functions just as much as to a reader's output.
