// [e2e] The /logos table's columns (task logos-table-columns-tidy): the colour strip scrolls inside its own cell, so a
// brand with any number of colours keeps its row's height, and the page body never scrolls sideways at 375 px. The
// shipped palettes fit (eight at most), so the spec adds swatches in the browser to make one overflow.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function open(page, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/logos");
}

// Clones the brand's first swatch until its strip holds `count`, and reports the strip and its row.
async function growPalette(page, brand, count) {
  return page.evaluate(([brand, count]) => {
    const strip = document.querySelector(`[data-test='logo-colours'] [data-test='logo-palette'][data-brand='${brand}']`);
    const row = strip.closest("[data-test='logo-brand-row']");
    const before = row.getBoundingClientRect().height;
    while (strip.children.length < count) strip.appendChild(strip.children[0].cloneNode(true));
    return { before, after: row.getBoundingClientRect().height, scroll: strip.scrollWidth, client: strip.clientWidth,
             overflow: getComputedStyle(strip).overflowX, page: document.documentElement.scrollWidth,
             table: (({ scrollWidth, clientWidth }) => scrollWidth - clientWidth)(document.querySelector("[data-test='logo-table-scroll']")) };
  }, [brand, count]);
}

// Thirty colours scroll inside their cell without growing the row, the table's wrapper or the page.
async function expectStripScrolls(page, width) {
  await open(page, width);
  const grown = await growPalette(page, "studio", 30);
  expect(grown.overflow).toBe("auto");
  expect(grown.scroll).toBeGreaterThan(grown.client);
  expect(grown.after).toBe(grown.before);
  expect(grown.page).toBeLessThanOrEqual(width);
  expect(grown.table).toBe(0); // the table's own wrapper does not scroll sideways either

  const strip = page.locator("[data-test='logo-palette'][data-brand='studio']");
  await strip.evaluate((el) => { el.scrollLeft = el.scrollWidth; });
  expect(await strip.evaluate((el) => el.scrollLeft)).toBeGreaterThan(0);
  expect(await page.evaluate(() => window.scrollX)).toBe(0);
}

test("at 375 px thirty colours scroll inside their cell without growing the row or the page", async ({ page }) => {
  await expectStripScrolls(page, 375);
});

test("at 1280 px thirty colours scroll inside their cell without growing the row or the page", async ({ page }) => {
  await expectStripScrolls(page, 1280);
});

test("at 375 px every app and Google kit chip fits the screen", async ({ page }) => {
  await open(page, 375);
  const chips = page.locator("[data-test='kit-chip']");
  expect(await chips.count()).toBeGreaterThan(0);
  for (const box of await chips.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().toJSON()))) {
    expect(box.left).toBeGreaterThanOrEqual(0);
    expect(box.right).toBeLessThanOrEqual(375);
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(375);
});
