# Instructions for the fleet

Copy this to the root of a project that mounts cerebro, as `CLAUDE.md`: Claude Code loads it, and
Copilot loads the same file as its custom instructions when no `AGENTS.md` sits beside it. Replace
*The project*; keep the two headings the skills read by their exact names, *Four Eye Principle* and
*Work tracking*; edit the rest until it says what is true here.

## The project

One paragraph: what this application is, who uses it, and what "working" means for it.

## Four Eye Principle

*Read by `skills/implement-bead` and `skills/plan-bead` by this exact heading: the implementer's
whole standing approval to merge without asking. Delete it and nothing merges. The block between
the markers is synced from `templates/four-eye-principle.md` by `scripts/four-eye-sync`.*

<!-- four-eye:begin -->

Nothing merges unreviewed and nothing merges red.

An agent's change is reviewed by a **review sub-agent the implementer spawns for itself**, given the
diff and the bead, never the implementer's reasoning. It counts when: the review **chain** covers
the implementation merged, a cold read of the whole change then each delta since the round before;
every round posted in full on the pull request, naming its kind; every usable round's finding
answered by a change or posted reply explaining why; every check green. Failed or unusable attempts
may be retried; three unusable for one head require the navigator. That is the whole standing
approval, for a planned bead only.

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

<!-- four-eye:end -->

No review is asked of the code-hosting platform, and none is waited for. A review a person or a bot
leaves on the pull request anyway is read and answered like any other comment; it is not what the
approval rests on.

Everything else needs a person — a change nobody planned, a red or missing check, a finding about
approach, scope or what the audience sees, a finding answered by neither a change nor a reply, and a
review sub-agent that could not be spawned or returned nothing usable.

## Work tracking

*Read by every role through `skills/beads-workflow`, which carries the commands; this section is
where a project says anything that differs.*

Planned work is tracked in beads. An external issue tracker, if there is one, is the inbox for
outside requests and bug reports only. Every bead is created unranked and ranked later with a human;
a bead is planned in one session and implemented in another.

## Development practices

*Read by planners and implementers when deciding how much to build at once and how to test it.*

- Work is delivered in small increments that stand on their own.
- Code is written test-first.
- Prefer the simple design; say so when you decline a more general one.
