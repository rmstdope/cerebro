# cb-kcs.2.1 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-01
- **PR:** #244

## I answered a review finding "already done" for an edit that was never in the diff

**What happened.** Round one of the review asked me to note that `docs/ui/cb-kcs.2-split-console.html`
is on an unmerged PR. I edited `CLAUDE.md` to say so, committed, and answered the finding. Rounds
three and five raised it again; both times I replied that "the sentence on this head already carries
the dependency" without re-reading the file. It did not: `git log --oneline -- CLAUDE.md` shows the
paragraph was only ever committed in the *first* commit, in its original form. My edit had gone into
the working tree and then been overwritten by a second edit of my own in the same batch, whose
`old` string no longer matched — a `str.replace` that finds nothing changes nothing and says nothing.
So two posted answers on a public pull request asserted a state of the diff that was false, and the
reviewer was right all three times.

**Why.** Two causes, and the second is the one that matters. A `python3 - <<EOF` edit using
`s.replace(old, new)` with no assertion is a silent no-op when `old` has drifted — the same script
with `assert old in s` would have failed loudly, and I used that assertion in some edits and not in
others. And when the finding came back I answered from memory of having made the edit rather than
from the file, which is the whole of it: the review had already told me twice that the thing was
not there.

**Cost.** Two review rounds — about twenty minutes of sub-agent time and two full answer/push
cycles — spent re-raising and re-dismissing one true finding, plus the credibility cost of two wrong
statements standing on the PR.

**Prevent by.** `skills/implement-bead`, *Answering it, and going on*, already says a reply must
say *why not*. The gap is the other kind of reply: **an answer that claims a change is already
present must be read out of the file first**, the same way *When the plan is wrong* requires a
helper to be read before a sentence is written about it — that paragraph's rule ("a sentence there
about what a helper or a label does is read by the reviewer and the navigator with the trust a plan
gets, so run or read the thing before writing the sentence") covers claims about *code* and not
claims about *what the diff contains*. One clause extending it to "and a claim that a finding is
already answered is checked against `git show HEAD:<file>` or `gh pr diff`, not against memory"
would have caught this. Cheap mechanical form: every scripted edit asserts its `old` matched.

**Seen before.** None found — `grep -rl` over `docs/retrospectives/` for a silently-skipped edit or
an answer given from memory returns nothing.
