# cb-hwpj — retrospective

## Saving main's copy of a file for a timing baseline reverted my uncommitted edit

**What happened.** I wanted to time the old `tests/fleet-retry.sh` beside my edited one, with my edit not yet committed. I ran `git checkout origin/main -- tests/fleet-retry.sh && cp … scratchpad/old.sh; git checkout HEAD -- tests/fleet-retry.sh`, meaning to restore my version afterwards. HEAD was still main, so both checkouts wrote main's copy over the working file and my edit was gone. I rebuilt it from the diff still in the session and committed at once.

**Why.** `git checkout <ref> -- <path>` overwrites the working copy without asking. "Restore with HEAD" only gives back committed work, and none of mine was committed yet.

**Cost.** About five minutes to rebuild and re-verify the edit. Had the diff not been in the session, the whole increment would have been lost.

**Prevent by.** To read another revision of a file, write it somewhere else and never touch the working copy: `git show origin/main:<path> > <scratch>/old`. Commit an increment before any baseline run. A line under `skills/produce-bead` *Workspace* (next to "Check `pwd` before every git command") would carry it.

**Seen before.** `cb-5yr.1.md` recovered with `git checkout HEAD -- <paths>` on purpose. That is the same command, used there to restore and here to destroy.
