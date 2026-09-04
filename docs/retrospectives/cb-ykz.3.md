# cb-ykz.3 — retrospective

- **Implementer:** Storm
- **Date:** 2026-09-04
- **PR:** #332

## An edit that never landed, reported to the reviewer as done

**What happened.** Two elisp edits — a comment rewrite and a re-indent — were made by a `python3
<<'PY' ... PY` heredoc whose `assert old in s` failed because the string had moved under an earlier
edit. The script printed a traceback and exited non-zero, but it was the first of three commands in
one `Bash` call, the last being `bash tests/gate 2>&1 | tail -3`: the traceback scrolled past, the
gate was genuinely green (the edits were cosmetic), and the whole call reported `gate: green`. The
answer posted on the PR said both languages were fixed. The next delta round read the file and
found the Rust half done and the elisp half untouched, word for word as the finding had quoted it.

**Why.** Established. `cmd_a; cmd_b | tail -3` discards `cmd_a`'s failure twice over — `;` does not
stop on non-zero, and the pipeline's `tail` is what the caller reads. Nothing in the run then
distinguishes "two files edited" from "one file edited and a script that died".

**Cost.** One extra delta round, about two minutes of agent time, and a posted answer that was
false — which is the part that matters, since the Four Eye Principle is a chain of claims the next
round checks.

**Prevent by.** A script that edits a file is a step whose exit status is the answer, so run it in
its own `Bash` call, or as `python3 ... && bash tests/gate`, never as the first of a `;` list ending
in a pipe to `tail`. And when an answer claims a change in two languages, `git show --stat` the
commit before posting it: the claim is cheap to check and expensive to get wrong.

**Seen before.** cb-2e9 — same shape, other direction: `bash tests/gate 2>&1 | tail -N && git
commit && git push` pushed a head whose gate had printed `gate: RED`, because `tail`'s status is
what `&&` reads. That retrospective's *Prevent by* names the pipeline; this is the second sighting,
so the rule is worth stating as its own line rather than as an aside: **never put a step whose
status you rely on into a `;` list or on the left of a pipe.**
