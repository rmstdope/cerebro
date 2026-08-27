# cb-d59.6 — retrospective

- **Implementer:** Cyclops
- **Date:** 2026-08-27
- **PR:** #178

## A measurement recipe with no control pointed at the wrong fix

**What happened.** The plan's M6b probe was one run: a hook file reached by a relative symlink,
`"matcher":"bash"`, in a `mktemp -d` repository, with "a non-empty log is the answer" and a
specified code change (`scripts/sync-symlinks.sh` writes a real copy instead of a link) if it came
back empty. It came back empty. Two controls that the plan did not ask for — the same probe with a
real file, and again with no matcher — came back empty too, so the symlink was not what the run had
measured. The actual confound was `~/.copilot/config.json`'s `trustedFolders`: **Copilot does not
load a repository's hook file at all in a folder it has not been told to trust**, and says nothing
when it does not. With the probe directories added to that list, both the real file and the relative
symlink fire. Copilot follows the symlink; the plan's specified fix would have been the wrong change,
made confidently, on one green-looking run.

**Why.** Established. The user-level hook log at `~/.copilot/logs/hooks/` recorded the *global*
`axis-hooks.json` firing during every one of the failed runs, which is what proved the machinery was
live and only the repository's own file was unread.

**Cost.** Four premium Copilot requests spent on runs that measured nothing, plus two more to get a
real answer, and about twenty minutes. The larger cost was avoided rather than paid: a behaviour
change to the sync every consumer runs, justified by a confounded measurement.

**Prevent by.** A plan that specifies a measurement whose *negative* outcome triggers a code change
should specify the positive control alongside it — here, "the same probe with a real file at the
same path, which M6 measured firing". One run cannot distinguish "the variable under test is the
cause" from "the harness is not running", and a negative result is exactly where that matters. The
`implement-bead` traps list already says a wall of identical errors is infrastructure rather than a
defect; this is the same rule one level up, in a plan rather than in CI.

**Seen before.** `cb-d59.1` — *Probing an interactive TUI CLI needs a real pty* — is the previous
finding from probing this same CLI, and the same shape: the probe's own setup, not the thing being
probed, decided the result.

## The plan's throwaway consumer used a symlink mount, and it synced the real tree

**What happened.** M13's recipe builds a probe consumer with
`ln -s <this checkout> .claude/cerebro`, then runs `sync-symlinks.sh`. The sync reported paths
inside `/Users/henrikku/repos/cerebro/.cerebro/worktrees/cb-d59.6` — the *worktree*, not the probe.
`scripts/consumer-root` resolves the script directory physically and climbs `../../..`, so a symlink
mount lands it back in the cerebro checkout, which is itself a valid consumer (the self-mount). The
probe consumer got no `.github/agents/` at all, and the run wrote into the tree the bead was being
built in. Replacing the symlink with `cp -R` gave the shape the plan intended.

**Why.** Established, and already documented: `CLAUDE.md`'s *This repository is a consumer of
itself* gotcha describes exactly this round trip. The plan's recipe simply did not account for it.

**Cost.** One wasted probe cycle and a `git status` check to confirm the worktree was undamaged
(it was — the sync was idempotent against files already correct). Perhaps ten minutes.

**Prevent by.** Any plan step that fabricates a throwaway consumer should say **copy, not symlink**,
and name why — `tests/lib/consumer.sh`'s `consumer_new --copy` already takes that shape for the same
reason, and is the thing to point a plan at. A cheap check before trusting such a fixture:
`.claude/cerebro/scripts/consumer-root` from inside it must print the probe's own path.

**Seen before.** None found for this exact failure; `cb-akc` and `cb-rdv` are the nearest, both about
`consumer-root` and mounts rather than about a fabricated fixture.
