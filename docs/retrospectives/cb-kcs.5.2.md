# cb-kcs.5.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #281

## A plan's citation of the elisp it ports was wrong, and the test it specified could not catch it

**What happened.** The plan's `app.rs` section asked for `work_requested_at`, "set by
`begin_work_refresh`", and argued for it at length by citing `cerebro--beads-read-at`
(`emacs/cerebro.el:5520-5527`) as the thing the guard exists for. That is wrong about the elisp in
the one way that matters: `cerebro--beads-read-at` is assigned only inside the success arm of the
callback (`emacs/cerebro.el:5588-5596`), so the request time is written *with* the value. Stamping
it at begin, as the plan said, lets a **failed** read move the age while `PaneContent::value()`
goes on handing out the previous read's buckets — old ids against a young age, which passes the
`panel_age < idle_for` guard and types Cerebro a line naming beads it has just ranked. That is
precisely the failure the guard exists to prevent.

It survived the build because the plan also specified the test —
`app::tests::the_work_request_time_is_when_it_was_asked`, a begin, a successful finish, and the
earlier of the two — and that test exercises only the path the plan described. A wrong claim about
current behaviour and a test written from the same claim agree with each other.

**Why.** Established. The plan's own prose named `cerebro--beads-read-at` three times as the reason
for the change, which reads as a citation somebody has checked; I read the defvar's docstring and
the lines the plan cited, and never opened the assignment. `implement-bead`'s *When the plan is
wrong* already covers this — "a helper the plan cites for what it decides is read before it is
built on" — and I applied it to the helpers I called and not to the elisp I was porting.

**Cost.** One review round: the cold read found it, and a fix commit plus a delta round followed.
About twenty-five minutes, and it would have been a silent wrong line typed into a live Cerebro if
the reviewer had not read the elisp.

**Prevent by.** Reading `implement-bead`'s *helper the plan cites* rule as covering **the source
being ported**, not only the symbols the new code calls: when a plan says "this is the port of X"
and gives X's reason for existing, open X's assignment sites before writing the increment's first
test — the docstring and the lines a plan cites are the half most likely to be the half that was
read. Concretely, for a port the failing test should exercise the arm the plan does *not* describe
(here: the read that fails), because the arm it does describe is the one both the plan and the
test were written from.

**Seen before.** cb-547 and cb-kcs.4.4 — both a plan claim about existing behaviour taken as read,
both costing a mid-build reduction or a deviation. This is the third, and the first where the
claim's own specified test concealed it rather than exposing it.
