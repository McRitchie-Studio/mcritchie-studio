// [e2e] Task navbar-spacing-and-rotated-guides — the two widest drawings this task makes fit their
// plates at 1280 with no plate scroll: the rule-of-6 Navbar Logo guides (capitals four rows of six,
// so the widest navbar drawing), and the tagline-form Stacked Logo guides, whose ruler copies are now
// tracked exactly as the real tagline is (Industries' is the widest drawing the gallery draws). At 375
// the page body never scrolls sideways.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const plates = (page) => page.locator("[data-scroll-tab-stop]");

async function open(page, path, width) {
  await page.setViewportSize({ width, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
  await page.waitForFunction(() =>
    [...document.querySelectorAll("[data-scroll-tab-stop] img")].every((img) => img.complete && img.naturalWidth > 0)
  );
  // Give the ResizeObserver a frame to run after the last load.
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

async function everyPlateFits(page) {
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
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("industries rule of 6 guides: the Rule control offers 3, 4 and 6, and every plate fits at 1280", async ({ page }) => {
  await open(page, "/logos/industries?rule=6&guides=1", 1280);
  await expect(page.locator("a[data-test='rule-option']")).toHaveText(["Rule of 3", "Rule of 4", "Rule of 6"]);
  await expect(page.locator("a[data-test='rule-option'][aria-current='true']")).toHaveText("Rule of 6");
  await expect(page.locator("img[data-test='logo-image']").first()).toHaveAttribute("alt", /McRitchie Industries navbar logo, rule of 6, .*construction guides/);
  await everyPlateFits(page);
});

test("industries tagline guides: every plate fits its tracked ruler at 1280", async ({ page }) => {
  await open(page, "/logos/industries?type=stacked&form=tagline&guides=1", 1280);
  await expect(page.locator("a[data-test='form-option'][aria-current='true']")).toHaveText("With tagline");
  await expect(page.locator("[data-test='guides-sentence']")).toContainText("one copy turned on end beside the icon");
  await everyPlateFits(page);
});

test("studio tagline guides: every plate fits at 1280", async ({ page }) => {
  await open(page, "/logos/studio?type=stacked&form=tagline&guides=1", 1280);
  await everyPlateFits(page);
});

test("industries rule of 6 guides: at 375 the page body does not scroll sideways", async ({ page }) => {
  await open(page, "/logos/industries?rule=6&guides=1", 375);
  const bodyFits = await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
  expect(bodyFits, "the page body does not scroll sideways at 375").toBe(true);
  const plate = plates(page).first();
  expect(await plate.evaluate((el) => el.scrollWidth > el.clientWidth), "the plate scrolls inside itself instead").toBe(true);
  await expect(plate).toHaveAttribute("tabindex", "0");
});
