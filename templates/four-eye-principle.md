Nothing merges unreviewed and nothing merges red.

An agent's change is reviewed by a **review sub-agent the implementer spawns for
itself**, given the diff and the bead, never the implementer's reasoning. It counts when: the review
**chain** covers the implementation merged, a cold read of the whole change then each delta; every
round posted in full on the pull request, naming its kind; every usable round's finding
answered by a change or a posted reply saying why not; every check green. Failed or unusable
attempts may be retried; three unusable for one head require the navigator. That is the whole
standing approval, for a planned bead only.

Documentation (`docs/`, `README.md` and the like) is unreviewed. **`agents/` and `skills/` are never
documentation.** `scripts/app-paths --classify` settles doubt; anything it calls `application` needs
review.

**A commit that only answers findings does not restart the review.** A delta round gets the two
shas, takes the delta itself, and treats the answers posted to its findings as **claims to check
against the code**: were the findings addressed, and does the delta introduce anything new? Nothing
blocking ends it.

What a commit does, not its size, decides its round:

- **answers findings, or only greens a red check** — a delta round;
- **rebase, conflict resolution or `update-branch`** — none;
- **documentation only** — none;
- **anything else** (new behaviour, another approach, unseen work), and the first round after a
  hand-back — a fresh cold read.
