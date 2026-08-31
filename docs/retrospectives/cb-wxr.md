# cb-wxr — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-31
- **PR:** #213

## No Copilot review arrived, and the skill's fallback does not cover a silent review — second sighting

**What happened.** `.claude/cerebro/scripts/request-review 213` exited **0**: the request was
accepted. No Copilot review ever appeared on the PR. The navigator interrupted the wait loop to say
Copilot reviews are unavailable and to obtain a sub-agent review instead. The `implement-bead`
skill's *When the automatic review cannot be requested* fires on **exit 3 and on nothing else**, and
states explicitly that "a review that was requested and never arrived is not the fallback case"; the
consumer's `CLAUDE.md` Four Eye Principle says the same. So the path the rules give for what actually
happened is *escalate and hand the bead back*, and the fallback review I ran was authorised by the
navigator speaking directly, not by either document.

**Why.** Established for the mismatch, not for the outage. The two documents discriminate on
*whether GitHub refused the request*, which is a proxy for *whether a second pair of eyes is
obtainable*. While Copilot reviews are down the proxy is wrong in the one direction that matters: the
request succeeds, the review never comes, and every implementer reaches a rule that tells it to hand
back a finished, green bead. Why the reviews are unavailable was not investigated and is outside this
bead.

**Cost.** About twelve minutes of wait loop, one navigator interruption, and one sub-agent review
that the rules as written did not authorise. Small here only because the navigator was awake and
watching; unattended, this bead would have been handed back complete, green and unmerged.

**Prevent by.** This is the second recorded sighting of the same thing (cb-3up, PR #204, five days
earlier), so it has earned a decision rather than another retrospective. The navigator's to make, in
one of two places: either `skills/implement-bead/SKILL.md`'s *When the automatic review cannot be
requested* and the `CLAUDE.md` *Four Eye Principle* stop discriminating on exit 3 and admit a
timed-out review as the same case — the sub-agent review is obtainable either way, and the paragraph
that currently forbids it is the only thing making a green bead hand back — or the fleet gets a way
for the navigator to declare the outage once, so an implementer does not need to be interrupted per
bead. Do not leave it as "the navigator will be watching": that is what was relied on twice.

**Seen before.** `docs/retrospectives/cb-3up.md` — "No Copilot review arrived, and the standing
approval has no path without one", same repository, same succeeded-request-then-silence, same
navigator interruption.
