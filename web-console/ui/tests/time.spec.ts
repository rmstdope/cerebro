import { type Page, type Route, expect, test } from "@playwright/test";

// The Time tab (cb-koio.2), against a /api/time this file answers: every spec routes it itself,
// so nothing here reads the checkout's own records.

const H = 3600;
type Activity = { name: string; seconds: number };
type Phase = { name: string; working: number; waiting: number; activities: Activity[]; undetailed_before: number; undetailed: number };
type AgentTime = { name: string; working: number; waiting: number; sessions: number; phases: Phase[] };
type Role = { name: string; working: number; waiting: number; sessions: number; agents: AgentTime[] };

const phase = (name: string, working: number, waiting = 0, activities: [string, number][] = [], undetailedBefore = 0): Phase => ({
  name, working: working * H, waiting: waiting * H, activities: activities.map(([name, hours]) => ({ name, seconds: hours * H })),
  undetailed_before: undetailedBefore * H, undetailed: 0,
});
const agent = (name: string, sessions: number, phases: Phase[]): AgentTime => ({
  name, sessions, phases,
  working: phases.reduce((sum, item) => sum + item.working, 0), waiting: phases.reduce((sum, item) => sum + item.waiting, 0),
});
const role = (name: string, agents: AgentTime[]): Role => ({
  name, agents, sessions: agents.reduce((sum, item) => sum + item.sessions, 0),
  working: agents.reduce((sum, item) => sum + item.working, 0), waiting: agents.reduce((sum, item) => sum + item.waiting, 0),
});
/// One agent of ROLE with HOURS of work and WAITING of it waiting on the navigator.
const solo = (name: string, hours: number, waiting = 0) => role(name, [agent(`${name}-1`, 2, [phase("sweep", hours - waiting, waiting)])]);

const cyclops = agent("Cyclops", 12, [
  phase("build", 11, 0, [["editing code", 6], ["running tests", 4], ["reading", 1]]),
  phase("ci", 5),
  phase("design", 3, 1),
  phase("review", 1, 2),
  phase("merge", 2),
]);
const producer = role("producer", [
  cyclops,
  agent("Storm", 6, [phase("build", 6, 3)]),
  agent("Wolverine", 3, [phase("build", 2.5, 2.5)]),
  agent("Rogue", 2, [phase("build", 1.5, 0.5)]),
]);
const fleet = (): Role[] => [producer, solo("orchestrator", 22, 4), solo("ux", 12, 3), solo("verifier", 6, 1), solo("bugfixer", 5, 1), solo("qa", 4), solo("architect", 3)];
const report = (roles: Role[], detailFrom: string | null = "2026-10-27T09:00:00Z") => ({ read_at: "2026-11-20T10:42:00Z", detail_from: detailFrom, roles });

/// Answers /api/time with ANSWER for the period asked, and counts the asks.
async function serve(page: Page, answer: (period: string) => object | number) {
  const asked: string[] = [];
  await page.route(/\/api\/time(\?|$)/, (route: Route) => {
    const period = new URL(route.request().url()).searchParams.get("period") ?? "";
    asked.push(period);
    const body = answer(period);
    return typeof body === "number" ? route.fulfill({ status: body, json: { error: "unreadable" } }) : route.fulfill({ json: body });
  });
  return asked;
}

async function openTime(page: Page) {
  await page.goto("/");
  await page.getByRole("navigation", { name: "Console sections" }).getByRole("button", { name: "time" }).click();
}

const map = (page: Page) => page.getByRole("group", { name: "Time map" });
const tile = (page: Page, name: string | RegExp) => map(page).getByRole("button", { name });
const area = async (page: Page, name: string) => {
  const box = (await tile(page, name).boundingBox())!;
  return box.width * box.height;
};

test("opens the Time tab and draws one tile per role sized by time", async ({ page }) => {
  const asked = await serve(page, () => report(fleet()));
  await openTime(page);

  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles");
  await expect(page.getByRole("radio", { name: "7 days" })).toBeChecked();
  expect(asked).toContain("7d");
  await expect(page.getByText("93 h in all · 18 h of it waiting on you (grey)")).toBeVisible();
  for (const name of ["producer", "orchestrator", "ux", "verifier", "bugfixer", "qa", "architect"]) await expect(tile(page, new RegExp(`^${name},`))).toBeVisible();
  expect(await area(page, "producer, 41 h")).toBeGreaterThan(await area(page, "orchestrator, 22 h"));
  expect(await area(page, "orchestrator, 22 h")).toBeGreaterThan(await area(page, "ux, 12 h"));
  await expect(tile(page, "producer, 41 h")).toHaveAttribute("aria-current", "true");
});

test("clicks down to an agent's phases and back by the path", async ({ page }) => {
  await serve(page, () => report(fleet()));
  await openTime(page);

  await tile(page, "producer, 41 h").click();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer");
  await expect(page.getByText("41 h in all · 9 h of it waiting on you (grey)")).toBeVisible();
  await tile(page, /^Cyclops,/).click();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer›Cyclops");
  const build = tile(page, /^build,/);
  await expect(build).toContainText("· editing code 6 h");
  await expect(build).toContainText("· running tests 4 h");
  await expect(build).toContainText("· reading 1 h");
  await expect(tile(page, /^waiting on CI,/)).toBeVisible();

  await page.getByRole("navigation", { name: "Path" }).getByRole("button", { name: "producer" }).click();
  await expect(tile(page, /^Storm,/)).toBeVisible();
  await page.getByRole("navigation", { name: "Path" }).getByRole("button", { name: "All roles" }).click();
  await expect(tile(page, /^ux,/)).toBeVisible();
});

test("shows the waiting band and the pointing box", async ({ page }) => {
  await serve(page, () => report(fleet()));
  await openTime(page);

  await expect(tile(page, "producer, 41 h").locator(".band")).toHaveText("9 h waiting on you");
  await expect(tile(page, /^qa,/).locator(".band")).toHaveCount(0);
  await tile(page, "producer, 41 h").hover();
  const box = page.getByRole("tooltip");
  await expect(box).toContainText("producer");
  await expect(box).toContainText("41 h · 44% of all time");
  await expect(box).toContainText("32 h working · 9 h waiting on you");
  await expect(box).toContainText("4 agents · 23 sessions");
  await expect(box).toContainText("Click to see its agents");

  await tile(page, "producer, 41 h").click();
  await tile(page, /^Cyclops,/).click();
  await tile(page, /^build,/).hover();
  await expect(box).toContainText("11 h · 12% of all time");
  await expect(box).not.toContainText("Click to see");
});

test("notes a period before full detail", async ({ page }) => {
  const old = agent("Cyclops", 4, [phase("build", 30, 0, [["editing code", 5]], 25)]);
  await serve(page, period => period === "all" ? report([role("producer", [old])]) : report(fleet()));
  await openTime(page);
  await expect(page.getByText(/Full detail from/)).toHaveCount(0);

  await page.getByRole("radio", { name: "All" }).click();
  await expect(page.getByText("Full detail from 27 Oct. Before that, only which phase each agent was in is known.")).toBeVisible();
  await tile(page, /^producer,/).click();
  await tile(page, /^Cyclops,/).click();
  await expect(tile(page, /^build,/)).toContainText("· no detail (before 27 Oct) 25 h");
});

test("says when nothing ran in the period", async ({ page }) => {
  await serve(page, () => report([], null));
  await openTime(page);
  await page.getByRole("radio", { name: "24 hours" }).click();
  await expect(page.getByText("No agent ran in the last 24 hours.")).toBeVisible();
  await expect(page.getByText("Pick a longer period above.")).toBeVisible();
  await page.getByRole("radio", { name: "30 days" }).click();
  await expect(page.getByText("No agent ran in the last 30 days.")).toBeVisible();

  await page.getByRole("radio", { name: "All" }).click();
  await expect(page.getByText("Nothing has been recorded for this project yet. Time shows here once an agent has run.")).toBeVisible();
});

test("keeps the tiles and says when a read fails", async ({ page }) => {
  await serve(page, period => period === "30d" ? 502 : report(fleet()));
  await openTime(page);
  await expect(tile(page, "producer, 41 h")).toBeVisible();

  await page.getByRole("radio", { name: "30 days" }).click();
  const time = await page.evaluate(() => new Date("2026-11-20T10:42:00Z").toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }));
  await expect(page.getByRole("alert")).toHaveText(`Couldn't read the fleet's records just now. Showing what was read at ${time}. Trying again every minute.`);
  await expect(tile(page, "producer, 41 h")).toBeVisible();
});

test("says a failed first read without a time and draws nothing", async ({ page }) => {
  await serve(page, () => 502);
  await openTime(page);
  await expect(page.getByRole("alert")).toHaveText("Couldn't read the fleet's records just now. Trying again every minute.");
  await expect(map(page).getByRole("button")).toHaveCount(0);
});

// A service started before the Time tab existed has no /api/time: an older build answers with the
// page itself, a newer one with a 404. Either way retrying cannot help, so the page says what will.
for (const [how, answer] of [
  ["answers with the page", (route: Route) => route.fulfill({ contentType: "text/html", body: "<!doctype html><html></html>" })],
  ["has no such endpoint", (route: Route) => route.fulfill({ status: 404, json: { error: "this service has no such endpoint" } })],
] as const) {
  test(`says the service needs a restart when it ${how}`, async ({ page }) => {
    await page.route(/\/api\/time(\?|$)/, answer);
    await openTime(page);
    await expect(page.getByRole("alert")).toHaveText("The console's service is older than this page and has no time report. Restart cerebro-web; this tab reads it within a minute.");
    await expect(map(page).getByRole("button")).toHaveCount(0);
  });
}

test("gathers small tiles into Other", async ({ page }) => {
  const small = (name: string) => agent(name, 1, [phase("build", 0.2)]);
  const crowd = role("producer", [agent("Cyclops", 5, [phase("build", 26)]), agent("Storm", 4, [phase("build", 18)]), small("Iceman"), small("Gambit"), small("Bishop")]);
  await serve(page, () => report([crowd]));
  await openTime(page);
  await tile(page, /^producer,/).click();

  await expect(tile(page, /^Other · 3 agents,/)).toBeVisible();
  await expect(tile(page, /^Iceman,/)).toHaveCount(0);
  await tile(page, /^Other · 3 agents,/).click();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer›Other");
  await expect(tile(page, /^Iceman,/)).toBeVisible();
  await expect(tile(page, /^Bishop,/)).toBeVisible();
});

test("shows a list of bars below 600 px", async ({ page }) => {
  await page.setViewportSize({ width: 400, height: 800 });
  await serve(page, () => report(fleet()));
  await openTime(page);

  const rows = page.getByRole("list", { name: "Time list" }).getByRole("button");
  await expect(rows).toHaveCount(7);
  await expect(rows.nth(0)).toContainText("producer");
  await expect(rows.nth(0)).toContainText("41 h");
  await expect(rows.nth(1)).toContainText("orchestrator");
  await rows.nth(0).click();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer");
});

test("moves between tiles with the keyboard", async ({ page }) => {
  await serve(page, () => report(fleet()));
  await openTime(page);
  await expect(tile(page, "producer, 41 h")).toHaveAttribute("aria-current", "true");

  await page.keyboard.press("ArrowRight");
  await expect(tile(page, "producer, 41 h")).not.toHaveAttribute("aria-current", "true");
  await page.keyboard.press("ArrowLeft");
  await expect(tile(page, "producer, 41 h")).toHaveAttribute("aria-current", "true");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles");
  await expect(tile(page, "producer, 41 h")).toHaveAttribute("aria-current", "true");
});

test("remembers the period and the level across a reload", async ({ page }) => {
  await serve(page, () => report(fleet()));
  await openTime(page);
  await page.getByRole("radio", { name: "30 days" }).click();
  await tile(page, "producer, 41 h").click();
  await tile(page, /^Cyclops,/).click();

  await page.reload();

  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer›Cyclops");
  await expect(page.getByRole("radio", { name: "30 days" })).toBeChecked();
});

test("updates every minute without moving the reader", async ({ page }) => {
  await page.clock.install();
  let grown = false;
  await serve(page, () => report(grown ? [role("producer", [agent("Cyclops", 13, [...cyclops.phases.slice(1), phase("build", 15)])])] : fleet()));
  await openTime(page);
  await tile(page, "producer, 41 h").click();
  await tile(page, /^Cyclops,/).click();
  await expect(tile(page, /^build, 11 h/)).toBeVisible();

  grown = true;
  await page.clock.runFor(61_000);

  await expect(tile(page, /^build, 15 h/)).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer›Cyclops");
});

test("Enter on a focused period or path control does that control's work", async ({ page }) => {
  await serve(page, () => report(fleet()));
  await openTime(page);
  await tile(page, "producer, 41 h").click();

  await page.getByRole("radio", { name: "30 days" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("radio", { name: "30 days" })).toBeChecked();
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles›producer");

  await page.getByRole("navigation", { name: "Path" }).getByRole("button", { name: "All roles" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("navigation", { name: "Path" })).toHaveText("All roles");
});

test("pulses grey tiles while the first read runs, and keeps the old ones while a new period loads", async ({ page }) => {
  let release = () => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  await page.route(/\/api\/time(\?|$)/, async route => {
    const period = new URL(route.request().url()).searchParams.get("period");
    if (period === "7d") await held;
    if (period === "30d") return; // never answered: the old tiles must stay
    return route.fulfill({ json: report(fleet()) });
  });
  await openTime(page);

  await expect(map(page)).toHaveAttribute("aria-busy", "true");
  await expect(map(page).getByRole("button")).toHaveCount(0);
  release();
  await expect(tile(page, "producer, 41 h")).toBeVisible();
  await expect(map(page)).not.toHaveAttribute("aria-busy", "true");

  await page.getByRole("radio", { name: "30 days" }).click();
  await expect(page.getByRole("radio", { name: "30 days" })).toBeChecked();
  await expect(tile(page, "producer, 41 h")).toBeVisible();
});
