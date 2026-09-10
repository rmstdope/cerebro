# cb-94y.1 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-10
- **PR:** #367

## `tests/model-for.sh`'s failure message cannot run on the machine it was written for

**What happened.** This suite was modelled on `tests/model-for.sh`, as the plan asked, and its
assertion helper was copied verbatim — including
`fail "... expected '$(printf '%s' "$want" | cat -A)' ..."`. The first failing assertion printed
`cat: illegal option -- A` twice and then a message showing two empty strings, hiding the actual
mismatch. BSD `cat` has no `-A`; GNU's does, so the line works in CI and not on the navigator's
macOS machine. `tests/model-for.sh:79` still carries it: it is invisible until that suite fails,
and on the one machine where a red suite is read first it will fail while failing.

**Why.** A failure-path expression is only ever executed on the day something else is already
wrong, so nothing exercises it. `-A` is a GNU extension, and the suite it came from has been green
since it was written.

**Cost.** Two minutes here, because the surrounding case made the mismatch obvious anyway. The cost
is latent rather than paid: it lands on whoever next sees `tests/model-for.sh` go red locally, at
the moment they least want a second puzzle.

**Prevent by.** `printf '%q'` in place of `cat -A` wherever a suite renders a value into a failure
message — it is a builtin, it makes tabs and carriage returns visible as `\t` and `\r`, and it
cannot fail. This suite uses it. `tests/model-for.sh` is not this bead's file to change, and
`scripts/model-for` is retired by `cb-94y.2`, whose implementer will have the whole file open.

**Seen before.** None found — no retrospective here mentions `cat -A`.

## A narrowed-PATH case cannot scrub the root hints, because `consumer-root --shared` needs git

**What happened.** The plan's increment 7 asked for the narrowed-PATH shape from
`tests/launchers.sh` — a PATH of `dirname` and `bash` alone — with the suite's usual scrubbing of
`CEREBRO_CONSUMER_ROOT`, `CEREBRO_CONSUMER_SHARED_ROOT` and `CEREBRO_CONSUMER_MOUNT`. The two
together cannot both hold: with the hints scrubbed the script falls back to
`consumer-root --shared`, whose shared-root step is a `git` call, so under that PATH it answers
nothing and the case reads `miss<TAB>no-file` rather than the hit it asserts.

**Why.** Established. `consumer-root`'s validated `../../..` climb needs no git, but `--shared`
does, and only the *enclosing* root has a git-free path. The field never hits this because
`scripts/launch` resolves the hints once with a whole PATH and exports them; every reader below it
prefers the hint.

**Cost.** About five minutes — one red case and one look at `consumer-root`.

**Prevent by.** A plan that asks for both the narrowed PATH and scrubbed hints in one case is
asking for two different fixtures. The case here passes the hints and keeps the PATH narrow, which
is the field's own shape and still pins the thing the case exists for (no external command inside
the script under test). Worth saying in a plan that names `--shared`: under a narrowed PATH, the
hint is not optional.

**Seen before.** None found.
