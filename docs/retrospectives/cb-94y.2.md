# cb-94y.2 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-10
- **PR:** #368

## A tab-separated contract cannot be read with `IFS=$'\t' read`, and its own header said it could

**What happened.** `scripts/agents-conf` (cb-94y.1) answers on one TAB-separated line whose middle
fields may be empty, and its header instructs every caller to consume it with one unconditional
`IFS=$'\t' read -r kind a b c d <<<"$(...)"`, saying "that single `read` always fills five
variables". It does not. TAB is IFS *whitespace*, so a run of tabs folds into a single delimiter:
`hit<TAB>Psylocke<TAB>claude<TAB><TAB>high` — a hit naming an effort and no model — arrives as four
fields with `high` sitting in the model's variable. `scripts/launch` followed the header and would
have started that session with `--model high`. The launcher now splits the line by hand, five
fields each possibly empty, and the header shows its old advice as `# WRONG`.

**Why.** Established. `read` splits on IFS, and for IFS characters that are whitespace (space, tab,
newline) a *sequence* of them is one delimiter and leading/trailing ones are stripped — the rule
that makes `read a b c` work on ragged spacing is the same rule that destroys an empty middle
field. A non-whitespace IFS (`:`, `,`) does not behave this way, which is why the idiom looks safe
to anyone who has only used it on `/etc/passwd`-shaped data.

**Cost.** About twenty minutes, and only because a review finding about a *different* thing (a
sentence that contradicted its own argv) sent me to write a case for exactly the shape that breaks.
Nothing had exercised an empty model beside a present effort: three of the four field combinations
pass under the folding read, and the fourth was the one nobody had a case for.

**Prevent by.** Two places, both done here: `scripts/agents-conf`'s header now marks the folding
`read` wrong and points at `scripts/launch`'s split, and `tests/launchers.sh` has a case for the
empty-model-with-effort shape. The general form is worth knowing before the next tab-separated
contract is written in this repository — **a TAB-separated line with optionally-empty fields cannot
be parsed with `read`, whatever IFS you set** — and a new one should either forbid empty middle
fields or carry the hand split in the first caller.

**Seen before.** None found. `docs/retrospectives/` has nothing on IFS field folding;
`cb-kcs.5.4.md`'s "collapsed" is about a UI section, not a parser.
