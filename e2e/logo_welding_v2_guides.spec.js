// [e2e] /logos/welding_v2?type=navbar&rule=3&guides=1 (task welding-llc-and-v2-helmet) —
// Commercial Welding v2's rule-of-3 guide drawings (its helmet is wider than v1's: the box
// is widened to centre it) fit their plates at 1280 without the plate scrolling, and the
// table lists v2 in the row after v1 so the two compare side by side.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const PAGE = "/logos/welding_v2?type=navbar&rule=3&guides=1";
const plates = (page) => page.locator("[data-scroll-tab-stop]");

async function open(page, path, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
  await page.waitForFunction(() =>
    [...document.querySelectorAll("img[data-test='logo-image']")].every((img) => img.complete && img.naturalWidth > 0)
  );
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("welding v2 rule-of-3 guides: every plate fits its drawing at 1280, with no plate scroll", async ({ page }) => {
  await open(page, PAGE, 1280);
  await expect(page.locator("h1")).toHaveText("Commercial Welding v2");
  await expect(page.locator("img[data-test='logo-image']").first()).toHaveAttribute("alt", /^Commercial Welding v2 navbar logo, rule of 3, .*construction guides/);

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

test("welding v1 and v2 sit in neighbouring rows of the logo table", async ({ page }) => {
  await open(page, "/logos", 1280);
  const brands = await page.locator("[data-test='logo-brand-row']").evaluateAll((rows) => rows.map((row) => row.dataset.brand));
  expect(brands.indexOf("welding_v2")).toBe(brands.indexOf("welding") + 1);
  await expect(page.locator("[data-test='logo-brand-row'][data-brand='welding'] th a")).toHaveText("Commercial Welding v1");
  await expect(page.locator("[data-test='logo-brand-row'][data-brand='welding_v2'] th a")).toHaveText("Commercial Welding v2");
});
