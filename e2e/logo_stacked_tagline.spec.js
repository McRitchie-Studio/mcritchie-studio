// [e2e] /logos/welding?type=stacked&form=tagline&guides=1 (task stacked-tagline-and-ghost-grid) —
// the widest guide drawing the gallery draws (Commercial Welding's tagline form, with its
// ruler of ghost copies beside it) fits its plate at 1280 without the plate scrolling, and at
// 375 the page body never scrolls sideways (the plate scrolls inside itself instead).
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const PAGE = "/logos/welding?type=stacked&form=tagline&guides=1";
const plates = (page) => page.locator("[data-scroll-tab-stop]");

async function open(page, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(PAGE);
  await page.waitForFunction(() =>
    [...document.querySelectorAll("[data-scroll-tab-stop] img")].every((img) => img.complete && img.naturalWidth > 0)
  );
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("welding tagline guides: every plate fits its drawing at 1280, with no plate scroll", async ({ page }) => {
  await open(page, 1280);
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("With tagline");
  await expect(page.locator("img[data-test='logo-image']").first()).toHaveAttribute("alt", /Commercial Welding stacked logo, with tagline, .*construction guides/);

  const count = await plates(page).count();
  expect(count).toBe(3);
  for (let i = 0; i < count; i++) {
    const plate = plates(page).nth(i);
    const fits = await plate.evaluate((el) => el.scrollWidth <= el.clientWidth);
    expect(fits, `plate ${i} fits its drawing at 1280`).toBe(true);
    await expect(plate).not.toHaveAttribute("tabindex", /.*/);
  }
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits).toBe(true);
});

test("welding tagline guides: at 375 the page body does not scroll sideways", async ({ page }) => {
  await open(page, 375);
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits, "the page body does not scroll sideways at 375").toBe(true);
  const plate = plates(page).first();
  expect(await plate.evaluate((el) => el.scrollWidth > el.clientWidth), "the plate scrolls inside itself instead").toBe(true);
  await expect(plate).toHaveAttribute("tabindex", "0");
});
