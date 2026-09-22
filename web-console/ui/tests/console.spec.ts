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

const lines = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => `line ${from + i}\r\n`).join("");

async function hostSession(page: import("@playwright/test").Page) {
  let stream = "\u001b[8;5;40t" + lines(1, 50);
  await page.route("/api/fleet", (route) =>
    route.fulfill({ json: { state: "fresh", value: [{ name: "Storm", role: "producer", state: "working", bead: "cb-1" }] } }),
  );
  await page.route(/\/api\/sessions\/Storm/, (route) => {
    const query = new URL(route.request().url()).searchParams;
    const reset = !query.has("log");
    const from = reset ? 0 : Number(query.get("from"));
    return route.fulfill({ json: { state: "live", log: "Storm.1-0-0.log", reset, data: stream.slice(from), offset: stream.length, more: false } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: /Storm/ }).click();
  return { rows: page.getByRole("region", { name: "Storm session" }).locator(".xterm-rows"), append: (text: string) => { stream += text; } };
}

test("shows a running agent's session and follows new output at the bottom", async ({ page }) => {
  const session = await hostSession(page);
  await expect(session.rows).toContainText("line 50");

  session.append(lines(51, 51));

  await expect(session.rows).toContainText("line 51");
});

test("keeps a scrolled-back session where the reader left it", async ({ page }) => {
  const session = await hostSession(page);
  await expect(session.rows).toContainText("line 50");

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").hover();
  await page.mouse.wheel(0, -2000);
  await expect(session.rows).not.toContainText("line 50");
  const before = await session.rows.innerText();
  session.append(lines(51, 51));
  await page.waitForTimeout(1500);

  expect(await session.rows.innerText()).toBe(before);
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
