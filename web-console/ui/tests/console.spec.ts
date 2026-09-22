import { expect, test } from "@playwright/test";

test("loads data and requests the event stream through Vite", async ({ page }) => {
  const fleet = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/fleet");
  const events = page.waitForRequest((request) => new URL(request.url()).pathname === "/api/events");

  await page.goto("/");

  expect((await fleet).status()).toBe(200);
  expect((await events).method()).toBe("GET");
  await expect(page.getByRole("heading", { name: "Cerebro" })).toBeVisible();
  await expect(page.getByText("Fleet and work · read-only")).toBeVisible();
});

test("shows a running agent's session screen", async ({ page }) => {
  await page.route("/api/fleet", (route) =>
    route.fulfill({ json: { state: "fresh", value: [{ name: "Storm", role: "producer", state: "working", bead: "cb-1" }] } }),
  );
  await page.route("/api/sessions/Storm", (route) =>
    route.fulfill({ json: { state: "live", rows: 5, cols: 40, screen: "\u001b[1mStorm is building\u001b[m", updated_at: new Date().toISOString() } }),
  );

  await page.goto("/");
  await page.getByRole("button", { name: /Storm/ }).click();

  const session = page.getByRole("region", { name: "Storm session" });
  await expect(session.locator(".xterm-rows")).toContainText("Storm is building");
});

test("does not offer a session for a dead agent", async ({ page }) => {
  await page.route("/api/fleet", (route) =>
    route.fulfill({ json: { state: "fresh", value: [{ name: "Rogue", role: "producer", state: "dead" }] } }),
  );

  await page.goto("/");
  await page.getByRole("button", { name: /Rogue/ }).click();

  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByRole("region", { name: "Rogue session" })).toHaveCount(0);
});
