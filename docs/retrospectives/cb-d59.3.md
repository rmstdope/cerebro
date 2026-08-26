# cb-d59.3 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #175

## Four liveness fixtures passed on macOS and matched no process at all in CI

**What happened.** `bash tests/gate` was green here three times. The same commit failed both ERT
jobs in CI on the four cases that start a real process and read its command line back
(`cerebro-test/session-alive-p-accepts-the-agents-own-process` and three siblings), every one with
`:value nil` — the rule found neither needle in a process whose command line plainly carried the
marker.

**Why.** Established. `process-attributes` is a *display* spelling of the command line, and the two
platforms disagree about one character: on GNU/Linux Emacs escape-quotes the whitespace **inside a
single argv entry**, so a marker sentence that is one argument reads `This\ session\ is\ …` there
and `This session is …` on macOS, where the same value comes back through `ps` unescaped. Every
needle the rule had ever used until this bead sat inside one *word* — `--name Rogue` is two argv
entries joined by a plain space, and a `--settings` path has no spaces in it — so no needle had ever
spanned a space and the divergence had never been reachable. The fix is
`cerebro--marker-needle`, which matches each space as an optional backslash-and-space.

**Cost.** Two CI cycles and about 40 minutes, one of them spent on a wrong first diagnosis (bash's
exec optimisation dropping the fixtures' arguments), which shipped as a commit of its own.

**Prevent by.** `CLAUDE.md`'s *emacs/cerebro.el* section already says a display spelling is
normalised by the reader that produces it and never assumed canonical by a comparator — it names
abbreviated paths and formatted times. **Whitespace escaping belongs on that list**, and the general
rule behind all three is worth stating: a comparator that spans a space in a value read from
`process-attributes` is platform-dependent, and the ERT reader-contract case for it proves only the
platform it ran on. A needle that spans a space should be built by a helper that tolerates both
spellings, the way this one now is. There is no local check that would have caught it: the
navigator's machine cannot produce the Linux spelling at all.

**Seen before.** `docs/retrospectives/cb-5yr.1.md` (*Every ERT case for the root rule fed it a root
the real producer never returns*) and `docs/retrospectives/cb-5yr.2.md` (*A test passed on Emacs
30.2 locally and failed in CI on 28.2*) are the same family — a comparator in this file, trusted
against a value only one environment produces. This is that family's third sighting.
