import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  use: {
    baseURL: "http://127.0.0.1:5199",
  },
  webServer: [
    {
      command: "cargo run -p cerebro-web",
      cwd: "../..",
      url: "http://127.0.0.1:7171/api/fleet",
      reuseExistingServer: !process.env.CI,
    },
    {
      command: "pnpm exec vite --host 127.0.0.1 --port 5199 --strictPort",
      url: "http://127.0.0.1:5199",
      reuseExistingServer: !process.env.CI,
    },
  ],
});
