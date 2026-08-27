# cb-5yr.3 — retrospective

- **Implementer:** Wolverine
- **Date:** 2026-08-24
- **PR:** #128

## The plan's verbatim paragraph made a false claim about the code its sibling bead had just shipped

**What happened.** The plan specified a replacement paragraph to ship word for word in five files,
under *User-facing decisions*: "The paragraph above is what the navigator approved as the
replacement text; ship it verbatim." Its last sentence read "`--wake-in` is what you *ask* for and
is honoured as a floor: the view never starts you again sooner than that after your last start."
That is not what cb-5yr.1 shipped. `cerebro--trigger` gates every rule on
`(>= (- now started) (alist-get 'floor context))`, where `floor` is `cerebro-wake-interval` — a
`defcustom` — and `cerebro--started-at`'s docstring says the floor is measured from there "rather
than from the state file". The agent-written `wake_at` is parsed into the struct and then read by
nothing; `cerebro--standby-label`'s docstring says so outright: "Nothing waits for a wake any more
(cb-5yr)." So the paragraph would have put a guarantee the code does not make into every consumer's
five role documents — on the bead whose entire purpose was to stop the role documents lying.

Nothing local caught it. `bash scripts/lint` was clean (15/15) and `bash tests/gate` green, both
before and after the fix, because this project does not test prose — deliberately, and correctly.
The Copilot review caught it, five times, once per file.

**Why.** Established. The plan was written against cb-5yr.1's *design*, not against its merged
source. The design says `--wake-in` is a floor; the implementation made the defcustom the floor and
left `wake_at` vestigial. Between the plan being written and this bead being claimed, cb-5yr.1
merged (#127) and nothing re-checked the paragraph against what it actually did.

**Cost.** One CI cycle and five review replies, roughly 25 minutes. Cheap only because Copilot
caught it; had it not, the wrong text would have shipped to every consumer, and the next bead to
touch these files would have inherited a paragraph it had been told was navigator-approved.

**Prevent by.** When `plan-bead` writes text to be shipped verbatim that describes behaviour a
*sibling bead* implements, its *Known traps* should carry a check against that sibling's merged
source, not its plan — this plan already had the trap "Do not ship this before cb-5yr.1 has merged"
and a `git log` command to confirm the merge, which is one step short of the check that mattered.
Concretely, an increment reading "confirm each claim the paragraph makes against `emacs/cerebro.el`
at the sibling's merge commit" would have caught this before the PR opened. For the implementer's
side, `skills/implement-bead/SKILL.md` *When the plan is wrong* covers a plan that cannot be built;
it has nothing about a plan that can be built and is false, which is the case here — the deviation
was mine to justify on a bead planned so that no such judgement was mine.

**Seen before.** `cb-4yo`, `ah-kjfm`, `cb-abg` — the same class on its fourth sighting: the plan's
word-for-word text was not shippable as written. The three earlier ones were all caught by a local
check (`tests/prose-decoupling.sh`, `scripts/lint`, the plan's own other quote). This one is the
first the local checks could not catch at all, because the defect was a factual claim about elisp
rather than a forbidden string — which is why the prevention has to sit in the plan rather than in
another lint check.

## The plan's survey of "what a role keeps in context" missed the one the bead's own description named

**What happened.** The bead description says the child must make "the planner records which P4 beads
the navigator declined to rank so a fresh session does not ask twice" true. The plan's *Files to
change* concluded the opposite: "add one clause to the new paragraph **only if a role keeps
something in context today** (none was found at planning: planners → labels on beads; …)". So the
design specified no work for the outcome the description mandates. `skills/plan-bead/SKILL.md` in
fact kept it in context in two places — "what a session remembers having asked lives in its own
context and nowhere on the bead" at the head of *Then: triage the P4 backlog*, and "Ask only about
the beads in it you have not already put to the navigator this session" below it. With a pass now
being a session, that memory is destroyed every pass and the navigator is re-asked about the same
P4s in a fresh window every ten minutes.

I built it: a `triage:declined` label, applied when a triage question goes unanswered and excluded
from the triage query. The mechanism was mine to pick; the outcome was the bead's.

**Why.** Established, from the text itself. The survey listed each role's *persistence* mechanism
("planners → labels on beads") and concluded from its existence that nothing was context-only. That
is a different question: planners do persist holds in labels *and* kept the triage transcript in
context. Enumerating what each role persists cannot answer what it fails to.

**Cost.** Small in time — about 20 minutes to find, decide and build — but it was an architecture
decision (which mechanism, what the label is called, where it is excluded) taken by an implementer,
which is the split this fleet exists to prevent. Had I taken the plan's *Files to change* as
authoritative over the description, the child would have merged with its stated purpose unbuilt and
nothing would have failed.

**Prevent by.** When a bead's description names a specific outcome and the design concludes that
outcome needs no work, the design should say so explicitly and why — "the description's clause about
X is already satisfied by Y" — rather than leaving the two silently disagreeing. An implementer
reading a description and a design that contradict each other has no rule telling it which wins;
`skills/implement-bead/SKILL.md` *Refuse a plan missing a mandatory section* covers absence, not
contradiction.

**Seen before.** None found. `ah-tjaz` ("The plan's chosen routing had no mechanism behind it") is
adjacent — a plan naming an outcome without the means — but there the plan asked for the thing and
gave no mechanism, where here the plan concluded the thing was not needed.
