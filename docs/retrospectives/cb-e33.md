# cb-e33 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-24
- **PR:** #133

## Dropping `shell: bash` from a step silently drops `-o pipefail`, not only the `set` lines

**What happened.** The plan's *Known traps* stated that GitHub runs `run:` steps under
`bash --noprofile --norc -e -o pipefail {0}`, and instructed dropping `shell: bash` from the
`decide` step on the grounds that "the default is already `bash -e`" and "the interpreter line
GitHub uses already carries `-e` and `-o pipefail`". Both cannot be true, and the second is the
false one. This PR's own run measured it: the `decide` step, with no `shell:` key, logged
`shell: /usr/bin/bash -e {0}`, while the two steps that do carry `shell: bash` logged
`shell: /usr/bin/bash --noprofile --norc -e -o pipefail {0}`.

**Why.** Established. GitHub's *default* shell for a Linux `run:` step is `bash -e {0}`; the
`--noprofile --norc -eo pipefail` form is what the explicit `shell: bash` keyword selects. The plan
quoted the explicit form while removing the keyword that produces it.

**Cost.** None to this bead beyond the check itself — a few minutes reading one job log. The
designed safety property survives for a reason the plan did not name: `scripts/ci-needed` is the
**last** command in `printf … | bash scripts/ci-needed >> "$GITHUB_OUTPUT"`, so plain `-e`
propagates its status whether or not `pipefail` is set. Had the pipeline gained a command after the
predicate — a `tee`, a `sort`, a `grep` — a crashed predicate would have been swallowed and the
whole point of this bead lost, silently, with no test able to see it.

**Prevent by.** Two things, one of which is in this PR. (1) The `decide` step now carries a comment
naming the real reason its status is safe, and saying not to append to the pipe — that is the fact a
future editor needs at the point of editing. (2) A plan that removes a `shell:` key should say
which interpreter line the step ends up on, rather than quoting the one it had; the measurement is
one `grep -a 'shell: '` over any job log of the workflow, and it settles the question in seconds.

**Seen before.** None found — `grep -rl pipefail docs/retrospectives/` matched nothing.
