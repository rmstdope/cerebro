# Cerebro web console

For development, run the read-only Rust service and Vite in separate terminals from the repository
root:

```bash
cargo run -p cerebro-web
pnpm --dir web-console/ui dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` requests to the Rust service at
`http://127.0.0.1:7171`.

The page has two tabs, in a dark and a light theme (the button top right; the first visit follows
the system). **Fleet** lists the agents down the side, live ones first, each with a status dot, its
bead and how long it has been in its phase; the chosen agent's CLI session fills the rest,
read-only. With nobody chosen it shows whoever is asking, else working. **Work** is the board in
five lanes, searchable, filterable by type and priority, and grouped by epic: a bead's epic is its
nearest dotted-id ancestor, named from the `epics` map in `/api/work`. An agent that is asking, or
a bead waiting for human input, is named in a banner above both tabs.

The UI is React with Tailwind v4 and shadcn/ui on Base UI; the generated components live in
`ui/src/components/ui/` and are ours to edit (`pnpm dlx shadcn@latest add <name>` adds another).

The session scrolls back through its history, which goes back up to 10,000 lines; the view follows
new output only while it is scrolled to the bottom, which the Follow switch shows and sets.
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

Which offline agents are on standby rather than dead is the supervising fleet view's to say, since
its armed set moves with every kill, give-up and manual start. It publishes those names to
`.cerebro/state/standby.json`, refreshed every 5 seconds. With no fleet view supervising, or one
that has stopped refreshing it for 15 seconds, every offline agent shows as dead.

Run the browser smoke test with:

```bash
pnpm --dir web-console/ui test:e2e
```
