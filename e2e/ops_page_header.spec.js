const { test, expect } = require("@playwright/test");

// [e2e] The hub's ops pages on the engine page header (hub-ops-page-headers). Sticky
// ends where the row's parent ends, so each pin test puts a spacer after the page's
// last content block and reads the row after a 1500px scroll. Headless Chrome will not
// go below 500px, so phone tests emulate a 390px device and assert window.innerWidth.
// /stack and the Insight Bank use the admin session; /privacy runs signed out.

const PHONE = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 3 };

const sidewaysScroll = (page) => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);

// Puts a 3000px spacer after the last element matching `content`, in its parent, scrolls
// 1500px, and answers how far the row's top sits from its pinned place (0 when pinned).
async function pinGapAfterScroll(page, content) {
  const shared = await page.evaluate((selector) => {
    const blocks = document.querySelectorAll(selector);
    const last = blocks[blocks.length - 1];
    const spacer = document.createElement("div");
    spacer.style.height = "3000px";
    spacer.dataset.test = "pin-spacer";
    last.parentElement.insertBefore(spacer, last.nextSibling);
    return document.querySelector(".page-header").parentElement.contains(last);
  }, content);
  expect(shared, "the row and the page content share one container").toBe(true);
  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(1500);
  return page.evaluate(() => {
    const row = document.querySelector(".page-header");
    return Math.round(row.getBoundingClientRect().top - parseFloat(getComputedStyle(row).top));
  });
}

async function oneHeader(page, path, title) {
  await page.goto(path);
  const row = page.locator(".page-header");
  await expect(row).toHaveCount(1);
  await expect(page.locator("h1")).toHaveCount(1);
  await expect(row.locator("h1.page-header-title")).toHaveText(title);
  return row;
}

test("/stack at desktop: the trail reaches the Basement, and the row stays pinned after a 1500px scroll", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const row = await oneHeader(page, "/stack", "Every client's stack");
  await expect(row.locator(".page-header-crumbs li")).toHaveText(["Admin", "Basement", "Stack"]);
  expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  expect(await pinGapAfterScroll(page, "[data-test='stack-page'] > *")).toBe(0);
});

test("the Insight Bank at desktop: the header wears the dark surface's palette, and pins", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(() => localStorage.setItem("theme", "light"));
  const row = await oneHeader(page, "/devops/insights", "💡 Insight Bank");
  // The surface is fixed-dark on a light desktop: the title reads light on it.
  const colour = await row.locator("h1").evaluate((el) => getComputedStyle(el).color);
  expect(colour).toBe("rgb(230, 237, 243)");
  await expect(row.locator(".page-header-menu-button")).toHaveText(/Links/);
  expect(await pinGapAfterScroll(page, "#mason-insights > *")).toBe(0);
  // Once stuck (the controller sets data-stuck after the scroll; the fill fades in over
  // 150ms) the bar is the surface's own dark, not the light theme's surface.
  await expect(row).toHaveAttribute("data-stuck", /.*/);
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(13, 17, 23)");
});

test.describe("on a 390px phone", () => {
  test.use(PHONE);

  test("/stack at 390px in dark mode: one parent link, no sideways scroll, pinned after a 1500px scroll", async ({ page }) => {
    await page.addInitScript(() => localStorage.setItem("theme", "dark"));
    const row = await oneHeader(page, "/stack", "Every client's stack");
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    await expect(page.locator("html")).toHaveClass(/\bdark\b/);
    await expect(row.locator(".page-header-crumbs")).toBeHidden();
    const parent = row.locator("a.page-header-parent");
    await expect(parent).toBeVisible();
    await expect(parent).toContainText("Basement");
    const box = await row.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
    expect(await pinGapAfterScroll(page, "[data-test='stack-page'] > *")).toBe(0);
  });

  test("/agents/activities at 390px: the row fits the dark section's narrow gutter with no sideways scroll", async ({ page }) => {
    const row = await oneHeader(page, "/agents/activities", "Activities");
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    const box = await row.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
  });

  test.describe("signed out", () => {
    test.use({ storageState: { cookies: [], origins: [] } });

    test("/privacy at 390px: the long title wraps in the row, no trail, pinned after a 1500px scroll", async ({ page }) => {
      const row = await oneHeader(page, "/privacy", "Privacy Policy and Messaging Terms and Conditions");
      expect(await page.evaluate(() => window.innerWidth)).toBe(390);
      await expect(row.locator(".page-header-trail")).toHaveCount(0);
      expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
      expect(await pinGapAfterScroll(page, "[data-test='privacy-page'] > *")).toBe(0);
    });
  });
});

// dark-devops-header-polish: Shannon's three notes on the fixed-dark surfaces.
const DARK_PAGES = ["/mason/heartbeat", "/mason/heartbeat/activities", "/devops/insights", "/devops/pipeline", "/agents/activities"];

// WCAG contrast of two computed rgb() colours; the background is opaque or blended over
// the surface's own --hb-bg.
function contrastInPage(page, selector) {
  return page.evaluate((sel) => {
    const el = document.querySelector(sel);
    const parse = (c) => c.match(/[\d.]+/g).map(Number);
    const [fr, fg, fb] = parse(getComputedStyle(el).color);
    let [br, bg, bb, ba = 1] = parse(getComputedStyle(el).backgroundColor);
    const [sr, sg, sb] = [13, 17, 23]; // --hb-bg
    [br, bg, bb] = [br * ba + sr * (1 - ba), bg * ba + sg * (1 - ba), bb * ba + sb * (1 - ba)];
    const lum = (r, g, b) => [r, g, b].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; })
      .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
    const [hi, lo] = [lum(fr, fg, fb), lum(br, bg, bb)].sort((a, b) => b - a);
    return (hi + 0.05) / (lo + 0.05);
  }, selector);
}

test("the five dark pages' titles share one size: no inline h1 rule restyles the engine title", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const sizes = {};
  for (const path of DARK_PAGES) {
    await page.goto(path);
    const title = page.locator(".page-header h1.page-header-title");
    await expect(title).toHaveCount(1);
    sizes[path] = await title.evaluate((el) => `${getComputedStyle(el).fontSize} ${getComputedStyle(el).fontWeight}`);
  }
  expect(new Set(Object.values(sizes)).size, JSON.stringify(sizes)).toBe(1);
  expect(sizes["/devops/pipeline"]).not.toMatch(/^19px/);
});

test("the heartbeat dashboard at desktop keeps its fixed height and internal scroll; the pipeline keeps its column scroll", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/mason/heartbeat");
  const dash = await page.evaluate(() => {
    const s = document.querySelector("#mason-heartbeat");
    return { height: s.getBoundingClientRect().height, inner: window.innerHeight,
      fixed: getComputedStyle(s).height, scroll: getComputedStyle(s.querySelector(".hb-scroll")).overflowY };
  });
  expect(dash.height).toBeLessThan(dash.inner);
  expect(dash.scroll).toBe("auto");
  await page.goto("/devops/pipeline");
  const pipe = await page.evaluate(() => {
    const s = document.querySelector("#mason-heartbeat");
    const l = s.querySelector(".pl-grid .pl-list");
    return { height: s.getBoundingClientRect().height, inner: window.innerHeight,
      overflow: getComputedStyle(l).overflowY, max: getComputedStyle(l).maxHeight };
  });
  // The fixed dashboard height (heartbeat.css) holds on a desktop: the section ends above
  // the fold, and each column scrolls inside it.
  expect(pipe.height).toBeLessThan(pipe.inner);
  expect(pipe.overflow).toBe("auto");
  expect(pipe.max).not.toBe("none");
});

test("the pipeline at ~900px: the columns stack and the header stays pinned after a 1500px scroll", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 900 });
  await oneHeader(page, "/devops/pipeline", "🍽️ Distillation Pipeline");
  expect(await page.evaluate(() => window.innerWidth)).toBe(900);
  const columns = await page.evaluate(() => getComputedStyle(document.querySelector(".pl-grid")).gridTemplateColumns.split(" ").length);
  expect(columns, "the three columns stack under 1000px").toBe(1);
  expect(await pinGapAfterScroll(page, "#mason-heartbeat > *")).toBe(0);
});

for (const theme of ["light", "dark"]) test(`the Insight Bank in the ${theme} theme: the Links button and list wear the dark palette; the label passes 4.5:1; the stuck glass bar has no hairline`, async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript((t) => localStorage.setItem("theme", t), theme);
  const row = await oneHeader(page, "/devops/insights", "💡 Insight Bank");
  const button = row.locator(".page-header-menu-button");
  expect(await button.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(22, 27, 34)");
  expect(await button.evaluate((el) => getComputedStyle(el).color)).toBe("rgb(230, 237, 243)");
  const ratio = await contrastInPage(page, "#mason-insights > .page-header .page-header-menu-button");
  expect(ratio).toBeGreaterThanOrEqual(4.5);
  await button.click();
  const list = row.locator(".page-header-menu-list");
  await expect(list).toBeVisible();
  expect(await list.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(22, 27, 34)");
  expect(await list.locator(".page-header-menu-item").first().evaluate((el) => getComputedStyle(el).color)).toBe("rgb(230, 237, 243)");
  expect(await contrastInPage(page, "#mason-insights > .page-header .page-header-menu-item")).toBeGreaterThanOrEqual(4.5);
  await page.keyboard.press("Escape");
  await expect(page.locator("html")).toHaveAttribute("data-surface-style", "glass");
  expect(await pinGapAfterScroll(page, "#mason-insights > *")).toBe(0);
  await expect(row).toHaveAttribute("data-stuck", /.*/);
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(13, 17, 23)");
  await expect.poll(() => row.evaluate((el) => `${getComputedStyle(el).borderTopColor} ${getComputedStyle(el).borderBottomColor}`))
    .toBe("rgba(0, 0, 0, 0) rgba(0, 0, 0, 0)");
});

test.describe("the pipeline on a 390px phone", () => {
  test.use(PHONE);

  test("the columns stack and the header stays pinned after a 1500px scroll", async ({ page }) => {
    await oneHeader(page, "/devops/pipeline", "🍽️ Distillation Pipeline");
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    expect(await sidewaysScroll(page)).toBeLessThanOrEqual(0);
    expect(await pinGapAfterScroll(page, "#mason-heartbeat > *")).toBe(0);
  });
});
