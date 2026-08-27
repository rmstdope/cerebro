# cb-d59.5 — retrospective

- **Implementer:** Storm
- **Date:** 2026-08-27
- **PR:** #177

## The plan's sync loop would have refused every launch on an older submodule

**What happened.** The plan specified the new hooks loop in `scripts/sync-symlinks.sh` as
`mkdir -p <dest>` then `sync_links <mount>/hooks/copilot …`, with no word about a mount that ships
no `hooks/copilot/`. `sync_links` refuses (exit 1) on a missing source directory — correctly, for
skills and agents. Three existing fixtures in `tests/sync-symlinks.sh` are exactly the older-mount
shape, and the suite died on the first of them. Since `launch-preflight` runs this script before
every single session, shipping it as written would have blocked every launch in every consumer whose
submodule predates the commit, until the bump.
**Why.** The plan reused `sync_links` for a source directory whose absence is an ordinary state
(an older mount) rather than a broken one, and did not say which of the two it is.
**Cost.** About five minutes: the fixtures failed immediately and the guard plus its test was three
lines. The cost avoided is the point, not the cost paid.
**Prevent by.** A plan that adds a new source directory under the mount to `sync-symlinks.sh`
should say, in its *Files to change* section, what a mount that does not ship it yet must do —
refuse or skip. Every consumer runs this script on a submodule older than the change at least once.
**Seen before.** None found — `grep -rl "older mount\|submodule bump" docs/retrospectives/` names
only unrelated files.
