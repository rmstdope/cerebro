import { defineConfig } from "@playwright/test";

// The ports come from CEREBRO_PORT_BASE, which `scripts/smoke-port' sets to a block it has
// reserved for exactly this run (tests/web-console-ui runs the suite under it): the service on the
// base, Vite on the next port. Unset, they are the ports `pnpm test:e2e' has always used, and a
// server already listening there is reused (a dev server started by hand). A reserved block is
// never reused: whatever answers on it is not this checkout's.
const base = Number(process.env.CEREBRO_PORT_BASE) || 0;
const servicePort = base ? base : 7171;
const vitePort = base ? base + 1 : 5199;

export default defineConfig({
  testDir: "./tests",
  use: {
    baseURL: `http://127.0.0.1:${vitePort}`,
  },
  webServer: [
    {
      command: "cargo run -p cerebro-web --locked",
      cwd: "../..",
      env: { CEREBRO_WEB_ADDRESS: `127.0.0.1:${servicePort}` },
      url: `http://127.0.0.1:${servicePort}/api/fleet`,
      reuseExistingServer: !process.env.CI && !base,
      // A cold `cargo run' compiles the workspace; tests/web-console-ui builds it first, but a
      // by-hand run may not have.
      timeout: 180_000,
    },
    {
      command: `pnpm exec vite --host 127.0.0.1 --port ${vitePort} --strictPort`,
      env: { CEREBRO_WEB_PORT: String(servicePort) },
      url: `http://127.0.0.1:${vitePort}`,
      reuseExistingServer: !process.env.CI && !base,
    },
  ],
});
