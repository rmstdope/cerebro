Nothing merges unreviewed and nothing merges red.

An agent's change is reviewed by a **review sub-agent the implementer spawns for
itself**, given the diff and the bead, never the implementer's reasoning. It counts when: the review
**chain** covers the implementation merged, a cold read then each delta since the last round; every
round is posted in full on the pull request, naming its kind; every usable round's finding is
answered by a change or a posted reply saying why not; every check is green. Failed or unusable
attempts may be retried; three unusable for one head require the navigator. That is the whole
standing approval, for a planned bead only.

Documentation (`docs/`, `README.md` and the like) needs no review. **`agents/` and `skills/` are
never documentation.** `scripts/app-paths --classify` settles doubt; `application` needs review.

**A commit that only answers findings does not restart the review.** A delta round gets the two
shas and takes the delta itself; its findings and the answers are **claims to check against the
code**. Were they addressed, and does the delta add anything? Nothing blocking ends the review.

What a commit does, not its size, decides its round:

- **answers findings, or only greens a red check** — a delta round;
- **a rebase, conflict resolution or `update-branch`** — none;
- **documentation only** — none;
- **anything else** (new behaviour, a different approach, unseen work), and the first round after a
  hand-back — a fresh cold read.
