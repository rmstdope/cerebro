# Cerebro web console

For development, run the read-only Rust service and Vite in separate terminals from the repository
root:

```bash
cargo run -p cerebro-web
pnpm --dir web-console/ui dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` requests to the Rust service at
`http://127.0.0.1:7171`.

Clicking a running agent shows its CLI session, read-only. Scroll back through its history, which
goes back up to 10,000 lines; the view follows new output only while it is scrolled to the bottom.
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

Run the browser smoke test with:

```bash
pnpm --dir web-console/ui test:e2e
```
