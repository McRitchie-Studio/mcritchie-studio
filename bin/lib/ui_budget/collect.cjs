// UI budget collector: measures public production pages signed out and writes
// the raw numbers as JSON. It judges nothing; bin/lib/ui_budget.rb holds the
// ceilings (config/ui_budget.yml) and the verdicts. Called by `bin/ui-budget
// --collect`; by hand:
//
//   node bin/lib/ui_budget/collect.cjs --out results.json --widths 390,1280 <url>...
//
// Method (the platform audit's browser evidence, 2026-10-24): headless Chromium
// from the hub's own @playwright/test, a fresh context per page and width, no
// cookies, a user agent marked `ui-budget`, dark scheme, `networkidle`. Bytes are
// encoded (request.sizes().responseBodySize) except the document, which is also
// read raw. axe-core is injected from node_modules, never from a CDN.
const { chromium } = require("@playwright/test");
const fs = require("fs");
const path = require("path");

const AXE_PATH = require.resolve("axe-core/axe.min.js");
const AXE_TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"];
const UA_MARK = "ui-budget";
const ONE_YEAR = 31536000;
const NAV_TIMEOUT_MS = 45000;

function parseArgs(argv) {
  const out = { urls: [], widths: [390, 1280], outPath: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--out") out.outPath = argv[++i];
    else if (a === "--widths") out.widths = argv[++i].split(",").map(Number);
    else if (a.startsWith("--")) throw new Error(`unknown flag ${a}`);
    else out.urls.push(a);
  }
  if (!out.outPath || out.urls.length === 0 || out.widths.some((w) => !(w > 0))) {
    throw new Error("usage: collect.cjs --out <file> [--widths 390,1280] <url>...");
  }
  return out;
}

function typeOf(resp) {
  const ct = (resp.headers()["content-type"] || "").split(";")[0].trim();
  const u = resp.url();
  if (ct.includes("javascript") || /\.m?js(\?|$)/.test(u)) return "js";
  if (ct.includes("css")) return "css";
  if (ct.startsWith("image/")) return "img";
  if (ct.includes("font") || /\.woff2?(\?|$)/.test(u)) return "font";
  if (ct.includes("html")) return "html";
  return "other";
}

function maxAge(cacheControl) {
  const m = /(?:^|,)\s*max-age=(\d+)/i.exec(cacheControl || "");
  return m ? Number(m[1]) : null;
}

async function measure(browser, url, width, userAgent) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 }, userAgent, colorScheme: "dark" });
  const page = await ctx.newPage();
  const pageHost = new URL(url).host;
  const pending = [];
  const reqs = [];
  page.on("requestfinished", (req) => {
    pending.push((async () => {
      const resp = await req.response();
      if (!resp) return;
      const sizes = await req.sizes().catch(() => null);
      const u = new URL(resp.url());
      // An <img> reports the URL it asked for, not where a redirect landed
      // (Active Storage 302s to R2), so keep every hop to match it by.
      const aliases = [];
      for (let r = req.redirectedFrom(); r; r = r.redirectedFrom()) aliases.push(r.url());
      reqs.push({
        url: resp.url(), aliases, host: u.host, pathname: u.pathname, type: typeOf(resp),
        bytes: sizes ? sizes.responseBodySize : 0, maxAge: maxAge(resp.headers()["cache-control"]),
      });
    })().catch(() => {}));
  });

  const result = { url, width, status: null, error: null, warnings: [], metrics: {}, detail: {} };
  let doc = null;
  try {
    doc = await page.goto(url, { waitUntil: "networkidle", timeout: NAV_TIMEOUT_MS });
  } catch (e) {
    // A page that never goes quiet (a poller, a socket) still rendered; measure
    // what arrived and say so. A page that never answered is an error.
    if (/Timeout/i.test(String(e)) && page.url() !== "about:blank") result.warnings.push("networkidle not reached in 45s");
    else result.error = String(e).split("\n")[0].slice(0, 200);
  }
  if (result.error) { await ctx.close(); return result; }
  result.status = doc ? doc.status() : null;
  if (doc && doc.status() >= 400) { result.error = `HTTP ${doc.status()}`; await ctx.close(); return result; }

  const htmlRaw = doc ? (await doc.body().catch(() => Buffer.alloc(0))).length : null;

  const images = await page.evaluate(() => Array.from(document.images).map((img) => {
    const box = img.getBoundingClientRect();
    return { src: img.currentSrc || img.src, naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight,
      renderedWidth: Math.round(box.width), renderedHeight: Math.round(box.height), fit: getComputedStyle(img).objectFit };
  })).catch(() => []);

  let axe = null;
  try {
    await page.addScriptTag({ path: AXE_PATH });
    axe = await page.evaluate(async (tags) => {
      const r = await window.axe.run(document, { resultTypes: ["violations"], runOnly: { type: "tag", values: tags } });
      return r.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length }));
    }, AXE_TAGS);
  } catch (e) {
    result.warnings.push("axe did not run: " + String(e).split("\n")[0].slice(0, 160));
  }

  await Promise.allSettled(pending);
  await ctx.close();

  const sum = (rows) => rows.reduce((a, r) => a + r.bytes, 0);
  const byType = {};
  for (const r of reqs) byType[r.type] = (byType[r.type] || 0) + r.bytes;
  const thirdPartyJs = reqs.filter((r) => r.type === "js" && r.host !== pageHost);
  const assets = reqs.filter((r) => r.host === pageHost && r.pathname.startsWith("/assets/"));
  const cachedYear = assets.filter((r) => r.maxAge !== null && r.maxAge >= ONE_YEAR);

  // The largest image is the heaviest <img> on the wire that rendered with a
  // box. Its ratio is natural over rendered pixels at device scale 1: the larger
  // axis ratio for fill and contain, the smaller for cover, which crops the
  // other axis (hub's hero is 4700x1800 in a 507x720 box at 390px: 2.5x, not 9.3x).
  const imgBytes = {};
  for (const r of reqs) if (r.type === "img") for (const u of [r.url, ...r.aliases]) imgBytes[u] = Math.max(imgBytes[u] || 0, r.bytes);
  const sized = images
    .filter((i) => i.naturalWidth > 0 && i.renderedWidth > 0 && i.renderedHeight > 0)
    .map((i) => ({ ...i, bytes: imgBytes[i.src] || 0,
      ratio: (i.fit === "cover" ? Math.min : Math.max)(i.naturalWidth / i.renderedWidth, i.naturalHeight / i.renderedHeight) }))
    .sort((a, b) => b.bytes - a.bytes);
  const largest = sized[0] || null;

  result.metrics = {
    axe_serious_critical: axe ? axe.filter((v) => v.impact === "serious" || v.impact === "critical").reduce((a, v) => a + v.nodes, 0) : null,
    js_bytes: byType.js || 0,
    third_party_js_bytes: sum(thirdPartyJs),
    total_bytes: sum(reqs),
    largest_image_ratio: largest ? Math.round(largest.ratio * 100) / 100 : null,
    html_raw_bytes: htmlRaw,
    css_bytes: byType.css || 0,
    assets_cached_one_year_pct: assets.length ? Math.round((cachedYear.length / assets.length) * 1000) / 10 : null,
  };
  result.detail = {
    bytes_by_type: byType,
    requests: reqs.length,
    assets: assets.length,
    assets_cached_one_year: cachedYear.length,
    third_party_js_hosts: [...new Set(thirdPartyJs.map((r) => r.host))].sort(),
    largest_image: largest && { src: largest.src.slice(0, 200), bytes: largest.bytes,
      natural: `${largest.naturalWidth}x${largest.naturalHeight}`, rendered: `${largest.renderedWidth}x${largest.renderedHeight}`, object_fit: largest.fit },
    axe_violations: axe,
  };
  return result;
}

(async () => {
  const args = parseArgs(process.argv.slice(2));
  const browser = await chromium.launch({ headless: true });
  const userAgent = (await browser.newContext().then(async (c) => {
    const p = await c.newPage(); const ua = await p.evaluate(() => navigator.userAgent); await c.close(); return ua;
  })).replace("HeadlessChrome", "Chrome") + ` ${UA_MARK}`;
  const results = [];
  for (const url of args.urls) {
    for (const width of args.widths) {
      const r = await measure(browser, url, width, userAgent);
      results.push(r);
      console.error(`ui-budget: ${width}px ${r.status || "-"} ${r.error ? "ERROR " + r.error : Math.round(r.metrics.total_bytes / 1024) + "KB"} ${url}`);
    }
  }
  await browser.close();
  const pkg = (name) => JSON.parse(fs.readFileSync(require.resolve(`${name}/package.json`), "utf8")).version;
  const out = { collected_at: new Date().toISOString(), user_agent: userAgent,
    tools: { playwright: pkg("@playwright/test"), axe_core: pkg("axe-core"), axe_tags: AXE_TAGS }, results };
  fs.mkdirSync(path.dirname(path.resolve(args.outPath)), { recursive: true });
  fs.writeFileSync(args.outPath, JSON.stringify(out, null, 1));
})().catch((e) => { console.error("ui-budget collector: " + (e && e.stack || e)); process.exit(2); });
