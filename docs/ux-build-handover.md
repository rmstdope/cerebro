# The handover between the UX stage and the build-design stage

This is the contract cb-lz5 splits planning along: a **UX agent**, written for a designer, agrees
what a person will see; a **build-design agent**, written for a developer, turns that into a plan an
implementer can build. They run at different times and may be run by different people, so **nothing
survives between them except what is written on the bead**. This document is that written thing —
the shape `agents/ux.md` and `agents/build-design.md` are written against, and the one place it is
stated.

A project's roster carries **either the combined `planner` role or the two stage roles, never
both**. `scripts/plan-candidates`, `scripts/planner-buffer --count` and `skills/plan-bead` are what
the combined role goes on using, unchanged; everything below is the two-agent variant.

## The bead's `acceptance` field carries the agreed UX design

Written by the UX agent, read by the build-design agent, and **never edited by it**. Five headings,
in this order:

```markdown
## The agreed experience
## The states
## The words, exactly
## What was considered and rejected
## The mockup
```

`bd` is not ours and has four long-text fields, so there is no way to add one called *UX design*:
`bd show` prints the words `ACCEPTANCE CRITERIA` above this content whatever we write there. The
naming is a convention inside the field rather than a real field name, and the navigator chose that
cost knowingly over a tracked `docs/ux/<bead>.md` file, which can go out of step with its bead.

**A bead that nothing a person can see** — a script, a reader, a refactoring — still goes through
the UX stage, and the UX agent takes that route **itself, without asking anybody**: `None.` under
each of the five headings, with the reason under the first.

```markdown
## The agreed experience

None. This bead ships two shell readers and a document; nothing a person can look at changes.

## The states

None.
```

## The bead's `design` field carries the build design

Unchanged, and this trial does not change it: the eight `##` headings
`skills/plan-bead/SKILL.md` specifies, exactly where `skills/implement-bead` already reads them —
context, files and reuse, increments with their tests, test plan, user-facing decisions, out of
scope, validation, traps. The UX agent **never edits `design`**, and the build-design agent never
edits `acceptance`.

## How to write the field, and the trap

`bd update` has `--design-file` but **no `--acceptance-file`**, and no stdin form. So the UX design
is written to a file and passed as one argument:

```bash
bd update <id> --acceptance "$(cat /tmp/ux-<id>.md)"
```

**Quoted.** An unquoted expansion word-splits the document into hundreds of arguments.

And when reading a single bead back, `bd show --json` returns an **array**:

```bash
bd show <id> --json | jq -r '(if type=="array" then .[0] else . end) | .acceptance'
```

## `ux:agreed` is the stage label

| The bead carries | The stage it is at |
|---|---|
| neither `ux:agreed` nor `planned` | the UX stage |
| `ux:agreed`, not `planned` | the build-design stage |
| `planned`, whatever else | an implementer's |

The label is added by the UX agent and **stays on the bead for the rest of its life**: it is the
record that the experience was agreed, and losing it would make a delivered bead indistinguishable
from one that never had a designer. The counts and the fleet view's `UX agreed` section exclude
`planned` instead. Only a send-back removes it.

Both agents take the existing `planning:<name>` hold while they have a bead open — the same label,
the same spelling, read by the same readers — so both show under *Being planned*.

## A send-back is silent

The build-design agent that cannot build a plan from the agreed experience removes `ux:agreed`,
appends its finding to the bead's **`notes`** under a `## Sent back to the UX stage` heading, and
stops:

```bash
bd update <id> --remove-label ux:agreed \
  --append-notes "## Sent back to the UX stage

<what is missing, and what the designer has to decide>"
```

Nobody is flagged, no `human` label is added, and the bead returns to the UX agent's queue as an
ordinary candidate. `notes` and not `acceptance`, because `notes` is the only one of the two with an
append operation (there is no `--append-acceptance`), it is already this fleet's append-log, and it
keeps the developer's words out of the designer's own document.

## The two scripts

```
scripts/stage-candidates <ux|build-design>      the beads that agent may take, as a JSON array
scripts/stage-candidates --print-stage-label    ux:agreed, before any root is resolved

scripts/planner-buffer --ux-agreed              <a>, how much agreed, undesigned work is waiting
scripts/planner-buffer --ux-count               agreed=<a> want=<m>
```

`scripts/stage-candidates` is the one place the harness answers which beads an agent at a stage may
take, and the one place the shell spells `ux:agreed` — `planner-buffer` asks it rather than
repeating the literal. Neither filters by priority: which candidate, and in what order, is policy
the agents' own skills explain, exactly as with `scripts/plan-candidates`.

`<m>` is the existing wanted number, `planner-buffer --want`, shared with `--count`: the
build-design agent's own buffer is the `planned` count, so `--count` already serves it.

## What is not decided here

The two agents' own words — how each introduces itself, how it interviews the navigator, and how a
send-back reads to a designer — are cb-lz5.2's and cb-lz5.3's, together with the roster rows that
switch the trial on. Nothing here creates a role: `scripts/launch-preflight` refuses a launch of a
role whose `agents/<role>.md` is missing.
