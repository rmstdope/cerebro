# cb-kcs.4.4 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-02
- **PR:** #278

## The plan named a file untouched and asked for an event only that file can observe

**What happened.** The plan's *Files to change* said `session.rs` was untouched, and its `main.rs`
section asked for an `exit` line "written only for an ending this view did not cause", using
`classify_exit` as the test. Both sentences cannot hold: the reap and the classification happen
inside `SessionHost::sync` (`fleet-view/src/session.rs`), nothing outside it sees an `Ended`, and
`App::set_exits`/`exits()` deliberately forget a clean ending — so from `main.rs` there is no way to
tell "a child exited with status 0 on its own" from "no child exited". Resolving it mid-build meant
taking a design decision the plan had already decided the other way: `SessionHost` gained a
`take_reaped()` drain queue and `main::log_exits` writes the line, so `session.rs` still writes no
file and still knows nothing about a log.

**Why.** The plan was written against four sibling beads that had not merged yet, so its
file-by-file section was reasoning about seams it could not open. The `exit` requirement and the
"untouched" list were written in different sections and never checked against each other.

**Cost.** About fifteen minutes of reading `session.rs`, `lifecycle::classify_exit` and
`App::set_exits` to establish that the two sentences were genuinely incompatible rather than my
misreading — plus a paragraph in the PR body declaring the deviation, and a reviewer round spent
confirming it.

**Prevent by.** When `plan-bead` writes a *Files to change* section that marks a file **untouched**,
the increment that needs a fact only that file produces should say where the fact crosses the
boundary. Concretely: a plan naming an event whose discriminator is a private value of another
module should name the seam it expects (a return value, a drain, a parameter), or not call that
module untouched. Two lines in the plan; the alternative is that every implementer of such a bead
re-derives the same answer and declares the same deviation.

**Seen before.** None found — `grep -rn untouched docs/retrospectives/` turns up only cb-ypx, about
something unrelated.
