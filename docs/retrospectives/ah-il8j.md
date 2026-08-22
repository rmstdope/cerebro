# ah-il8j — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-22
- **PR:** #92

## The full shell suite does not fit in one agent tool call

**What happened.** `for t in tests/*.sh; do bash "$t"; done` from this repository's root, which
`CLAUDE.md` gives as the way to run all of them, was killed at the harness's ten-minute ceiling with
15 of 21 suites reported. The remaining six had to be run in two further batches, split by hand from
`ls tests/*.sh`. The same 21 suites finish in **48 seconds** in CI (`Bash suites (ubuntu-latest)`).

**Why.** Not established which suite dominates — I have no per-suite timings, only the aggregate. The
suites that fabricate consumers do `git init`, `cp -R` and `git fetch` against local remotes, and
macOS filesystem and process-spawn costs are the obvious suspects; I did not measure, so this is not
a claim.

**Cost.** About twenty minutes of wall clock, two killed tool calls, and one manual reconstruction of
which suites had not yet run. No CI cycles, and no effect on the change itself.

**Prevent by.** `CLAUDE.md`'s *Commands* section presents the `for t in tests/*.sh` loop as a single
thing to run; it should say that on macOS it takes upwards of fifteen minutes and that an agent
should run it in batches of three or four suites, each in its own call with an explicit timeout. A
per-suite timing line (`time bash "$t"`) in that loop would also let the next reader name the slow
one instead of guessing as I did.

**Seen before.** none found — this is the first file in this directory.

## The defect could not be reproduced by hand, because bd found the right database anyway

**What happened.** Validation item 4 asks for a by-hand check that the script answers the same from an
agent worktree as from the main checkout. I built a consumer worktree with its submodule initialised
and ran the **unfixed** script from it: it returned the same 303 beads as the main checkout. The
fixed script returns 303 too. The reported wrong-database answer never appeared.

**Why.** A consumer worktree carries no `.beads/` of its own — it is git-ignored, so it exists only in
the main checkout — and `bd` resolves its database by walking up and across to the shared checkout.
In this layout the rootless call lands on the right database by accident rather than by contract.
The defect is real but **latent**: it is a missing guarantee, not a currently-visible wrong count.

**Cost.** About ten minutes, spent building a consumer worktree to reproduce something that does not
reproduce. Nothing else; the change and its regression test are unaffected, since the test asserts on
the recorded `argv` rather than on the answer.

**Prevent by.** A plan whose validation asks for a by-hand reproduction should say what a *failure*
would look like and whether the author has seen one. Here, the honest instruction is: "the wrong
answer is not expected to appear in a worktree of this consumer — `bd` resolves to the shared
database anyway; check that `-C` is passed, not that the count differs." As written, item 4 reads as
though a difference should be visible, and an implementer who finds none has no way to tell a latent
defect from a fix that does nothing.

**Seen before.** none found.
