const { test, expect } = require("@playwright/test");

// [component] The /agents header links (Dreams, Activities feed, in the Links menu) and each agent
// row's docs link ("10 files": app/views/agents/index.html.erb; once a wall of
// role/soul/heartbeat chips, before the page became a table)
// sit on theme tokens, so they read in BOTH themes. They used white-alpha pills
// (border-white/10 bg-white/5 text-secondary) that all but vanished on the light
// page. Each pass flips the theme on <html> and measures each label against the
// ground it sits on.

const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");

const LINKS = "[data-test='agents-dreams-link'], [data-test='agents-activities-link']";
const CHIPS = "[data-test='agent-docs-link']";

// Dreams and the Activities feed are pages elsewhere, so they are the header's Links
// menu (studio-engine docs/PAGE_HEADER.md, "The four kinds of control"): the list opens
// from the Links button, and its items read against the list's own ground. The button
// is the engine's neutral .btn-sm, the one look every header control shares, so its
// label is measured here and its outline is the engine's to hold.
test("the /agents header links read in both themes", async ({ page }) => {
  await page.goto("/agents");
  const button = page.locator(".page-header .page-header-menu-button");
  await expect(button).toHaveText(/Links/);
  await button.click();
  await expect(page.locator("[data-test='agents-dreams-link']")).toBeVisible();
  await expect(page.locator("[data-test='agents-activities-link']")).toBeVisible();

  await eachTheme(page, async (theme) => {
    const labels = await page.evaluate(CONTRAST, LINKS);
    expect(labels.length, `${theme}: both links render`).toBe(2);
    for (const label of labels) {
      expect(label.ratio, `${theme}: "${label.text}" text contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
    for (const label of await page.evaluate(CONTRAST, ".page-header .page-header-menu-button")) {
      expect(label.ratio, `${theme}: the Links button label`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
});

test("the /agents docs links read in both themes", async ({ page }) => {
  await page.goto("/agents");
  await expect(page.locator(CHIPS).first()).toBeVisible();

  await eachTheme(page, async (theme) => {
    const labels = await page.evaluate(CONTRAST, CHIPS);
    expect(labels.length, `${theme}: the docs links render`).toBeGreaterThan(0);
    for (const label of labels) {
      expect(label.ratio, `${theme}: "${label.text}" docs link contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
});
