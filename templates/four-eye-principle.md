Nothing merges unreviewed and nothing merges red.

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself** — given the diff and the bead, never the implementer's own reasoning — and it
counts when all of these hold: the review **chain** covers the implementation being merged, its
first round reading the whole change cold and each later round the delta since the round before it;
every round is posted in full on the pull request, saying which of the two it was; every finding from every usable round is answered, by a change or
by a posted reply saying why not; and every check is green. Failed or unusable attempts may be retried,
but three unusable attempts for one head require the navigator. That is the whole standing approval,
and it covers a planned bead only.

Updates after rebase and/or conflict resolution does not need to trigger an additional review.

Documentation only does not need reviews — `docs/`, `README.md` and the like. **A change under
`agents/` or `skills/` is never documentation**: those files are what the fleet reads, so a word
changed there changes how every consumer behaves, and they are reviewed like any other behaviour.
`scripts/app-paths --classify` settles the question when it is not obvious; anything it calls
`application` needs a review.

**A commit that only answers findings does not start the review over.** The first round is a cold
read of the whole change. Every round after it is given the two shas, so it can take the delta
itself, together with the findings it raised and the answers posted — which it treats as **claims to
check against the code**, never as an account to accept. It asks two questions: were the findings
addressed, and does the delta introduce anything new. A round that returns nothing blocking ends the
review.

Which round a commit buys is decided by what the commit does, not by how big it is:

- **answers findings, or only makes a red check green** — a delta round;
- **a rebase, a conflict resolution or an `update-branch`** — no round at all;
- **documentation only**, by the paragraph above — no round at all;
- **anything else** — new behaviour, a different approach, work the reviewer has not seen — a fresh
  cold read, as is the first round after a hand-back.
