# Cerebro web console

For development, run the Rust service and Vite in separate terminals from the repository
root:

```bash
cargo run -p cerebro-web
pnpm --dir web-console/ui dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` requests to the Rust service at
`http://127.0.0.1:7171`.

The page has two tabs, in a dark and a light theme (the button top right; the first visit follows
the system). **Fleet** lists the agents down the side, live ones first, each with a status dot, its
bead and how long it has been in its phase; the chosen agent's CLI session fills the rest. With nobody chosen it shows whoever is asking, else working. **Work** is the board in
five lanes, searchable, filterable by type and priority, and grouped by epic: a bead's epic is its
nearest dotted-id ancestor, named from the `epics` map in `/api/work`. A click selects a card and a
second click, or `Enter`, opens it; the arrow keys move the selection, up and down within a lane
and left and right to the nearest lane with a card in it. An open bead shows everything
`bd show` holds about it: status, priority, type and labels under its title, then a tab each for
the overview (every fact and its dependencies), each of its texts rendered as markdown (raw HTML
stays text) and the raw JSON, with the arrow keys moving between tabs. It is read on opening through `GET /api/beads/<id>` (a 502 carrying the reason
when `bd` fails). An agent that is asking, or
a bead waiting for human input, is named in a banner above both tabs.

The UI is React with Tailwind v4 and shadcn/ui on Base UI; the generated components live in
`ui/src/components/ui/` and are ours to edit (`pnpm dlx shadcn@latest add <name>` adds another).

The session scrolls back through its history, which goes back up to 10,000 lines; the view follows
new output only while it is scrolled to the bottom, which the Follow switch shows and sets. The
session's box is the size of its screen, as in the terminal console, and follows each pty resize;
a screen taller or wider than the room is drawn smaller, so all of it shows at once. Text can be
selected anywhere, the screen included: a CLI's requests for mouse and focus reporting are
ignored, so only the keyboard reaches it, as in the terminal console.

Clicking the screen gives it the keyboard: what is typed or pasted there goes to the agent, and
returns a scrolled-back view to the bottom. The pty keeps the terminal console's size. The page
posts xterm's own bytes to `POST /api/sessions/<name>/input`, which refuses a request without the
`X-Cerebro-Input: 1` header or naming a host or origin other than this machine, so no other site
can type into a session. The service hands the bytes to the Unix socket the fleet view publishes
as `input` in `<name>.json`, which writes them to the pty. What xterm answers a CLI's queries
with, every time a log is replayed, is never sent. Typing into one session from both consoles at
once is not guarded against.

The chosen agent's header has the terminal console's `s`, `f` and `k` as buttons: **Start** an
agent that is not running, **Finish after this pass** (or **Keep going** once its stop flag is set)
and **Kill**, which is **Disarm** on a standby agent and **Stop starting** on one being started. The
same keys work on the chosen agent while nothing is being typed, and `⌘K` lists every action on
every agent. A kill, disarm or stop asks first, in a dialog `y` confirms. The page posts
`POST /api/agents/<name>/<start|finish|resume|kill|disarm|stop>`, with the same header and host checks as
typing, and the service hands it to the supervising fleet view's control socket, named as `control`
in `standby.json`. The fleet view does it by the same rules as its keys and the page shows its
answer; a refusal is the sentence its header would have shown. A kill, disarm or stop is done
only if the row still calls for that one, so a disarm confirmed on an agent started since kills
nothing. With no fleet view supervising, the
buttons are disabled and the header says **Read-only** rather than **Supervised**.
`GET /api/control` says which, and `/api/events` sends `control` when it changes. An agent whose
stop flag is set is reported with `finishing: true`.
The output comes from the fleet view (`cerebro-tui`) that hosts the session. It appends each hosted
session's pty output to a log under `.cerebro/state/sessions/`, with the pty's resizes recorded in
the log, and publishes `<name>.json` naming that log. `GET /api/sessions/<name>?log=&from=` serves
the log from an offset. When a log passes 8 MiB it starts again from the current screen, and the
older history is dropped. An agent started outside the fleet view has no session to show.

A full-screen CLI, such as Copilot on the alternate screen, keeps no terminal scrollback: it
scrolls its conversation inside a scroll region, and the lines leave from the region's top. The
fleet view takes each such line as it goes and writes it into the log as `OSC 7717`, a JSON array of
styled runs. The page shows those lines above the live screen, and the wheel scrolls back through
them. The last 2 MiB of these lines are written again at the top of a new log, so they survive the
8 MiB restart. A line the CLI draws again, when it re-renders, can appear twice.

A resize loses lines without scrolling them: the CLI clears the screen and redraws only its newest
lines. So the fleet view saves the screen before a resize. After the redraw, it keeps the lines at
the top of the saved screen that the new screen no longer shows, up to the first one it still does.
The pty is told a new size only after the pane has held it for 150 ms. A window being dragged or
animated then reaches the CLI as one resize, not as a burst it would draw at the wrong width.

Which offline agents are on standby rather than dead is the supervising fleet view's to say, since
its armed set moves with every kill, give-up and manual start. It publishes those names to
`.cerebro/state/standby.json`, refreshed every 5 seconds. With no fleet view supervising, or one
that has stopped refreshing it for 15 seconds, every offline agent shows as dead.

Run the browser smoke test with:

```bash
pnpm --dir web-console/ui test:e2e
```
