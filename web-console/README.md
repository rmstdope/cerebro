# Cerebro web console

For development, run the read-only Rust service and Vite in separate terminals from the repository
root:

```bash
cargo run -p cerebro-web
pnpm --dir web-console/ui dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` requests to the Rust service at
`http://127.0.0.1:7171`.

Clicking a running agent shows its CLI session, read-only. The screen comes from the fleet view
(`cerebro-tui`) that hosts the session: it publishes each hosted session's screen to
`.cerebro/state/sessions/<name>.json`, and `GET /api/sessions/<name>` serves it. An agent started
outside the fleet view has no screen to show.

Run the browser smoke test with:

```bash
pnpm --dir web-console/ui test:e2e
```
