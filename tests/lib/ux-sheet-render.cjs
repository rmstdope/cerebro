// The browser half of tests/ux-sheet-render:
//     node ux-sheet-render.cjs <modules-dir> <four-option page> <its kept copy, agreed D>
"use strict";

const assert = require("assert/strict");
const path = require("path");
const { createRequire } = require("module");
const { pathToFileURL } = require("url");

const [modulesDir, page4, kept] = process.argv.slice(2);
const req = createRequire(path.join(modulesDir, "noop.js"));
const { chromium } = (() => {
  for (const m of ["playwright", "@playwright/test", "playwright-core"]) {
    try {
      return req(m);
    } catch (e) {
      // try the next name
    }
  }
  throw new Error(`no Playwright resolves from ${modulesDir}`);
})();

const ok = (name) => console.log(`ok - ${name}`);

// Which drawings are on screen, and which tab says it is selected.
const state = (page) =>
  page.evaluate(() => ({
    shown: [...document.querySelectorAll(".ux-panel")].filter((p) => p.offsetParent !== null).map((p) => p.id),
    selected: [...document.querySelectorAll('.ux-tab[aria-selected="true"]')].map((t) => t.dataset.uxTab),
  }));
const only = (letter) => ({ shown: [`ux-panel-${letter}`], selected: [letter] });

// The tab row's overflow, the faded edges, and where the selected tab sits in the row.
const row = (page) =>
  page.evaluate(() => {
    const r = document.querySelector(".ux-tabs");
    const wrap = r.parentNode;
    const box = r.getBoundingClientRect();
    const sel = r.querySelector('[aria-selected="true"]').getBoundingClientRect();
    const tabs = [...r.children].map((t) => t.getBoundingClientRect());
    return {
      scrolls: r.scrollWidth > r.clientWidth,
      oneLine: tabs.every((t) => t.top === tabs[0].top && t.height === tabs[0].height && t.height < 50),
      whole: [...r.children].every((t) => t.scrollWidth <= t.clientWidth + 1),
      left: getComputedStyle(wrap, "::before").opacity,
      right: getComputedStyle(wrap, "::after").opacity,
      selectedInView: sel.left >= box.left - 1 && sel.right <= box.right + 1,
      pageWidth: document.documentElement.scrollWidth,
      scrollY: window.scrollY,
    };
  });

async function main() {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => m.type() === "error" && errors.push(m.text()));

    await page.goto(pathToFileURL(page4).href);
    assert.deepEqual(await state(page), only("A"));
    ok("a page opens on A, not on the recommended option");

    await page.click('.ux-tab[data-ux-tab="C"]');
    assert.deepEqual(await state(page), only("C"));
    ok("a clicked tab is the one drawing on screen, whatever the drawing's own rules say");

    await page.keyboard.press("ArrowRight");
    assert.deepEqual(await state(page), only("D"));
    assert.equal(await page.evaluate(() => document.activeElement.dataset.uxTab), "D");
    await page.keyboard.press("ArrowRight");
    assert.deepEqual(await state(page), only("A"));
    await page.keyboard.press("ArrowLeft");
    assert.deepEqual(await state(page), only("D"));
    await page.keyboard.press("Shift+ArrowLeft");
    assert.deepEqual(await state(page), only("D"));
    ok("the arrow keys move between tabs, wrap, and carry the focus");

    await page.goto(pathToFileURL(page4).href);
    await page.keyboard.press("ArrowRight");
    assert.deepEqual(await state(page), only("B"));
    assert.equal(await page.evaluate(() => document.activeElement === document.body), true);
    await page.keyboard.press("ArrowLeft");
    await page.focus("#field");
    await page.keyboard.press("ArrowRight");
    assert.deepEqual(await state(page), only("A"));
    ok("the arrows work with nothing focused, and a drawing's text field keeps its own");

    await page.click('.ux-tab[data-ux-tab="C"]');
    await page.reload();
    assert.deepEqual(await state(page), only("A"));
    ok("a reload goes back to A");

    assert.equal((await row(page)).scrolls, false);
    assert.equal((await row(page)).right, "0");

    const phone = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    phone.on("pageerror", (e) => errors.push(e.message));
    await phone.goto(pathToFileURL(page4).href);
    let r = await row(phone);
    assert.equal(r.scrolls, true);
    assert.equal(r.oneLine, true);
    assert.equal(r.whole, true);
    assert.equal(r.pageWidth, 390);
    assert.deepEqual([r.left, r.right], ["0", "1"]);
    await phone.evaluate(() => {
      const t = document.querySelector(".ux-tabs");
      t.scrollLeft = t.scrollWidth;
    });
    await phone.waitForFunction(() => document.querySelector(".ux-tabrow").classList.contains("ux-more-left"));
    r = await row(phone);
    assert.deepEqual([r.left, r.right], ["1", "0"]);
    ok("four long tabs on a phone scroll sideways, whole and on one line, with a faded edge where there are more");

    await phone.goto(pathToFileURL(kept).href);
    assert.deepEqual(await state(phone), only("D"));
    r = await row(phone);
    assert.equal(r.selectedInView, true);
    assert.equal(r.scrollY, 0);
    ok("the kept copy opens on the agreed option, its tab scrolled into view");

    assert.deepEqual(errors, []);
    ok("no script error");
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(`FAIL: ${e.message}`);
  process.exit(1);
});
