# Cerebro web console

For development, run the read-only Rust service and Vite in separate terminals from the repository
root:

```bash
cargo run -p cerebro-web
pnpm --dir web-console/ui dev
```

Open <http://127.0.0.1:5173>. Vite proxies `/api` requests to the Rust service at
`http://127.0.0.1:7171`.

Run the browser smoke test with:

```bash
pnpm --dir web-console/ui test:e2e
```
