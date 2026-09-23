import { expect, test } from "@playwright/test";

test("loads data and requests the event stream through Vite", async ({ page }) => {
  const fleet = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/fleet");
  const events = page.waitForRequest((request) => new URL(request.url()).pathname === "/api/events");

  await page.goto("/");

  expect((await fleet).status()).toBe(200);
  expect((await events).method()).toBe("GET");
  await expect(page.getByRole("heading", { level: 1, name: "Cerebro" })).toBeVisible();
  await expect(page.getByText("Read-only")).toBeVisible();
});

const past = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => `\u001b]7717;[{"t":"old ${from + i}"}]\u0007`).join("");
const lines = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => `line ${from + i}\r\n`).join("");

async function hostSession(page: import("@playwright/test").Page, opening = "\u001b[8;5;40t" + lines(1, 50)) {
  let stream = opening;
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
  const region = page.getByRole("region", { name: "Storm session" });
  return { rows: region.locator(".xterm-rows"), history: region.locator(".history"), screen: region.locator(".screen"), append: (text: string) => { stream += text; } };
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

test("draws the session at the size its log last set", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t" + "\u001b[8;12;60t" + lines(1, 3));
  await expect(session.rows).toContainText("line 3");

  await expect(session.rows.locator(":scope > div")).toHaveCount(12);
});

test("offers the lines a full-screen CLI scrolled away above its screen", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 60) + "live screen");
  await expect(session.rows).toContainText("live screen");
  await expect(session.history.getByText("old 60", { exact: true })).toBeInViewport();
  await expect(session.history.getByText("old 1", { exact: true })).not.toBeInViewport();

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").hover();
  await page.mouse.wheel(0, -100000);

  await expect(session.history.getByText("old 1", { exact: true })).toBeInViewport();
});

test("follows new history at the bottom and leaves a reader scrolled back where they are", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 60) + "live screen");
  await expect(session.history.getByText("old 60", { exact: true })).toBeInViewport();

  session.append(past(61, 61));
  await expect(session.history.getByText("old 61", { exact: true })).toBeInViewport();

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").hover();
  await page.mouse.wheel(0, -100000);
  await expect(session.history.getByText("old 1", { exact: true })).toBeInViewport();
  const top = await session.screen.evaluate(element => element.scrollTop);
  session.append(past(62, 70));
  await expect(session.history.getByText("old 70", { exact: true })).toHaveCount(1);

  expect(await session.screen.evaluate(element => element.scrollTop)).toBe(top);
  await expect(session.history.getByText("old 1", { exact: true })).toBeInViewport();
});

test("keeps the last 10,000 lines of history, quickly", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 20000) + "live screen");

  await expect(session.rows).toContainText("live screen", { timeout: 3000 });
  await expect(session.history.locator(":scope > div")).toHaveCount(10000);
  await expect(session.history.locator(":scope > div").first()).toHaveText("old 10001");
});

test("holds a reader's place in history while the oldest lines are dropped", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 10000) + "live screen");
  await expect(session.rows).toContainText("live screen");
  const topLine = () => session.screen.evaluate(element => {
    const top = element.getBoundingClientRect().top;
    return [...element.querySelectorAll(".history > div")].find(line => line.getBoundingClientRect().bottom > top + 1)?.textContent;
  });
  await session.screen.evaluate(element => { element.scrollTop = element.scrollHeight / 2; });
  const before = await topLine();

  session.append(past(10001, 10050));
  await expect(session.history.getByText("old 10050", { exact: true })).toHaveCount(1);
  await expect(session.history.getByText("old 50", { exact: true })).toHaveCount(0);

  expect(await topLine()).toBe(before);
});

test("draws history in the colours the CLI used", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h\u001b]7717;[{\"t\":\"red\",\"fg\":1},{\"t\":\"rgb\",\"bg\":\"#010203\"}]\u0007live");
  await expect(session.rows).toContainText("live");

  await expect(session.history.getByText("red", { exact: true })).toHaveCSS("color", "rgb(204, 0, 0)");
  await expect(session.history.getByText("rgb", { exact: true })).toHaveCSS("background-color", "rgb(1, 2, 3)");
});

test("keeps history out of the way of a CLI on the normal screen", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 3) + "\u001b[?1049lback to the shell");
  await expect(session.rows).toContainText("back to the shell");

  await expect(session.history).toBeHidden();
});

test("starts history afresh with a new log", async ({ page }) => {
  const first = "\u001b[8;5;40t\u001b[?1049h" + past(1, 30) + "first log";
  const second = "\u001b[8;5;40t" + past(1, 4) + "\u001b[?1049hsecond log";
  await page.route("/api/fleet", (route) =>
    route.fulfill({ json: { state: "fresh", value: [{ name: "Storm", role: "producer", state: "working", bead: "cb-1" }] } }),
  );
  await page.route(/\/api\/sessions\/Storm/, (route) => {
    const log = new URL(route.request().url()).searchParams.get("log");
    const from = Number(new URL(route.request().url()).searchParams.get("from"));
    // The old log, then at once a new one that carries some of the same history.
    if (log === null) return route.fulfill({ json: { state: "live", log: "Storm.1-0-0.log", reset: true, data: first, offset: first.length, more: true } });
    if (log === "Storm.1-0-0.log") return route.fulfill({ json: { state: "live", log: "Storm.1-1-1.log", reset: true, data: second, offset: second.length, more: false } });
    return route.fulfill({ json: { state: "live", log: "Storm.1-1-1.log", reset: false, data: second.slice(from), offset: second.length, more: false } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: /Storm/ }).click();
  const region = page.getByRole("region", { name: "Storm session" });

  await expect(region.locator(".xterm-rows")).toContainText("second log");
  await page.waitForTimeout(1000);
  await expect(region.locator(".history > div")).toHaveCount(4);
});

test("does not offer a session for a dead agent", async ({ page }) => {
  await page.route("/api/fleet", (route) =>
    route.fulfill({ json: { state: "fresh", value: [{ name: "Rogue", role: "producer", state: "dead" }] } }),
  );

  await page.goto("/");
  await page.getByRole("button", { name: /Rogue/ }).click();

  await expect(page.getByRole("region", { name: "Rogue details" })).toContainText("not running");
  await expect(page.getByRole("region", { name: "Rogue session" })).toHaveCount(0);
});

test("tells a standby agent from a dead one in the offline list", async ({ page }) => {
  await page.route("/api/fleet", route => route.fulfill(fleetOf(
    { name: "Rogue", role: "producer", state: "Dead" },
    { name: "Moira", role: "user-feedback", state: "Standby" },
  )));
  await page.goto("/");

  const fleet = page.getByRole("complementary", { name: "Fleet" });
  await expect(fleet).toContainText("Offline · 2");
  const moira = fleet.getByRole("button", { name: /Moira/ });
  const rogue = fleet.getByRole("button", { name: /Rogue/ });
  await expect(moira).toContainText("standby");
  await expect(rogue).toContainText("dead");
  await expect(moira.locator("[data-state]")).toHaveAttribute("data-state", "standby");
  await expect(rogue.locator("[data-state]")).toHaveAttribute("data-state", "dead");
  await expect(fleet.getByRole("button").filter({ hasText: /Moira|Rogue/ }).first()).toContainText("Moira");

  await moira.click();
  await expect(page.getByRole("region", { name: "Moira details" })).toContainText("on standby");
  await rogue.click();
  await expect(page.getByRole("region", { name: "Rogue details" })).toContainText("not running");
});

const fleetOf = (...agents: object[]) => ({ json: { state: "fresh", value: agents } });
const bead = (id: string, title: string, extra: object = {}) => ({ id, title, status: "open", issue_type: "feature", labels: [], priority: 2, ...extra });
const emptyWork = { claimed: [], planned: [], being_planned: [], ux_agreed: [], unplanned: [], paused: [], merged: [] };

test("opens on the agent that is asking, and says so above the page", async ({ page }) => {
  await page.route("/api/fleet", route => route.fulfill(fleetOf(
    { name: "Storm", role: "producer", state: "Working", bead: "cb-1" },
    { name: "Cyclops", role: "producer", state: "Asking", bead: "cb-2" },
    { name: "Rogue", role: "producer", state: "Dead" },
  )));
  await page.route(/\/api\/sessions\//, route => route.fulfill({ json: { state: "absent" } }));
  await page.goto("/");

  await expect(page.getByRole("region", { name: "Cyclops details" })).toBeVisible();
  await expect(page.getByText("Cyclops is asking you a question on cb-2")).toBeVisible();
  await expect(page.getByRole("complementary", { name: "Fleet" })).toContainText("Offline · 1");

  await page.getByRole("button", { name: /Storm/ }).click();
  await expect(page.getByRole("region", { name: "Storm details" })).toBeVisible();
  await page.getByRole("button", { name: "View session" }).click();
  await expect(page.getByRole("region", { name: "Cyclops details" })).toBeVisible();
});

test("the Follow switch tells whether the session follows, and turning it on returns to the bottom", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t\u001b[?1049h" + past(1, 200) + "live screen");
  const follow = page.getByRole("switch", { name: "Follow new output" });
  await expect(session.rows).toContainText("live screen");
  await expect(follow).toBeChecked();

  await session.screen.evaluate(element => { element.scrollTop = 0; element.dispatchEvent(new Event("scroll")); });
  await expect(follow).not.toBeChecked();

  await follow.click();
  await expect(follow).toBeChecked();
  await expect(page.getByRole("button", { name: "Jump to the bottom" })).toHaveCount(0);
  expect(await session.screen.evaluate(element => element.scrollHeight - element.scrollTop - element.clientHeight)).toBeLessThan(4);
});

test("Follow stays on while a session larger than the pane loads and resizes", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;83;400t\u001b[?1049h" + past(1, 60) + "\u001b[8;52;125t" + past(61, 200) + "live screen");
  await expect(session.rows).toContainText("live screen");

  await expect(page.getByRole("switch", { name: "Follow new output" })).toBeChecked();
  expect(await session.screen.evaluate(element => element.scrollHeight - element.scrollTop - element.clientHeight)).toBeLessThan(4);
});

test("a screen taller than the pane is drawn small enough to show all of it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const rows = Array.from({ length: 52 }, (_, i) => `\u001b[${i + 1};1Hrow ${i + 1}`).join("");
  const session = await hostSession(page, "\u001b[8;52;125t\u001b[?1049h" + past(1, 30) + rows);
  await expect(session.rows).toContainText("row 52");

  await expect(session.rows.getByText("row 1", { exact: true })).toBeInViewport({ ratio: 0.9 });
  await expect(session.rows.getByText("row 52", { exact: true })).toBeInViewport({ ratio: 0.9 });
});

test("the Follow switch reads and sets xterm's own scrollback on the normal screen", async ({ page }) => {
  const session = await hostSession(page);
  const follow = page.getByRole("switch", { name: "Follow new output" });
  await expect(session.rows).toContainText("line 50");

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").hover();
  await page.mouse.wheel(0, -2000);
  await expect(follow).not.toBeChecked();
  await follow.click();
  await expect(follow).toBeChecked();
  await expect(session.rows).toContainText("line 50");

  await follow.click();
  await expect(follow).not.toBeChecked();
  session.append(lines(51, 60));
  await page.waitForTimeout(1500);
  await expect(session.rows).toContainText("line 50");
  await expect(session.rows).not.toContainText("line 60");
  await expect(follow).not.toBeChecked();

  await follow.click();
  await expect(session.rows).toContainText("line 60");
});

test("Follow off holds even before the session has any scrollback", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;5;40t" + lines(1, 2));
  const follow = page.getByRole("switch", { name: "Follow new output" });
  await expect(session.rows).toContainText("line 2");

  await follow.click();
  session.append(lines(3, 20));
  await page.waitForTimeout(1500);

  await expect(follow).not.toBeChecked();
  await expect(session.rows).not.toContainText("line 20");
});

test("switches between the dark and light themes and remembers the choice", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator("html")).toHaveClass(/dark/);

  await page.getByRole("button", { name: "Use the light theme" }).click();
  await expect(page.locator("html")).not.toHaveClass(/dark/);
  await page.reload();

  await expect(page.locator("html")).not.toHaveClass(/dark/);
  await expect(page.getByRole("button", { name: "Use the dark theme" })).toBeVisible();
});

test("groups the board by epic, filters it, and opens a bead", async ({ page }) => {
  await page.route("/api/fleet", route => route.fulfill(fleetOf()));
  await page.route("/api/work", route => route.fulfill({ json: { state: "fresh", value: { ...emptyWork,
    unplanned: [bead("cb-9.1", "Command palette"), bead("cb-7", "Loose bug", { issue_type: "bug", priority: null })],
    claimed: [bead("cb-9.2", "Live session view", { status: "in_progress", assignee: "Storm", priority: 1 })],
    epics: { "cb-9": "Web console" },
  } } }));
  await page.goto("/");
  await page.getByRole("button", { name: "work" }).click();

  const backlog = page.getByRole("region", { name: "Backlog" });
  await expect(backlog.getByText("Web console")).toBeVisible();
  await expect(backlog.getByText("No epic")).toBeVisible();
  await expect(backlog.getByText("unranked")).toBeVisible();
  await expect(page.getByRole("region", { name: "In progress" })).toContainText("Storm");

  await page.getByRole("group", { name: "Type" }).getByRole("button", { name: "bug", exact: true }).click();
  await expect(backlog.getByText("Command palette")).toHaveCount(0);
  await expect(backlog.getByText("Loose bug")).toBeVisible();

  await backlog.getByText("Loose bug").click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("cb-7");
  await expect(dialog).toContainText("Backlog");
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
});
