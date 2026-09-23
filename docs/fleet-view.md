# The fleet view — `cerebro-tui`

*This is the operating description of the fleet view, moved out of the root `CLAUDE.md` on
2026-09-14 so that file could stay a guide to developing cerebro. It is the record of what each
bead added to the view and why; the module map and the rules a change must keep are in
`CLAUDE.md` under `fleet-view/`. Bead ids are the pointer into `bd show` for the full decision.*

`.claude/cerebro/scripts/cerebro-tui` opens `cerebro-tui`, a Rust/Ratatui program that draws the
the fleet and the work queues - seven of them since cb-lz5.1, which
added a `UX agreed {n}` section between `Being planned` and `Unplanned` for beads carrying the
`ux:agreed` stage label, hidden entirely when empty, and which starts the two cb-lz5 roles `ux`
and `build-design` off queues of their own; the combined `planner` role reads the union of the
two buckets and is unaffected. **Since cb-kcs.1 what it may do at all is
a consequence of what the project declares rather than of what the program can do.** Since cb-kcs.3 it acts unattended on
the sessions it hosts where a project declares it the supervisor: it ends one whose pass is over
after `END_GRACE_SECONDS`, retires one under a stop flag and clears the flag with it, deletes the
state file of every session it ends, and types one line into a session that has gone quiet mid-work
(`stuck_for`, and the resume beside it). **Never into one that is waiting for an answer**: since
cb-0q1 a question waits until it is answered, so no elapsed time acts on an `asking` row for either
kind and whatever the flag — the two answer timeouts, `Supervision::Nudge` and both nudge messages
are gone, and `tests/lib/supervise.cases` keeps its twelve `asking` rows answering `none` so the
table asserts that promise rather than merely not contradicting it. `scripts/fleet-health` drops an
`asking` interval from `$running` and `model::history_line` answers `None` for one, so neither
self-report counts a waiting session as the fleet running slowly. A stop flag on an idle session
still retires it — that is the flag's arm, and the navigator's hand is what still ends a waiting
one.
Since cb-kcs.4.1 it also **starts** sessions on its own: the roster's `autostart`/`standby`
declaration is honoured as the view comes up, and the board-backed triggers for the planner,
implementer, verifier and orchestrator roles bring a blue `standby` row back — held back by a
per-role wake floor, the unchanged-work fingerprint, role-start spacing and, since
cb-10d.1 for builders and cb-10d.2.2 for the planning roles, a bead: a start is made only with a bead
no row, handed record or give-back holds, and the session is handed that bead: its row reads a blue `starting <id>` until its session reports, and a start that
goes away unreported gives the bead back with a gold line in the header. A bead handed inside one tick is taken out of the rest of that tick — the fleet read that would
show the first start up is five seconds away. Every successful
launch arms, whoever asked for it — `s`, an autostart and a trigger alike — and a retire, a `k`
(at every row state, not only standby), a give-up and a tick on which somebody else has or is
taking the checkout all disarm; a pass that merely ends does not, which is the whole point of the
set (cb-op0), and neither does a tick on which this view could not tell who supervises — a
declaration it could not read is an outage, not a handover (cb-nc8).
`docs/ui/cb-op0-arming.html` §6 is where that whole rule is written down, for both views. Since
cb-kcs.4.2 a start that keeps failing backs off on `0/30s/2m/10m` — the row counts the wait down
in place of its condition — and is abandoned after five consecutive starts
that produced no pass, which disarms the name and leaves `s` as the only way back; a launcher
refusal is parked from the first failure, where a silent crash is retried. Since cb-kcs.4.3 the
three roles whose work arrives from outside the fleet start too, off a `gh` reader on its own
cadence and an hourly floor each. Since cb-kcs.4.4 all of it is written down, in the same three
append-only files under `.cerebro/state/`: `decisions.jsonl` — a line per start (with the trigger that
fired), end, retire, resume, stuck, arm, disarm, exit and give-up, and since cb-xhu.2 nothing else, which is why it
keeps months; `evaluations.jsonl` — at the verbosity this view compiles in, a
line per trigger evaluation per armed row per tick carrying what the trigger read and which guard
held it; and `errors.jsonl`, one line per outage rather than per failed read, naming the pane or
the name it came from. One policy rotates all three; the writer is silent and unable to fail; and a
read-only view writes none of them, since it decides nothing.

Since cb-hjf every Fleet row carries the agent's **role** at every width, in the roster's own word
and faded against the name beside it. The column is paid for out of `AGENT_FLOOR`'s and
`STATE_FLOOR`'s unused cells and never out of the work cell, cut with a trailing `…` when the word
does not fit, and given up whole below `ui::ROLE_MIN` — a pane too narrow for it draws exactly the
row it drew before, with nothing else shortened. `ui::default_left_column` is the one place the
left column's starting width lives: `LEFT_COLUMN` (40), or `WIDE_LEFT_COLUMN` (52) on a window at
least `WIDE_LEFT_COLUMN_SCREEN` (134) wide, which is 52 plus two borders plus the eighty columns
agents print to. It picks the *starting* width alone — a width the navigator dragged or keyed is
theirs and survives every resize, and `Shift-Home` hands it back to this rule, saying what it has
always said (`panes back to their default sizes`, with no number); the double-click reset, which
does name a number, now names the one the reset actually produces. Like cb-bch.1's chords and
cb-xhu.4.2's health section, it has no `tests/lib/` table: one view, one implementation.

Since cb-ykz.2 its Fleet rows carry a **stuck** signal, off
`lifecycle::stuck_for` and a 1800-second ceiling: a red `✗` glyph, and `stuck 8h49`
in red. Which cell carries the text is the one divergence, and it is the pane's own shape: in the
wide layout it replaces the FOR column's elapsed pair, and **below `WIDE_COLUMNS` — which is the
ordinary split layout, where the Fleet pane is 40 cells — or 52 on a window at least 134 wide
(cb-hjf) — unless the navigator has widened it
(cb-bch.1) — the BEAD cell carries it**
instead, standing aside as it already does for a standby label and a dead row's verdict, with
`columns` sizing that column from the same `bead_cell` so the text is never cut. The STATE cell is
untouched in both. One `stuck` line per occurrence goes into `decisions.jsonl`, gated on
supervision like the resume beside it. Since cb-ykz.3 it also **acts**, off the same rule and the same
memory it keeps: one `resume` line typed into the session, then — if it is stuck again
with its `(since, phase_since)` pair unmoved — the interactive role's session ended, or retired
under a stop flag, and an implementer's left for the navigator's `k`, after which the view releases what it held. A stuck row this view hosts
therefore writes two lines per occurrence, `stuck` and `resume`: the observation and what was done
about it.

Since cb-kcs.5.1 it runs **the four sweeps** as well, on their own ten-minute cadence and their own
in-flight slot, and draws what they found as the Work pane's **first** section — `Sweeps {n}`, one
truncated line per finding, a gold line for a stranded P0, and the failed script named beside the
header in red when one did not answer (`sweep-epics failed`), because one of the four `git fetch`es
and a stale section that reads like a current one is what silence costs. The chain
stops at the first script that did not answer, which is what lets the header name exactly one. Under
Work the arrow and page keys move a **cursor over the findings** while there are any and scroll the
pane when there are none (widened to bead rows by cb-kcs.5.4, below) — and `x`, from any focus, shows the exact `bd` and runs
it only on `y`, followed by `bd dolt push` on the same keystroke — since cb-21g both of those run
on the **write worker** rather than on the drawing thread, so the keystroke returns at once and the
header's sentence arrives when the write answers. That was **the one write in this
crate that does not pass `--readonly`** until cb-kcs.5.4 added the priority keys beside it; it lives
in `lifecycle::run_finding` beside every other
write and spawns through `readers::CommandRunner` like every other command
(cb-i1w), and it is deliberately **outside the lease**: the board is shared, so a view that may start
nothing may still close a delivered bead. `tests/lib/sweep-findings.json` is the table both
implementations answer — every finding, every label and every command — for `supervise.cases`'
reason: both views go on sweeping after the cutover, so one decision has two implementations in two
languages. The header now renders **whichever** `Prompt` is up, through the enum's own `text`
(cb-4cn): matching one variant by name is how cb-kcs.4.1's disarm confirmation came to be built and
never drawn.

Since cb-kcs.5.2 it runs the supervisor's last two unattended jobs as well. Since cb-10d.4 there is no
watcher: a take-back the board refuses says `Could not take <id> back from <Name>: the task list did not
answer.` and a tree removal that fails says `Could not remove <Name>'s copy for <id>: <cause>`, each red
in the notice slot, once and then every ten minutes while the same one stays broken (`App::complain`). And it types the triage line into an
idle orchestrator this view hosts when unranked beads are waiting for a ranking — the same bytes
Cerebro already reads — saying `Cerebro was asked to rank 3 unranked beads.` in gold beside the
resume's own line, and repeating the same set every ten minutes while Cerebro stays idle. The line
is typed, recorded and throttled **only when it went into a session this view hosts**, which is a
deliberate divergence from `cerebro--triage-tell`: that one records and logs even when no buffer
took the string, so its throttle then holds for a line that never left the building.
`tests/lib/triage.cases` is the table both implementations answer, for `supervise.cases`' reason —
both views go on triaging until the declaration moves.

Since cb-7nx a **second** line goes into an idle orchestrator on the same mechanism: every two hours
(`cerebro-sweep-interval` / `SWEEP_INTERVAL_SECONDS`, both 7200) it is asked to look at the work the view kept
rather than throw away, which needs a judgement no table makes — an orchestrator
has no cadence of its own, so without it Cerebro sweeps once at startup and never again.
`tests/lib/sweep-tell.cases` is its own table, answered by both implementations, and it is separate
from `triage.cases` for the reason its header gives: triage's trigger is a condition that stays true,
so a busy Cerebro needs no queue, while a two-hour mark is an **edge** that passes — one falling
mid-pass is queued and typed at the first idle tick after it, at most one at a time, so six hours of
work is followed by one sweep. The clock resets when the line is typed rather than when a sweep
completes (the navigator's choice: the alternative needs a new signal from the agent back to the
view), and it is dropped entirely for a name this view holds no session for, which is what keeps a
restarted Cerebro from being told to sweep seconds after its own startup sweep. The event is
`sweep-tell` in both writers, `sweep` being the `x`-on-a-finding decision. `triggers::cadence` is
deliberately untouched: an orchestrator gets no wake trigger, since a two-hour *cadence* would have
the view starting Opus sessions round the clock. Its surface was approved over three interview rounds
on 2026-09-02 and arrives, like cb-kcs.2's, in a docs-only pull request of its own — so no path
for it is written here, for the reason the paragraph above gives.

Since cb-kcs.5.4 it carries two things that are the navigator's own hands rather than the
supervisor's. **The priority keys** — `0`-`4`, `+`
(more urgent, so the *number* goes down), `-` and `u` — write a bead's priority to the shared board
with no confirmation and `bd dolt push` on the same keystroke, saying what they did in the header
(`cb-x: P1 → P0`, `cb-x is already P0`, `cb-x: back to P1`, and the push failure in the same line).
Since cb-21g the write itself runs on the **write worker**: the keystroke leaves a dim provisional
line (`cb-x: P1 → P0…`) that no other keystroke clears, the row shows the priority it was asked to
have until a board read that began after the write settled lands, and the sentence above arrives
when the write answers — a refused one in red, and in `errors.jsonl` under the context `write`.
`u` is one step, spent only by using it, surviving a refresh and overwritten by the next change.
They are the second write in this crate that does not pass `--readonly`, beside `x`, and the one key
set in this view that is **not** "from any focus": Work focus only, because a
digit is far more ordinary than `x` and from Fleet focus `3` would silently rerank a bead in a pane
nobody was looking at. And **the History section**, last in the Work pane — one line per agent running something right now, gold when it has run past twice its own
median (`Psylocke asking 537m - long, median 2m`), on its own five-minute reader; a state nothing
has finished in has no median and is never called long. A failed run keeps the rows it had and says
`History 4  fleet-history failed` in red, and a *first* failure draws no section at all, which is
the ordinary state of a machine that has never run the fleet. Both are **outside the supervision
lease**, exactly as `x` is, and both hint clauses are shown on a read-only view where `s`/`f`/`k`
are not. Since cb-10d.5 **`a`** on a Work bead opens a live list of the agents who take work from
the board, directly beneath that row, and **Enter** gives the bead to one through
`scripts/assign-bead --given`, on the write worker, Work focus only and outside the supervision
lease; the supervising window starts the agent.

Since cb-xhu.4.2 the Work pane's **first** section — above Sweeps — is `Health {n}`, one line per
thing `scripts/fleet-health` says is stuck right now: a name running long (red), a name started more
often than the script's own ceiling, and a name more than half of whose completed passes held no
bead (both gold). Findings only, hidden entirely when there is nothing to report, on its own
five-minute reader and its own in-flight slot, with `h report` dim beside the header. It follows
**History's** failure rule and not the Sweeps': a run that fails with rows worth keeping says
`Health 4  fleet-health failed` in red beside the header, and a *first* failure draws no section at
all, which is the ordinary state of a machine that has never run the fleet. A Health row is never
selectable — no key acts on one — so the cursor walks past them exactly as it walks past History
rows. **`h`** pins the whole four-section report in the Session pane, titled `Fleet health`, from
any focus; `h` again unpins and leaves focus where it is; a pinned bead replaces it and it replaces
a pinned bead, `App::pin` holding exactly one tenant by construction; and arriving at Fleet by
`Tab` or `F1` drops it exactly as a pinned bead is dropped (cb-lor), while `F2` and
`F3` leave it alone; `s` drops it too, by the same rule that already drops a pinned bead — the pane
is the agent's again — where `f` and `k` leave either alone. `h` starts no read: the report is
whatever the five-minute reader last got, so it can never fail and never blocks, and `g` is what
refreshes it. All of it is **outside the supervision lease**, as `x` and the priority keys are: it
reads logs and decides nothing, so a read-only view shows it. The hint clause `h health` is offered
unconditionally, at a rank (`HintRank::Optional`) below the movement hints and dropped first and
alone — the ordinary hundred-column screen has one cell of slack, so an unconditional clause at any
higher rank drops a whole tier of hints the navigator asked by name to keep.
There is no `tests/lib/` table here and no second implementation.

With it the Work **cursor** widened from findings to findings, bead rows and `+N more` rows —
never a header, a blank, `(none)` or a History row, so a grey row always means a key will do
something here — and it is on the first selectable row from the first frame. `Enter` on a `+N more`
row opens that one section (`all 23 shown — Enter`) and closes it again, which is the only way a
bead in the P4 backlog can be reranked at all; an open section survives the thirty-second refresh
and `g`. That widening is what moved the whole Work document into `app::work_body`: it now owns
every drawn line — headers, bead rows, notices, `+N more`, History and all — and `ui::work_document`
renders one arm per variant and computes no structure of its own, so the row the cursor is on and
the row that is drawn cannot come from two pieces of arithmetic. `sorted_by_priority`,
`sorted_by_recency`, `paused_age`, `SectionKind` and `WORK_ROWS_PER_SECTION` live in `app.rs` for
that reason.

**Exactly one window supervises, and the lease is the whole of the rule** (cb-abs.2). There is
nothing to declare: `fleet_supervisor` is gone, and so is every answer that named one of two
implementations. `scripts/fleet-supervisor` keeps its name and is the one place the lease's address
is computed — a port derived from the *shared* root, so every worktree of a checkout contends for
one lease; a bare invocation is now a usage error, since every remaining question is an explicit
flag. `supervisor::reconcile_supervision` is a function of one bool — hold the listener and this
window supervises, otherwise try to take it — and there is no third answer.

**The lease is a bound loopback listener and nothing else.** No pid file, no timestamp, no
heartbeat, no lease duration, no stale-entry sweep: the kernel closes a listener when its holder
dies, so a crashed owner releases immediately and nobody has to decide it had crashed. Every
timeout scheme has a window in which a live owner looks dead; this one has none.
`.cerebro/state/supervisor.json` beside it is **diagnosis only** — it names who to put on the
header or the mode line, and a missing, malformed or foreign record on a bound port is a visible
lock error, never permission to take over. The rule it gates is one boolean, asserted beside
`reconcile_supervision` itself: `tests/lib/supervisor.cases` is gone with the second
implementation it existed to hold to the same table (cb-abs.2).

A view that does not own the checkout starts, resumes, arms, triages and prunes nothing — the
**session lifecycle** is what the lease gates. The bead panel's own keys are deliberately outside
it: `x` on a sweep finding and the priority keys write to the shared board rather than to this
checkout's sessions, they are the navigator's own act and each asks first, and a board `bd` runs
the same from any machine whether or not this view supervises anything. **There is no drain**
(cb-abs.2): with one window there is nobody to hand over to gracefully, so a view that does not
hold the lease releases it at once, hosted sessions or not. Ownership shows in the header line and
nowhere else, which is the navigator's choice: it takes neither a row nor a Tab stop from Fleet and
Work, and the header says one of exactly four things — `Cerebro — starting`,
`Cerebro — supervising`, `Cerebro — read-only; another window is driving this fleet` and
`Cerebro — read-only; this window could not take charge of the fleet`.

**The family is complete.** `cb-kcs.1` brought ownership, `.2` the PTYs, `.3` retirement, `.4` the
triggers and `.5` the sweeps, the pruner, the triage line and the cutover itself; `cb-abs` removed
the second window and, with it, everything that existed to choose between two.

One screen, **three** independently bordered, independently scrolling widgets since cb-kcs.2.1:
Fleet, Work and Session, each with its own title, focus and scroll offset rather than one shared
document. At `SPLIT_COLUMNS` (100) or wider the screen is a `LEFT_COLUMN` (40) holding Fleet
over Work, with Session taking every remaining cell beside them; below that width all three stack.
Neither divider is fixed any more - see the resize chords below.
`Tab` cycles Fleet → Work → Session, and since cb-5kk `F1`/`F2`/`F3`
jump straight to those three panes from any focus (held back from a focused live session; `F4` and
above still reach the agent) — the focused one draws a
bright-blue thick-line border and a bold title. `Shift-Tab` is the hosted agent's and does nothing
in the view at any focus. From a focused **live** session `Tab` and `Shift-Tab` both reach the
agent, and `F1`/`F2`/`F3` are the only way out (cb-lmk, narrowing cb-3v5). `PgUp`/`PgDn` and the
wheel over a live session do not reach the agent: they scroll the view back through what it
printed — the lines the web console keeps for a full-screen CLI, or the terminal's own scrollback —
and the view holds still while output arrives, titled `[n lines back, PgDn returns]` and with no
cursor. Any key that does reach the agent returns it to the bottom. Since cb-lor **arriving
at the Fleet pane by `Tab` or `F1` drops a bead pinned in the Session pane** by `Enter` on a Work row
(cb-41r), so that pane goes back to drawing the selected agent, at its top; `F2` and `F3` leave a
pinned bead alone, and `Enter` on the same Work row re-opens it. `↑`/`↓`/`PgUp`/`PgDn` move only the focused widget:
under Work and Session that is its own scroll offset, and **under Fleet it is the selection**, which
the pane then scrolls to follow. Since cb-d31 **`Enter` under Fleet focus is `Tab` twice in one
key**: it moves focus straight to the selected agent's Session pane, and only while that pane is
holding something — a live child, one starting, a retained pass or a refused launch. An empty pane
refuses in gold (`Rogue has no session`) and leaves the focus where it was, so walking the roster
with `↓` never throws the navigator into an empty pane; nothing selected is silent. It moves focus
and nothing else, so it is **outside the supervision lease** exactly as `x` and the priority keys
are, and it behaves identically on a read-only view. `g` refreshes both readers regardless of focus,
`q`/`Esc`/`Ctrl-C` quits. A pane whose content outgrows its inner height reserves its last row for a dim
`Rows n–m of total` cue.

Since cb-bch.1 those dividers move from the keyboard: `Shift-←`/`Shift-→` widen and narrow the left
column a cell at a time, `Shift-↑`/`Shift-↓` move a horizontal divider a row at a time - in the
stacked layout the one **below the focused pane**, so Session focus has none to move - and
`Shift-Home` puts every divider back, each saying what it did in the header's notice slot, including
when it moved nothing (a silently dead key is what the whole vocabulary exists to prevent). They are
`Shift` keys and not `Ctrl` ones because the `Ctrl` chords shipped first and never arrived: macOS
binds all four `Ctrl`-arrows by default - Spaces on left and right, Mission Control and Application
Windows on up and down - and takes them before any terminal sees them, so verification found a
feature that compiled, tested green and could not be pressed. The five `Shift` keys were probed in
the navigator's own terminal before they were agreed, and `Ctrl`-arrows are nobody's again and reach
a hosted agent. The
reset is `Shift-Home` and never `Ctrl-=`, which is neither a control byte nor a CSI sequence and
which macOS Terminal.app and iTerm2 send nothing at all for. `app::resize_action` is the ONE place
a chord's meaning is decided, pure over the sizes, the focus and `LayoutFacts` - what
`ui::layout_facts` says the drawn frame actually came to, off the same `split`, so a chord and a
border can never disagree - and `ui::clamp_*` is the one place a floor (`MIN_PANE_COLUMNS` 24,
`MIN_PANE_ROWS` 3) or a ceiling is decided, asked by both. `app::is_view_key` is the one place the
set held back from a hosted agent is named: the pane keys plus these five. **The sizes are memory
only** (`App::panes`), on the navigator's own choice - no file is read and none is written, since
this crate has no on-disk UI preference and a size takes two seconds to set again - stored
unclamped and clamped where used, so a narrow spell never overwrites what was set on a wide screen,
and split and stacked keep separate heights for the same reason. The chords are outside the
supervision lease, as `x` and the priority keys are: moving a divider changes this screen and
nothing else. Like cb-xhu.4.2's health section it has no `tests/lib/` table: one implementation.

Since cb-bch.2 the **mouse** drives exactly that state: capture is on for the whole run, with no
key to turn it off, so the terminal's own click-drag selection and scroll wheel are given up over
the whole window - a cost the navigator took knowingly, bearable because most terminals give both
back while a modifier is held (Option on macOS Terminal and iTerm2, Shift elsewhere), which is the
terminal's behaviour and not something this program promises. A left drag on either divider's two
border cells moves it, saying `left column 56 cells` / `Fleet 16 rows` through `app::size_notice` -
the one place a chord and a drag word the same event - and a double-click within
`DOUBLE_CLICK_MS` resets **that divider alone** (`left column back to 40 cells`, or `panes are
already at their default sizes` when it had not moved), which is what makes it different from
`Shift-Home`. The wheel acts on the pane under the **pointer** and never moves focus: one row of
the Fleet selection or the Work cursor per notch, `WHEEL_LINES` of the Session transcript. A click
selects a Fleet row or a selectable Work row and focuses that pane through `App::set_focus`, so
arriving at Fleet drops a pinned bead (cb-lor); on a heading, a blank or the range cue row it
focuses and changes nothing else, and on the Session pane it never refuses the way `Enter` under
Fleet does. `ui::mouse_target` is the ONE place a screen position becomes a divider or a pane,
pure over the `LayoutFacts` rects the drawn frame came from, and dividers win over panes because a
divider cell IS a border cell. **No mouse event ever reaches a hosted agent** - `session::key_bytes`
has no mouse path - and all of it is outside the supervision lease, as the chords are. The surface
itself is written down at `docs/ui/cb-bch-resizable-panes.html`.

**The selection is a name, never an index** (`App::selected`, `App::selected_index`): the roster can
shrink under the navigator, and an index would silently come to mean a different agent. A selected
agent that leaves the roster moves the selection to the row at its old index, clamped, and says so
in the header in gold until the next keystroke (`App::notice`) — and only ever on a **successful**
fleet read, so a five-second `ps` hiccup can never reselect anybody. The fleet body is not one line
per row (a heading, plus a diagnostic line per invalid row), so `model::row_document_line` is the
one place a row index becomes a document line and the renderer calls it rather than keeping a
second copy.

Session can hold a real child since cb-kcs.2.2: `scripts/launch <Name>` in a pty (`portable-pty`),
its screen drawn from a `vt100::Parser` this crate owns — which is why a killed child's screen is
still drawable — and every key of a focused live session forwarded to it, `Tab` and `Shift-Tab`
included, with `F1`/`F2`/`F3` held back as the way out (cb-lmk). A pass that ends is kept as a scrollable transcript of at most ten thousand
lines, until that agent starts again. **Nothing a navigator can press starts one**: `SessionHost::spawn`
is reached by test code alone, and `s`/`f`/`k` are cb-kcs.2.3's, so the pane still says why there is
no session in it and the header hint still names no key that does not exist. The rule that pays for
all of it is that `SessionHost::sync` materialises the child's screen into a `SessionView` **before**
the frame: `App` holds no pty, no thread and no child, and `ui::draw` stays pure over `App` while a
reader thread writes into a parser continuously. That reader thread drains the master
unconditionally, focused or not — a pipe nobody drains is a deadlock — and `Session`'s `Drop` kills
its child, because a pane the navigator can no longer see must not leave an agent running against a
bead nobody is watching. The surface the navigator approved for the
whole `cb-kcs.2` family is the split console, interviewed over three rounds on 2026-09-01. It
refines `docs/ui/cb-kcs-supervisor.html`, which the epic's own interview approved, and supersedes
`docs/ui/cb-42k-independent-widgets.html` and the original single-document
`docs/ui/cb-vyp-read-only-view.html`. **Its own mockup file arrives with its own docs-only pull
request rather than with any of the three children**, so this paragraph deliberately names no path
for it: a pointer that resolves on one merge order and not the other is worse than none, and
nothing checks a path written in prose the way `scripts/tracked-links` checks a link.

The crate is split into a pure core and a small set of impure readers, so the tests exercise the
pure half with plain data:

- `sweeps.rs` — pure throughout: what the four sweeps decide (`Sweep::judge`), the four `Finding`
  shapes, the Sweeps line, the exact argv and the header's question. The Rust copy of
  `cerebro--sweeps` and its neighbours, held to `tests/lib/sweep-findings.json` the way `model.rs`
  is held to its own table. The four thresholds are `const`s here and defcustoms there, exactly as
  `lifecycle::END_GRACE_SECONDS` is.
- `model.rs` — pure parsing and derivation (roster, state files, the marker sentence, the process
  tree, `partition_beads` — which since cb-hzl skips an epic only while it HAS a direct child,
  answered from the ids the one board read already holds, so a childless epic partitions like any
  other bead; `scripts/work-beads`, whose list is scoped to one status, asks `bd children` instead). It is the Rust copy of the elisp rules, held to the same
  `tests/lib/session-args.cases` table as every other reader of the marker sentence.
- `supervisor.rs` — ownership: the pure `reconcile_supervision`, one bool in and one mode out,
  and `SupervisorLease`, the bound listener that IS the lock.
- `readers.rs` — every file and subprocess: `scripts/roster`, `ps -axo pid=,ppid=,args=`, and one
  `bd --readonly -C <shared root> list --status open,in_progress,blocked,deferred,closed --json
  --brief`. Each child has a wall-clock bound - five seconds, or `BD_TIMEOUT`'s thirty for the two `bd` reads,
  which wait behind the fleet's Dolt traffic - is killed **and reaped** on it, and has
  both pipes drained on their own threads before anything waits — a child that fills a pipe while
  the parent waits is a deadlock no timeout can see. `read_fleet` and `read_work` are the two
  aggregate reads, and **a failure is never an empty answer**: `Ok(vec![])` would draw a fleet in
  which every agent is dead, and `Ok(WorkBuckets::default())` a board with nothing on it. Since
  cb-x3u the spawning itself is behind `CommandRunner`: production passes `RealCommands`, which is
  the only implementation that starts a process, and a test about parsing passes
  `readers::testing::FakeCommands`, which answers from a table and records the argv. Spawning is
  proved once, in `fleet-view/tests/command_runner.rs`, against **tracked** fixture scripts under
  `fleet-view/tests/fixtures/` — a file no test writes cannot be `ETXTBSY`, which is what four
  patches in this module had been working around. Since
  cb-kcs.4.3 `read_gh` is a third reader — three `gh` calls on their own ten-minute cadence, each
  bounded at thirty seconds because these are network calls — and it is what starts the roles whose
  work arrives from outside the fleet. Its pane is never drawn: its four content states are exactly
  what tells a trigger "no answer yet" (no suffix) from "the last request failed" (`gh?` on Moira's
  and Cypher's rows, and their hourly floor alone). Since cb-xhu.4.2 `read_health` is the ninth —
  `scripts/fleet-health --json` on a thirty-second bound, `read_history`'s shape and its reason: a
  `jq` walk over logs that grow without limit, and not a network call. `Ok(FleetHealth::default())`
  would draw a fleet in perfect health that nobody could look at, so a failure is never an empty
  answer here either.
- `log.rs` — the three JSONL files, split the same way: the pure half (`Event::basename`,
  `log_event_p`, `log_evaluation_p`, `log_rotate_p`, `log_line`, `log_file`, `reader_context`) and
  one impure `Logger` that owns them. It is the ONLY thing in the crate that writes any of them, its
  root is a constructor parameter and never resolved — a logger that found its own root would make
  every test append to the navigator's live log — and it starts disabled, so a view that comes up
  read-only has written nothing by its first frame.
- `app.rs` — the display state, the pane sizes and the resize decision (`PaneSizes`,
  `LayoutFacts`, `resize_action` - where the geometry `App` holds begins and ends, and the one
  place this module reaches INTO `ui`, for the floors and ceilings `ui::split` lays out with), the
  two
  independent cadences (fleet every 5s, work every 30s) and
  one worker thread per pane. The panes are independent all the way down: one in-flight slot each,
  one clock each, one `Pane<T>` state machine each. A global busy bit would let the five-second
  fleet read starve the thirty-second work read, and a busy fleet would swallow the retry a
  navigator pressed `g` for. Since cb-21g the two board **writes** have a worker of their own — the
  eighth — for the reason the seven readers have theirs: a `bd dolt push` is a network call bounded
  at thirty seconds, and running it on the drawing thread froze the screen, keys and all, for as
  long as the remote took. **One** worker and one write at a time, deliberately: writes to the
  shared board must run in the order the navigator pressed them, and a pool would let `3` overtake
  `0` on the same bead. The UI thread decides (`lifecycle::priority_action`), records
  (`App::begin_write`) and looks (`App::finish_write`); it starts nothing. A write the worker
  never received is answered by `WriteAnswer::undeliverable`, and one it received and can no
  longer answer — its thread gone — by `App::abandon_outstanding_writes`, because `Worker::poll`
  answers `None` for "nothing yet" and for "never" alike and only the second is news
  (`Worker::is_dead`).
  Since cb-10d.3 worktree tidies have a worker of their own too, `TidyWorker`, and deliberately not
  the write worker: a tree removal deletes a build directory and fetches, and on the write worker it
  would hold the priority keys behind it on every pass.
- `ui.rs` — pure over `App` plus an injected `DateTime<Utc>`. It never reads a file, runs a
  program or asks the clock, which is what makes its `TestBackend` cases assertions about the
  screen rather than about the machine. Widths are **terminal cells** (`unicode-width`), never
  bytes or `char`s.
- `main.rs` — the terminal, the event loop and nothing else. Raw mode and the alternate screen are
  entered under an RAII guard, because `?`, an early return and a panic all skip a cleanup call
  and none of them skips a drop.

Two rules a change here must keep. **A failed refresh never destroys a snapshot still worth
reading**: a first failure is `Unavailable`, a later one is `Stale` carrying the original
`read_at`, and a success clears the error with the value. And **the two panes fail apart**: `bd`
being unreadable says nothing about the fleet. The header is the one place they meet — while
either pane is retrying it says `refreshing...`, otherwise it carries the newest failure's time,
and the key hint stays `g retry` until both panes are fresh.
