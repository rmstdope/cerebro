# cb-drjb

## A producer was launched with no bead in its prompt while one was claimed for it

**What happened.** Storm's launch prompt carried the marker sentence and "follow your agent
definition", but no bead id. `produce-bead` step 1 says a prompt with no bead runs `end-pass` and
stops. But `bd` showed cb-drjb `in_progress` with assignee Storm, and `.cerebro/worktrees/cb-drjb`
held an earlier session's uncommitted, working implementation and no state file. Storm judged the
claim to be the fleet's intent and produced the bead, against the rule's letter.

**Why.** Not established. Either the launch dropped the `--bead` line from the prompt, or a
relaunch after the first session died (the state file was absent and the work uncommitted) did not
pass the bead again.

**Cost.** One judgement call made against a written rule, and ~2 minutes spent checking the board
and worktree. Ending the pass as written would have thrown away a prepared tree with nearly
finished work, and might have looped if the relaunch repeated the omission.

**Prevent by.** `scripts/launch` (or the fleet view's relaunch of a producer row): when the session
name holds an `in_progress` claim, pass `--bead <id>` into the prompt. Or have `produce-bead`
step 1 say what to do when the prompt names no bead but `bd list --assignee <name> --status
in_progress` returns exactly one.

**Seen before.** No.
