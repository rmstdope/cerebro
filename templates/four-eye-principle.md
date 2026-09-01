Nothing merges unreviewed and nothing merges red.

For a change built by an agent, the second pair of eyes is a **review sub-agent the implementer
spawns for itself** — given the diff and the bead, never the implementer's own reasoning — and it
counts when all of these hold: at least one usable review covers the implementation being merged; it is
posted in full on the pull request; every finding from every usable round is answered, by a change or
by a posted reply saying why not; and every check is green. Failed or unusable attempts may be retried,
but three unusable attempts for one head require the navigator. That is the whole standing approval,
and it covers a planned bead only.

Updates after rebase and/or conflict resolution does not need to trigger an additional review.

Documentation only does not need reviews — `docs/`, `README.md` and the like. **A change under
`agents/` or `skills/` is never documentation**: those files are what the fleet reads, so a word
changed there changes how every consumer behaves, and they are reviewed like any other behaviour.
`scripts/app-paths --classify` settles the question when it is not obvious; anything it calls
`application` needs a review.

**A commit that only answers findings does not start a review over.** The first round is a cold
read of the whole change; every round after it is given the delta since the head it reviewed, the
findings it raised and the answers to them, and asks one question — were they addressed, and does
the delta introduce anything new. A round that returns nothing blocking ends the review. Work that
goes beyond answering findings — new behaviour, a different approach, anything the reviewer has not
seen — is a fresh cold read, and so is the first round after a hand-back.
