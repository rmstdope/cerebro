# Retrospectives

One file per bead, `<bead id>.md`, written by the implementer that built it — but only when
something went unexpectedly. A bead that went to plan leaves no file, so everything in here is
something that cost somebody time.

Each file is one retrospective and is never edited afterwards: it is the record of a run that is
over. A later bead that hits the same thing writes its own file and names this one under
**Seen before**, which is how a recurring problem becomes visible as a count rather than a feeling.

## Format

    # <bead id> — retrospective

    - **Implementer:** <name>
    - **Date:** <YYYY-MM-DD>
    - **PR:** #<n>

    ## <one line: the symptom, not the cause>

    **What happened.** What you observed, concretely, with the command or step that produced it.
    **Why.** The cause if you established one; "not established" if you did not. Do not guess.
    **Cost.** What it took: wall-clock, CI cycles, a bead handed back, a rebase.
    **Prevent by.** The specific change that would stop it — a file and section, a step to add, a
    check to run earlier. "Be careful" is not a prevention.
    **Seen before.** Other bead ids whose file describes the same thing, or "none found".

Two findings in one run are two `##` sections in that bead's one file.
