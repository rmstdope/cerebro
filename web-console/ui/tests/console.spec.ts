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
