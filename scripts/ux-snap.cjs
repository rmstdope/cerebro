// The renderer behind scripts/ux-snap (cb-6bgn); run only by it:
//
//     node ux-snap.cjs <modules-dir> <out-dir> <widths> <url>...
//
// exit 0 clean, 3 at least one finding, 4 Playwright's browser is not installed, 1 anything else.
// CommonJS so Playwright can be resolved from a directory that is not this file's own.
"use strict";

const path = require("path");
const { createRequire } = require("module");

const [modulesDir, outDir, widthsArg, ...urls] = process.argv.slice(2);
const widths = widthsArg.split(",").map(Number);
const PHONE_MAX = 600;

function loadChromium() {
  const req = createRequire(path.join(modulesDir, "noop.js"));
  for (const m of ["playwright", "@playwright/test", "playwright-core"]) {
    try {
      const mod = req(m);
      if (mod && mod.chromium) return mod.chromium;
    } catch (e) {
      // try the next name
    }
  }
  throw new Error(`no Playwright resolves from ${modulesDir}`);
}

function slug(url) {
  const base = decodeURIComponent(url.replace(/[?#].*$/, "").replace(/\/+$/, "")).split("/").pop() || "page";
  return base.replace(/\.[a-z0-9]+$/i, "").replace(/[^a-zA-Z0-9_-]+/g, "-").slice(0, 60) || "page";
}

// In the page: what passes the right edge, and which images did not load.
function inspectPage() {
  const vw = window.innerWidth;
  const sw = document.documentElement.scrollWidth;
  const name = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += "#" + el.id;
    if (typeof el.className === "string" && el.className.trim()) {
      s += "." + el.className.trim().split(/\s+/).slice(0, 2).join(".");
    }
    return s;
  };
  const wide = [];
  if (sw > vw) {
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.right > vw + 0.5) wide.push({ name: name(el), width: Math.round(r.width), right: Math.round(r.right) });
    }
    wide.sort((a, b) => b.width - a.width);
  }
  const broken = [];
  for (const img of document.images) {
    if (img.complete && img.naturalWidth === 0) broken.push(img.currentSrc || img.src || name(img));
  }
  return { vw, sw, wide: wide.slice(0, 3), broken };
}

async function renderOne(browser, url, width, index) {
  const height = width <= PHONE_MAX ? 844 : 800;
  const context = await browser.newContext({ viewport: { width, height } });
  const page = await context.newPage();
  const findings = [];
  const brokenUrls = new Set();
  page.on("console", (msg) => {
    if (msg.type() === "error") findings.push(`console error: ${msg.text()}`);
  });
  page.on("pageerror", (err) => findings.push(`console error: uncaught ${err.message}`));
  page.on("requestfailed", (req) => {
    if (req.resourceType() === "image") brokenUrls.add(req.url());
  });
  page.on("response", (res) => {
    if (res.request().resourceType() === "image" && res.status() >= 400) brokenUrls.add(res.url());
  });

  const png = path.join(outDir, `${index}-${slug(url)}-${width}.png`);
  try {
    await page.goto(url, { waitUntil: "load", timeout: 30000 });
    await page.waitForLoadState("networkidle", { timeout: 3000 }).catch(() => {});
    const seen = await page.evaluate(inspectPage);
    if (seen.sw > seen.vw) {
      const who = seen.wide.map((w) => `${w.name} ${w.width}px`).join(", ") || "no single element";
      findings.push(`overflow: page is ${seen.sw}px wide at ${seen.vw}px (widest: ${who})`);
    }
    for (const src of seen.broken) brokenUrls.add(src);
    await page.screenshot({ path: png, fullPage: true });
  } catch (err) {
    findings.push(`load failed: ${String(err.message || err).split("\n")[0]}`);
  }
  for (const src of brokenUrls) findings.push(`broken image: ${src}`);
  await context.close();
  return { png, findings };
}

async function main() {
  let chromium;
  try {
    chromium = loadChromium();
  } catch (err) {
    console.error(`ux-snap: ${err.message}`);
    return 1;
  }
  let browser;
  try {
    browser = await chromium.launch();
  } catch (err) {
    const msg = String(err.message || err);
    if (/Executable doesn't exist|playwright install/i.test(msg)) return 4;
    console.error(`ux-snap: the browser would not start: ${msg.split("\n")[0]}`);
    return 1;
  }
  let renders = 0;
  let total = 0;
  try {
    let index = 0;
    for (const url of urls) {
      index += 1;
      for (const width of widths) {
        const { png, findings } = await renderOne(browser, url, width, index);
        renders += 1;
        total += findings.length;
        const verdict = findings.length === 0 ? "ok" : `${findings.length} finding(s)`;
        console.log(`${url} @${width}  ${png}  ${verdict}`);
        for (const f of findings) console.log(`    ${f}`);
      }
    }
  } finally {
    await browser.close();
  }
  console.log(`ux-snap: ${renders} render(s), ${total} finding(s); PNGs in ${outDir}`);
  return total === 0 ? 0 : 3;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(`ux-snap: ${err && err.stack ? err.stack : err}`);
    process.exit(1);
  },
);
