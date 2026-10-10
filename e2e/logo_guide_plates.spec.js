// [e2e] /logos/:brand?guides=1 — a guide drawing fits its plate on a desktop and
// scrolls inside it on a phone, and the plate is a keyboard stop only while it
// scrolls (app/javascript/scroll_tab_stop.js). The page body never scrolls sideways.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const plates = (page) => page.locator("[data-scroll-tab-stop]");

async function settle(page) {
  // Wait for every guide picture to load, so the plates have their final widths.
  await page.waitForFunction(() =>
    [...document.querySelectorAll("[data-scroll-tab-stop] img")].every((img) => img.complete && img.naturalWidth > 0)
  );
  // Give the ResizeObserver a frame to run after the last load.
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

for (const brand of ["industries", "studio"]) {
  test(`${brand}: guide plates fit at 1280 and are not tab stops`, async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginWithMagicLink(page, "alex@test.com");
    await page.goto(`/logos/${brand}?guides=1`);
    await settle(page);

    const count = await plates(page).count();
    expect(count).toBeGreaterThan(0);
    for (let i = 0; i < count; i++) {
      const plate = plates(page).nth(i);
      const fits = await plate.evaluate((el) => el.scrollWidth <= el.clientWidth);
      expect(fits, `plate ${i} fits its drawing at 1280`).toBe(true);
      await expect(plate).not.toHaveAttribute("tabindex", /.*/);
    }
    const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    expect(bodyFits).toBe(true);
  });

  test(`${brand}: guide plates scroll at 375 and are tab stops; the body does not scroll`, async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 800 });
    await loginWithMagicLink(page, "alex@test.com");
    await page.goto(`/logos/${brand}?guides=1`);
    await settle(page);

    const plate = plates(page).first();
    const scrolls = await plate.evaluate((el) => el.scrollWidth > el.clientWidth);
    expect(scrolls).toBe(true);
    await expect(plate).toHaveAttribute("tabindex", "0");

    const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
    expect(bodyFits, "the page body does not scroll sideways at 375").toBe(true);
  });
}
