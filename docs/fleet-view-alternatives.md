# Fleet view alternatives: ratatui, Textual, and staying on Emacs

Measured on 2026-08-31 on macOS 26.6.2 (25G83, arm64), with `cargo 1.98.0`, `rustc 1.98.0`,
`python3 3.14.7`, `GNU Emacs 30.2` and `GitHub Copilot CLI 1.0.82`, against the crate versions
`ratatui 0.30.2`, `crossterm 0.29.0`, `portable-pty 0.9.0`, `tui-term 0.3.4` and `vt100 0.16.2`
(the lockfile of the throwaway prototype; one `ratatui-core 0.1.2` resolved into the tree).

Four of the fleet view's own uses were built and run in a Rust prototype: hosting a live session,
focusing it and typing into it, sending a line into it unfocused, and killing it. Each was run
first against `vim` and then confirmed once against a real `copilot` session. Textual was **not**
measured — that was decided while planning (cb-qke, *User-facing decisions*, round one Q1) — and
every Textual claim below is sourced to PyPI and GitHub, fetched on 2026-08-31, and marked as such.

Anything that could not be measured says so and says why; nothing here is inferred from documentation.

Output is quoted verbatim from the prototype's own frame dumps, minus terminal escape sequences.
Where an excerpt stops short of a frame's closing border, or elides rows inside one, it says so or
marks the elision `...`.
The prototype lived at `.cerebro/scratch/cb-qke/rat/` and has been deleted; it is a measuring
instrument, not a deliverable, and every command below states what it was.

## Summary

| what the fleet view needs | ratatui (measured) | Textual (sourced, not measured) | Emacs today |
|---|---|---|---|
| Host a live agent CLI in a real pty, full-screen, in colour | **yes** (S1) — `portable-pty` + `vt100` + `tui-term::PseudoTerminal`; `copilot`'s own TUI drew correctly, 24-bit colour preserved | claimed by `textual-terminal`, whose last release predates the current `textual` by 3½ years | yes — vterm, `cerebro--make-session-buffer` (`cerebro.el:3492`) |
| Focus a session and type into it (`RET` then typing) | **yes** (S2) — but every key is a hand-written `KeyEvent`→bytes mapping, and its gaps are the migration cost | not established; nothing in the sourced material speaks to key translation | yes — vterm is the terminal; no mapping is written by hand |
| Send a line into an **unfocused** session (the triage nudge) | **yes** (S3) — both of `cerebro--type-into-session`'s spellings landed as a real Copilot message | not established; nothing in the sourced material speaks to it | yes — `cerebro--type-into-session` (`cerebro.el:3977`) |
| Kill the session and keep the screen as the record of the pass | **yes, the last screen** (S4) — the app owns the `vt100::Parser`, so the pane kept drawing with `child_alive=false`; scrollback was not measured | not established | yes — `vterm-kill-buffer-on-exit` bound to nil (`cerebro.el:3521`) |
| Startup for a navigator with no Emacs | one binary, no runtime | Python ≥3.9 plus a dependency tree | needs Emacs 28+ **and** libvterm |
| The five-second poll, sweeps, bead panel, two JSONL logs | ordinary Rust; nothing measured stands in the way | ordinary Python | exists, 6 267 lines, 497 ERT cases |
| Cost to move | ~342 pure tests port; 155 tests and all rendering do not — see *Cost of a migration* | same, plus a Python runtime to ship | zero |

Every row marked **yes** is an `S`-section below with the command and the output. Every Textual row
says "claimed" or "not established" and is sourced in *Textual, from its documentation*.

## S1 Hosting a live session

### Command

The prototype opens a pty with `portable-pty`'s `NativePtySystem`, spawns the child in it, feeds the
bytes into a `vt100::Parser` the **app** owns, and draws `tui_term::widget::PseudoTerminal` into the
right-hand pane of an ordinary `ratatui` layout. It was driven through a real pty by a throwaway
Python driver, so crossterm decoded real keystrokes rather than synthesised events:

```
python3 drive.py s1 /tmp/s1.log vim
BOOT=15 python3 drive.py s1 /tmp/c-s1.log \
  copilot --name Probe --allow-all -i "Reply with the single word ok and nothing else."
```

`d` dumps the frame the prototype last drew; `q` quits.

### Output

`vim`, in the prototype's session pane:

```
===== frame: d1 (child_alive=true, vt100 cursor=row 0 col 0)
┌fleet───────────────┐┌ session [list] ────────────────────────────────────────────────────────────┐
│Cyclops   working   ││█                                                                           │
│Xavier    idle      ││~                                                                           │
│Psylocke  idle      ││~                                                                           │
│                    ││~                                                                           │
│                    ││~                                                                           │
│                    ││~                                                                           │
│                    ││~                                                                           │
│                    ││~                                                                           │
│                    ││~                            VIM - Vi IMproved                              │
│                    ││~                                                                           │
│                    ││~                             version 9.1.1752                              │
│                    ││~                         by Bram Moolenaar et al.                          │
│                    ││~               Vim is open source and freely distributable                 │
│                    ││~                                                                           │
│                    ││~                      Become a registered Vim user!                        │
│                    ││~              type  :help register<Enter>   for information                │
│                    ││~                                                                           │
│                    ││~              type  :q<Enter>               to exit                        │
(cut at the pane's twentieth row; the frame continues to the closing border)
----- distinct fg/bg pairs in frame: Reset/Reset, Gray/Reset, Indexed(12)/Reset, Indexed(4)/Reset
```

The confirming run, hosting a real `copilot` session:

```
===== frame: d1 (child_alive=true, vt100 cursor=row 25 col 2)
┌fleet───────────────┐┌ session [list] ────────────────────────────────────────────────────────────┐
│Cyclops   working   ││  Current   Sessions   Issues   Pull requests   Gists                       │
│Xavier    idle      ││                                                                            │
│Psylocke  idle      ││  ╭─╮╭─╮                                                                    │
│                    ││  ╰─╯╰─╯  Copilot v1.0.82 uses AI.                                          │
│                    ││  █ ▘▝ █  Check for mistakes.                                               │
│                    ││   ▔▔▔▔                                                                     │
│                    ││                                                                            │
│                    ││ ● Tip: /model                                                              │
│                    ││   └ Select the AI model for this session (use 'auto' to let Copilot pick   │
│                    ││     automatically). Use /config model to set the user default,             │
│                    ││     '--repo'/'--local' to set the repo default, or 'plan'/'--plan' to set  │
│                    ││     the plan-mode model.                                                   │
│                    ││ ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  │
│                    ││  ❯ Reply with the single word ok and nothing else.                10:10    │
│                    ││ ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀  │
│                    ││ ● ok                                                                       │
│                    ││                                                                            │
```

(Both frames are cut where the excerpt ends; each continues to its closing border.)

The colour list for the Copilot frame, which is the answer to "are the colours right":

```
----- distinct fg/bg pairs in frame: Reset/Reset, Rgb(255, 255, 255)/Rgb(9, 105, 218),
Rgb(177, 186, 196)/Rgb(20, 27, 34), Rgb(48, 148, 255)/Reset, Rgb(145, 152, 161)/Reset,
Rgb(133, 52, 243)/Reset, Rgb(95, 237, 131)/Reset, Rgb(59, 120, 255)/Reset, Rgb(180, 180, 180)/Reset,
Rgb(20, 27, 34)/Reset, Reset/Rgb(20, 27, 34), Rgb(240, 246, 252)/Rgb(20, 27, 34),
Rgb(145, 152, 161)/Rgb(20, 27, 34), Rgb(68, 147, 248)/Reset, Rgb(129, 139, 152)/Reset
```

### Conclusion

**Yes.** A ratatui application hosts a live, full-screen agent CLI in a real pty and draws it as one
widget among others. `vim`'s indexed colours (`Indexed(12)`, `Indexed(4)`) and Copilot's 24-bit
colours (`Rgb(9, 105, 218)` — GitHub blue — and fifteen more) both survive `vt100`'s parse into
ratatui cells. Copilot's own alternate-screen TUI, its rounded box drawing and its half-block
composer border all render. The cursor is tracked by the parser (`vt100 cursor=row 25 col 2`); it is
reported to the frame, though drawing a *visible* cursor in the pane requires
`PseudoTerminal::cursor`, which this prototype did not exercise.

The whole of it is roughly 60 lines: `openpty`, `spawn_command`, a reader thread, and
`PseudoTerminal::new(parser.screen())`.

## S2 Focusing a session and typing into it

### Command

`Tab` gives the pane focus; while focused, every crossterm `KeyEvent` is translated to bytes by a
function in the prototype and written to the pty master. `Shift-Tab` takes focus back. Real bytes
were sent into the prototype's own terminal, so crossterm's decoder is part of what was measured.

```
python3 drive.py s2 /tmp/s2.log vim        # Tab, "ihello from S2", Esc, Shift-Tab, d, Tab,
                                           # Down, Ctrl-C, F1, Alt-x, Shift-Tab, d, q
BOOT=15 python3 drive.py s2 /tmp/c-s2.log copilot --name Probe --allow-all -i "..."
```

### Output

The prototype's event log, `vim` run:

```
[event] focused
[event] forwarded Char('i') as [105]
[event] forwarded Char('h') as [104]
...
[event] forwarded Esc as [27]
[event] forwarded Down as [27, 91, 66]
[event] forwarded Char('c') as [3]
[event] forwarded F(1) as [27, 79, 80]
[event] forwarded Char('x') as [27, 120]
[event] unfocused (BackTab)
```

The frame after typing, showing what `vim` received:

```
===== frame: d18 (child_alive=true, vt100 cursor=row 0 col 12)
┌fleet───────────────┐┌ session [list] ────────────────────────────────────────────────────────────┐
│Cyclops   working   ││hello from S2                                                               │
│Xavier    idle      ││~                                                                           │
│Psylocke  idle      ││~                                                                           │
```

`F1` then opened `vim`'s help in a later frame — an independent confirmation, seen in the running
prototype and not pasted here, that the escape
sequence arrived intact.

The confirming run, the same keystrokes into a live `copilot` composer:

```
│                    ││ ~/repos/.../rat [⎇ cb-qke-fleet-view-alternatives]  Session: 8.48 AIC used │
│                    ││╻▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄│
│                    ││┃ ihello from S2█                                                           │
│                    ││╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
│                    ││ @ files · # issues                                           GPT-5.6 Terra │
```

### Conclusion

**Yes, and this is where the real migration cost is.** Typing works, and the keys tried —
printable characters, `Esc`, arrows, `Ctrl-C`, `F1`, `Alt-x` — all reached both children correctly.
But every one of them works because a function in the prototype says so:

```rust
KeyCode::Char(c) if ctrl => vec![(c.to_ascii_uppercase() as u8).wrapping_sub(b'@')],
KeyCode::Enter           => vec![b'\r'],
KeyCode::Backspace       => vec![0x7f],
KeyCode::F(n) if (1..=4).contains(&n) => vec![0x1b, b'O', b'P' + (n - 1)],
```

That table is ~25 lines and it is **incomplete by construction**: `F(5)`–`F(12)`, keypad keys,
bracketed paste, and every modifier combination beyond a plain Ctrl or Alt fall through to a "no
mapping" branch. Backspace is the classic disagreement (`0x7f` versus `0x08`), and `Shift-Tab` is
spent on the prototype's own unfocus key, so the child can never receive it. In Emacs none of this
is written at all: vterm *is* a terminal emulator, and the navigator's keystrokes reach the child by
the same path they reach any other vterm buffer. **A migration inherits this table and every bug
report about it.**

## S3 Sending a line into an unfocused session

### Command

The fleet view's triage nudge is `cerebro--type-into-session` (`cerebro.el:3977`), which sends the
string and then the return **on a timer** (`cerebro-return-delay`). Both spellings were measured:
one write of `text + CR`, and text, a 400 ms pause, then CR. Focus was never given to the pane.

S3 is therefore the one demo that cost **two** confirming `copilot` runs rather than the one the
header describes: the two spellings are two different things to send, and one run cannot measure
both.

```
python3 drive.py s3  /tmp/s3-vim.log  vim         # one write
python3 drive.py s3d /tmp/s3d-vim.log vim         # text, 400ms, CR
python3 drive.py s3  /tmp/s3-bash.log  bash --norc --noprofile -i
python3 drive.py s3d /tmp/s3d-bash.log bash --norc --noprofile -i
BOOT=15 python3 drive.py s3  /tmp/c-s3.log  copilot --name Probe --allow-all -i "..."
BOOT=15 python3 drive.py s3d /tmp/c-s3d.log copilot --name Probe --allow-all -i "..."
```

### Output

`vim` receives the bytes as commands, not as a line — which is the correct result for a modal
editor and is quoted so the claim below is not mistaken for "every child treats it as a message".
Both spellings produced the same screen:

```
----- vt100 screen contents:
s is the nudge line.

~                                                                           
```

`bash`, one write (the delayed spelling produced a byte-identical screen):

```
[event] nudge sent: text and CR in one write
----- vt100 screen contents:

The default interactive shell is now zsh.
To update your account to use zsh, please run `chsh -s /bin/zsh`.
For more details, please visit https://support.apple.com/kb/HT208050.
bash-3.2$ This is the nudge line.
bash: This: command not found
bash-3.2$
-----
```

The confirming runs, into a live `copilot` session — in each case the log's `nudge sent` line and
rows elided from the frame it produced. One write:

```
[event] nudge sent: text and CR in one write
│                    ││  ❯ This is the nudge line.                                        10:11    │
│                    ││ ● I see th                                                                 │
...
│                    ││ ◎ Working · 21 B esc interrupt                               GPT-5.6 Terra │
```

Text, 400 ms, then CR:

```
[event] nudge sent: text, 400ms, then CR
│                    ││  ❯ This is the nudge line.                                        10:12    │
...
│                    ││ ● Working esc interrupt                                      GPT-5.6 Terra │
```

### Conclusion

**Yes, and the two spellings did not differ** — against `vim`, against `bash`, or against `copilot`.
Each child received the bytes and acted on them in its own terms: `vim` as commands, `bash` as a
command line, and `copilot` as a submitted message — the transcript shows it as a user turn
(`❯ This is the nudge line.`) with the model already answering.

That the two spellings agree is a result about *this* CLI on *this* day, and not a licence to delete
the delay: the delay in `cerebro.el` exists because some line editor, at some point, needed it, and
one measurement finding no difference against `copilot 1.0.82` does not retire it. What S3 establishes is that a ratatui view has the
mechanism — a `Box<dyn Write + Send>` from `master.take_writer()`, reachable from any key handler,
with no notion of focus involved.

## S4 Killing a session, and what is left

### Command

`x` kills the child. The reader thread sees EOF and clears `child_alive`. The question is whether
the pane still draws — Emacs keeps the buffer because `vterm-kill-buffer-on-exit` is bound to nil
(`cerebro.el:3521`), and that buffer is the record of the pass.

```
python3 drive.py s4 /tmp/s4.log vim
BOOT=15 python3 drive.py s4 /tmp/c-s4.log copilot --name Probe --allow-all -i "..."
```

### Output

`vim`, after the kill:

```
[event] killed the child

===== frame: d2 (child_alive=false, vt100 cursor=row 27 col 0)
┌fleet───────────────┐┌ session [list] ────────────────────────────────────────────────────────────┐
│Cyclops   dead      ││Vim: Caught deadly signal HUP                                               │
│Xavier    idle      ││Vim: Finished.                                                              │
│Psylocke  idle      ││                                                                            │
...
----- distinct fg/bg pairs in frame: Reset/Reset, Gray/Reset
```

The confirming run — a killed `copilot` session, still on screen:

```
===== frame: d2 (child_alive=false, vt100 cursor=row 25 col 2)
┌fleet───────────────┐┌ session [list] ────────────────────────────────────────────────────────────┐
│Cyclops   dead      ││  Current   Sessions   Issues   Pull requests   Gists                       │
│Xavier    idle      ││                                                                            │
│Psylocke  idle      ││  ╭─╮╭─╮                                                                    │
│                    ││  ╰─╯╰─╯  Copilot v1.0.82 uses AI.                                          │
│                    ││  █ ▘▝ █  Check for mistakes.                                               │
│                    ││   ▔▔▔▔                                                                     │
│                    ││                                                                            │
│                    ││ ● Tip: /skills                                                             │
│                    ││   └ Manage skills for enhanced capabilities                                │
│                    ││ ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  │
│                    ││  ❯ Reply with the single word ok and nothing else.                10:12    │
│                    ││ ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀  │
│                    ││ ● ok                                                                       │
│                    ││                                                                            │
...
```

### Conclusion

**Yes, and the reason is ownership rather than luck.** The `Arc<RwLock<vt100::Parser>>` belongs to
the app, not to the pty: the reader thread writes into it and dies at EOF, and the draw loop goes on
reading `parser.screen()` exactly as before. The left pane flips to `dead` from the same flag, so
"the session is gone but its screen is still here" is a state the view can render — which is what
the fleet view needs for `cerebro--recorded-buffer` (`cerebro.el:3389`).

Two limits, both real and neither measured away. The screen is the **last screen**, not the
scrollback: this prototype constructed its parser with a zero-line scrollback
(`vt100::Parser::new(rows, cols, 0)`), so nothing above the top row survives. Scrolling back through
a finished session was one of the three demos deliberately not chosen (cb-qke, round one Q4), and it
is the part of "the buffer as the record of a pass" that S4 does **not** cover. `vt100` takes a
scrollback size as that third argument, so the mechanism exists; how it behaves under a
thousand-line agent transcript is *estimated, not measured*.

## What would have to be rewritten

`emacs/cerebro.el` is 6 267 lines and 252 functions; `emacs/cerebro-test.el` is 8 529 lines and 497
ERT cases. The word `vterm` appears 65 times in the view, and the coupling is genuinely narrow —
these nine places, each verified to open at that line in this checkout:

| `emacs/cerebro.el` | what it does | demo |
|---|---|---|
| `cerebro--make-session-buffer` :3492 | creates the vterm buffer, process running, in no window | S1 |
| `cerebro--vterm-available-p` :3524 | vterm is a soft dependency | — |
| `cerebro--launch` :3532 | let-binds `vterm-shell` to the launch command | S1 |
| :3521 | `(setq-local vterm-kill-buffer-on-exit nil)` — why a buffer survives its process | S4 |
| `cerebro--recorded-buffer` :3389 | the buffer of a session whose process has exited | S4 |
| `cerebro--note-exit` :3795 | runs from vterm's sentinel | S4 |
| `cerebro--type-into-session` :3977 | `vterm-send-string`, then `vterm-send-return` on a timer | S3 |
| `cerebro--nudge` :3997 | the triage nudge | S3 |
| `cerebro--show-detail` :3463 | puts a session's buffer in the detail window | S2 |

**But vterm is not the size of the job, and reading only that table would badly under-estimate it.**
The root `CLAUDE.md` describes the file as a pure core plus a small set of impure readers, with the
tests exercising the pure half. Splitting the suite mechanically — a test counts as impure if its body names one of the documented
readers, or `cerebro--repo-root`, or one of a named list of Emacs runtime primitives. The rule is
the regexp below and nothing else, so the split is reproducible rather than judged:

```
$ awk '
  /^\(ert-deftest/ { if (n) { total++; if (body ~ RE) impure++ } n=1; body="" }
  n { body = body $0 "\n" }
  END { if (n) { total++; if (body ~ RE) impure++ }
        printf "total ert tests: %d\ntests touching an impure reader / emacs runtime: %d\ntests over pure functions only: %d\n", total, impure, total-impure }
' RE='cerebro--(fleet|roster|read-state-file|system-processes|owned|gather-sweeps|fleet-snapshot|repo-root)|with-temp-buffer|with-current-buffer|make-temp-|process-attributes|call-process|shell-command|find-file|insert-file|write-region|get-buffer|tabulated-list|window' emacs/cerebro-test.el
total ert tests: 497
tests touching an impure reader / emacs runtime: 155
tests over pure functions only: 342
```

The primitive list is a choice, and a different one moves the number: naming only the documented
readers gives 72 impure, and the split is worth reading as *most of the suite is plain data*, not as
a figure accurate to the case.

So **342 of the 497 cases are about plain data**: state derivation, the trigger predicates, the log
policy, the sweep findings, the launch command, the marker needle. Those are the functions a Rust
port would carry over as ordinary `#[test]`s over the same inputs, and the port would be a
transliteration with the shared case tables (`tests/lib/session-args.cases`) unchanged — which is
the strongest single argument that a migration is *possible*.

The other 155, and all the rendering, have no equivalent. Concretely, what has to be rebuilt rather
than ported: 94 references to Emacs windows, a `tabulated-list-mode` derivation used 25 times, 23
`propertize` calls, three `define-derived-mode`s, `with-current-buffer` 37 times, and the timer
machinery. And the test story changes shape: ERT runs *inside the editor that hosts the view*, so a
test can put a real buffer in a real window and assert on it. A ratatui port would use
`ratatui::backend::TestBackend` for the drawing — which is a good story, but a different one — and
the impure readers would need the same "run it for real, feed its output to the pure function"
contract cases the ERT suite already has, rewritten.

## Textual, from its documentation

**Not measured. Nothing was installed and nothing was run** — decided in planning (round one Q1),
and the reason is recorded there: a second prototype roughly doubles the bead for the route least
likely to be taken. What follows was fetched from PyPI and the GitHub API on 2026-08-31.

| package | latest | uploaded | releases | declares |
|---|---|---|---|---|
| `textual` | 8.2.8 | 2026-06-30 | 254 | `requires_python <4.0,>=3.9` |
| `textual-terminal` | 0.3.0 | **2023-01-29** | 4 | `textual (>=0.8.0)`, `pyte (>=0.8.1,<0.9.0)` |
| `pyte` | 0.8.2 | 2023-11-12 | 18 | `wcwidth` |

`https://api.github.com/repos/mitosch/textual-terminal` reports `pushed_at 2024-06-27`, 141 stars,
11 open issues, not archived.

**The finding, stated as what it is.** Textual ships no first-party terminal widget, so hosting a
session means the third-party `textual-terminal`. Its last of four releases predates the current
`textual` by three and a half years, its repository has had no push in over two years, and it pins
`textual>=0.8.0` with **no upper bound** — so `pip` would install it against `textual 8.2.8` and it
would be running against an API that has moved 254 releases since it was written. That is a
statement about maintenance and about what would install. It is **not** a measurement that it is
broken, and this document does not claim it is.

For contrast, the Rust stack was fetched the same day: `ratatui 0.30.2` (updated 2026-06-19,
47.3M downloads), `tui-term 0.3.4` (2026-04-07, 1.2M), `portable-pty 0.9.0` (2025-02-11, 13.4M),
`crossterm 0.29.0` (2025-04-05, 181.7M). `tui-term` re-exports `vt100` specifically so a consumer
cannot resolve two incompatible copies, and it tracks `ratatui` releases.

## The three compared

**Startup for a navigator with no Emacs.** ratatui wins outright: one binary, no runtime, no
`libvterm`. Emacs is the worst of the three here — the fleet view needs Emacs 28+ *and* a compiled
`emacs-libvterm`, which is a C build against `libvterm`, and `cerebro--vterm-available-p`
(`cerebro.el:3524`) exists because that install fails for people. Textual is in between: a Python
≥3.9 and a dependency tree, familiar to most navigators, plus an unmaintained widget.

**Distribution.** ratatui: `cargo build --release` produced a 1.2 MB binary here, from a clean
`target/` in **7.1 s wall** (85 crates, warm `~/.cargo`) — timed in the prototype, which has since
been deleted, so the figure is a recollection rather than a paste; the first ever build, including downloads,
was minutes and was not timed. Textual: a `pip install` into a virtualenv the consumer has to
manage. Emacs: nothing to distribute — the view is a file in the repository the navigator loads,
which is the single biggest reason it is cheap today.

**The five-second poll and the sweep timers.** Even. Emacs has `run-at-time`; Rust and Python both
have ordinary threads or an async runtime. Nothing measured here bears on it. One caution for a Rust
port: `cerebro.el`'s pure core is called every five seconds *and may not spawn a process*
(hence `cerebro--planner-want` duplicating `scripts/planner-buffer`); a Rust port inherits that
constraint unchanged, and with it the contract test that keeps the copy honest.

**The bead panel.** Even, and the least interesting part of the port: it is one `bd` call partitioned
into sections, which is a pure function over parsed JSON in any language.

**Per-session buffers as the record of a pass.** Emacs wins, and S4 is why the gap is narrower than
expected but real. A ratatui port gets the *last screen* for free (S4) and would have to choose a
scrollback size for `vt100::Parser`; Emacs gets a full buffer, searchable, with the navigator's
ordinary editing commands, `M-x occur`, and copy-paste — for free, because it is a buffer. Nothing
in a TUI replaces "it is an Emacs buffer, do what you like with it".

**The two JSONL logs.** Even, and slightly in Rust's favour: `cerebro--log-line` is a hand-written
JSON writer in elisp precisely because elisp could not source `scripts/jsonl-log.sh`; Rust would use
`serde_json` and Python `json`.

**CI.** Emacs is currently the cheapest: two `emacs --batch` jobs on ubuntu-latest, no toolchain
install. A Rust port adds a `cargo` toolchain and a build to every CI run — bounded, but the ERT half's install
today is one `purcell/setup-emacs` step per job (`.github/workflows/ci.yml:61`, `:80`) and no
build at all. Textual adds a Python setup step and
a `pip install` whose resolution includes an unmaintained package.

## Cost of a migration

**Rough size.** The port divides into three unequal parts:

1. **The pure core — 342 tests' worth of logic.** A transliteration. Large but low-risk, and the
   existing tests tell you when you are done. Call it the bulk of the line count and the smallest
   share of the risk.
2. **The impure readers and the rendering — 155 tests, 94 window references, the tabulated list, the
   detail window, the key map.** A rewrite, not a port. This is where the schedule goes.
3. **The terminal layer — S1 to S4, plus everything not chosen.** Measured at roughly 60 lines for
   the pty and the widget, plus a ~25-line key mapping that is *permanently incomplete* (S2), plus
   the three demos deliberately not measured: resize reaching the child, scrollback through a
   finished session, and several sessions at once with only one visible. All three are plausible —
   `MasterPty::resize` and `vt100::Parser`'s `screen_mut().set_size` exist and the prototype calls both on
   `Event::Resize` — but none of them is measured here.

**Incremental or a cutover: incremental for reading, a cutover for deciding.** This is the question
that decides affordability, and the answer has two halves.

Both views can read the same `.cerebro/state/*.state.json` files at once, safely and today. Nothing
in the state contract is exclusive: agents write their own files through `scripts/agent-state`, and a
reader polls them. A ratatui view could be built as a **read-only fleet display** and run beside
Emacs for as long as it takes, with no risk and no flag day. Everything in *The three compared*'s
poll, bead panel and log rows is reachable that way.

But the fleet view is not only a reader. It **starts sessions on triggers, ends them on `waiting`,
deletes state files when it ends a session, writes stop flags, and holds role-start spacing** — and
CLAUDE.md is explicit that `cerebro--end-session` is the one owner of that deletion, and that a
name with a live session is refused a launch. Two supervisors on one fleet would double-start
implementers on the same planned bead and delete each other's state files. So the **supervision half
is a cutover**: exactly one process may hold it, and the day it moves is a day both views cannot be
supervising.

That is a good shape — the risky half can be exercised for weeks before the irreversible half moves
— but it does mean a migration is not "run both for a while and let the better one win".

### Delivered: the read-only half exists (cb-vyp)

The first increment above is no longer hypothetical. `cerebro-tui` — a Rust/Ratatui binary in
`fleet-view/`, started by `.claude/cerebro/scripts/cerebro-tui` from anywhere inside a consumer —
draws the fleet rows and the six work queues from the same `scripts/roster`, `.cerebro/state/*.state.json`
and `bd --readonly` contracts the Emacs view reads, on its own five-second and thirty-second
cadences. It is stacked and scrollable, with scroll, refresh and quit keys and nothing else.

**The supervision half has not moved.** The Ratatui process starts no session, ends none, evaluates
no trigger, writes no stop flag, deletes no state file and changes no bead. `M-x cerebro` remains
the sole supervisor, and both views may read one repository at the same time — which is exactly
the property this section said made the read-only increment safe. Nothing below is revised by it:
the measurements and the recommendation stand as they were made.

## Recommendation

**Ranked, all three:**

1. **Stay on Emacs.** The ratatui route is buildable — S1, S2, S3 and S4 all came back yes, and the
   pty layer is 60 lines — but nothing measured here is something the current view does *badly*. The
   migration is 6 267 lines of elisp and 497 ERT cases, of which the 155 hardest are a rewrite rather
   than a port, and it ends with a hand-written key table (S2) and a chosen scrollback size (S4)
   where today there is a terminal emulator that already works. The one real cost it removes is
   "the navigator must have Emacs and libvterm", which has cost this project nothing so far.
2. **ratatui**, if that cost ever becomes real — a navigator who will not install Emacs, or a
   `libvterm` build that breaks. The stack is maintained, version-aligned today, and the four uses
   that matter are demonstrated rather than claimed. If it is ever taken, take it as *The three
   compared* suggests: a read-only view first, supervision last.
3. **Textual**, and not close. It would be the only one of the three whose terminal pane depends on
   an unmaintained third-party package, and it is the only one this document did not measure — which
   is itself a reason not to choose it.

**The trigger to revisit**, so this is a decision rather than a shrug: an Emacs or `libvterm` install
that actually blocks a navigator, or a second consumer repository whose people do not use Emacs.
Until then the evidence says the view is not the constraint.

## What could not be measured, and why

- **Textual was not measured at all.** Decided in planning (cb-qke, round one Q1): building a second
  prototype roughly doubles the bead for the route least likely to be taken. Its column in the
  summary table is sourced to PyPI and GitHub, marked *claimed* or *not established* throughout, and
  **no part of the recommendation rests on a Textual measurement** — the third place is argued from
  maintenance metadata and from the absence of evidence, which is stated rather than hidden.
- **Three of the fleet view's uses were not demonstrated** — window resize reaching the child,
  scrollback through a finished session, and several sessions at once with only one visible. All
  three were deliberately not chosen (round one Q4). The prototype does call `MasterPty::resize` and
  `screen_mut().set_size` on `Event::Resize`, but no measurement of what the child then does was
  taken, and none is claimed.
- **Scrollback past the last screen was not measured** (S4). The prototype ran with a zero-line
  scrollback, so what survives a kill is the final screen. `vt100::Parser::new` takes a scrollback
  size, so the mechanism exists; its behaviour and memory cost under a long agent transcript is
  *estimated, not measured*.
- **A visible cursor in the session pane was not measured** (S1). The parser tracks the cursor and
  the position was dumped every frame, but `PseudoTerminal::cursor` was never called, so "the cursor
  is in the right place *on screen*" is unproven; only "the parser knows where it is" was shown.
- **The first, cold `cargo build` was not timed.** Only a rebuild from a clean `target/` with a warm
  `~/.cargo` was (7.1 s, release, 85 crates). The download-and-compile-from-nothing figure quoted in
  the plan as "minutes" stands as an estimate.
- **The `copilot` runs used no `--agent`.** The fleet's own argv
  (`scripts/agent-cli --argv --role implementer --name Probe`) is `--agent implementer --name Probe
  --allow-all`, and the confirming runs dropped `--agent implementer` on purpose: a probe session
  loading the implementer role could have claimed a bead. What was measured is therefore a real
  `copilot` session started the way the fleet starts one **minus the role flag**, which changes what
  the agent does and nothing about the pty, the drawing or the keys.
- **Nothing was measured on Linux.** Every number here is macOS 26.6.2 on arm64. `portable-pty` and
  `crossterm` are cross-platform, but this document does not demonstrate it.
