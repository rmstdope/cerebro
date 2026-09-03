# cb-gln — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-09-03
- **PR:** #295

## A Rust port-bind test failed in CI on a prose-only diff

**What happened.** `probe::tests::free_endpoint_answers_a_bindable_loopback_address` failed the
`Rust tests` job with `Os { code: 98, kind: AddrInUse }` at `fleet-view/src/probe.rs:250` — "the
address a probe just released is bindable". The diff on that head was five Markdown files and
nothing else; no Rust source, test or `Cargo.lock` was touched. It passed locally twice and passed
on a bare re-run of the same head.
**Why.** The test releases a probe's port and immediately re-binds it, which races anything else on
the runner that grabs the freed port in that window. Not established beyond that — I did not
instrument the runner.
**Cost.** One CI cycle plus two local runs, about eight minutes, and one of the bead's two bare
re-runs.
**Prevent by.** The test asserts bindability of a *just-released* address, which is only true when
nothing else is competing. `fleet-view/src/probe.rs:250` would be sound as a retry (bind, and on
`AddrInUse` ask for another free endpoint and try again) rather than a single-shot assertion. That
is a change to `fleet-view/`, outside this bead, so it is recorded here rather than made.
**Seen before.** None found — `grep -rl 'AddrInUse' docs/retrospectives/` was empty.

## A plan's own validation check contradicted the prose it quoted

**What happened.** cb-gln's *Validation* listed `grep -c 'what would fixing it cost'
skills/plan-bead/SKILL.md` expecting `1`, but the replacement paragraph the same plan quoted wraps
that phrase across two lines ("…after it shipped, what\nwould fixing it cost?*"). Shipping the
quoted paragraph verbatim gave `0`, which reads as a failed edit rather than as a wrapping
artefact. I re-wrapped one word earlier so the phrase sits on one line, changing no words, and said
so in the PR body.
**Why.** A plan that quotes hard-wrapped replacement prose *and* greps a phrase inside it has two
representations of one sentence, and the line break in one is invisible from the other.
**Cost.** About five minutes, and a moment's doubt about whether increment 1 had landed.
**Prevent by.** `skills/plan-bead/SKILL.md`, *Validation* — a check over prose the same plan quotes
should either grep a phrase that fits inside one wrapped line, or use `tr -d '\n'` / `grep -z`. An
implementer meeting the mismatch re-wraps rather than re-words, and records the deviation.
**Seen before.** `docs/retrospectives/cb-5qk.md` mentions a validation `grep`, but for a different
cause.
