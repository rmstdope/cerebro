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
  await page.route(/\/api\/sessions\/Storm(\?|$)/, (route) => {
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

test("the session's box is the size of its screen, and follows it when the pty resizes", async ({ page }) => {
  await page.setViewportSize({ width: 1600, height: 1000 });
  const session = await hostSession(page, "\u001b[8;20;100t\u001b[?1049h" + past(1, 30) + "\u001b[20;1Hlast row");
  await expect(session.rows).toContainText("last row");
  const box = async () => {
    const screen = await session.screen.boundingBox();
    const drawn = await session.screen.locator(".xterm-screen").boundingBox();
    return { rows: screen!.height - drawn!.height, cols: screen!.width - drawn!.width };
  };
  // Only the box's padding, and a scrollbar, around the drawn screen.
  await expect.poll(async () => (await box()).rows).toBeLessThan(20);
  await expect.poll(async () => (await box()).cols).toBeLessThan(45);
  const wide = (await session.screen.boundingBox())!;

  session.append("\u001b[8;10;70t\u001b[10;1Hsmaller");
  await expect(session.rows).toContainText("smaller");
  await expect.poll(async () => (await session.screen.boundingBox())!.width).toBeLessThan(wide.width * 0.8);
  await expect.poll(async () => (await session.screen.boundingBox())!.height).toBeLessThan(wide.height * 0.7);
  await expect.poll(async () => (await box()).rows).toBeLessThan(20);
  await expect.poll(async () => (await box()).cols).toBeLessThan(45);
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

test("a small screen's box still has room for its name and its controls", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;10;20t" + lines(1, 3));
  await expect(session.rows).toContainText("line 3");
  const region = page.getByRole("region", { name: "Storm session" });

  await expect(region.getByText("Storm · 20×10")).toBeVisible();
  const name = await region.getByText("Storm · 20×10").evaluate(e => e.scrollWidth <= e.clientWidth);
  expect(name).toBe(true);
  await expect(region.getByRole("button", { name: "Full screen" })).toBeInViewport({ ratio: 1 });
  const card = (await region.boundingBox())!;
  const button = (await region.getByRole("button", { name: "Full screen" }).boundingBox())!;
  expect(button.x + button.width).toBeLessThanOrEqual(card.x + card.width);
});

test("a session that goes away says so over its last screen", async ({ page }) => {
  let absent = false;
  const session = await hostSession(page, "\u001b[8;20;100t\u001b[?1049h" + past(1, 30) + "\u001b[20;1Hlast row");
  await expect(session.rows).toContainText("last row");
  await page.route(/\/api\/sessions\/Storm/, route => absent ? route.fulfill({ json: { state: "absent" } }) : route.fallback());
  absent = true;

  const message = page.getByText("No screen for this session.", { exact: false });
  await expect(message).toBeInViewport({ ratio: 1 });
  await expect(message).toBeVisible();
  const box = (await message.boundingBox())!;
  const last = (await session.rows.getByText("last row").boundingBox())!;
  expect(box.y + box.height).toBeGreaterThanOrEqual(last.y + last.height);
});

test("text on a screen whose CLI asked for the mouse can still be selected", async ({ page }) => {
  const session = await hostSession(page, "\u001b[8;10;60t\u001b[?1049h" + past(1, 5) + "\u001b[?1003h\u001b[?1006h\u001b[3;1Hselect me please");
  await expect(session.rows).toContainText("select me please");

  const text = (await session.rows.getByText("select me please").boundingBox())!;
  await page.mouse.move(text.x + 2, text.y + text.height / 2);
  await page.mouse.down();
  await page.mouse.move(text.x + text.width - 2, text.y + text.height / 2, { steps: 5 });
  await page.mouse.up();

  await expect(page.getByRole("region", { name: "Storm session" }).locator(".xterm-selection div")).not.toHaveCount(0);
});

test("what is typed into a focused session goes to its agent, in order", async ({ page }) => {
  const typed: string[] = [];
  const headers: Record<string, string>[] = [];
  const session = await hostSession(page, "\u001b[8;10;60t\u001b[?1004h" + lines(1, 3));
  await page.route("/api/sessions/Storm/input", async route => {
    headers.push(route.request().headers());
    typed.push(route.request().postData() ?? "");
    await new Promise(resolve => setTimeout(resolve, 50));
    await route.fulfill({ status: 204 });
  });
  await expect(session.rows).toContainText("line 3");

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();
  await page.keyboard.type("hello there");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Control+C");

  await expect.poll(() => typed.join("")).toBe("hello there\r\u0003");
  expect(headers.every(header => header["x-cerebro-input"] === "1")).toBe(true);
});

test("typing into a session scrolled back returns it to the bottom", async ({ page }) => {
  const session = await hostSession(page);
  await page.route("/api/sessions/Storm/input", route => route.fulfill({ status: 204 }));
  const follow = page.getByRole("switch", { name: "Follow new output" });
  await expect(session.rows).toContainText("line 50");
  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").hover();
  await page.mouse.wheel(0, -2000);
  await expect(follow).not.toBeChecked();

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();
  await page.keyboard.type("x");

  await expect(follow).toBeChecked();
  await expect(session.rows).toContainText("line 50");
});

test("what the screen answers the CLI's queries is not typed into the agent", async ({ page }) => {
  const typed: string[] = [];
  await page.route("/api/sessions/Storm/input", route => { typed.push(route.request().postData() ?? ""); return route.fulfill({ status: 204 }); });
  const session = await hostSession(page, "\u001b[8;10;60t\u001b[6n\u001b[c\u001b[>c\u001b[5n\u001b]11;?\u0007\u001b[?2004$p" + lines(1, 3));
  await expect(session.rows).toContainText("line 3");
  session.append("\u001b[6n" + lines(4, 4));
  await expect(session.rows).toContainText("line 4");

  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();
  await page.keyboard.type("x");
  await page.waitForTimeout(700);

  expect(typed.join("")).toBe("x");
});

test("a long paste is typed in pieces, in order, and what is refused says so", async ({ page }) => {
  const typed: string[] = [];
  let refuse = false;
  const session = await hostSession(page, "\u001b[8;10;60t" + lines(1, 3));
  await page.route("/api/sessions/Storm/input", route => {
    typed.push(route.request().postData() ?? "");
    return route.fulfill({ status: refuse ? 503 : 204 });
  });
  await expect(session.rows).toContainText("line 3");
  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();
  const text = "é".repeat(50_000) + "end";

  await page.evaluate(text => {
    const event = new ClipboardEvent("paste", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
    event.clipboardData!.setData("text/plain", text);
    document.querySelector(".xterm-helper-textarea")!.dispatchEvent(event);
  }, text);

  await expect.poll(() => typed.join("")).toBe(text);
  expect(typed.length).toBeGreaterThan(1);
  expect(typed.every(body => new TextEncoder().encode(body).length <= 64 * 1024)).toBe(true);
  await expect(page.getByRole("status").filter({ hasText: "Not typed" })).toHaveCount(0);

  refuse = true;
  await page.keyboard.type("x");
  await expect(page.getByRole("status").filter({ hasText: "Not typed" })).toBeVisible();
});

test("a paste whose piece is refused sends none of the rest of it", async ({ page }) => {
  const typed: string[] = [];
  const session = await hostSession(page, "\u001b[8;10;60t" + lines(1, 3));
  await page.route("/api/sessions/Storm/input", route => {
    typed.push(route.request().postData() ?? "");
    return route.fulfill({ status: typed.length === 2 ? 503 : 204 });
  });
  await expect(session.rows).toContainText("line 3");
  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();

  await page.evaluate(text => {
    const event = new ClipboardEvent("paste", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
    event.clipboardData!.setData("text/plain", text);
    document.querySelector(".xterm-helper-textarea")!.dispatchEvent(event);
  }, "x".repeat(200_000));
  await expect(page.getByRole("status").filter({ hasText: "Not typed" })).toBeVisible();
  await page.keyboard.type("after");

  await expect.poll(() => typed.slice(2).join("")).toBe("after");
});

test("what is typed while a refused paste is still going out goes with the paste's rest", async ({ page }) => {
  const typed: string[] = [];
  let answer: (() => void) | undefined;
  const session = await hostSession(page, "\u001b[8;10;60t" + lines(1, 3));
  await page.route("/api/sessions/Storm/input", async route => {
    typed.push(route.request().postData() ?? "");
    if (typed.length === 1) await new Promise<void>(resolve => { answer = resolve; });
    return route.fulfill({ status: typed.length === 1 ? 503 : 204 });
  });
  await expect(session.rows).toContainText("line 3");
  await page.getByRole("region", { name: "Storm session" }).locator(".xterm-screen").click();
  await page.evaluate(text => {
    const event = new ClipboardEvent("paste", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
    event.clipboardData!.setData("text/plain", text);
    document.querySelector(".xterm-helper-textarea")!.dispatchEvent(event);
  }, "x".repeat(100_000));
  await expect.poll(() => answer).toBeDefined();
  await page.keyboard.type("y");
  answer!();
  await expect(page.getByRole("status").filter({ hasText: "Not typed" })).toBeVisible();

  await page.keyboard.type("z");
  await expect.poll(() => typed.slice(1).join("")).toBe("z");
});

type Asked = { path: string; header: string | null };

/// A fleet, a fleet view that does or does not supervise it, and a record of what was asked of it.
async function controlled(page: import("@playwright/test").Page, agents: object[], supervised = true, reply = (path: string) => ({ done: true, text: `did ${path}` })) {
  const asked: Asked[] = [];
  await page.route("/api/fleet", (route) => route.fulfill({ json: { state: "fresh", value: agents } }));
  await page.route("/api/control", (route) => route.fulfill({ json: { supervised } }));
  await page.route(/\/api\/sessions\//, (route) => route.fulfill({ json: { state: "absent" } }));
  await page.route(/\/api\/agents\//, (route) => {
    const path = new URL(route.request().url()).pathname;
    asked.push({ path, header: route.request().headers()["x-cerebro-input"] ?? null });
    return route.fulfill({ json: reply(path) });
  });
  await page.goto("/");
  return asked;
}

const storm = { name: "Storm", role: "producer", state: "Working", bead: "cb-1" };
const moira = { name: "Moira", role: "user-feedback", state: "Standby" };

test("the action bar asks the supervising fleet view, and says what it answered", async ({ page }) => {
  const asked = await controlled(page, [storm], true, () => ({ done: true, text: "Storm will finish after this pass." }));
  await expect(page.getByText("Supervised")).toBeVisible();

  await page.getByRole("toolbar", { name: "Storm actions" }).getByRole("button", { name: /Finish after this pass/ }).click();

  await expect(page.getByRole("status", { name: "Action result" })).toHaveText("Storm will finish after this pass.");
  expect(asked).toEqual([{ path: "/api/agents/Storm/finish", header: "1" }]);
});

test("a kill asks first, names the bead, and y confirms it", async ({ page }) => {
  const asked = await controlled(page, [storm]);
  await expect(page.getByRole("toolbar", { name: "Storm actions" })).toBeVisible();

  await page.keyboard.press("k");
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Kill Storm?");
  await expect(dialog).toContainText("Its bead cb-1 stays claimed.");
  expect(asked).toEqual([]);
  await page.keyboard.press("y");

  await expect(dialog).toBeHidden();
  await expect.poll(() => asked.map(item => item.path)).toEqual(["/api/agents/Storm/kill"]);
});

test("a cancelled kill asks nothing of the fleet view", async ({ page }) => {
  const asked = await controlled(page, [storm]);
  await page.getByRole("toolbar", { name: "Storm actions" }).getByRole("button", { name: /Kill/ }).click();
  await expect(page.getByRole("dialog")).toBeVisible();

  await page.keyboard.press("Escape");

  await expect(page.getByRole("dialog")).toBeHidden();
  await page.waitForTimeout(300);
  expect(asked).toEqual([]);
});

test("keys typed into a session are the session's, not the page's", async ({ page }) => {
  const asked = await controlled(page, [storm]);
  const typed: string[] = [];
  await page.route("/api/sessions/Storm/input", async (route) => { typed.push(route.request().postData() ?? ""); await route.fulfill({ status: 204 }); });
  await page.route(/\/api\/sessions\/Storm(\?|$)/, (route) => route.fulfill({ json: { state: "live", log: "Storm.1-0-0.log", reset: true, data: "\u001b[8;5;40tready", offset: 21, more: false } }));
  await page.reload();
  const region = page.getByRole("region", { name: "Storm session" });
  await expect(region.locator(".xterm-rows")).toContainText("ready");

  await region.locator(".xterm-screen").click();
  await page.keyboard.press("f");

  await expect.poll(() => typed.join("")).toBe("f");
  expect(asked).toEqual([]);
});

test("⌘K finds any action on any agent", async ({ page }) => {
  const asked = await controlled(page, [storm, moira]);
  await expect(page.getByRole("toolbar", { name: "Storm actions" })).toBeVisible();

  await page.keyboard.press("Meta+k");
  const palette = page.getByRole("listbox", { name: "Actions" });
  await expect(palette.getByRole("option", { name: /Kill Storm/ })).toBeVisible();
  await page.getByRole("combobox", { name: "Find an action" }).fill("disarm");
  await expect(palette.getByRole("option")).toHaveText([/Disarm Moira/]);
  await page.keyboard.press("Enter");

  await expect(page.getByRole("dialog")).toContainText("Disarm Moira?");
  await page.getByRole("button", { name: /Disarm Moira/ }).click();
  await expect.poll(() => asked.map(item => item.path)).toEqual(["/api/agents/Moira/disarm"]);
  await expect(page.getByRole("heading", { level: 2, name: "Moira" })).toBeVisible();
});

test("with no fleet view supervising, nothing can be done and the page says why", async ({ page }) => {
  const asked = await controlled(page, [storm], false);
  const toolbar = page.getByRole("toolbar", { name: "Storm actions" });

  await expect(page.getByText("Read-only")).toBeVisible();
  await expect(toolbar.getByRole("button", { name: /Kill/ })).toBeDisabled();
  await page.keyboard.press("f");

  await expect(page.getByRole("status", { name: "Action result" })).toContainText("No fleet view is supervising");
  expect(asked).toEqual([]);
});

test("an agent that will finish after this pass says so and can be kept going", async ({ page }) => {
  const asked = await controlled(page, [{ ...storm, finishing: true }]);
  await expect(page.getByText("Storm will stop when this pass ends")).toBeVisible();
  await expect(page.getByRole("toolbar", { name: "Storm actions" }).getByRole("button", { name: /Keep going/ })).toBeVisible();

  await page.getByRole("button", { name: "Keep it running" }).click();

  await expect.poll(() => asked.map(item => item.path)).toEqual(["/api/agents/Storm/resume"]);
});

test("an agent that is not running can be started", async ({ page }) => {
  const asked = await controlled(page, [{ name: "Rogue", role: "producer", state: "Dead" }]);

  await page.getByRole("toolbar", { name: "Rogue actions" }).getByRole("button", { name: /Start/ }).click();

  await expect.poll(() => asked.map(item => item.path)).toEqual(["/api/agents/Rogue/start"]);
});

test("a supervision answer that could not be read is asked again", async ({ page }) => {
  const readable = Date.now() + 1500;
  await page.route("/api/fleet", (route) => route.fulfill({ json: { state: "fresh", value: [storm] } }));
  await page.route(/\/api\/sessions\//, (route) => route.fulfill({ json: { state: "absent" } }));
  await page.route("/api/control", (route) => route.fulfill({ json: Date.now() < readable ? { supervised: false, error: "unreadable" } : { supervised: true } }));
  await page.goto("/");
  await expect(page.getByText("Read-only")).toBeVisible();

  await expect(page.getByText("Supervised")).toBeVisible({ timeout: 8000 });
});
