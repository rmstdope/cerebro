Nothing merges unreviewed and nothing merges red.

An agent's change is reviewed by a **review sub-agent the producer spawns for itself**, given the
diff and the bead, never the producer's reasoning. It counts when: the review **chain** covers
the implementation merged, a cold read of the whole change then each delta since the round before;
every round posted in full on the pull request, naming its kind; every usable round's finding
answered by a change or posted reply explaining why; every check green. Failed or unusable attempts
may be retried; three unusable for one head require the navigator. That is the whole standing
approval, for a producer-held bead only.

Documentation (`docs/`, `README.md` and the like) needs no review. **`agents/` and `skills/` are
never documentation.** `scripts/app-paths --classify` settles doubt; anything it calls
`application` needs review.

**A commit that only answers findings does not restart the review.** A delta round gets the two
shas, takes the delta itself, and treats answers to its findings as **claims to check against the
code**: were the findings addressed; does the delta introduce anything new? Nothing blocking ends
the review.

What a commit does, not its size, decides its round:

- **answers findings, or only greens a red check** — delta round;
- **rebase, conflict resolution or `update-branch`** — none;
- **documentation only** — none;
- **anything else** (new behaviour, another approach, unseen work), and the first round after a
  hand-back — a fresh cold read.
