import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: {
    baseURL: "http://127.0.0.1:5173",
  },
  webServer: [
    {
      command: "cargo run -p cerebro-web",
      cwd: "../..",
      url: "http://127.0.0.1:7171/api/fleet",
      reuseExistingServer: !process.env.CI,
    },
    {
      command: "pnpm exec vite --host 127.0.0.1",
      url: "http://127.0.0.1:5173",
      reuseExistingServer: !process.env.CI,
    },
  ],
});
