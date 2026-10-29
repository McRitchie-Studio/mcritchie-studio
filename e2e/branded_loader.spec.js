const { test, expect } = require("@playwright/test");
const { VISITOR, watchPageErrors } = require("./helpers");

// [e2e] The hub shows its branded loader during a slow navigation (task
// branded-app-loader; studio-engine docs/LOADER.md). The Studio style is
// Sparkle on the kit's violet icon. The overlay is hidden on arrival, shows
// once a Turbo visit outlasts its 350ms delay, and goes again when the page
// lands. (That a fast visit never flashes it is the engine's unit test,
// test/javascript/loader.test.mjs: a timing claim a CI browser cannot hold.)
// The slow server is simulated by holding
// the visit's response, so the spec needs no slow route of its own.

test.use({ storageState: VISITOR });

const overlay = (page) => page.locator("[data-studio-loader-overlay]");

async function holdResponses(page, pathname, ms) {
  await page.route((url) => url.pathname === pathname, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, ms));
    await route.continue();
  });
}

test("a slow navigation shows the Sparkle loader until the page arrives", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto("/about");
  await expect(overlay(page)).toBeHidden();

  await holdResponses(page, "/packages", 2000);
  await page.evaluate(() => window.Turbo.visit("/packages"));

  await expect(overlay(page)).toBeVisible({ timeout: 1500 });
  const loader = overlay(page).locator('.studio-loader[data-loader-style="sparkle"]');
  await expect(loader.locator("img.studio-loader-icon")).toHaveAttribute("src", "/brand/icon-dark.svg");
  await expect(loader.locator("path.studio-loader-sparkle")).toHaveCount(5);
  expect(await loader.locator("path.studio-loader-sparkle").first().evaluate((el) => getComputedStyle(el).animationName))
    .toBe("studio-loader-twinkle");

  await page.waitForURL("**/packages");
  await expect(overlay(page)).toBeHidden();
  expect(errors.pageErrors, errors.report()).toHaveLength(0);
});
