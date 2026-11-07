// [e2e] The landing's logo grid backdrop runs in a live browser (task
// logo-grid-backdrop): logo_grid.js builds the cells to fit the band, a tile
// under the pointer lights and keeps a fading trail when the pointer moves on,
// reduced motion gets a still grid, and a phone gets the wandering light with
// no sideways scroll. Every check reads state only a running script makes (the
// built cells, a cell's computed --lit), never markup.
// @qa-readonly: it only reads the signed-out home page.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, VISITOR } = require("./helpers");

test.use({ storageState: VISITOR });

// The --lit value of the cell nearest a viewport point, and that cell's index.
async function litNear(page, x, y) {
  return page.evaluate(([px, py]) => {
    const cells = [...document.querySelectorAll("[data-logo-grid] .logo-grid-cell")];
    let best = -1;
    let bestDistance = Infinity;
    cells.forEach((cell, i) => {
      const box = cell.getBoundingClientRect();
      const d = Math.hypot(box.left + box.width / 2 - px, box.top + box.height / 2 - py);
      if (d < bestDistance) { bestDistance = d; best = i; }
    });
    const lit = best < 0 ? 0 : parseFloat(getComputedStyle(cells[best]).getPropertyValue("--lit")) || 0;
    return { index: best, lit };
  }, [x, y]);
}

async function cellLit(page, index) {
  return page.evaluate((i) => {
    const cell = document.querySelectorAll("[data-logo-grid] .logo-grid-cell")[i];
    return parseFloat(getComputedStyle(cell).getPropertyValue("--lit")) || 0;
  }, index);
}

// The suite runs with reduced motion on (playwright.config.js contextOptions);
// a spec about this motion opts out per test, as that file says.
async function openBand(page, reducedMotion = "no-preference") {
  await page.emulateMedia({ reducedMotion });
  await blockThirdPartyRequests(page);
  await page.goto("/");
  const band = page.locator("[data-test=portfolio-band]");
  await band.scrollIntoViewIfNeeded();
  await expect.poll(async () => Number(await page.locator("[data-logo-grid]").getAttribute("data-logo-grid-cells"))).toBeGreaterThan(20);
  return band.boundingBox();
}

test("a tile under the pointer lights, then fades as the pointer moves on", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const box = await openBand(page);
  const here = { x: box.x + box.width * 0.15, y: box.y + box.height * 0.3 };
  await page.mouse.move(here.x, here.y);
  await page.mouse.move(here.x + 2, here.y + 2);
  const { index } = await litNear(page, here.x, here.y);
  await expect.poll(() => cellLit(page, index)).toBeGreaterThan(0.8);
  const peak = await cellLit(page, index);
  // Far across the band: the old tile keeps a trail for a moment, then fades.
  await page.mouse.move(box.x + box.width * 0.85, box.y + box.height * 0.7, { steps: 4 });
  await expect.poll(() => cellLit(page, index)).toBeLessThan(peak * 0.5);
});

test("reduced motion gets a still grid that never lights", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const box = await openBand(page, "reduce");
  const here = { x: box.x + box.width * 0.15, y: box.y + box.height * 0.3 };
  await page.mouse.move(here.x, here.y);
  await page.mouse.move(here.x + 4, here.y + 4);
  // Lighting the band is the script's own write; give it frames to make one.
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(done)))));
  const lit = await page.evaluate(() =>
    [...document.querySelectorAll("[data-logo-grid] .logo-grid-cell")].filter((c) => c.style.getPropertyValue("--lit") !== "").length);
  expect(lit).toBe(0);
});

test("a phone gets the wandering light and no sideways scroll", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await openBand(page);
  await expect.poll(() => page.evaluate(() =>
    Math.max(0, ...[...document.querySelectorAll("[data-logo-grid] .logo-grid-cell")]
      .map((c) => parseFloat(getComputedStyle(c).getPropertyValue("--lit")) || 0)))).toBeGreaterThan(0.5);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
